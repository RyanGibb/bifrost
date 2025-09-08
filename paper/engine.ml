open Bifrost
open Bifrost.Utils
open Bifrost.Bigraph
open Bifrost.Matching

module Api = Bigraph_capnp.Make(Capnp.BytesMessage)

(* ---------- helpers ---------- *)

let prop_of (nd : node) (k : string) : property_value option =
  match nd.properties with Some ps -> List.assoc_opt k ps | None -> None

let prop_bool (nd : node) (k : string) : bool option =
  match prop_of nd k with
  | Some (Bool b) -> Some b
  | Some (Int n) -> Some (n <> 0)
  | Some (String "true") -> Some true
  | Some (String "false") -> Some false
  | _ -> None

let nodes_by_id (bg : bigraph) : (int, node) Hashtbl.t =
  let tbl = Hashtbl.create 256 in
  let roots = get_root_nodes bg in
  let rec dfs nid =
    match get_node bg nid with
    | None -> ()
    | Some nd ->
        Hashtbl.replace tbl nid nd;
        let kids = get_children bg nid in
        NodeSet.iter dfs kids
  in
  NodeSet.iter dfs roots; tbl

(* ---------- capnp ---------- *)

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
      Color (r,g,b)
  | Api.Reader.PropertyValue.Undefined _ -> String ""

let build_bigraph_with_interface (b : Api.Reader.Bigraph.t) : bigraph_with_interface =
  let nodes = Api.Reader.Bigraph.nodes_get_list b in
  let sig_tbl : (string, control) Hashtbl.t = Hashtbl.create (List.length nodes) in
  List.iter (fun n ->
    let cname = Api.Reader.Node.control_get n in
    let arity = Api.Reader.Node.arity_get_int_exn n in
    if not (Hashtbl.mem sig_tbl cname) then
      Hashtbl.add sig_tbl cname (create_control cname arity)
  ) nodes;
  let signature = Hashtbl.to_seq_values sig_tbl |> List.of_seq in

  let node_tbl : (int, node) Hashtbl.t = Hashtbl.create (List.length nodes) in
  List.iter (fun n ->
    let id = Api.Reader.Node.id_get_int_exn n in
    if Hashtbl.mem node_tbl id then failwith (Printf.sprintf "Duplicate node id %d" id);
    let cname   = Api.Reader.Node.control_get n in
    let control =
      match Hashtbl.find_opt sig_tbl cname with
      | Some c -> c
      | None   -> create_control cname (Api.Reader.Node.arity_get_int_exn n)
    in
    let name     = Api.Reader.Node.name_get n in
    let node_typ = Api.Reader.Node.type_get n in
    let ports    = List.map Int32.to_int (Api.Reader.Node.ports_get_list n) in
    let props =
      let pls = Api.Reader.Node.properties_get_list n in
      if pls = [] then None
      else Some (List.map (fun p ->
        let k = Api.Reader.Property.key_get p in
        let v = propvalue_of_capnp (Api.Reader.Property.value_get p) in
        (k, v)) pls)
    in
    Hashtbl.add node_tbl id { id; name; node_type = node_typ; control; ports; properties = props }
  ) nodes;

  let bg_ref = ref (empty_bigraph signature) in
  List.iter (fun n ->
    let id     = Api.Reader.Node.id_get_int_exn n in
    let parent = Api.Reader.Node.parent_get_int_exn n in
    let nd     = Hashtbl.find node_tbl id in
    if parent = -1 then bg_ref := add_node_to_root !bg_ref nd
    else bg_ref := add_node_as_child !bg_ref parent nd
  ) nodes;

  let site_count = Api.Reader.Bigraph.site_count_get_int_exn b in
  let names      = Api.Reader.Bigraph.names_get_list b in
  { bigraph = !bg_ref; inner = { sites = site_count; names }; outer = { sites = 0; names = [] } }

let read_message_from_file filename =
  let ic = open_in_bin filename in
  let len = in_channel_length ic in
  let raw = really_input_string ic len in
  close_in ic;
  let stream = Capnp.Codecs.FramedStream.of_string ~compression:`None raw in
  match Capnp.Codecs.FramedStream.get_next_frame stream with
  | Ok msg  -> msg
  | Error _ -> failwith ("Failed to decode Cap'n Proto from "^filename)

let load_rule_from_file file =
  let msg = read_message_from_file file in
  let rr  = Api.Reader.Rule.of_message msg in
  let red = build_bigraph_with_interface (Api.Reader.Rule.redex_get rr) in
  let rct = build_bigraph_with_interface (Api.Reader.Rule.reactum_get rr) in
  let nm  = Api.Reader.Rule.name_get rr in
  create_rule nm red rct

let load_bigraph_from_file file =
  let msg = read_message_from_file file in
  let r   = Api.Reader.Bigraph.of_message msg in
  build_bigraph_with_interface r

let flatten_nodes_with_parents (bg : bigraph) : (int * int * node) list =
  let roots = get_root_nodes bg in
  let rec dfs acc parent_id nid =
    match get_node bg nid with
    | None -> acc
    | Some nd ->
        let acc' = (nid, parent_id, nd) :: acc in
        let kids = get_children bg nid in
        NodeSet.fold (fun cid a -> dfs a nid cid) kids acc'
  in
  NodeSet.fold (fun rid a -> dfs a (-1) rid) roots [] |> List.rev

let write_bigraph_to_file (gwi : bigraph_with_interface) (out_path : string) : unit =
  let flat = flatten_nodes_with_parents gwi.bigraph in
  let root = Api.Builder.Bigraph.init_root ~message_size:4096 () in
  Api.Builder.Bigraph.site_count_set root (Int32.of_int gwi.inner.sites);
  ignore (Api.Builder.Bigraph.names_set_list root gwi.inner.names);
  let nodes_arr = Api.Builder.Bigraph.nodes_init root (List.length flat) in
  List.iteri (fun i (id, parent, nd) ->
    let cn = Capnp.Array.get nodes_arr i in
    Api.Builder.Node.id_set_int_exn     cn id;
    Api.Builder.Node.control_set        cn nd.control.name;
    Api.Builder.Node.arity_set_int_exn  cn nd.control.arity;
    Api.Builder.Node.parent_set_int_exn cn parent;
    Api.Builder.Node.name_set           cn nd.name;
    Api.Builder.Node.type_set           cn nd.node_type;
    ignore (Api.Builder.Node.ports_set_list cn (List.map Int32.of_int nd.ports));
    let props = match nd.properties with None -> [] | Some ps -> ps in
    let props_arr = Api.Builder.Node.properties_init cn (List.length props) in
    List.iteri (fun j (k, v) ->
      let p  = Capnp.Array.get props_arr j in
      Api.Builder.Property.key_set p k;
      let pv = Api.Builder.Property.value_init p in
      match v with
      | Bool b   -> Api.Builder.PropertyValue.bool_val_set   pv b
      | Int  n   -> Api.Builder.PropertyValue.int_val_set_int_exn pv n
      | Float f  -> Api.Builder.PropertyValue.float_val_set  pv f
      | String s -> Api.Builder.PropertyValue.string_val_set pv s
      | Color (r,g,b) ->
          let c = Api.Builder.PropertyValue.color_val_init pv in
          Api.Builder.PropertyValue.ColorVal.r_set_exn c r;
          Api.Builder.PropertyValue.ColorVal.g_set_exn c g;
          Api.Builder.PropertyValue.ColorVal.b_set_exn c b
    ) props
  ) flat;
  let bytes = Capnp.Codecs.serialize ~compression:`None (Api.Builder.Bigraph.to_message root) in
  let oc = open_out_bin out_path in
  output_string oc bytes; close_out oc

(* ---------- Docker (local or remote over SSH) ---------- *)

type effect_cfg = { image:string; cname:string; run_args:string }
let env_default k d = match Sys.getenv_opt k with Some v when v<>"" -> v | _ -> d

let stt_cfg () : effect_cfg =
  { image   = env_default "STT_IMAGE" "j0shm/stt-service:latest";
    cname   = env_default "STT_CONTAINER" "stt";
    run_args= env_default "STT_RUN_ARGS"
                "--device /dev/snd --group-add audio -v stt_models:/models -e MODEL_NAME=moonshine/base" }

let sh_escape_single_quotes s =
  "'" ^ (String.concat "'\\''" (String.split_on_char '\'' s)) ^ "'"

let run_cmd (cmd : string) : int =
  Printf.printf "[engine] $ %s\n%!" cmd; Sys.command cmd

let env_default k d = match Sys.getenv_opt k with Some v when v<>"" -> v | _ -> d

let ssh_prefix () : string option =
  match Sys.getenv_opt "STT_REMOTE_HOST" with
  | None -> None
  | Some host ->
      let port   = env_default "STT_REMOTE_PORT" "22" in
      let strict =
        match String.lowercase_ascii (env_default "STT_REMOTE_STRICT" "no") with
        | "no" | "0" | "false" ->
            "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        | _ -> ""
      in
      let key_opt =
        match Sys.getenv_opt "STT_SSH_KEY" with
        | Some k when k <> "" -> Printf.sprintf "-i %s" (Filename.quote k)
        | _ -> ""
      in
      Some (Printf.sprintf "ssh -o BatchMode=yes -o IdentitiesOnly=yes %s %s -p %s %s"
              strict key_opt (Filename.quote port) host)

let docker_exec (docker_args : string) : int =
  (match Sys.getenv_opt "STT_DOCKER_HOST" with
   | Some v when v<>"" -> Unix.putenv "DOCKER_HOST" v
   | _ -> ());
  match ssh_prefix () with
  | Some ssh ->
      let remote = Printf.sprintf "%s %s" ssh (sh_escape_single_quotes ("docker " ^ docker_args)) in
      run_cmd remote
  | None ->
      run_cmd (Printf.sprintf "docker %s" docker_args)

let docker_exec_local (docker_args : string) : int =
  run_cmd (Printf.sprintf "docker %s" docker_args)

let image_present_remote img =
  docker_exec (Printf.sprintf "image inspect %s >/dev/null 2>&1" img) = 0

let image_present_local img =
  docker_exec_local (Printf.sprintf "image inspect %s >/dev/null 2>&1" img) = 0

let pull_remote img : bool =
  docker_exec (Printf.sprintf "pull %s" img) = 0

(* Optional fallback: stream local image to remote via ssh *)
let push_image_via_ssh img : bool =
  match ssh_prefix () with
  | None -> false
  | Some ssh ->
      if not (image_present_local img) then false
      else
        let cmd =
          Printf.sprintf
            "docker save %s | gzip | %s 'gunzip | docker load'"
            (Filename.quote img) ssh
        in
        run_cmd cmd = 0

let ensure_image_remote (img:string) : bool =
  if image_present_remote img then (
    Printf.printf "[engine] Image present (remote): %s\n%!" img; true
  ) else begin
    (* try pull; if denied and STT_PUSH_VIA_SSH=1, stream local image *)
    if pull_remote img then true
    else (
      match Sys.getenv_opt "STT_PUSH_VIA_SSH" with
      | Some ("1"|"true"|"TRUE") ->
          Printf.printf "[engine] Remote pull failed; streaming local image via SSH...\n%!";
          push_image_via_ssh img
      | _ -> false
    )
  end

let container_running name =
  docker_exec (Printf.sprintf "ps --format '{{.Names}}' | grep -x %s >/dev/null 2>&1" name) = 0

let container_exists name =
  docker_exec (Printf.sprintf "ps -a --format '{{.Names}}' | grep -x %s >/dev/null 2>&1" name) = 0

let ensure_container_running cfg : bool =
  if container_running cfg.cname then (
    Printf.printf "[engine] Container '%s' already running.\n%!" cfg.cname; true
  ) else if container_exists cfg.cname then (
    docker_exec (Printf.sprintf "start %s" cfg.cname) = 0
  ) else (
    docker_exec (Printf.sprintf "run -d --name %s %s %s"
                  cfg.cname cfg.run_args cfg.image) = 0
  )

let docker_verify ~container ~tail_lines =
  ignore (docker_exec (Printf.sprintf "ps --format '{{.Names}}\\t{{.Status}}' | grep -E '^%s\\b' || true" container));
  ignore (docker_exec (Printf.sprintf "logs --tail %d %s || true" tail_lines container))

let maybe_start_stt ~(before: bigraph_with_interface) ~(after: bigraph_with_interface) =
  (* fire iff any STT went from inactive->active *)
  let b = nodes_by_id before.bigraph in
  let a = nodes_by_id after.bigraph in
  let activated = ref false in
  Hashtbl.iter (fun id nd_after ->
    if nd_after.node_type = "STT" then
      let now = match prop_bool nd_after "active" with Some v -> v | None -> false in
      let was =
        match Hashtbl.find_opt b id with
        | None -> false
        | Some nd_before -> (match prop_bool nd_before "active" with Some v -> v | None -> false)
      in
      if (not was) && now then activated := true
  ) a;
  if !activated then (
    let cfg = stt_cfg () in
    Printf.printf "[engine] STT active\n%!";
    let ok_img =
      match Sys.getenv_opt "STT_REMOTE_HOST" with
      | None -> image_present_local cfg.image || (docker_exec_local (Printf.sprintf "pull %s" cfg.image) = 0)
      | Some _ -> ensure_image_remote cfg.image
    in
    if not ok_img then
      Printf.printf "[engine] ERROR: image '%s' not available remotely and pull/stream failed.\n%!" cfg.image
    else (
      let started = ensure_container_running cfg in
      if started then (
        (match Sys.getenv_opt "STT_VERIFY" with
         | Some _ -> docker_verify ~container:cfg.cname ~tail_lines:50
         | None -> ());
        let where = match Sys.getenv_opt "STT_REMOTE_HOST" with Some h -> h | None -> "local" in
        Printf.printf "[engine] STT started on %s (container=%s)\n%!" where cfg.cname
      ) else
        Printf.printf "[engine] ERROR: failed to start container '%s'\n%!" cfg.cname
    )
  )

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
        (fun (k,v) -> match List.assoc_opt k bl with Some v' -> v = v' | None -> false)
        al

let node_sig_match (needle : node) (hay : node) : bool =
  (needle.node_type = hay.node_type)
  && (needle.control.name = hay.control.name)
  && props_subset needle.properties hay.properties

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
  List.iter (fun nd ->
    if not (Hashtbl.mem tbl nd.control.name) then
      Hashtbl.add tbl nd.control.name nd.control
  ) all;
  Hashtbl.to_seq_values tbl |> List.of_seq

let rebuild_with_parents (nodes : (int, node) Hashtbl.t)
                        (parents : (int,int) Hashtbl.t) : bigraph =
  let all_nodes = Hashtbl.to_seq_values nodes |> List.of_seq in
  let signature = signature_from_nodes all_nodes in
  let bg_ref = ref (empty_bigraph signature) in
  let added = Hashtbl.create (Hashtbl.length nodes) in
  let rec pass () =
    let progressed = ref false in
    Hashtbl.iter (fun id nd ->
      if not (Hashtbl.mem added id) then
        let parent = Hashtbl.find parents id in
        if parent = -1 || Hashtbl.mem added parent then begin
          if parent = -1 then bg_ref := add_node_to_root !bg_ref nd
          else bg_ref := add_node_as_child !bg_ref parent nd;
          Hashtbl.add added id true;
          progressed := true
        end
    ) nodes;
    if !progressed && Hashtbl.length added < Hashtbl.length nodes then pass ()
  in
  pass ();
  !bg_ref

let repair_parenting_of_new_nodes
    ~(rule: reaction_rule)
    ~(result: bigraph_with_interface)
  : bigraph_with_interface =
  let redex_pm  = parent_map_of rule.redex.bigraph in
  let react_pm  = parent_map_of rule.reactum.bigraph in

  let redex_id_set =
    let s = Hashtbl.create 128 in
    Hashtbl.iter (fun k _ -> Hashtbl.replace s k true) redex_pm; s
  in
  let is_redex_id i = Hashtbl.mem redex_id_set i in

  let new_ids =
    Hashtbl.to_seq_keys react_pm
    |> List.of_seq
    |> List.filter (fun i -> not (is_redex_id i))
  in
  if new_ids = [] then result
  else begin
    let res_nodes   = nodes_by_id result.bigraph in
    let res_parents = parent_map_of result.bigraph in

    let rec depth_of i =
      let p = Hashtbl.find react_pm i in
      if p = -1 then 0 else 1 + depth_of p
    in
    let new_ids_sorted = List.sort (fun a b -> compare (depth_of a) (depth_of b)) new_ids in

    let find_matching_in_result (red_nd : node) : int option =
      let candidate = ref None in
      Hashtbl.iter (fun id nd ->
        if !candidate = None && node_sig_match red_nd nd then candidate := Some id
      ) res_nodes;
      !candidate
    in

    let resolved_parent : (int, int) Hashtbl.t = Hashtbl.create 64 in
    let resolve_parent_id (rp : int) : int option =
      if rp = -1 then None
      else if Hashtbl.mem resolved_parent rp then Some (Hashtbl.find resolved_parent rp)
      else if not (Hashtbl.mem redex_id_set rp) then
        (Hashtbl.add resolved_parent rp rp; Some rp)
      else
        match get_node rule.redex.bigraph rp with
        | None -> None
        | Some redex_parent ->
            begin match find_matching_in_result redex_parent with
            | Some id -> Hashtbl.add resolved_parent rp id; Some id
            | None -> None
            end
    in

    List.iter (fun nid ->
      match Hashtbl.find_opt react_pm nid with
      | None -> ()
      | Some rp ->
          begin match resolve_parent_id rp with
          | None -> ()
          | Some target_parent_id ->
              Hashtbl.replace res_parents nid target_parent_id
          end
    ) new_ids_sorted;

    let repaired_bigraph = rebuild_with_parents res_nodes res_parents in
    { result with bigraph = repaired_bigraph }
  end

(* ---------- main ---------- *)

let () =
  if Array.length Sys.argv < 3 then begin
    prerr_endline "Usage: engine.exe <target.capnp> <rule1.capnp> [rule2.capnp ...]";
    exit 2
  end;
  let target_path = Sys.argv.(1) in
  let rule_files  = Array.to_list (Array.sub Sys.argv 2 (Array.length Sys.argv - 2)) in

  let state = ref (load_bigraph_from_file target_path) in
  Printf.printf "[engine] target: %s\n%!" target_path;

  List.iter (fun rf ->
    Printf.printf "[engine] applying rule file: %s\n%!" rf;
    let rule = load_rule_from_file rf in
    Printf.printf "[engine]   can_apply(%s)? %b\n%!" rule.name (can_apply rule !state);
    match apply_rule rule !state with
    | Some s0 ->
        let s = repair_parenting_of_new_nodes ~rule ~result:s0 in
        Printf.printf "[engine] Applied rule: %s\n%!" rule.name;
        maybe_start_stt ~before:!state ~after:s;
        state := s;
        write_bigraph_to_file !state target_path
    | None ->
        Printf.printf "[engine] Rule NOT applicable: %s (skipping)\n%!" rule.name;
  ) rule_files;

  write_bigraph_to_file !state target_path;
  Printf.printf "[engine] Done. Wrote updated graph to %s\n%!" target_path
