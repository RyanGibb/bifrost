open Bigraph
open Utils

type pattern = bigraph_with_interface
type reaction_rule = { redex : pattern; reactum : pattern; name : string }

type match_result = {
  context : bigraph_with_interface;
  parameter : bigraph_with_interface;
  node_mapping : (node_id * node_id) list; (* redex → target *)
}

exception NoMatch of string
exception InvalidRule of string

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

(* ------------------------------------------------------------------ *)
(*  Node compatibility :                                              *)
(*   – control must match                                             *)
(*   – if the redex carries a unique-id, the target must carry SAME   *)
(* ------------------------------------------------------------------ *)
let node_uid bg n_id =
  match bg.id_graph with
  | None -> None
  | Some l -> List.find_opt (fun (_, nid) -> nid = n_id) l |> Option.map fst

let nodes_compatible pattern_bg pattern_node target_bg target_node =
  pattern_node.control = target_node.control
  &&
  match node_uid pattern_bg pattern_node.id with
  | None -> true (* no id constraint *)
  | Some uid -> node_uid target_bg target_node.id = Some uid

(* candidates inside target that are compatible with given pattern node *)
let candidate_nodes pattern_bg target_bg pattern_node =
  NodeMap.fold
    (fun tid tnode acc ->
      if nodes_compatible pattern_bg pattern_node target_bg tnode then
        tid :: acc
      else acc)
    target_bg.place.nodes []

(* spatial consistency helper *)
let parent_ok mapping pattern_bg target_bg p_child t_child =
  match get_parent pattern_bg p_child with
  | None -> get_parent target_bg t_child = None
  | Some p_parent -> (
      let t_parent =
        List.assoc_opt p_parent mapping
        (* mapped already? *)
      in
      match t_parent with
      | None -> true (* parent not mapped yet *)
      | Some t_parent_id -> get_parent target_bg t_child = Some t_parent_id)

(* recursive back-tracking matcher *)
let find_structural_match pattern_bg target_bg =
  let pat_nodes = NodeMap.bindings pattern_bg.place.nodes in
  let rec aux todo mapping =
    match todo with
    | [] -> Some mapping
    | (pid, pnode) :: rest ->
        let rec try_cands = function
          | [] -> None
          | t_id :: more ->
              if List.exists (fun (_, tid) -> tid = t_id) mapping then
                try_cands more
              else if parent_ok mapping pattern_bg target_bg pid t_id then
                match aux rest ((pid, t_id) :: mapping) with
                | Some m -> Some m
                | None -> try_cands more
              else try_cands more
        in
        try_cands (candidate_nodes pattern_bg target_bg pnode)
  in
  aux pat_nodes []

(* ------------------------------------------------------------------ *)
(*  PUBLIC matching API                                               *)
(* ------------------------------------------------------------------ *)
let match_pattern pattern target =
  match find_structural_match pattern.bigraph target.bigraph with
  | None -> raise (NoMatch "no structural match")
  | Some node_mapping ->
      (* build trivial context (everything unmatched) – simplified *)
      let matched = List.map snd node_mapping in
      let remaining_nodes =
        NodeMap.filter
          (fun id _ -> not (List.mem id matched))
          target.bigraph.place.nodes
      in
      let context_place =
        { target.bigraph.place with nodes = remaining_nodes }
      in
      let context_bigraph = { target.bigraph with place = context_place } in
      {
        context =
          {
            bigraph = context_bigraph;
            inner = target.inner;
            outer = target.outer;
          };
        parameter =
          {
            bigraph = empty_bigraph [];
            inner = { sites = 0; names = [] };
            outer = { sites = 0; names = [] };
          };
        node_mapping;
      }

(* ------------------------------------------------------------------ *)
(*  Rule application (same naive implementation as before)            *)
(* ------------------------------------------------------------------ *)
let apply_rule rule target =
  try
    let match_result = match_pattern rule.redex target in

    (* 1. Get redex → target mapping as lookup *)
    let redex_to_target = match_result.node_mapping in

    (* 2. Build reactum nodes where UIDs in redex are preserved *)
    let reactum_nodes_preserving_ids =
      NodeMap.fold
        (fun rid rnode acc ->
          match node_uid rule.reactum.bigraph rid with
          | Some uid -> (
              (* If this node existed in the redex, preserve its mapped ID *)
              let preserved_id =
                rule.redex.bigraph.place.nodes |> NodeMap.bindings
                |> List.find_map (fun (rid_redex, r) ->
                       if node_uid rule.redex.bigraph r.id = Some uid then
                         List.assoc_opt rid_redex redex_to_target
                       else None)
              in
              match preserved_id with
              | Some tid ->
                  let node' = { rnode with id = tid } in
                  NodeMap.add tid node' acc
              | None -> NodeMap.add rid rnode acc
              (* fallback to original reactum ID *))
          | None -> NodeMap.add rid rnode acc (* no UID, keep original *))
        rule.reactum.bigraph.place.nodes NodeMap.empty
    in

    (* 3. Merge with context (unmatched) nodes *)
    let new_nodes =
      NodeMap.union
        (fun _ _ r -> Some r)
        match_result.context.bigraph.place.nodes reactum_nodes_preserving_ids
    in

    (* 4. Update parent map based on reactum (using preserved IDs) *)
    let preserved_id_map =
      NodeMap.fold
        (fun old_id node acc -> (old_id, node.id) :: acc)
        reactum_nodes_preserving_ids []
    in

    let reactum_parent_map_preserved =
      NodeMap.fold
        (fun child parent acc ->
          match
            ( List.assoc_opt child preserved_id_map,
              List.assoc_opt parent preserved_id_map )
          with
          | Some new_child, Some new_parent ->
              NodeMap.add new_child new_parent acc
          | _ -> acc)
        rule.reactum.bigraph.place.parent_map NodeMap.empty
    in

    let new_parent_map =
      NodeMap.union
        (fun _ _ r -> Some r)
        match_result.context.bigraph.place.parent_map
        reactum_parent_map_preserved
    in

    (* 5. Assemble new place graph *)
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

    let new_bigraph =
      {
        place = new_place;
        link = match_result.context.bigraph.link;
        signature = target.bigraph.signature;
        id_graph = target.bigraph.id_graph;
        (* unchanged *)
      }
    in

    Some { target with bigraph = new_bigraph }
  with NoMatch _ -> None

(* ------------------------------------------------------------------ *)
(*  Rule repository helpers                                           *)
(* ------------------------------------------------------------------ *)
type rule_repo = reaction_rule list ref

let create_repo () = ref []
let add_rule repo rule = repo := rule :: !repo
let rules repo = !repo

let can_apply rule target =
  try
    let _ = match_pattern rule.redex target in
    true
  with NoMatch _ -> false

let create_rule name redex reactum = { redex; reactum; name }
