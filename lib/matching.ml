open Bigraph
open Utils

type pattern = bigraph_with_interface
type reaction_rule = { redex : pattern; reactum : pattern; name : string }

type match_result = {
  context : bigraph_with_interface;
  parameter : bigraph_with_interface;
  node_mapping : (node_id * node_id) list;
      (* (pattern_node_id, target_node_id) *)
}

exception NoMatch of string
exception InvalidRule of string

(* Check if two nodes are structurally compatible *)
let nodes_compatible pattern_node target_node =
  pattern_node.control.name = target_node.control.name
  && pattern_node.control.arity = target_node.control.arity

(* Find all nodes in target that match a given control *)
let find_matching_nodes target_bigraph (control_spec : control) =
  NodeMap.fold
    (fun id node acc ->
      if
        node.control.name = control_spec.name
        && node.control.arity = control_spec.arity
      then id :: acc
      else acc)
    target_bigraph.place.nodes []

(* Check if a spatial relationship exists in target *)
let has_containment_relationship target_bg parent_id child_id =
  match get_parent target_bg parent_id with
  | Some actual_parent -> actual_parent = child_id
  | None -> false

(* Try to find a structural match for the pattern in the target *)
let find_structural_match pattern_bg target_bg =
  let pattern_nodes = NodeMap.bindings pattern_bg.place.nodes in
  let rec try_match_nodes remaining_pattern acc_mapping =
    match remaining_pattern with
    | [] -> Some acc_mapping (* All pattern nodes matched *)
    | (pattern_id, pattern_node) :: rest ->
        let candidates = find_matching_nodes target_bg pattern_node.control in
        let rec try_candidates = function
          | [] -> None (* No valid candidate found *)
          | target_id :: other_candidates ->
              if
                List.exists
                  (fun (_, mapped_id) -> mapped_id = target_id)
                  acc_mapping
              then
                try_candidates other_candidates (* Target node already used *)
              else
                let new_mapping = (pattern_id, target_id) :: acc_mapping in
                (* Check if spatial relationships are preserved *)
                let spatial_ok =
                  match get_parent pattern_bg pattern_id with
                  | None ->
                      get_parent target_bg target_id = None (* Both at root *)
                  | Some pattern_parent_id -> (
                      match
                        List.find_opt
                          (fun (p_id, _) -> p_id = pattern_parent_id)
                          new_mapping
                      with
                      | None ->
                          true (* Parent not yet mapped, assume ok for now *)
                      | Some (_, target_parent_id) ->
                          get_parent target_bg target_id = Some target_parent_id
                      )
                in
                if spatial_ok then
                  match try_match_nodes rest new_mapping with
                  | Some final_mapping -> Some final_mapping
                  | None -> try_candidates other_candidates
                else try_candidates other_candidates
        in
        try_candidates candidates
  in
  try_match_nodes pattern_nodes []

let match_pattern pattern target =
  (* First check if the pattern can be structurally matched *)
  match find_structural_match pattern.bigraph target.bigraph with
  | None -> raise (NoMatch "No structural match found")
  | Some node_mapping ->
      (* Extract the context (target without matched nodes) *)
      let matched_target_nodes = List.map snd node_mapping in
      let remaining_nodes =
        NodeMap.filter
          (fun id _node -> not (List.mem id matched_target_nodes))
          target.bigraph.place.nodes
      in

      (* Create context place graph - keep parents even if their children were matched *)
      let context_parent_map =
        NodeMap.filter
          (fun child_id _parent_id ->
            not (List.mem child_id matched_target_nodes))
          target.bigraph.place.parent_map
      in

      let context_place =
        {
          nodes = remaining_nodes;
          parent_map = context_parent_map;
          sites = target.bigraph.place.sites;
          regions = target.bigraph.place.regions;
          site_parent_map = target.bigraph.place.site_parent_map;
          region_nodes = target.bigraph.place.region_nodes;
        }
      in

      let context_link =
        {
          edges = target.bigraph.link.edges;
          (* Simplified - should filter matched edges *)
          outer_names = target.bigraph.link.outer_names;
          inner_names = target.bigraph.link.inner_names;
          linking = target.bigraph.link.linking;
        }
      in

      let context_bigraph =
        {
          place = context_place;
          link = context_link;
          signature = target.bigraph.signature;
        }
      in

      let parameter_bigraph = empty_bigraph [] in

      {
        context =
          {
            bigraph = context_bigraph;
            inner = target.inner;
            outer = target.outer;
          };
        parameter =
          {
            bigraph = parameter_bigraph;
            inner = { sites = 0; names = [] };
            outer = { sites = 0; names = [] };
          };
        node_mapping;
      }

let apply_rule rule target =
  try
    let match_result = match_pattern rule.redex target in

    (* Build mapping from redex node IDs to matched target node IDs *)
    let redex_to_target_map = 
      List.fold_left (fun acc (redex_id, target_id) ->
        NodeMap.add redex_id target_id acc
      ) NodeMap.empty match_result.node_mapping in

    (* Start with ALL nodes from the original target (preserving their controls) *)
    let result_nodes = ref target.bigraph.place.nodes in
    let result_parent_map = ref target.bigraph.place.parent_map in

    (* Update parent relationships based on reactum structure *)
    NodeMap.iter (fun reactum_child_id reactum_parent_id ->
      (* Find corresponding nodes in the target *)
      let target_child_id = 
        (* Find which redex node corresponds to this reactum node *)
        let corresponding_redex_id = 
          (* This is tricky - we need to match based on structure/control *)
          (* For now, assume nodes with same control correspond *)
          let reactum_node = NodeMap.find reactum_child_id rule.reactum.bigraph.place.nodes in
          NodeMap.fold (fun redex_id redex_node acc ->
            if redex_node.control.name = reactum_node.control.name then redex_id else acc
          ) rule.redex.bigraph.place.nodes (-1) in
        
        if corresponding_redex_id <> -1 then
          try NodeMap.find corresponding_redex_id redex_to_target_map
          with Not_found -> reactum_child_id
        else reactum_child_id
      in
      
      let target_parent_id = 
        let reactum_parent = NodeMap.find reactum_parent_id rule.reactum.bigraph.place.nodes in
        let corresponding_redex_id = 
          NodeMap.fold (fun redex_id redex_node acc ->
            if redex_node.control.name = reactum_parent.control.name then redex_id else acc
          ) rule.redex.bigraph.place.nodes (-1) in
        
        if corresponding_redex_id <> -1 then
          try NodeMap.find corresponding_redex_id redex_to_target_map
          with Not_found -> reactum_parent_id
        else reactum_parent_id
      in
      
      (* Update the parent relationship *)
      result_parent_map := NodeMap.add target_child_id target_parent_id !result_parent_map
    ) rule.reactum.bigraph.place.parent_map;

    (* Remove parent mappings that should no longer exist *)
    NodeMap.iter (fun redex_child_id _ ->
      (* If this parent relationship doesn't exist in reactum, remove it *)
      let should_remove = 
        not (NodeMap.exists (fun _ _ -> true) rule.reactum.bigraph.place.parent_map) in
      if should_remove then
        let target_child_id = NodeMap.find redex_child_id redex_to_target_map in
        result_parent_map := NodeMap.remove target_child_id !result_parent_map
    ) rule.redex.bigraph.place.parent_map;

    let new_place = {
      nodes = !result_nodes;
      parent_map = !result_parent_map;
      sites = target.bigraph.place.sites;
      regions = target.bigraph.place.regions;
      site_parent_map = target.bigraph.place.site_parent_map;
      region_nodes = target.bigraph.place.region_nodes;
    } in

    let result_bigraph = {
      place = new_place;
      link = target.bigraph.link;
      signature = target.bigraph.signature;
    } in

    Some { target with bigraph = result_bigraph }
  with NoMatch _ -> None

let create_rule name redex reactum = { redex; reactum; name }

let can_apply rule target =
  try
    let _ = match_pattern rule.redex target in
    true
  with NoMatch _ -> false
