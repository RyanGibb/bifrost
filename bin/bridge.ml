(*
  bridge.ml  —  apply a bigraph rewrite rule to a target bigraph
*)

open Bifrost 
open Bifrost.Bigraph 
open Bifrost.Utils 
open Bifrost.Matching

module Api = Bigraph_capnp.Make(Capnp.BytesMessage)

(* ----------------------- Cap'n Proto -> OCaml ----------------------- *)

let propvalue_of_capnp (pv : Api.Reader.PropertyValue.t) : property_value =
  match Api.Reader.PropertyValue.get pv with
  | Api.Reader.PropertyValue.BoolVal b   -> Bool b
  | Api.Reader.PropertyValue.IntVal i    -> Int (Int32.to_int i)
  | Api.Reader.PropertyValue.FloatVal f  -> Float f
  | Api.Reader.PropertyValue.StringVal s -> String s
  | Api.Reader.PropertyValue.ColorVal c  ->
      let r = Api.Reader.PropertyValue.ColorVal.r_get c in
      let g = Api.Reader.PropertyValue.ColorVal.g_get c in
      let b = Api.Reader.PropertyValue.ColorVal.b_get c in
      Color (r, g, b)
  | Api.Reader.PropertyValue.Undefined _ -> String ""

let build_bigraph_with_interface (b : Api.Reader.Bigraph.t) : bigraph_with_interface =
  let nodes = Api.Reader.Bigraph.nodes_get_list b in

  (* signature from controls *)
  let signature_tbl : (string, control) Hashtbl.t =
    Hashtbl.create (List.length nodes)
  in
  List.iter
    (fun n ->
      let cname = Api.Reader.Node.control_get n in
      let arity = Api.Reader.Node.arity_get_int_exn n in
      if not (Hashtbl.mem signature_tbl cname) then
        Hashtbl.add signature_tbl cname (create_control cname arity))
    nodes;
  let signature = Hashtbl.to_seq_values signature_tbl |> List.of_seq in

  (* build nodes *)
  let node_tbl : (int, node) Hashtbl.t = Hashtbl.create (List.length nodes) in
  List.iter
    (fun n ->
      let id = Api.Reader.Node.id_get_int_exn n in
      if Hashtbl.mem node_tbl id then
        failwith (Printf.sprintf "Duplicate node ID in input: %d" id);

      let cname   = Api.Reader.Node.control_get n in
      let control =
        match Hashtbl.find_opt signature_tbl cname with
        | Some c -> c
        | None   -> create_control cname (Api.Reader.Node.arity_get_int_exn n)
      in

      let name     = Api.Reader.Node.name_get n in
      let node_typ = Api.Reader.Node.type_get n in
      let ports    = List.map Int32.to_int (Api.Reader.Node.ports_get_list n) in

      let props_list =
        let pls = Api.Reader.Node.properties_get_list n in
        if pls = [] then None
        else
          Some (List.map
                  (fun p ->
                     let k = Api.Reader.Property.key_get p in
                     let v = propvalue_of_capnp (Api.Reader.Property.value_get p) in
                     (k, v))
                  pls)
      in

      let node =
        { id; name; node_type = node_typ; control; ports; properties = props_list }
      in
      Hashtbl.add node_tbl id node)
    nodes;

  (* assemble bigraph (parenting) *)
  let bg_ref = ref (empty_bigraph signature) in
  List.iter
    (fun n ->
      let id     = Api.Reader.Node.id_get_int_exn n in
      let parent = Api.Reader.Node.parent_get_int_exn n in
      let node   = Hashtbl.find node_tbl id in
      if parent = -1 then
        bg_ref := add_node_to_root !bg_ref node
      else
        bg_ref := add_node_as_child !bg_ref parent node)
    nodes;

  let site_count = Api.Reader.Bigraph.site_count_get_int_exn b in
  let names      = Api.Reader.Bigraph.names_get_list b in
  {
    bigraph = !bg_ref;
    inner   = { sites = site_count; names };
    outer   = { sites = 0; names = [] };
  }

let read_message_from_file filename =
  let ic = open_in_bin filename in
  let len = in_channel_length ic in
  let raw = really_input_string ic len in
  close_in ic;
  let stream = Capnp.Codecs.FramedStream.of_string ~compression:`None raw in
  match Capnp.Codecs.FramedStream.get_next_frame stream with
  | Ok msg   -> msg
  | Error _  -> failwith ("Failed to decode Cap'n Proto message from " ^ filename)

let load_rule_from_file (rule_file : string) : reaction_rule =
  let msg = read_message_from_file rule_file in
  let rr  = Api.Reader.Rule.of_message msg in
  let red = build_bigraph_with_interface (Api.Reader.Rule.redex_get rr) in
  let rct = build_bigraph_with_interface (Api.Reader.Rule.reactum_get rr) in
  let nm  = Api.Reader.Rule.name_get rr in
  create_rule nm red rct

let load_bigraph_from_file (path : string) : bigraph_with_interface =
  let msg = read_message_from_file path in
  let r   = Api.Reader.Bigraph.of_message msg in
  build_bigraph_with_interface r

(* ----------------------- OCaml -> Cap'n Proto ----------------------- *)

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

let write_bigraph_to_file (gwi : bigraph_with_interface) (out_path : string) : unit =
  let flat = flatten_nodes_with_parents gwi.bigraph in
  let root = Api.Builder.Bigraph.init_root ~message_size:4096 () in

  Api.Builder.Bigraph.site_count_set_int_exn root gwi.inner.sites;
  ignore (Api.Builder.Bigraph.names_set_list root gwi.inner.names);

  let nodes_arr = Api.Builder.Bigraph.nodes_init root (List.length flat) in
  List.iteri
    (fun i (id, parent, nd) ->
      let cn = Capnp.Array.get nodes_arr i in
      Api.Builder.Node.id_set_int_exn      cn id;
      Api.Builder.Node.control_set         cn nd.control.name;
      Api.Builder.Node.arity_set_int_exn   cn nd.control.arity;
      Api.Builder.Node.parent_set_int_exn  cn parent;
      Api.Builder.Node.name_set            cn nd.name;
      Api.Builder.Node.type_set            cn nd.node_type;

      (* ports *)
      let ports32 = List.map Int32.of_int nd.ports in
      ignore (Api.Builder.Node.ports_set_list cn ports32);

      (* properties *)
      let props = match nd.properties with None -> [] | Some ps -> ps in
      let props_arr = Api.Builder.Node.properties_init cn (List.length props) in
      List.iteri
        (fun j (k, v) ->
          let p  = Capnp.Array.get props_arr j in
          Api.Builder.Property.key_set p k;
          let pv = Api.Builder.Property.value_init p in
          match v with
          | Bool b   -> Api.Builder.PropertyValue.bool_val_set   pv b
          | Int  n   -> Api.Builder.PropertyValue.int_val_set_int_exn    pv n
          | Float f  -> Api.Builder.PropertyValue.float_val_set  pv f
          | String s -> Api.Builder.PropertyValue.string_val_set pv s
          | Color (r,g,b) ->
              let c = Api.Builder.PropertyValue.color_val_init pv in
              Api.Builder.PropertyValue.ColorVal.r_set_exn c r;
              Api.Builder.PropertyValue.ColorVal.g_set_exn c g;
              Api.Builder.PropertyValue.ColorVal.b_set_exn c b)
        props)
    flat;

  let bytes = Capnp.Codecs.serialize ~compression:`None (Api.Builder.Bigraph.to_message root) in
  let oc = open_out_bin out_path in
  output_string oc bytes;
  close_out oc

(* ------------------------------ Main ------------------------------- *)

let () =
  if Array.length Sys.argv < 3 then begin
    prerr_endline "Usage: bridge.exe <rule.capnp> <target.capnp>";
    exit 2
  end;

  let rule_file   = Sys.argv.(1) in
  let target_file = Sys.argv.(2) in

  let rule   = load_rule_from_file rule_file in
  let target = load_bigraph_from_file target_file in

  Printf.printf "== Parsed redex ==\n";   print_bigraph rule.redex.bigraph;
  Printf.printf "== Parsed reactum ==\n"; print_bigraph rule.reactum.bigraph;
  Printf.printf "== Target bigraph ==\n"; print_bigraph target.bigraph;

  let can = can_apply rule target in
  Printf.printf "Can apply rule: %b\n" can;

  match apply_rule rule target with
  | Some result_state ->
      Printf.printf "Rule applied successfully!\n";
      Printf.printf "Result state:\n"; print_bigraph result_state.bigraph;
      write_bigraph_to_file result_state target_file
  | None ->
      Printf.printf "Rule could not be applied\n"