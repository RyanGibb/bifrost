type node_id = int
type edge_id = int
type port_id = int
type site_id = int
type region_id = int

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

type control = { name : string; arity : int }
type node = { id : node_id; control : control; ports : port_id list }
type link = Closed of edge_id | Name of string
type linking = port_id -> link option

type place_graph = {
  nodes : node NodeMap.t;
  parent_map : node_id NodeMap.t; (* child_id -> parent_id *)
  sites : SiteSet.t;
  regions : RegionSet.t;
  site_parent_map : node_id SiteMap.t; (* site_id -> parent_node_id *)
  region_nodes : NodeSet.t RegionMap.t; (* region_id -> nodes in region *)
}

type link_graph = {
  edges : EdgeSet.t;
  outer_names : string list;
  inner_names : string list;
  linking : linking;
}

type bigraph = {
  place : place_graph;
  link : link_graph;
  signature : control list;
}

type interface = { sites : int; names : string list }

type bigraph_with_interface = {
  bigraph : bigraph;
  inner : interface;
  outer : interface;
}

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
  { place = empty_place_graph; link = empty_link_graph; signature }

let create_control name arity = { name; arity }

let create_node id control =
  let ports = List.init control.arity (fun i -> i + (id * 1000)) in
  { id; control; ports }
