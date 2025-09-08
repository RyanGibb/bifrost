open Bigraph
open Bigraph_events 
open Utils

module NM = Bigraph.NodeMap
module NS = Bigraph.NodeSet

type pattern = bigraph_with_interface
type reaction_rule = { redex : pattern; reactum : pattern; name : string }

type match_result = {
  context       : bigraph_with_interface;
  parameter     : bigraph_with_interface;
  node_mapping  : (node_id * node_id) list;  
}

exception NoMatch of string
exception InvalidRule of string

let pattern_parent (pbg : bigraph) (pid:int) : int option =
  NM.find_opt pid pbg.place.parent_map

let compute_depths (pbg: bigraph) : (int, int) Hashtbl.t =
  let depth = Hashtbl.create 16 in
  let rec d pid =
    match Hashtbl.find_opt depth pid with
    | Some v -> v
    | None ->
        let v =
          match pattern_parent pbg pid with
          | None -> 0
          | Some p -> (d p) + 1
        in
        Hashtbl.add depth pid v; v
  in
  NM.iter (fun pid _ -> ignore (d pid)) pbg.place.nodes;
  depth

let find_matching_nodes target_bigraph (control_spec : control) =
  NodeMap.fold
    (fun id node acc ->
      if
        node.control.name = control_spec.name
        && node.control.arity = control_spec.arity
      then id :: acc
      else acc)
    target_bigraph.place.nodes []

let has_containment_relationship target_bg parent_id child_id =
  match get_parent target_bg parent_id with
  | Some actual_parent -> actual_parent = child_id
  | None -> false
  
(* ------------------------------------------------------------------ *)
(*  Node compatibility                                                *)
(* ------------------------------------------------------------------ *)

let props_include (reqs : (string * property_value) list)
                  (tprops_opt : (string * property_value) list option) =
  let tprops = match tprops_opt with None -> [] | Some ps -> ps in
  List.for_all (fun (k, v) ->
    match List.assoc_opt k tprops with Some v' -> v' = v | None -> false
  ) reqs

let nodes_compatible ?(check_name=false) ?(check_type=false)
    (pnode : node) (tnode : node) =
  let ctrl_ok = (pnode.control = tnode.control) in
  let name_ok = (not check_name) || pnode.name = tnode.name in
  let type_ok = (not check_type) || pnode.node_type = tnode.node_type in
  let props_ok =
    match pnode.properties with
    | None -> true
    | Some reqs -> props_include reqs tnode.properties
  in
  ctrl_ok && name_ok && type_ok && props_ok

let candidate_nodes target_bg (pnode : node) =
  let check_name = (String.length pnode.name > 0) in
  let check_type = (String.length pnode.node_type > 0) in
  NodeMap.fold
    (fun tid tnode acc ->
      if nodes_compatible ~check_name ~check_type pnode tnode then tid :: acc else acc)
    target_bg.place.nodes []
let parent_ok
    (pbg : bigraph) (tbg : bigraph)
    (mapping : (node_id * node_id) list)
    (p_child : node_id) (t_child : node_id)
  : bool =
  match NM.find_opt p_child pbg.place.parent_map with
  | None ->
      Utils.get_parent tbg t_child = None
  | Some p_parent ->
      match List.assoc_opt p_parent mapping with
      | None -> true
      | Some t_parent -> Utils.get_parent tbg t_child = Some t_parent

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
              else if parent_ok pattern_bg target_bg mapping pid t_id then
                match aux rest ((pid,t_id)::mapping) with
                | Some m -> Some m
                | None   -> try_cands more
              else try_cands more
        in
        try_cands (candidate_nodes target_bg pnode) 
  in
  aux pat_nodes []

(* ------------------------------------------------------------------ *)
(*  API                                                               *)
(* ------------------------------------------------------------------ *)

let match_pattern pattern target =
  match find_structural_match pattern.bigraph target.bigraph with
  | None -> raise (NoMatch "no structural match")
  | Some node_mapping ->
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


let build_control_index (target_bg : bigraph)
: ((string * int), int list) Hashtbl.t =
    let tbl = Hashtbl.create 16 in
    (NM.iter : (int -> node -> unit) -> node NM.t -> unit)
      (fun tid (tnode : node) ->
        let key = (tnode.control.name, tnode.control.arity) in
        let prev = match Hashtbl.find_opt tbl key with Some xs -> xs | None -> [] in
        Hashtbl.replace tbl key (tid :: prev)
      ) target_bg.place.nodes;
    tbl

let build_name_index (target_bg : bigraph) : (string, int list) Hashtbl.t =
    let tbl = Hashtbl.create 16 in
    (NM.iter : (int -> node -> unit) -> node NM.t -> unit)
      (fun tid (tnode : node) ->
        if String.length tnode.name > 0 then
          let prev = match Hashtbl.find_opt tbl tnode.name with Some xs -> xs | None -> [] in
          Hashtbl.replace tbl tnode.name (tid :: prev)
      ) target_bg.place.nodes;
    tbl

let build_child_index (target_bg : bigraph) : (int, int list) Hashtbl.t =
    let tbl = Hashtbl.create 16 in
    NM.iter (fun child parent ->
      let prev = match Hashtbl.find_opt tbl parent with Some xs -> xs | None -> [] in
      Hashtbl.replace tbl parent (child :: prev)
    ) target_bg.place.parent_map;
    tbl

let children_of (child_idx : (int, int list) Hashtbl.t) parent_id : int list =
    match Hashtbl.find_opt child_idx parent_id with Some xs -> xs | None -> []

let precompute_domains_and_order (pattern_bg : bigraph) (target_bg : bigraph)
    : (int, int list) Hashtbl.t * int array =
    let ctrl_idx = build_control_index target_bg in
    let cand_tbl : (int, int list) Hashtbl.t = Hashtbl.create 16 in
    let pat_nodes = NodeMap.bindings pattern_bg.place.nodes in
    List.iter (fun (pid, pnode) ->
      let base =
        match Hashtbl.find_opt ctrl_idx (pnode.control.name, pnode.control.arity) with
        | Some ids -> ids
        | None -> []
      in
      let check_name = String.length pnode.name > 0 in
      let check_type = String.length pnode.node_type > 0 in
      let filtered =
        List.filter (fun tid ->
          match NodeMap.find_opt tid target_bg.place.nodes with
          | Some tnode -> nodes_compatible ~check_name ~check_type pnode tnode
          | None -> false
        ) base
      in
      Hashtbl.replace cand_tbl pid filtered
    ) pat_nodes;
    let order =
      pat_nodes
      |> List.map (fun (pid, _) ->
            let sz = match Hashtbl.find_opt cand_tbl pid with Some l -> List.length l | None -> 0 in
            (pid, sz))
      |> List.sort (fun (_,a) (_,b) -> Int.compare a b)
      |> List.map fst
      |> Array.of_list
    in
    cand_tbl, order

let find_structural_matches_seq (pattern_bg : bigraph) (target_bg : bigraph)
  : ((node_id * node_id) list) Seq.t =
  let ctrl_idx  = build_control_index target_bg in
  let name_idx  = build_name_index   target_bg in
  let child_idx = build_child_index  target_bg in

  let pat_nodes = NM.bindings pattern_bg.place.nodes in
  let base_dom : (int, int list) Hashtbl.t = Hashtbl.create 16 in
  List.iter (fun (pid, pnode) ->
    let by_ctrl =
      match Hashtbl.find_opt ctrl_idx (pnode.control.name, pnode.control.arity) with
      | Some xs -> xs | None -> []
    in
    let by_name =
      if String.length pnode.name > 0
      then (match Hashtbl.find_opt name_idx pnode.name with Some ys -> ys | None -> [])
      else by_ctrl
    in
    let check_name = String.length pnode.name > 0 in
    let check_type = String.length pnode.node_type > 0 in
    let filtered =
      List.filter (fun tid ->
        match (NM.find_opt : int -> node NM.t -> node option) tid target_bg.place.nodes with
        | Some tnode -> nodes_compatible ~check_name ~check_type pnode tnode
        | None -> false
      ) by_name
    in
    Hashtbl.replace base_dom pid filtered
  ) pat_nodes;

  let depths = compute_depths pattern_bg in
  let order =
    pat_nodes
    |> List.map (fun (pid, _) ->
         let d  = match Hashtbl.find_opt depths pid with Some v -> v | None -> 0 in
         let sz = match Hashtbl.find_opt base_dom pid with Some l -> List.length l | None -> 0 in
         (pid, d, sz))
    |> List.sort (fun (_,d1,sz1) (_,d2,sz2) ->
         let c = Int.compare d1 d2 in if c <> 0 then c else Int.compare sz1 sz2)
    |> List.map (fun (pid,_,_) -> pid)
    |> Array.of_list
  in

  let parent_ok (mapping:(int*int) list) (p_child:int) (t_child:int) =
    match NM.find_opt p_child pattern_bg.place.parent_map with
    | None -> Utils.get_parent target_bg t_child = None
    | Some p_parent ->
        (match List.assoc_opt p_parent mapping with
         | None -> true
         | Some t_parent -> Utils.get_parent target_bg t_child = Some t_parent)
  in

  let children_of_parent tpar =
    match Hashtbl.find_opt child_idx tpar with Some xs -> xs | None -> []
  in

  let dyn_candidates (pid:int) (pnode:node) (mapping:(int*int) list) : int list =
    match NM.find_opt pid pattern_bg.place.parent_map with
    | Some ppar -> begin
        match List.assoc_opt ppar mapping with
        | Some tpar ->
            let kids = children_of_parent tpar in
            let check_name = String.length pnode.name > 0 in
            let check_type = String.length pnode.node_type > 0 in
            List.filter (fun tid ->
              match (NM.find_opt : int -> node NM.t -> node option) tid target_bg.place.nodes with
              | Some tnode -> nodes_compatible ~check_name ~check_type pnode tnode
              | None -> false
            ) kids
        | None ->
            (match Hashtbl.find_opt base_dom pid with Some l -> l | None -> [])
      end
    | None ->
        (match Hashtbl.find_opt base_dom pid with Some l -> l | None -> [])
  in

  let rec dfs k mapping used () =
    if k = Array.length order then
      Seq.Cons (List.rev mapping, (fun () -> Seq.Nil))  
    else
      let pid   = order.(k) in
      let pnode = (NM.find : int -> node NM.t -> node) pid pattern_bg.place.nodes in
      let cands = dyn_candidates pid pnode mapping in
      let rec loop = function
        | [] -> Seq.Nil
        | t_id :: more ->
            if NS.mem t_id used || not (parent_ok mapping pid t_id)
            then loop more
            else
              let mapping' = (pid, t_id) :: mapping in
              let used'    = NS.add t_id used in
              match dfs (k+1) mapping' used' () with
              | Seq.Nil -> loop more
              | Seq.Cons (v, kf) ->
                  Seq.Cons (v, fun () ->
                    match kf () with
                    | Seq.Nil -> loop more
                    | s -> s)
      in
      loop cands
  in
  dfs 0 [] NS.empty 

let find_structural_matches pattern_bg target_bg =
  find_structural_matches_seq pattern_bg target_bg |> List.of_seq

let match_all (pattern : pattern) (target : bigraph_with_interface)
  : (node_id * node_id) list list =
  find_structural_matches pattern.bigraph target.bigraph

(* ------------------------------------------------------------------ *)
(*  Rule app                                                          *)
(* ------------------------------------------------------------------ *)
let apply_rule_with_events rule target =
  try
    let match_result = match_pattern rule.redex target in
    let redex_to_target = match_result.node_mapping in

    let reactum_nodes_with_preserved_ids =
      NodeMap.fold (fun rid rnode acc ->
        match List.assoc_opt rid redex_to_target with
        | Some tid -> 
        
            let target_node = NodeMap.find tid target.bigraph.place.nodes in
            NodeMap.add tid { rnode with 
              id = tid; 
              name = target_node.name; 
              node_type = target_node.node_type 
            } acc
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
    } in

    let events = [RuleApplied (rule.name, redex_to_target)] in
    Some ({ target with bigraph = new_bigraph }, events)

  with NoMatch _ -> None

let apply_with_mapping (rule : reaction_rule)
  (target : bigraph_with_interface)
  (redex_to_target : (node_id * node_id) list) =
try
  let reactum_nodes_with_preserved_ids =
    NodeMap.fold (fun rid rnode acc ->
      match List.assoc_opt rid redex_to_target with
      | Some tid ->
          let target_node = NodeMap.find tid target.bigraph.place.nodes in
          NodeMap.add tid { rnode with
            id = tid; name = target_node.name; node_type = target_node.node_type } acc
      | None -> NodeMap.add rid rnode acc
    ) rule.reactum.bigraph.place.nodes NodeMap.empty
  in
  let new_nodes =
    NodeMap.union (fun _ _ r -> Some r)
      target.bigraph.place.nodes
      reactum_nodes_with_preserved_ids
  in
  let reactum_parent_map_preserved =
    NodeMap.fold (fun child parent acc ->
      match List.assoc_opt child redex_to_target,
            List.assoc_opt parent redex_to_target with
      | Some new_child, Some new_parent -> NodeMap.add new_child new_parent acc
      | _ -> acc
    ) rule.reactum.bigraph.place.parent_map NodeMap.empty
  in
  let new_parent_map =
    NodeMap.union (fun _ _ r -> Some r)
      target.bigraph.place.parent_map
      reactum_parent_map_preserved
  in
  let new_place = {
    nodes = new_nodes;
    parent_map = new_parent_map;
    sites = target.bigraph.place.sites;
    regions = target.bigraph.place.regions;
    site_parent_map = target.bigraph.place.site_parent_map;
    region_nodes = target.bigraph.place.region_nodes;
  } in
  let new_bigraph = {
    place = new_place;
    link = target.bigraph.link;
    signature = target.bigraph.signature;
  } in
  let events = [RuleApplied (rule.name, redex_to_target)] in
  Some ({ target with bigraph = new_bigraph }, events)
with _ -> None

let apply_rule_all (rule : reaction_rule) (target : bigraph_with_interface)
  : bigraph_with_interface =
  let embeddings = match_all rule.redex target in
  let used = ref NodeSet.empty in
  let choose m =
    let ids = List.map snd m in
    if List.for_all (fun id -> not (NodeSet.mem id !used)) ids
    then (List.iter (fun id -> used := NodeSet.add id !used) ids; true)
    else false
  in
  let selected = List.filter choose embeddings in
  List.fold_left (fun st mapping ->
    match apply_with_mapping rule st mapping with
    | Some (st', _) -> st'
    | None -> st
  ) target selected

let apply_rule rule target =
  match apply_rule_with_events rule target with
  | Some (state, _events) -> Some state
  | None -> None

(* ------------------------------------------------------------------ *)
(*  Helpers                                                           *)
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