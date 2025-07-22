open Bigraph

(* Helper functions for spatial hierarchy *)
let get_parent bigraph node_id =
  NodeMap.find_opt node_id bigraph.place.parent_map

let get_children bigraph node_id =
  NodeMap.fold
    (fun child_id parent_id acc ->
      if parent_id = node_id then NodeSet.add child_id acc else acc)
    bigraph.place.parent_map NodeSet.empty

let get_root_nodes bigraph =
  NodeMap.fold
    (fun node_id _node acc ->
      if NodeMap.mem node_id bigraph.place.parent_map then acc
      else NodeSet.add node_id acc)
    bigraph.place.nodes NodeSet.empty

(* Basic node manipulation *)
let add_node_to_root bigraph node =
  let new_nodes = NodeMap.add node.id node bigraph.place.nodes in
  let new_place = { bigraph.place with nodes = new_nodes } in
  { bigraph with place = new_place }

let add_node_as_child bigraph parent_id child_node =
  if not (NodeMap.mem parent_id bigraph.place.nodes) then
    failwith ("Parent node " ^ string_of_int parent_id ^ " does not exist")
  else
    let new_nodes = NodeMap.add child_node.id child_node bigraph.place.nodes in
    let new_parent_map =
      NodeMap.add child_node.id parent_id bigraph.place.parent_map
    in
    let new_place =
      { bigraph.place with nodes = new_nodes; parent_map = new_parent_map }
    in
    { bigraph with place = new_place }

(* Legacy add_node function - adds to root for backward compatibility *)
let add_node bigraph node = add_node_to_root bigraph node

let remove_node bigraph node_id =
  let new_nodes = NodeMap.remove node_id bigraph.place.nodes in
  let new_parent_map = NodeMap.remove node_id bigraph.place.parent_map in
  (* Also remove any children's parent references *)
  let children = get_children bigraph node_id in
  let new_parent_map =
    NodeSet.fold
      (fun child_id acc -> NodeMap.remove child_id acc)
      children new_parent_map
  in
  let new_place =
    { bigraph.place with nodes = new_nodes; parent_map = new_parent_map }
  in
  { bigraph with place = new_place }

let move_node bigraph node_id new_parent_id =
  if not (NodeMap.mem node_id bigraph.place.nodes) then
    failwith ("Node " ^ string_of_int node_id ^ " does not exist")
  else if not (NodeMap.mem new_parent_id bigraph.place.nodes) then
    failwith ("Parent node " ^ string_of_int new_parent_id ^ " does not exist")
  else
    let new_parent_map =
      NodeMap.add node_id new_parent_id bigraph.place.parent_map
    in
    let new_place = { bigraph.place with parent_map = new_parent_map } in
    { bigraph with place = new_place }

let move_node_to_root bigraph node_id =
  if not (NodeMap.mem node_id bigraph.place.nodes) then
    failwith ("Node " ^ string_of_int node_id ^ " does not exist")
  else
    let new_parent_map = NodeMap.remove node_id bigraph.place.parent_map in
    let new_place = { bigraph.place with parent_map = new_parent_map } in
    { bigraph with place = new_place }

(* Link graph operations *)
let add_edge bigraph edge_id =
  let new_edges = EdgeSet.add edge_id bigraph.link.edges in
  let new_link = { bigraph.link with edges = new_edges } in
  { bigraph with link = new_link }

let remove_edge bigraph edge_id =
  let new_edges = EdgeSet.remove edge_id bigraph.link.edges in
  let new_link = { bigraph.link with edges = new_edges } in
  { bigraph with link = new_link }

let connect_ports bigraph port1 port2 edge_id =
  let new_edges = EdgeSet.add edge_id bigraph.link.edges in
  let new_linking port =
    if port = port1 || port = port2 then Some (Closed edge_id)
    else bigraph.link.linking port
  in
  let new_link =
    { bigraph.link with edges = new_edges; linking = new_linking }
  in
  { bigraph with link = new_link }

let link_to_name bigraph port name =
  let new_linking p =
    if p = port then Some (Name name) else bigraph.link.linking p
  in
  let new_link = { bigraph.link with linking = new_linking } in
  { bigraph with link = new_link }

(* Query functions *)
let get_node bigraph node_id = NodeMap.find_opt node_id bigraph.place.nodes
let get_link bigraph port_id = bigraph.link.linking port_id

let is_connected bigraph port1 port2 =
  match (get_link bigraph port1, get_link bigraph port2) with
  | Some (Closed e1), Some (Closed e2) -> e1 = e2
  | Some (Name n1), Some (Name n2) -> n1 = n2
  | _ -> false

let get_node_count bigraph = NodeMap.cardinal bigraph.place.nodes
let get_edge_count bigraph = EdgeSet.cardinal bigraph.link.edges
let get_site_count bigraph = SiteSet.cardinal bigraph.place.sites

let find_nodes_by_control bigraph control_name =
  NodeMap.filter
    (fun _ node -> node.control.name = control_name)
    bigraph.place.nodes

let find_nodes_with_parent bigraph parent_id =
  NodeMap.fold
    (fun child_id parent_id_map acc ->
      if parent_id_map = parent_id then NodeSet.add child_id acc else acc)
    bigraph.place.parent_map NodeSet.empty

let is_ancestor bigraph ancestor_id descendant_id =
  let rec check_parent current_id =
    match get_parent bigraph current_id with
    | None -> false
    | Some parent_id when parent_id = ancestor_id -> true
    | Some parent_id -> check_parent parent_id
  in
  check_parent descendant_id

(* Validation *)
let validate_bigraph bigraph =
  let validate_ports () =
    NodeMap.for_all
      (fun _ node -> List.length node.ports = node.control.arity)
      bigraph.place.nodes
  in

  let validate_signature () =
    NodeMap.for_all
      (fun _ node ->
        List.exists
          (fun control ->
            control.name = node.control.name
            && control.arity = node.control.arity)
          bigraph.signature)
      bigraph.place.nodes
  in

  let validate_parent_map () =
    NodeMap.for_all
      (fun _child_id parent_id -> NodeMap.mem parent_id bigraph.place.nodes)
      bigraph.place.parent_map
  in

  validate_ports () && validate_signature () && validate_parent_map ()

(* Printing with spatial hierarchy *)
let print_bigraph bigraph =
  Printf.printf "Bigraph:\n";
  Printf.printf "  Nodes: %d\n" (get_node_count bigraph);
  Printf.printf "  Edges: %d\n" (get_edge_count bigraph);
  Printf.printf "  Sites: %d\n" (get_site_count bigraph);

  let rec print_node_hierarchy indent node_id =
    match get_node bigraph node_id with
    | Some node ->
        Printf.printf "%sNode %d: %s (arity %d)\n" indent node_id
          node.control.name node.control.arity;
        let children = get_children bigraph node_id in
        NodeSet.iter (print_node_hierarchy (indent ^ "  ")) children
    | None -> ()
  in

  let root_nodes = get_root_nodes bigraph in
  NodeSet.iter (print_node_hierarchy "    ") root_nodes

let create_identity_bigraph interface =
  let bigraph = empty_bigraph [] in
  { bigraph; inner = interface; outer = interface }

let clone_node node new_id =
  let new_ports =
    List.map (fun p -> p + ((new_id - node.id) * 1000)) node.ports
  in
  { node with id = new_id; ports = new_ports }
