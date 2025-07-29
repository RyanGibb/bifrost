(* Core types *)
type node_id = int
type edge_id = int
type port_id = int
type site_id = int
type region_id = int

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

module NodeSet = Set.Make (NodeId)
module EdgeSet = Set.Make (EdgeId)
module PortSet = Set.Make (PortId)
module SiteSet = Set.Make (SiteId)
module RegionSet = Set.Make (RegionId)
module NodeMap = Map.Make (NodeId)
module EdgeMap = Map.Make (EdgeId)
module PortMap = Map.Make (PortId)
module SiteMap = Map.Make (SiteId)
module RegionMap = Map.Make (RegionId)

(* ---------- controls & nodes ------------------------------------- *)
type control = { name : string; arity : int }

type property_value =
  | Bool of bool
  | Int of int
  | Float of float
  | String of string
  | Color of int * int * int

type properties = (string * property_value) list

type node = {
  id : node_id;
  control : control;
  ports : port_id list;
  properties : properties option;
}

(* ---------- id-graph --------------------------------------------- *)
type id_mapping = (string * node_id) list

(* ---------- link structures -------------------------------------- *)
type link = Closed of edge_id | Name of string
type linking = port_id -> link option

(* ---------- place & link graphs ---------------------------------- *)
type place_graph = {
  nodes : node NodeMap.t;
  parent_map : node_id NodeMap.t; (* child → parent *)
  sites : SiteSet.t;
  regions : RegionSet.t;
  site_parent_map : node_id SiteMap.t;
  region_nodes : NodeSet.t RegionMap.t;
}

type link_graph = {
  edges : EdgeSet.t;
  outer_names : string list;
  inner_names : string list;
  linking : linking;
}

(* ---------- whole bigraph ---------------------------------------- *)
type bigraph = {
  place : place_graph;
  link : link_graph;
  signature : control list;
  id_graph : id_mapping option;
}

(* ---------- interface wrappers ----------------------------------- *)
type interface = { sites : int; names : string list }

type bigraph_with_interface = {
  bigraph : bigraph;
  inner : interface;
  outer : interface;
}

(* ---------- empty skeletons -------------------------------------- *)
let empty_place_graph =
  {
    nodes = NodeMap.empty;
    parent_map = NodeMap.empty;
    sites = SiteSet.empty;
    regions = RegionSet.empty;
    site_parent_map = SiteMap.empty;
    region_nodes = RegionMap.empty;
  }

let empty_link_graph =
  {
    edges = EdgeSet.empty;
    outer_names = [];
    inner_names = [];
    linking = (fun _ -> None);
  }

let empty_bigraph signature =
  {
    place = empty_place_graph;
    link = empty_link_graph;
    signature;
    id_graph = None;
  }

(* ---------- constructors & helpers ------------------------------- *)
let create_control name arity = { name; arity }

let create_node ?props id control =
  let ports = List.init control.arity (fun i -> (id * 1000) + i) in
  { id; control; ports; properties = props }

(* ---- id-graph helpers ------------------------------------------- *)

let add_id_mapping bg uid nid =
  let m = match bg.id_graph with None -> [] | Some l -> l in
  { bg with id_graph = Some ((uid, nid) :: m) }

let find_node_by_unique_id bg uid =
  match bg.id_graph with None -> None | Some l -> List.assoc_opt uid l

let create_node_with_uid ?props uid id control bg =
  let node = create_node ?props id control in
  let bg_with_mapping = add_id_mapping bg uid id in
  (node, bg_with_mapping)

(* ---- property helpers ------------------------------------------- *)
let set_node_property node key value =
  let new_props =
    match node.properties with
    | None -> [ (key, value) ]
    | Some ps ->
        if List.exists (fun (k, _) -> k = key) ps then
          List.map (fun (k, v) -> if k = key then (k, value) else (k, v)) ps
        else (key, value) :: ps
  in
  { node with properties = Some new_props }

let get_node_property node key =
  match node.properties with None -> None | Some ps -> List.assoc_opt key ps

let update_node_property bg nid key value =
  match NodeMap.find_opt nid bg.place.nodes with
  | None -> bg
  | Some n ->
      let updated = set_node_property n key value in
      let nodes' = NodeMap.add nid updated bg.place.nodes in
      { bg with place = { bg.place with nodes = nodes' } }
