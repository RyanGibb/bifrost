(* lib/bigraph.mli *)

type node_id   = int
type edge_id   = int
type port_id   = int
type site_id   = int
type region_id = int

module NodeSet   : Set.S with type elt = node_id
module EdgeSet   : Set.S with type elt = edge_id
module PortSet   : Set.S with type elt = port_id
module SiteSet   : Set.S with type elt = site_id
module RegionSet : Set.S with type elt = region_id
module NodeMap   : Map.S with type key = node_id
module EdgeMap   : Map.S with type key = edge_id
module PortMap   : Map.S with type key = port_id
module SiteMap   : Map.S with type key = site_id
module RegionMap : Map.S with type key = region_id

type control = { name : string; arity : int }

(** Property type and values *)
type property_value =
  | Bool   of bool
  | Int    of int
  | Float  of float
  | String of string
  | Color  of int * int * int

type properties = (string * property_value) list

(** Node type *)
type node = {
  id         : node_id;
  control    : control;
  ports      : port_id list;
  properties : properties option;
}

(** ID mapping from unique identifier strings to node IDs *)
type id_mapping = (string * node_id) list

(** Links *)
type link    = Closed of edge_id | Name of string
type linking = port_id -> link option

(** Place graph structure *)
type place_graph = {
  nodes          : node NodeMap.t;
  parent_map     : node_id NodeMap.t;
  sites          : SiteSet.t;
  regions        : RegionSet.t;
  site_parent_map: node_id SiteMap.t;
  region_nodes   : NodeSet.t RegionMap.t;
}

(** Link graph structure *)
type link_graph = {
  edges       : EdgeSet.t;
  outer_names : string list;
  inner_names : string list;
  linking     : linking;
}

(** Bigraph structure *)
type bigraph = {
  place    : place_graph;
  link     : link_graph;
  signature: control list;
  id_graph : id_mapping option;
}

(** Interfaces and bigraph with interface *)
type interface = { sites : int; names : string list }

type bigraph_with_interface = {
  bigraph : bigraph;
  inner   : interface;
  outer   : interface;
}

(** Constructors *)
val empty_bigraph  : control list -> bigraph
val create_control : string -> int -> control
val create_node    : ?props:properties -> node_id -> control -> node
val create_node_with_uid :
  ?props:properties ->
  string -> node_id -> control -> bigraph ->
  node * bigraph

(** ID mapping utilities *)
val add_id_mapping         : bigraph -> string -> node_id -> bigraph
val find_node_by_unique_id : bigraph -> string -> node_id option

(** Property helpers *)
val set_node_property    : node -> string -> property_value -> node
val get_node_property    : node -> string -> property_value option
val update_node_property : bigraph -> node_id -> string -> property_value -> bigraph

(** Graph traversal *)
val collect_descendants : place_graph -> node_id -> NodeSet.t -> NodeSet.t
val project_bigraph     : bigraph -> root_ids:node_id list -> bigraph