(*
  bridge.ml  —  apply a bigraph rewrite rule to a target bigraph
  FIX: re-parent reactum-only nodes under the correct matched parents
*)

open Bifrost
open Bifrost.Bigraph
open Bifrost.Utils
open Bifrost.Matching
module Api = Bigraph_capnp.Make (Capnp.BytesMessage)

(* --------------------------------------------------------------- *)
(* Cap'n Proto -> OCaml Bigraph                                    *)
(* --------------------------------------------------------------- *)

let propvalue_of_capnp (pv : Api.Reader.PropertyValue.t) : property_value =
  match Api.Reader.PropertyValue.get pv with
  | Api.Reader.PropertyValue.BoolVal b -> Bool b
  | Api.Reader.PropertyValue.IntVal i -> Int (Int32.to_int i)
  | Api.Reader.PropertyValue.FloatVal f -> Float f
  | Api.Reader.PropertyValue.StringVal s -> String s
  | Api.Reader.PropertyValue.ColorVal c ->
      let r = Api.Reader.PropertyValue.ColorVal.r_get c in
      let g = Api.Reader.PropertyValue.ColorVal.g_get c in
      let b = Api.Reader.PropertyValue.ColorVal.b_get c in
      Color (r, g, b)
  | Api.Reader.PropertyValue.Undefined _ -> String ""

let build_bigraph_with_interface (b : Api.Reader.Bigraph.t) :
    bigraph_with_interface =
  let nodes = Api.Reader.Bigraph.nodes_get_list b in
  (* signature: deduplicate controls by (name, arity) *)
  let signature_tbl : (string, control) Hashtbl.t =
    Hashtbl.create (List.length nodes)
  in
  List.iter
    (fun n ->
      let cname = Api.Reader.Node.control_get n in
      let arity = Api.Reader.Node.arity_get n |> Int32.to_int in
      if not (Hashtbl.mem signature_tbl cname) then
        Hashtbl.add signature_tbl cname (create_control cname arity))
    nodes;
  let signature = Hashtbl.to_seq_values signature_tbl |> List.of_seq in

  (* build OCaml nodes *)
  let node_tbl : (int, node) Hashtbl.t = Hashtbl.create (List.length nodes) in
  List.iter
    (fun n ->
      let id = Api.Reader.Node.id_get n |> Int32.to_int in
      if Hashtbl.mem node_tbl id then
        failwith (Printf.sprintf "Duplicate node ID: %d" id);
      let cname = Api.Reader.Node.control_get n in
      let control =
        match Hashtbl.find_opt signature_tbl cname with
        | Some c -> c
        | None ->
            create_control cname (Api.Reader.Node.arity_get n |> Int32.to_int)
      in
      let name = Api.Reader.Node.name_get n in
      let node_typ = Api.Reader.Node.type_get n in
      let ports = Api.Reader.Node.ports_get_list n |> List.map Int32.to_int in
      let props_list =
        let pls = Api.Reader.Node.properties_get_list n in
        if pls = [] then None
        else
          Some
            (List.map
               (fun p ->
                 let k = Api.Reader.Property.key_get p in
                 let v = propvalue_of_capnp (Api.Reader.Property.value_get p) in
                 (k, v))
               pls)
      in
      Hashtbl.add node_tbl id
        {
          id;
          name;
          node_type = node_typ;
          control;
          ports;
          properties = props_list;
        })
    nodes;

  (* assemble by parenting *)
  let bg_ref = ref (empty_bigraph signature) in
  List.iter
    (fun n ->
      let id = Api.Reader.Node.id_get n |> Int32.to_int in
      let parent = Api.Reader.Node.parent_get n |> Int32.to_int in
      let nd = Hashtbl.find node_tbl id in
      if parent = -1 then bg_ref := add_node_to_root !bg_ref nd
      else bg_ref := add_node_as_child !bg_ref parent nd)
    nodes;

  let site_count = Api.Reader.Bigraph.site_count_get b |> Int32.to_int in
  let names = Api.Reader.Bigraph.names_get_list b in
  {
    bigraph = !bg_ref;
    inner = { sites = site_count; names };
    outer = { sites = 0; names = [] };
  }

let read_message_from_file filename =
  let ic = open_in_bin filename in
  let len = in_channel_length ic in
  let raw = really_input_string ic len in
  close_in ic;
  let stream = Capnp.Codecs.FramedStream.of_string ~compression:`None raw in
  match Capnp.Codecs.FramedStream.get_next_frame stream with
  | Ok msg -> msg
  | Error _ -> failwith ("Failed to decode Cap'n Proto message from " ^ filename)

let load_rule_from_file (rule_file : string) : reaction_rule =
  let msg = read_message_from_file rule_file in
  let rr = Api.Reader.Rule.of_message msg in
  let redex = build_bigraph_with_interface (Api.Reader.Rule.redex_get rr) in
  let react = build_bigraph_with_interface (Api.Reader.Rule.reactum_get rr) in
  let name = Api.Reader.Rule.name_get rr in
  create_rule name redex react

let load_bigraph_from_file (path : string) : bigraph_with_interface =
  let msg = read_message_from_file path in
  let r = Api.Reader.Bigraph.of_message msg in
  build_bigraph_with_interface r

(* --------------------------------------------------------------- *)
(* OCaml Bigraph -> Cap'n Proto                                    *)
(* --------------------------------------------------------------- *)

let flatten_nodes_with_parents (bg : bigraph) : (int * int * node) list =
  let roots = get_root_nodes bg in
  let rec dfs acc parent_id nid =
    match get_node bg nid with
    | None -> acc
    | Some nd ->
        let acc' = (nid, parent_id, nd) :: acc in
        let children = get_children bg nid in
        NodeSet.fold (fun cid a -> dfs a nid cid) children acc'
  in
  NodeSet.fold (fun rid a -> dfs a (-1) rid) roots [] |> List.rev

let write_bigraph_to_file (gwi : bigraph_with_interface) (out_path : string) :
    unit =
  let flat = flatten_nodes_with_parents gwi.bigraph in
  let root = Api.Builder.Bigraph.init_root ~message_size:4096 () in
  Api.Builder.Bigraph.site_count_set root (Int32.of_int gwi.inner.sites);
  ignore (Api.Builder.Bigraph.names_set_list root gwi.inner.names);
  let nodes_arr = Api.Builder.Bigraph.nodes_init root (List.length flat) in
  List.iteri
    (fun i (id, parent, nd) ->
      let cn = Capnp.Array.get nodes_arr i in
      Api.Builder.Node.id_set_int_exn cn id;
      Api.Builder.Node.control_set cn nd.control.name;
      Api.Builder.Node.arity_set_int_exn cn nd.control.arity;
      Api.Builder.Node.parent_set_int_exn cn parent;
      Api.Builder.Node.name_set cn nd.name;
      Api.Builder.Node.type_set cn nd.node_type;
      ignore
        (Api.Builder.Node.ports_set_list cn (List.map Int32.of_int nd.ports));
      let props = match nd.properties with None -> [] | Some ps -> ps in
      let props_arr = Api.Builder.Node.properties_init cn (List.length props) in
      List.iteri
        (fun j (k, v) ->
          let p = Capnp.Array.get props_arr j in
          Api.Builder.Property.key_set p k;
          let pv = Api.Builder.Property.value_init p in
          match v with
          | Bool b -> Api.Builder.PropertyValue.bool_val_set pv b
          | Int n -> Api.Builder.PropertyValue.int_val_set_int_exn pv n
          | Float f -> Api.Builder.PropertyValue.float_val_set pv f
          | String s -> Api.Builder.PropertyValue.string_val_set pv s
          | Color (r, g, b) ->
              let c = Api.Builder.PropertyValue.color_val_init pv in
              Api.Builder.PropertyValue.ColorVal.r_set_exn c r;
              Api.Builder.PropertyValue.ColorVal.g_set_exn c g;
              Api.Builder.PropertyValue.ColorVal.b_set_exn c b)
        props)
    flat;
  let bytes =
    Capnp.Codecs.serialize ~compression:`None
      (Api.Builder.Bigraph.to_message root)
  in
  let oc = open_out_bin out_path in
  output_string oc bytes;
  close_out oc

(* --------------------------------------------------------------- *)
(* REPAIR: re-parent reactum-only nodes under their intended parent *)
(* --------------------------------------------------------------- *)

let props_subset (a : (string * property_value) list option)
    (b : (string * property_value) list option) : bool =
  match a with
  | None -> true
  | Some al ->
      let bl = match b with None -> [] | Some bl -> bl in
      List.for_all
        (fun (k, v) ->
          match List.assoc_opt k bl with Some v' -> v = v' | None -> false)
        al

let node_sig_match (needle : node) (hay : node) : bool =
  (* match by node_type + control, and require needle.props ⊆ hay.props *)
  needle.node_type = hay.node_type
  && needle.control.name = hay.control.name
  && props_subset needle.properties hay.properties

let nodes_by_id (bg : bigraph) : (int, node) Hashtbl.t =
  let tbl = Hashtbl.create 256 in
  let rec dfs nid =
    match get_node bg nid with
    | None -> ()
    | Some nd ->
        Hashtbl.replace tbl nid nd;
        let kids = get_children bg nid in
        NodeSet.iter dfs kids
  in
  let roots = get_root_nodes bg in
  NodeSet.iter dfs roots;
  tbl

let parent_map_of (bg : bigraph) : (int, int) Hashtbl.t =
  let pm = Hashtbl.create 256 in
  let rec dfs parent nid =
    Hashtbl.replace pm nid parent;
    get_children bg nid |> NodeSet.iter (dfs nid)
  in
  get_root_nodes bg |> NodeSet.iter (dfs (-1));
  pm

let signature_from_nodes (all : node list) : control list =
  let tbl = Hashtbl.create 64 in
  List.iter
    (fun nd ->
      if not (Hashtbl.mem tbl nd.control.name) then
        Hashtbl.add tbl nd.control.name nd.control)
    all;
  Hashtbl.to_seq_values tbl |> List.of_seq

let rebuild_with_parents (nodes : (int, node) Hashtbl.t)
    (parents : (int, int) Hashtbl.t) : bigraph =
  let all_nodes = Hashtbl.to_seq_values nodes |> List.of_seq in
  let signature = signature_from_nodes all_nodes in
  let bg_ref = ref (empty_bigraph signature) in
  let added = Hashtbl.create (Hashtbl.length nodes) in
  let rec pass () =
    let progressed = ref false in
    Hashtbl.iter
      (fun id nd ->
        if not (Hashtbl.mem added id) then
          let parent = Hashtbl.find parents id in
          if parent = -1 || Hashtbl.mem added parent then (
            if parent = -1 then bg_ref := add_node_to_root !bg_ref nd
            else bg_ref := add_node_as_child !bg_ref parent nd;
            Hashtbl.add added id true;
            progressed := true))
      nodes;
    if !progressed && Hashtbl.length added < Hashtbl.length nodes then pass ()
  in
  pass ();
  !bg_ref

let repair_parenting_of_new_nodes ~(rule : reaction_rule)
    ~(result : bigraph_with_interface) : bigraph_with_interface =
  let redex_pm = parent_map_of rule.redex.bigraph in
  let react_pm = parent_map_of rule.reactum.bigraph in

  (* Build a set of redex node ids for membership checks *)
  let redex_id_set =
    let s = Hashtbl.create 128 in
    Hashtbl.iter (fun k _ -> Hashtbl.replace s k true) redex_pm;
    s
  in
  let is_redex_id i = Hashtbl.mem redex_id_set i in

  (* New nodes are those present in the reactum but not in the redex *)
  let new_ids =
    Hashtbl.to_seq_keys react_pm
    |> List.of_seq
    |> List.filter (fun i -> not (is_redex_id i))
  in
  if new_ids = [] then result
  else
    let res_nodes = nodes_by_id result.bigraph in
    let res_parents = parent_map_of result.bigraph in

    (* depth in reactum to ensure parent-before-child processing *)
    let rec depth_of i =
      let p = Hashtbl.find react_pm i in
      if p = -1 then 0 else 1 + depth_of p
    in
    let new_ids_sorted =
      List.sort (fun a b -> compare (depth_of a) (depth_of b)) new_ids
    in

    (* cache mapping: reactum parent id -> resolved target id *)
    let resolved_parent : (int, int) Hashtbl.t = Hashtbl.create 64 in

    let find_matching_in_result (red_nd : node) : int option =
      let candidate = ref None in
      Hashtbl.iter
        (fun id nd ->
          if !candidate = None && node_sig_match red_nd nd then
            candidate := Some id)
        res_nodes;
      !candidate
    in

    let resolve_parent_id (rp : int) : int option =
      if rp = -1 then None
      else if Hashtbl.mem resolved_parent rp then
        Some (Hashtbl.find resolved_parent rp)
      else if not (is_redex_id rp) then (
        (* parent is also a new node: its id is preserved in the result *)
        Hashtbl.add resolved_parent rp rp;
        Some rp)
      else
        match get_node rule.redex.bigraph rp with
        | None -> None
        | Some redex_parent -> (
            match find_matching_in_result redex_parent with
            | Some id ->
                Hashtbl.add resolved_parent rp id;
                Some id
            | None -> None)
    in

    (* Update parent map for each new node based on reactum parents *)
    List.iter
      (fun nid ->
        match Hashtbl.find_opt react_pm nid with
        | None -> ()
        | Some rp -> (
            match resolve_parent_id rp with
            | None -> () (* leave as-is/root if we cannot resolve *)
            | Some target_parent_id ->
                Hashtbl.replace res_parents nid target_parent_id))
      new_ids_sorted;

    let repaired_bigraph = rebuild_with_parents res_nodes res_parents in
    { result with bigraph = repaired_bigraph }

(* --------------------------------------------------------------- *)
(* Main                                                             *)
(* --------------------------------------------------------------- *)

let () =
  if Array.length Sys.argv < 3 then (
    prerr_endline "Usage: bridge.exe <rule.capnp> <target.capnp>";
    exit 2);

  let rule_file = Sys.argv.(1) in
  let target_file = Sys.argv.(2) in

  let rule = load_rule_from_file rule_file in
  let target = load_bigraph_from_file target_file in

  Printf.printf "== Parsed redex ==\n";
  print_bigraph rule.redex.bigraph;
  Printf.printf "== Parsed reactum ==\n";
  print_bigraph rule.reactum.bigraph;
  Printf.printf "== Target bigraph ==\n";
  print_bigraph target.bigraph;

  let can = can_apply rule target in
  Printf.printf "Can apply rule: %b\n" can;

  match apply_rule rule target with
  | Some s0 ->
      let s = repair_parenting_of_new_nodes ~rule ~result:s0 in
      Printf.printf "Rule applied successfully!\n";
      Printf.printf "Result state:\n";
      print_bigraph s.bigraph;
      write_bigraph_to_file s target_file
  | None -> Printf.printf "Rule could not be applied\n"
