open Bifrost
open Bifrost.Bigraph
open Bifrost.Utils

module Api = Bigraph_capnp.Make(Capnp.BytesMessage)

(* ------------------------------------------------------------------ *)
let _build (b : Api.Reader.Bigraph.t) : bigraph_with_interface =
  (* controls/signature first *)
  let nodes_r = Api.Reader.Bigraph.nodes_get_list b in
  let controls =
    nodes_r
    |> List.map (fun n ->
           create_control (Api.Reader.Node.control_get n)
             (Api.Reader.Node.arity_get n |> Int32.to_int))
    |> List.sort_uniq compare
  in
  
  (* create node objects *)
  let tbl = Hashtbl.create (List.length nodes_r) in
  List.iter
    (fun n ->
       let id = Api.Reader.Node.id_get n |> Int32.to_int in
       let ctl = List.find (fun c -> c.name = Api.Reader.Node.control_get n)
                    controls in
       let props =
         let pl = Api.Reader.Node.properties_get_list n in
         if List.length pl = 0 then None
         else Some (List.map (fun p ->
                       let key = Api.Reader.Property.key_get p in
                       let value =
                         match Api.Reader.PropertyValue.get (Api.Reader.Property.value_get p) with
                         | Api.Reader.PropertyValue.BoolVal b -> Bool b
                         | Api.Reader.PropertyValue.IntVal i -> Int (Int32.to_int i)
                         | Api.Reader.PropertyValue.FloatVal f -> Float f
                         | Api.Reader.PropertyValue.StringVal s -> String s
                         | Api.Reader.PropertyValue.ColorVal c ->
                             let r = Api.Reader.PropertyValue.ColorVal.r_get c
                             and g = Api.Reader.PropertyValue.ColorVal.g_get c
                             and b = Api.Reader.PropertyValue.ColorVal.b_get c in
                             Color (r, g, b)
                         | Api.Reader.PropertyValue.Undefined _ -> String "" (* fallback *)
                       in
                       (key, value)) pl)
       in
       Hashtbl.add tbl id (create_node ?props id ctl))
    nodes_r;

  (* empty bigraph with signature *)
  let bg = ref (empty_bigraph controls) in

  (* place: add nodes & parent relations *)
  List.iter
    (fun n ->
       let id     = Api.Reader.Node.id_get n |> Int32.to_int in
       let parent = Api.Reader.Node.parent_get n |> Int32.to_int in
       let node   = Hashtbl.find tbl id in
       if parent = -1 then
         bg := add_node_to_root !bg node
       else
         bg := add_node_as_child !bg parent node)
    nodes_r;

  {
    bigraph = !bg;
    inner   = { sites = Api.Reader.Bigraph.site_count_get b |> Int32.to_int
              ; names = Api.Reader.Bigraph.names_get_list b };
    outer   = { sites = 0; names = [] };
  }