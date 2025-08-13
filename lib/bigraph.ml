open Yojson.Safe

(* Core types *)
type node_id   = int
type edge_id   = int
type port_id   = int
type site_id   = int
type region_id = int

let schema_path = "../assets/schema.json"

(* ---------- ordered wrappers & containers ------------------------- *)

module NodeId = struct
  type t = node_id
  let compare = Int.compare
end

module EdgeId = struct
  type t = edge_id
  let compare = Int.compare
end

module PortId = struct
  type t = port_id
  let compare = Int.compare
end

module SiteId = struct
  type t = site_id
  let compare = Int.compare
end

module RegionId = struct
  type t = region_id
  let compare = Int.compare
end

module NodeSet   = Set.Make (NodeId)
module EdgeSet   = Set.Make (EdgeId)
module PortSet   = Set.Make (PortId)
module SiteSet   = Set.Make (SiteId)
module RegionSet = Set.Make (RegionId)

module NodeMap   = Map.Make (NodeId)
module EdgeMap   = Map.Make (EdgeId)
module PortMap   = Map.Make (PortId)
module SiteMap   = Map.Make (SiteId)
module RegionMap = Map.Make (RegionId)

(* ---------- controls & nodes ------------------------------------- *)
type control = { name : string; arity : int }

type property_type =
    | IntRange of (int * int)
    | TInt
    | TBool
    | TString of string list
    | TFloat
    | TColor

type property_value =
  | Bool   of bool
  | Int    of int
  | Float  of float
  | String of string
  | Color  of int * int * int

type properties = (string * property_value) list

let load_schema () =
  try
    let json = from_file schema_path in
    match json with
    | `Assoc bindings ->
        let schema_tbl = Hashtbl.create 10 in
        List.iter (fun (ctrl_name, ctrl_json) ->
          match ctrl_json with
          | `Assoc props ->
              let prop_tbl = Hashtbl.create 10 in
              List.iter (fun (prop_name, prop_def) ->
                match prop_def with
                | `Assoc fields ->
                    let typ_field = List.assoc "type" fields in
                    begin match typ_field with
                    | `String "int" ->
                        let range_field = try Some (List.assoc "range" fields) with _ -> None in
                        (match range_field with
                         | Some (`List [ `Int a; `Int b ]) ->
                             Hashtbl.add prop_tbl prop_name (IntRange (a, b))
                         | _ ->
                             Hashtbl.add prop_tbl prop_name TInt)
                    | `String "float" ->
                        Hashtbl.add prop_tbl prop_name TFloat (* TODO - add Float range *)
                    | `String "bool" ->
                        Hashtbl.add prop_tbl prop_name TBool
                    | `String "str" ->
                        let values_field = try Some (List.assoc "values" fields) with _ -> None in
                        let values = match values_field with
                          | Some (`List strs) -> List.map (function `String s -> s | _ -> "") strs
                          | _ -> []
                        in
                        Hashtbl.add prop_tbl prop_name (TString values)
                    | `String "color" ->
                        Hashtbl.add prop_tbl prop_name TColor
                    | _ -> failwith ("Unknown type: " ^ Yojson.Safe.to_string typ_field)
                    end
                | _ -> failwith ("Invalid property definition for " ^ prop_name)
              ) props;
              Hashtbl.add schema_tbl ctrl_name prop_tbl
          | _ -> failwith ("Invalid schema definition for " ^ ctrl_name)
        ) bindings;
        schema_tbl
    | _ -> failwith "Malformed schema file"
  with
  | _ -> Hashtbl.create 0

type node = {
  id         : node_id;
  control    : control;
  ports      : port_id list;
  properties : properties option;
}

(* ---------- id-graph --------------------------------------------- *)
type id_mapping = (string * node_id) list

(* ---------- link structures -------------------------------------- *)
type link    = Closed of edge_id | Name of string
type linking = port_id -> link option

(* ---------- place & link graphs ---------------------------------- *)
type place_graph = {
  nodes          : node NodeMap.t;
  parent_map     : node_id NodeMap.t;
  sites          : SiteSet.t;
  regions        : RegionSet.t;
  site_parent_map: node_id SiteMap.t;
  region_nodes   : NodeSet.t RegionMap.t;
}

type link_graph = {
  edges       : EdgeSet.t;
  outer_names : string list;
  inner_names : string list;
  linking     : linking;
}

(* ---------- whole bigraph ---------------------------------------- *)
type bigraph = {
  place    : place_graph;
  link     : link_graph;
  signature: control list;
  id_graph : id_mapping option;
}

(* ---------- interface wrappers ----------------------------------- *)
type interface = { sites : int; names : string list }

type bigraph_with_interface = {
  bigraph : bigraph;
  inner   : interface;
  outer   : interface;
}

(* ---------- empty skeletons -------------------------------------- *)
let empty_place_graph =
  { nodes          = NodeMap.empty
  ; parent_map     = NodeMap.empty
  ; sites          = SiteSet.empty
  ; regions        = RegionSet.empty
  ; site_parent_map= SiteMap.empty
  ; region_nodes   = RegionMap.empty
  }

let empty_link_graph =
  { edges       = EdgeSet.empty
  ; outer_names = []
  ; inner_names = []
  ; linking     = (fun _ -> None)
  }

let empty_bigraph signature =
  { place    = empty_place_graph
  ; link     = empty_link_graph
  ; signature
  ; id_graph = None
  }

(* ---------- constructors & helpers ------------------------------- *)
let create_control name arity = { name; arity }

let schema = load_schema ()

let validate_property control_name prop_name value =
  match Hashtbl.find_opt schema control_name with
  | None -> ()
  | Some prop_tbl ->
      match Hashtbl.find_opt prop_tbl prop_name with
      | None -> failwith (Printf.sprintf "Invalid property '%s' for control '%s'" prop_name control_name)
      | Some typ ->
          match typ, value with
          | IntRange (min, max), Int v when v >= min && v <= max -> ()
          | IntRange _, Int _ -> failwith "Integer value out of range"
          | TInt, Int _ -> ()
          | TBool, Bool _ -> ()
          | TString allowed, String s when List.mem s allowed -> ()
          | TColor, Color _ -> ()
          | _ -> failwith "Type mismatch for property"

let validate_properties control_name props =
  List.iter (fun (k, v) -> validate_property control_name k v) props

let create_node ?props id control =
  let ports = List.init control.arity (fun i -> id * 1000 + i) in
  Option.iter (validate_properties control.name) props;
  { id; control; ports; properties = props }

(* ---- id-graph helpers ------------------------------------------- *)
let add_id_mapping bg uid nid =
  let m = match bg.id_graph with None -> [] | Some l -> l in
  { bg with id_graph = Some ((uid,nid)::m) }

let find_node_by_unique_id bg uid =
  match bg.id_graph with
  | None -> None
  | Some l -> List.assoc_opt uid l

let create_node_with_uid ?props uid id control bg =
  let node = create_node ?props id control in
  let bg_with_mapping = add_id_mapping bg uid id in
  (node, bg_with_mapping)

(* ---- property helpers ------------------------------------------- *)
let get_node_property node key =
  match node.properties with
  | None -> None
  | Some ps -> List.assoc_opt key ps

let set_node_property node key value =
  validate_property node.control.name key value;
  let new_props =
    match node.properties with
    | None -> [key, value]
    | Some ps ->
        if List.exists (fun (k, _) -> k = key) ps then
          List.map (fun (k, v) -> if k = key then (k, value) else (k, v)) ps
        else (key, value) :: ps
  in
  { node with properties = Some new_props }

let update_node_property bg nid key value =
  match NodeMap.find_opt nid bg.place.nodes with
  | None -> bg
  | Some n ->
      let updated = set_node_property n key value in
      let nodes' = NodeMap.add nid updated bg.place.nodes in
      { bg with place = { bg.place with nodes = nodes' } }

let rec collect_descendants place root_id acc =
  let acc_with_root = NodeSet.add root_id acc in
  let children =
    NodeMap.fold (fun nid parent_id child_ids ->
      if parent_id = root_id then nid :: child_ids else child_ids
    ) place.parent_map []
  in
  List.fold_left (fun a child -> collect_descendants place child a) acc_with_root children

let project_bigraph (bg : bigraph) ~(root_ids : node_id list) : bigraph =
  let nodes_to_keep =
    List.fold_left (fun acc root ->
      collect_descendants bg.place root acc
    ) NodeSet.empty root_ids
  in
  let nodes =
    NodeMap.filter (fun nid _ -> NodeSet.mem nid nodes_to_keep) bg.place.nodes
  in
  let parent_map =
    NodeMap.filter (fun nid _ -> NodeSet.mem nid nodes_to_keep) bg.place.parent_map
  in
  let place = { bg.place with nodes; parent_map } in
  { bg with place }
