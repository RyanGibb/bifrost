open Bifrost.Bigraph
open Bifrost.Matching
open Bifrost.Utils

module Api = Bifrost.Bigraph_rpc.Make(Capnp.BytesMessage)
(* module Api = Bifrost.Bigraph_rpc.MakeRPC(Capnp_rpc_lwt) *)

let build (b : Api.Reader.Bigraph.t) : bigraph_with_interface =
  let nodes = Api.Reader.Bigraph.nodes_get_list b in
  let signature = ref [] in
  let node_tbl = Hashtbl.create (List.length nodes) in
  List.iter
    (fun n ->
       let control_name = Api.Reader.Node.control_get n in
       let arity = Api.Reader.Node.arity_get n |> Int32.to_int in
       let c = create_control control_name arity in
       signature := c :: !signature;
       let node = create_node (Api.Reader.Node.id_get n |> Int32.to_int) c in
       Hashtbl.add node_tbl (Api.Reader.Node.id_get n |> Int32.to_int) node)
    nodes;

  let bg = ref (empty_bigraph !signature) in
  List.iter
    (fun n ->
       let id = Api.Reader.Node.id_get n |> Int32.to_int in
       let node = Hashtbl.find node_tbl id in
       let parent = Api.Reader.Node.parent_get n |> Int32.to_int in
       if parent = -1 then
         bg := add_node_to_root !bg node
       else
         bg := add_node_as_child !bg parent node)
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

(* let read_message_from_file (filename : string) : Bifrost.Bigraph_rpc.ro Capnp.BytesMessage.Message.t =
  let ic = open_in_bin filename in
  let len = in_channel_length ic in
  let bytes = really_input_string ic len |> Bytes.of_string in
  close_in ic;
  Capnp.BytesMessage.Message.readonly
    (Capnp.BytesMessage.Message.of_storage [bytes]) *)

let read_message_from_file filename =
  let ic = open_in_bin filename in
  let len = in_channel_length ic in
  let raw = really_input_string ic len in
  close_in ic;

  let stream = Capnp.Codecs.FramedStream.of_string ~compression:`None raw in
  match Capnp.Codecs.FramedStream.get_next_frame stream with
  | Ok msg -> msg
  | Error _ -> failwith ("Failed to decode Cap'n Proto message")
    

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

  (match apply_rule rule target with
  | Some result_state ->
      Printf.printf "Rule applied successfully!\n";
      Printf.printf "Result state:\n";
      print_bigraph result_state.bigraph;
  | None -> Printf.printf "Rule could not be applied\n");
