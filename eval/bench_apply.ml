(* 
   output CSV:
     graph_size,rule,trial,latency_us,matched,
     load_bg_us,load_redex_us,load_react_us,load_meta_us,create_rule_us,
     bg_bytes,redex_bytes,react_bytes,meta_bytes,
     read_bg_us,decode_bg_us,read_redex_us,decode_redex_us,read_react_us,decode_react_us
*)

module J = Yojson.Safe
module U = Yojson.Safe.Util

open Bifrost
open Bifrost.Bigraph
open Bifrost.Matching

let now_us () = Int64.of_float (Unix.gettimeofday () *. 1e6)

(* --- prog bar --- *)

let progress_enabled = ref true

let fmt_hms (sec : float) : string =
  let s = int_of_float (max 0.0 sec) in
  let h = s / 3600 in
  let m = (s mod 3600) / 60 in
  let s = s mod 60 in
  if h > 0 then Printf.sprintf "%d:%02d:%02d" h m s
  else Printf.sprintf "%02d:%02d" m s

let draw_progress ~(done_:int) ~(total:int) ~(started:float) ~(label:string) =
  if not !progress_enabled then () else
  let total = max 1 total in
  let frac  = (float done_) /. (float total) in
  let pct   = 100.0 *. frac in
  let bar_w = 40 in
  let fill  = int_of_float (frac *. float bar_w) in
  let bar   = (String.make (max 0 (min bar_w fill)) '=')
              ^ (String.make (max 0 (bar_w - fill)) ' ') in
  let now   = Unix.gettimeofday () in
  let el    = now -. started in
  let rate  = if el <= 1e-9 then 0.0 else (float done_) /. el in
  let eta_s = if rate <= 1e-9 then 0.0 else (float (total - done_)) /. rate in
  Printf.eprintf "\r[%s] %5.1f%%  %d/%d  elapsed %s  eta %s  %s%!"
    bar pct done_ total (fmt_hms el) (fmt_hms eta_s) label


(* --------- csv --------- *)

let csv_escape s =
  if String.contains s ',' || String.contains s '"' then
    "\"" ^ String.concat "\"\"" (String.split_on_char '"' s) ^ "\""
  else s

let printf_csv cols =
  Printf.printf "%s\n%!" (String.concat "," (List.map csv_escape cols))

let trim_field (s : string) : string =
  let s = String.trim s in
  let n = String.length s in
  let s =
    if n > 0 && s.[n - 1] = '\r' then String.sub s 0 (n - 1) else s
  in
  let n = String.length s in
  if n >= 2 && s.[0] = '"' && s.[n - 1] = '"' then
    String.sub s 1 (n - 2) |> String.trim
  else
    s
    
(* --------- file i/o --------- *)

let file_bytes path =
  try (Unix.stat path).Unix.st_size with _ -> 0

let read_file_bytes (path : string) : string * int64 =
  let t0 = now_us () in
  let ic = open_in_bin path in
  let len = in_channel_length ic in
  let buf = really_input_string ic len in
  close_in ic;
  let t1 = now_us () in
  (buf, Int64.sub t1 t0)

(* --------- deserialization API --------- *)

module Api = Bigraph_capnp.Make(Capnp.BytesMessage)

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
  let sig_tbl : (string, control) Hashtbl.t = Hashtbl.create (List.length nodes) in
  List.iter (fun n ->
    let cname = Api.Reader.Node.control_get n in
    let arity = Api.Reader.Node.arity_get n |> Int32.to_int in
    if not (Hashtbl.mem sig_tbl cname) then
      Hashtbl.add sig_tbl cname (create_control cname arity)
  ) nodes;
  let signature = Hashtbl.to_seq_values sig_tbl |> List.of_seq in

  let node_tbl : (int, node) Hashtbl.t = Hashtbl.create (List.length nodes) in
  List.iter (fun n ->
    let id = Api.Reader.Node.id_get n |> Int32.to_int in
    if Hashtbl.mem node_tbl id then failwith (Printf.sprintf "Duplicate node ID: %d" id);
    let cname   = Api.Reader.Node.control_get n in
    let control =
      match Hashtbl.find_opt sig_tbl cname with
      | Some c -> c
      | None   -> create_control cname (Api.Reader.Node.arity_get n |> Int32.to_int)
    in
    let name     = Api.Reader.Node.name_get n in
    let node_typ = Api.Reader.Node.type_get n in
    let ports    = Api.Reader.Node.ports_get_list n |> List.map Int32.to_int in
    let props_list =
      let pls = Api.Reader.Node.properties_get_list n in
      if pls = [] then None else
        Some (List.map (fun p ->
          let k = Api.Reader.Property.key_get p in
          let v = propvalue_of_capnp (Api.Reader.Property.value_get p) in
          (k, v)) pls)
    in
    Hashtbl.add node_tbl id { id; name; node_type = node_typ; control; ports; properties = props_list }
  ) nodes;

  let bg_ref = ref (empty_bigraph signature) in
  List.iter (fun n ->
    let id     = Api.Reader.Node.id_get n |> Int32.to_int in
    let parent = Api.Reader.Node.parent_get n |> Int32.to_int in
    let nd     = Hashtbl.find node_tbl id in
    if parent = -1 then bg_ref := add_node_to_root !bg_ref nd
    else bg_ref := add_node_as_child !bg_ref parent nd
  ) nodes;

  let site_count = Api.Reader.Bigraph.site_count_get b |> Int32.to_int in
  let names      = Api.Reader.Bigraph.names_get_list b in
  { bigraph = !bg_ref; inner = { sites = site_count; names }; outer = { sites = 0; names = [] } }

let bytes_to_gwi (bytes : string) : bigraph_with_interface =
  let stream = Capnp.Codecs.FramedStream.of_string ~compression:`None bytes in
  match Capnp.Codecs.FramedStream.get_next_frame stream with
  | Ok msg ->
      let r = Api.Reader.Bigraph.of_message msg in
      build_bigraph_with_interface r
  | Error _ -> failwith "Cap'n Proto decode failed"

let wrap_state (bg: bigraph) : bigraph_with_interface =
  { bigraph = bg; inner = { sites = 0; names = [] }; outer = { sites = 0; names = [] } }

let wrap_iface (bg: bigraph) (inner_sites:int) (outer_sites:int) : bigraph_with_interface =
  { bigraph = bg; inner = { sites = inner_sites; names = [] }; outer = { sites = outer_sites; names = [] } }

(* --------- parsing --------- *)

type row = {
  graph_size : int;
  rule_name  : string;
  trial      : int;
  bg_path    : string;
  redex_path : string;
  react_path : string;
  meta_path  : string;
}

let parse_manifest_line (line : string) : row option =
  match String.split_on_char ',' line with
  | [gs; rule; tr; bgp; rdx; rct; mta] ->
      let tf = trim_field in
      Some {
        graph_size = int_of_string (tf gs);
        rule_name  = tf rule;
        trial      = int_of_string (tf tr);
        bg_path    = tf bgp;
        redex_path = tf rdx;
        react_path = tf rct;
        meta_path  = tf mta;
      }
  | _ -> None

let read_lines (path:string) : string list =
  let ic = open_in path in
  let rec loop acc =
    match input_line ic with
    | line -> loop (line :: acc)
    | exception End_of_file -> close_in ic; List.rev acc
  in loop []

(* --------- main --------- *)

let () =
  let manifest = ref "artifacts/manifest.csv" in
  let general = ref true in       
  let progress_enabled_flag = ref true in  

  let speclist = [
    ("--manifest", Arg.Set_string manifest, "path to manifest.csv");
    ("--general",  Arg.Set general, "enumerate ALL embeddings (streaming)");
    ("--fast",     Arg.Clear general, "single-apply (no full enumeration)");
    ("--no-progress", Arg.Clear progress_enabled_flag, "disable prog bar");
    ("--progress",    Arg.Set progress_enabled_flag,   "enable prog bar");
  ] in
  Arg.parse speclist (fun _ -> ()) "bench_apply: load, time, and apply rules";
  progress_enabled := !progress_enabled_flag;

  printf_csv [
    "graph_size"; "rule"; "trial"; "latency_us"; "matched";
    "search_us"; "apply_us";
    "load_bg_us"; "load_redex_us"; "load_react_us"; "load_meta_us"; "create_rule_us";
    "bg_bytes"; "redex_bytes"; "react_bytes"; "meta_bytes";
    "read_bg_us"; "decode_bg_us"; "read_redex_us"; "decode_redex_us"; "read_react_us"; "decode_react_us"
  ];
  
  let lines = read_lines !manifest in
  match lines with
  | [] -> ()
  | _hdr :: rows ->
    let parsed =
      List.filter_map (fun line -> parse_manifest_line line) rows
    in

    let total = List.length parsed in
    let started = Unix.gettimeofday () in

    let processed = ref 0 in
    List.iter (fun r ->
      let bg_bytes    = file_bytes r.bg_path in
      let redex_bytes = file_bytes r.redex_path in
      let react_bytes = file_bytes r.react_path in
      let meta_bytes  = file_bytes r.meta_path in

      let (bg_raw, read_bg_us) = read_file_bytes r.bg_path in
      let t0 = now_us () in
      let bg_gwi = bytes_to_gwi bg_raw in
      let t1 = now_us () in
      let decode_bg_us = Int64.sub t1 t0 in
      let load_bg_us = Int64.add read_bg_us decode_bg_us in
      let bg = bg_gwi.bigraph in

      let (rx_raw, read_redex_us) = read_file_bytes r.redex_path in
      let t2 = now_us () in
      let rx_gwi = bytes_to_gwi rx_raw in
      let t3 = now_us () in
      let decode_redex_us = Int64.sub t3 t2 in
      let load_redex_us = Int64.add read_redex_us decode_redex_us in
      let redex_bg = rx_gwi.bigraph in

      let (rt_raw, read_react_us) = read_file_bytes r.react_path in
      let t4 = now_us () in
      let rt_gwi = bytes_to_gwi rt_raw in
      let t5 = now_us () in
      let decode_react_us = Int64.sub t5 t4 in
      let load_react_us = Int64.add read_react_us decode_react_us in
      let react_bg = rt_gwi.bigraph in

      let t6 = now_us () in
      let meta_json = J.from_file r.meta_path in
      let t7 = now_us () in
      let load_meta_us = Int64.sub t7 t6 in

      let inner_sites =
        U.member "inner_sites" meta_json |> U.to_int_option |> Option.value ~default:0
      in
      let outer_sites =
        U.member "outer_sites" meta_json |> U.to_int_option |> Option.value ~default:0
      in
      let rule_name =
        match U.member "name" meta_json |> U.to_string_option with
        | Some s -> s | None -> r.rule_name
      in

      let t8 = now_us () in
      let redex  = wrap_iface redex_bg inner_sites outer_sites in
      let react  = wrap_iface react_bg inner_sites outer_sites in
      let rule   = create_rule rule_name redex react in
      let t9 = now_us () in
      let create_rule_us = Int64.sub t9 t8 in

      let tgt = wrap_state bg in

      let search_us, apply_us, matched =
        if !general then begin
          let t_s0 = now_us () in
          let seq = Matching.find_structural_matches_seq redex.bigraph bg in
          let first = ref None in
          let count = ref 0 in
          let rec consume s =
            match s () with
            | Seq.Nil -> ()
            | Seq.Cons (m, k) ->
                incr count;
                if !first = None then first := Some m;
                consume k
          in
          consume seq;
          let t_s1 = now_us () in
          let search_us = Int64.sub t_s1 t_s0 in
          let apply_us =
            match !first with
            | Some emap ->
                let t_a0 = now_us () in
                let _res = Matching.apply_with_mapping rule tgt emap in
                let t_a1 = now_us () in
                Int64.sub t_a1 t_a0
            | None -> 0L
          in
          (search_us, apply_us, !count)
        end else begin
          let t0 = now_us () in
          let res = Matching.apply_rule rule tgt in
          let t1 = now_us () in
          (Int64.sub t1 t0, 0L, (match res with Some _ -> 1 | None -> 0))
        end
      in
      let latency_us = Int64.add search_us apply_us in

      printf_csv [
        string_of_int r.graph_size; rule_name; string_of_int r.trial;
        Int64.to_string latency_us; string_of_int matched;
        Int64.to_string search_us; Int64.to_string apply_us;
        Int64.to_string load_bg_us; Int64.to_string load_redex_us; Int64.to_string load_react_us;
        Int64.to_string load_meta_us; Int64.to_string create_rule_us;
        string_of_int bg_bytes; string_of_int redex_bytes; string_of_int react_bytes; string_of_int meta_bytes;
        Int64.to_string read_bg_us; Int64.to_string decode_bg_us;
        Int64.to_string read_redex_us; Int64.to_string decode_redex_us;
        Int64.to_string read_react_us; Int64.to_string decode_react_us
      ];

    incr processed;
    let label = Printf.sprintf "%s n=%d (trial %d)" rule_name r.graph_size r.trial in
    draw_progress ~done_:!processed ~total ~started ~label;
  ) parsed;

  if !progress_enabled then (prerr_endline ""; flush stderr)
