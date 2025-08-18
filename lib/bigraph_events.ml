open Bigraph  (* we keep this, because we use Bigraph types *)

type graph_event =
  | NodeAdded of node
  | NodeRemoved of node_id
  | PropertyChanged of node_id * string * property_value
  | RuleApplied of string * (node_id * node_id) list  (* rule name + mapping *)

let property_value_to_json (v : property_value) : Yojson.Safe.t =
  match v with
  | Bool b -> `Bool b
  | Int i -> `Int i
  | Float f -> `Float f
  | String s -> `String s
  | Color (r,g,b) -> `List [`Int r; `Int g; `Int b]

let property_value_of_json (j : Yojson.Safe.t) : property_value =
  match j with
  | `Bool b -> Bool b
  | `Int i -> Int i
  | `Float f -> Float f
  | `String s -> String s
  | `List [`Int r; `Int g; `Int b] -> Color (r,g,b)
  | _ -> failwith "Invalid property value JSON"

let deserialize_graph_event (json : Yojson.Safe.t) : graph_event option =
  match json with
  | `Assoc fields ->
      let get_str k =
        match List.assoc k fields with
        | `String s -> s
        | _ -> failwith ("Expected string for key: " ^ k)
      in
      let get_int k =
        match List.assoc k fields with
        | `Int i -> i
        | _ -> failwith ("Expected int for key: " ^ k)
      in
      let t = get_str "type" in
      begin match t with
      | "NodeAdded" ->
          let id = get_int "node" in
          let control_name = get_str "control" in
          let arity = get_int "arity" in
          
          (* Get name and node_type, with defaults *)
          let name = 
            try get_str "name" 
            with _ -> Printf.sprintf "node_%d" id 
          in
          let node_type = 
            try get_str "node_type"
            with _ -> control_name
          in
          
          let props_json = List.assoc "properties" fields in
          let props =
            match props_json with
            | `Null -> None
            | `Assoc ps -> Some (List.map (fun (k,v) -> k, property_value_of_json v) ps)
            | _ -> failwith "Invalid properties json"
          in
          let ports =
            match List.assoc "ports" fields with
            | `List lst ->
                List.map (function `Int p -> p | _ -> failwith "Invalid port value") lst
            | _ -> []
          in
          let control = create_control control_name arity in
          Some (NodeAdded { id; name; node_type; control; ports; properties=props })
      | "NodeRemoved" ->
          let nid = get_int "node_id" in
          Some (NodeRemoved nid)
      | "PropertyChanged" ->
          let nid = get_int "node_id" in
          let key = get_str "key" in
          let value = property_value_of_json (List.assoc "value" fields) in
          Some (PropertyChanged (nid, key, value))
      | "RuleApplied" ->
          let name = get_str "name" in
          let mapping =
            match List.assoc "mapping" fields with
            | `List lst ->
                List.map (function
                  | `List [`Int a; `Int b] -> (a,b)
                  | _ -> failwith "Invalid mapping entry"
                ) lst
            | _ -> []
          in
          Some (RuleApplied (name, mapping))
      | _ -> None
      end
  | _ -> None

(* Also update serialize_graph_event to include name and node_type *)
let serialize_graph_event (ev : graph_event) : Yojson.Safe.t =
  match ev with
  | NodeAdded n ->
      `Assoc [
        "type", `String "NodeAdded";
        "node", `Int n.id;
        "name", `String n.name;
        "node_type", `String n.node_type;
        "control", `String n.control.name;
        "arity", `Int n.control.arity;
        "properties",
          (match n.properties with
            | None -> `Null
            | Some props ->
                `Assoc (List.map (fun (k,v) -> k, property_value_to_json v) props));
        "ports", `List (List.map (fun p -> `Int p) n.ports)
      ]
  | NodeRemoved nid ->
      `Assoc [
        "type", `String "NodeRemoved";
        "node_id", `Int nid
      ]
  | PropertyChanged (nid, key, value) ->
      `Assoc [
        "type", `String "PropertyChanged";
        "node_id", `Int nid;
        "key", `String key;
        "value", property_value_to_json value
      ]
  | RuleApplied (name, mapping) ->
      `Assoc [
        "type", `String "RuleApplied";
        "name", `String name;
        "mapping",
          `List (List.map (fun (a,b) -> `List [`Int a; `Int b]) mapping)
      ]