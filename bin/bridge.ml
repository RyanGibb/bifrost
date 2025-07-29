open Bifrost
open Bifrost.Bigraph
open Bifrost.Utils
open Bifrost.Matching
module Api = Bifrost.Bigraph_rpc.Make (Capnp.BytesMessage)

(* ------------------------------------------------------------------ *)
let build (b : Api.Reader.Bigraph.t) : bigraph_with_interface =
  let nodes = Api.Reader.Bigraph.nodes_get_list b in
  let signature_tbl = Hashtbl.create (List.length nodes) in
  let node_tbl = Hashtbl.create (List.length nodes) in

  (* build signature with deduplicated controls *)
  List.iter
    (fun n ->
      let control_name = Api.Reader.Node.control_get n in
      let arity = Api.Reader.Node.arity_get n |> Int32.to_int in
      if not (Hashtbl.mem signature_tbl control_name) then
        Hashtbl.add signature_tbl control_name
          (create_control control_name arity))
    nodes;

  let signature = Hashtbl.to_seq_values signature_tbl |> List.of_seq in

  (* create node objects, with optional properties *)
  List.iter
    (fun n ->
      let id = Api.Reader.Node.id_get n |> Int32.to_int in
      let control_name = Api.Reader.Node.control_get n in
      let c = Hashtbl.find signature_tbl control_name in
      let props =
        let pl = Api.Reader.Node.properties_get_list n in
        if pl = [] then None
        else
          Some
            (List.map
               (fun p ->
                 let key = Api.Reader.Property.key_get p in
                 let value =
                   match
                     Api.Reader.PropertyValue.get
                       (Api.Reader.Property.value_get p)
                   with
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
                 in
                 (key, value))
               pl)
      in
      Hashtbl.add node_tbl id (create_node ?props id c))
    nodes;

  let bg = ref (empty_bigraph signature) in

  List.iter
    (fun n ->
      let id = Api.Reader.Node.id_get n |> Int32.to_int in
      let node = Hashtbl.find node_tbl id in
      let parent = Api.Reader.Node.parent_get n |> Int32.to_int in
      if parent = -1 then bg := add_node_to_root !bg node
      else bg := add_node_as_child !bg parent node)
    nodes;

  let site_count = Api.Reader.Bigraph.site_count_get b |> Int32.to_int in
  let names = Api.Reader.Bigraph.names_get_list b in

  {
    bigraph = !bg;
    inner = { sites = site_count; names };
    outer = { sites = 0; names = [] };
  }

let add_rule (r : Api.Reader.Rule.t) : reaction_rule =
  let redex = build (Api.Reader.Rule.redex_get r) in
  let reactum = build (Api.Reader.Rule.reactum_get r) in
  create_rule (Api.Reader.Rule.name_get r) redex reactum

let read_message_from_file filename =
  let ic = open_in_bin filename in
  let len = in_channel_length ic in
  let raw = really_input_string ic len in
  close_in ic;

  let stream = Capnp.Codecs.FramedStream.of_string ~compression:`None raw in
  match Capnp.Codecs.FramedStream.get_next_frame stream with
  | Ok msg -> msg
  | Error _ -> failwith "Failed to decode Cap'n Proto message"

let () =
  let rule_file = Stdlib.Array.get Sys.argv 1 in
  let target_file = Stdlib.Array.get Sys.argv 2 in
  (* let rule_msg = Capnp.Message.read_file rule_file in *)

  let rule_msg = read_message_from_file rule_file in
  let rule_reader = Api.Reader.Rule.of_message rule_msg in
  let rule = add_rule rule_reader in

  let target_msg = read_message_from_file target_file in
  let target_reader = Api.Reader.Bigraph.of_message target_msg in
  let target = build target_reader in

  Printf.printf "== Parsed redex ==\n";
  print_bigraph rule.redex.bigraph;

  Printf.printf "== Parsed reactum ==\n";
  print_bigraph rule.reactum.bigraph;

  Printf.printf "== Target bigraph ==\n";
  print_bigraph target.bigraph;

  Printf.printf "Can apply rule: %b\n" (can_apply rule target);

  match apply_rule rule target with
  | Some result_state ->
      Printf.printf "Rule applied successfully!\n";
      Printf.printf "Result state:\n";
      print_bigraph result_state.bigraph
  | None -> Printf.printf "Rule could not be applied\n"
