open Bigraph
open Bigraph_events 
open Utils

type pattern = bigraph_with_interface
type reaction_rule = { redex : pattern; reactum : pattern; name : string }

type match_result = {
  context       : bigraph_with_interface;
  parameter     : bigraph_with_interface;
  node_mapping  : (node_id * node_id) list;  (* redex → target *)
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
  | Some l ->
      List.find_opt (fun (_,nid) -> nid = n_id) l |> Option.map fst

let nodes_compatible pattern_bg pattern_node target_bg target_node =
  pattern_node.control = target_node.control &&
  match node_uid pattern_bg pattern_node.id with
  | None -> true                 (* no id constraint *)
  | Some uid -> node_uid target_bg target_node.id = Some uid

(* candidates inside target that are compatible with given pattern node *)
let candidate_nodes pattern_bg target_bg pattern_node =
  NodeMap.fold
    (fun tid tnode acc ->
        if nodes_compatible pattern_bg pattern_node target_bg tnode
        then tid :: acc else acc)
    target_bg.place.nodes []

(* spatial consistency helper *)
let parent_ok mapping pattern_bg target_bg p_child t_child =
  match get_parent pattern_bg p_child with
  | None -> get_parent target_bg t_child = None
  | Some p_parent ->
      let t_parent =
        List.assoc_opt p_parent mapping    (* mapped already? *)
      in
      match t_parent with
      | None -> true                       (* parent not mapped yet *)
      | Some t_parent_id ->
          get_parent target_bg t_child = Some t_parent_id

(* recursive back-tracking matcher *)
let find_structural_match pattern_bg target_bg =
  let pat_nodes = NodeMap.bindings pattern_bg.place.nodes in
  let rec aux todo mapping =
    match todo with
    | [] -> Some mapping
    | (pid,pnode) :: rest ->
        let rec try_cands = function
          | [] -> None
          | t_id :: more ->
              if List.exists (fun (_,tid) -> tid = t_id) mapping
              then try_cands more
              else if parent_ok mapping pattern_bg target_bg pid t_id then
                match aux rest ((pid,t_id)::mapping) with
                | Some m -> Some m
                | None   -> try_cands more
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
        NodeMap.filter (fun id _ -> not (List.mem id matched))
          target.bigraph.place.nodes
      in
      let context_place = { target.bigraph.place with nodes = remaining_nodes } in
      let context_bigraph = { target.bigraph with place = context_place } in
      {
        context =
          { bigraph = context_bigraph; inner = target.inner; outer = target.outer };
        parameter =
          { bigraph = empty_bigraph []; inner = {sites=0;names=[]}; outer = {sites=0;names=[]} };
        node_mapping;
      }

(* ------------------------------------------------------------------ *)
(*  Rule application (same naive implementation as before)            *)
(* ------------------------------------------------------------------ *)
(* let apply_rule rule target =
  try
    let match_result = match_pattern rule.redex target in

    (* 1. Apply reactum over redex match IDs *)
    let redex_to_target = match_result.node_mapping in

    let reactum_nodes_with_preserved_ids =
      NodeMap.fold (fun rid rnode acc ->
        match List.assoc_opt rid redex_to_target with
        | Some tid ->
            let node' = { rnode with id = tid } in
            NodeMap.add tid node' acc
        | None ->
            (* Keep original reactum node if not mapped *)
            NodeMap.add rid rnode acc
      ) rule.reactum.bigraph.place.nodes NodeMap.empty
    in

    (* 2. Merge with ALL unmatched context nodes so nothing gets deleted *)
    let new_nodes =
      NodeMap.union (fun _ _ r -> Some r)
        match_result.context.bigraph.place.nodes
        reactum_nodes_with_preserved_ids
    in

    (* 3. Update parent map — preserve original parents for unmatched nodes *)
    let reactum_parent_map_preserved =
      NodeMap.fold (fun child parent acc ->
        match List.assoc_opt child redex_to_target,
              List.assoc_opt parent redex_to_target
        with
        | Some new_child, Some new_parent ->
            NodeMap.add new_child new_parent acc
        | _ -> acc
      ) rule.reactum.bigraph.place.parent_map NodeMap.empty
    in

    let new_parent_map =
      NodeMap.union (fun _ _ r -> Some r)
        match_result.context.bigraph.place.parent_map
        reactum_parent_map_preserved
    in

    (* 4. Assemble new place graph *)
    let new_place = {
      nodes = new_nodes;
      parent_map = new_parent_map;
      sites = match_result.context.bigraph.place.sites;
      regions = match_result.context.bigraph.place.regions;
      site_parent_map = match_result.context.bigraph.place.site_parent_map;
      region_nodes = match_result.context.bigraph.place.region_nodes;
    } in

    let new_bigraph = {
      place = new_place;
      link = match_result.context.bigraph.link;
      signature = target.bigraph.signature;
      id_graph = target.bigraph.id_graph;  (* unchanged *)
    } in

    Some { target with bigraph = new_bigraph }

  with NoMatch _ -> None *)

let apply_rule_with_events rule target =
  try
    let match_result = match_pattern rule.redex target in
    let redex_to_target = match_result.node_mapping in

    let reactum_nodes_with_preserved_ids =
      NodeMap.fold (fun rid rnode acc ->
        match List.assoc_opt rid redex_to_target with
        | Some tid -> NodeMap.add tid { rnode with id = tid } acc
        | None -> NodeMap.add rid rnode acc
      ) rule.reactum.bigraph.place.nodes NodeMap.empty
    in

    let new_nodes =
      NodeMap.union (fun _ _ r -> Some r)
        match_result.context.bigraph.place.nodes
        reactum_nodes_with_preserved_ids
    in

    let reactum_parent_map_preserved =
      NodeMap.fold (fun child parent acc ->
        match List.assoc_opt child redex_to_target,
              List.assoc_opt parent redex_to_target
        with
        | Some new_child, Some new_parent ->
            NodeMap.add new_child new_parent acc
        | _ -> acc
      ) rule.reactum.bigraph.place.parent_map NodeMap.empty
    in

    let new_parent_map =
      NodeMap.union (fun _ _ r -> Some r)
        match_result.context.bigraph.place.parent_map
        reactum_parent_map_preserved
    in

    let new_place = {
      nodes = new_nodes;
      parent_map = new_parent_map;
      sites = match_result.context.bigraph.place.sites;
      regions = match_result.context.bigraph.place.regions;
      site_parent_map = match_result.context.bigraph.place.site_parent_map;
      region_nodes = match_result.context.bigraph.place.region_nodes;
    } in

    let new_bigraph = {
      place = new_place;
      link = match_result.context.bigraph.link;
      signature = target.bigraph.signature;
      id_graph = target.bigraph.id_graph;
    } in

    let events = [RuleApplied (rule.name, redex_to_target)] in
    Some ({ target with bigraph = new_bigraph }, events)

  with NoMatch _ -> None

(* ------------------------------------------------------------------ *)
(*  Backwards-compatible API                                          *)
(* ------------------------------------------------------------------ *)
let apply_rule rule target =
  match apply_rule_with_events rule target with
  | Some (state, _events) -> Some state
  | None -> None

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