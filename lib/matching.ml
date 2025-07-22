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

    (* Create new nodes based on reactum, trying to preserve IDs from matched nodes *)
    let matched_node_ids = List.map snd match_result.node_mapping in
    let reactum_node_list = NodeMap.bindings rule.reactum.bigraph.place.nodes in

    let reactum_nodes_with_preserved_ids =
      let rec assign_ids reactum_nodes matched_ids acc =
        match (reactum_nodes, matched_ids) with
        | [], _ -> acc
        | (_, reactum_node) :: rest_reactum, original_id :: rest_matched ->
            (* Use original ID from matched target node *)
            let preserved_node =
              {
                reactum_node with
                id = original_id;
                ports =
                  List.mapi
                    (fun i _ -> (original_id * 1000) + i)
                    reactum_node.ports;
              }
            in
            assign_ids rest_reactum rest_matched
              (NodeMap.add original_id preserved_node acc)
        | (_, reactum_node) :: rest_reactum, [] ->
            (* No more original IDs, generate fresh ones *)
            let fresh_id =
              NodeMap.cardinal target.bigraph.place.nodes
              + 1000 + NodeMap.cardinal acc
            in
            let fresh_node =
              {
                reactum_node with
                id = fresh_id;
                ports =
                  List.mapi
                    (fun i _ -> (fresh_id * 1000) + i)
                    reactum_node.ports;
              }
            in
            assign_ids rest_reactum [] (NodeMap.add fresh_id fresh_node acc)
      in
      assign_ids reactum_node_list matched_node_ids NodeMap.empty
    in

    (* Merge context nodes with reactum nodes *)
    let new_nodes =
      NodeMap.fold NodeMap.add match_result.context.bigraph.place.nodes
        reactum_nodes_with_preserved_ids
    in

    (* Create parent map by combining context parent map with reactum structure, mapped to preserved IDs *)
    let original_to_preserved_id =
      let reactum_original_nodes =
        NodeMap.bindings rule.reactum.bigraph.place.nodes
      in
      let preserved_nodes = NodeMap.bindings reactum_nodes_with_preserved_ids in
      List.combine
        (List.map fst reactum_original_nodes)
        (List.map fst preserved_nodes)
    in

    let reactum_parent_map_fresh =
      NodeMap.fold
        (fun child_id parent_id acc ->
          match
            ( List.assoc_opt child_id original_to_preserved_id,
              List.assoc_opt parent_id original_to_preserved_id )
          with
          | Some preserved_child, Some preserved_parent ->
              NodeMap.add preserved_child preserved_parent acc
          | _ -> acc (* Skip if mapping not found *))
        rule.reactum.bigraph.place.parent_map NodeMap.empty
    in

    let new_parent_map =
      NodeMap.fold NodeMap.add match_result.context.bigraph.place.parent_map
        reactum_parent_map_fresh
    in

    let new_place =
      {
        nodes = new_nodes;
        parent_map = new_parent_map;
        sites = match_result.context.bigraph.place.sites;
        regions = match_result.context.bigraph.place.regions;
        site_parent_map = match_result.context.bigraph.place.site_parent_map;
        region_nodes = match_result.context.bigraph.place.region_nodes;
      }
    in

    let new_link =
      {
        edges = match_result.context.bigraph.link.edges;
        outer_names = target.bigraph.link.outer_names;
        inner_names = target.bigraph.link.inner_names;
        linking = match_result.context.bigraph.link.linking;
      }
    in

    let result_bigraph =
      {
        place = new_place;
        link = new_link;
        signature = target.bigraph.signature;
      }
    in

    Some { target with bigraph = result_bigraph }
  with NoMatch _ -> None

let create_rule name redex reactum = { redex; reactum; name }

let can_apply rule target =
  try
    let _ = match_pattern rule.redex target in
    true
  with NoMatch _ -> false
