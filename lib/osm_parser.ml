(** OSM JSON to Bigraph Parser

    This module parses the JSON output from bigraph-of-the-world (OpenStreetMap
    data converted to bigraph format) into the OCaml bigraph data structure. *)

open Bigraph
open Yojson.Safe.Util

(* Helper module for integer maps *)
module IntMap = Map.Make (Int)

(** Extract OSM ID string from control parameters if present *)
let extract_osm_id params =
  try
    match to_list params with
    | [] -> ""
    | hd :: _ -> hd |> member "ctrl_string" |> to_string
  with _ -> ""

(** Parse unique control definitions from the JSON *)
let parse_controls json =
  let ctrl_array = json |> member "nodes" |> member "ctrl" |> to_list in

  (* Extract unique control types from the array *)
  let ctrl_table = Hashtbl.create 10 in
  List.iter
    (fun ctrl_entry ->
      match ctrl_entry |> to_list with
      | _ :: def :: _ ->
          let name = def |> member "ctrl_name" |> to_string in
          let arity = def |> member "ctrl_arity" |> to_int in
          if not (Hashtbl.mem ctrl_table name) then
            Hashtbl.add ctrl_table name (create_control name arity)
      | _ -> ())
    ctrl_array;

  Hashtbl.fold (fun _ ctrl acc -> ctrl :: acc) ctrl_table []

(** Parse nodes from the JSON structure *)
let parse_nodes json _controls =
  let ctrl_array = json |> member "nodes" |> member "ctrl" |> to_list in
  let sort_array = json |> member "nodes" |> member "sort" |> to_list in

  (* Build map from node ID to (control, OSM ID) *)
  let ctrl_map =
    List.fold_left
      (fun acc ctrl_entry ->
        match ctrl_entry |> to_list with
        | [ id_json; def_json ] ->
            let id = id_json |> to_int in
            let name = def_json |> member "ctrl_name" |> to_string in
            let arity = def_json |> member "ctrl_arity" |> to_int in
            let params = def_json |> member "ctrl_params" in
            let osm_id = extract_osm_id params in
            let control = create_control name arity in
            IntMap.add id (control, osm_id) acc
        | _ -> acc)
      IntMap.empty ctrl_array
  in

  (* Create nodes grouped by type from the sorted structure *)
  List.fold_left
    (fun node_map sort_entry ->
      match sort_entry |> to_list with
      | [ type_json; ids_json ] ->
          let node_type = type_json |> to_string in
          let node_ids = ids_json |> to_list |> List.map to_int in
          let control = create_control node_type 1 in

          (* Create a node for each ID of this type *)
          List.fold_left
            (fun nm node_id ->
              (* Get OSM ID for this specific node if it exists *)
              let osm_id =
                try
                  let _, id = IntMap.find node_id ctrl_map in
                  id
                with Not_found -> ""
              in

              let node =
                if osm_id <> "" then
                  create_node
                    ~props:[ ("osm_id", String osm_id) ]
                    ~name:(node_type ^ "_" ^ string_of_int node_id)
                    ~node_type node_id control
                else
                  create_node
                    ~name:(node_type ^ "_" ^ string_of_int node_id)
                    ~node_type node_id control
              in
              NodeMap.add node_id node nm)
            node_map node_ids
      | _ -> node_map)
    NodeMap.empty sort_array

(** Parse place graph (hierarchical structure) from JSON *)
let parse_place_graph json nodes =
  let place = json |> member "place_graph" in
  let num_regions = place |> member "num_regions" |> to_int in

  (* Parse parent-child relationships from sparse matrix *)
  let nn = place |> member "nn" in
  let parent_map =
    try
      let r_major = nn |> member "r_major" |> to_list in
      List.fold_left
        (fun acc entry ->
          match entry |> to_list with
          | [ parent_json; children_json ] ->
              let parent_id = parent_json |> to_int in
              let children = children_json |> to_list |> List.map to_int in
              List.fold_left
                (fun m child_id -> NodeMap.add child_id parent_id m)
                acc children
          | _ -> acc)
        NodeMap.empty r_major
    with _ -> NodeMap.empty
  in

  (* Parse region-to-nodes mapping *)
  let region_nodes =
    try
      let rn = place |> member "rn" in
      let r_major = rn |> member "r_major" |> to_list in
      List.fold_left
        (fun acc entry ->
          match entry |> to_list with
          | [ region_json; nodes_json ] ->
              let region_id = region_json |> to_int in
              let node_ids = nodes_json |> to_list |> List.map to_int in
              RegionMap.add region_id (NodeSet.of_list node_ids) acc
          | _ -> acc)
        RegionMap.empty r_major
    with _ ->
      (* If no region mapping, put all nodes in region 0 *)
      RegionMap.singleton 0
        (NodeMap.fold (fun id _ acc -> NodeSet.add id acc) nodes NodeSet.empty)
  in

  {
    nodes;
    parent_map;
    sites = SiteSet.empty;
    regions = RegionSet.of_list (List.init num_regions (fun i -> i));
    site_parent_map = SiteMap.empty;
    region_nodes;
  }

(** Parse link graph (connections between nodes) from JSON *)
let parse_link_graph json _nodes =
  let links = json |> member "link_graph" |> to_list in
  let num_edges = List.length links in
  let edges = EdgeSet.of_list (List.init num_edges (fun i -> i)) in

  (* Build port-to-edge linking map *)
  let link_map =
    List.fold_left
      (fun (acc, edge_idx) link_obj ->
        let ports = link_obj |> member "ports" |> to_list in
        let new_map =
          List.fold_left
            (fun m port_entry ->
              match port_entry |> to_list with
              | [ port_json; _ ] ->
                  let port_id = port_json |> to_int in
                  PortMap.add port_id (Some (Closed edge_idx)) m
              | _ -> m)
            acc ports
        in
        (new_map, edge_idx + 1))
      (PortMap.empty, 0) links
    |> fst
  in

  let linking port_id =
    try PortMap.find port_id link_map with Not_found -> None
  in

  { edges; outer_names = []; inner_names = []; linking }

(** Main parser function - converts OSM JSON to bigraph *)
let parse_osm_json filename =
  let json = Yojson.Safe.from_file filename in

  let signature = parse_controls json in
  let nodes = parse_nodes json signature in
  let place = parse_place_graph json nodes in
  let link = parse_link_graph json nodes in

  { place; link; signature }

(* Search functions *)

(** Find a node by its OSM ID (e.g., "way 123456789") *)
let find_by_osm_id bigraph osm_id =
  NodeMap.fold
    (fun _node_id node acc ->
      match acc with
      | Some _ -> acc (* Already found *)
      | None -> (
          match node.properties with
          | Some props -> (
              match List.assoc_opt "osm_id" props with
              | Some (String id) when id = osm_id -> Some node
              | _ -> None)
          | None -> None))
    bigraph.place.nodes None

(** Find all nodes of a given type (e.g., "Building", "Street") *)
let find_by_type bigraph node_type =
  NodeMap.fold
    (fun _node_id node acc ->
      if node.node_type = node_type then node :: acc else acc)
    bigraph.place.nodes []

(** Find nodes whose name contains the given pattern *)
let find_by_name bigraph name_pattern =
  let pattern = String.lowercase_ascii name_pattern in
  NodeMap.fold
    (fun _node_id node acc ->
      if
        String.lowercase_ascii node.name
        |> String.split_on_char '_'
        |> List.exists (fun part -> part = pattern)
      then node :: acc
      else acc)
    bigraph.place.nodes []

(** Helper: Find control definition with specific OSM ID in raw JSON *)
let find_control_with_osm_id json osm_id =
  let ctrl_array = json |> member "nodes" |> member "ctrl" |> to_list in
  List.find_opt
    (fun ctrl_entry ->
      match ctrl_entry |> to_list with
      | [ _; def_json ] ->
          let params = def_json |> member "ctrl_params" in
          extract_osm_id params = osm_id
      | _ -> false)
    ctrl_array
