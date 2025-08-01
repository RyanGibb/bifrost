(* lib/simple_json_parser.ml *)

open Yojson.Safe.Util

(* Defining types for spatial data *)
type position = {
  x: float;
  y: float;
  z: float;
}

type device = {
  name: string;
  id: string;
  position: position;
}

type furniture = {
  id: string;
  category: string;
  position: position;
}

type room = {
  name: string;
  devices: device list;
  furniture: furniture list;
}


(* Display the spatial data *)
let create_place_graph_from_rooms rooms =
  Printf.printf "Creating place graph for %d rooms:\n" (List.length rooms);
  List.iter 
    (fun room ->
        let { name; devices; furniture } = room in (*Destruct Room*)
        Printf.printf "  Room: %s\n" name;
        Printf.printf "    Devices: %d\n" (List.length devices);

    (* Devices *)
    List.iter 
        (fun device ->
          let { name = dev_name; position = { x; y; z }; _ } = device in
          Printf.printf "      - %s at (%.2f, %.2f, %.2f)\n"
            dev_name x y z
        )
        devices;
    
    (* FURNITURE *)
    Printf.printf "    Furniture: %d\n" (List.length furniture);
    List.iter
        (fun furn ->
          let { id; category; position = { x; y; z } } = furn in
          Printf.printf "      - %s (%s) at (%.2f, %.2f, %.2f)\n"
            id category x y z
        )
        furniture
  ) rooms;
  Printf.printf "\n"


(*Read file *)
let read_json_file filename = 
    try 
        let ic = open_in filename in
        let rec read_lines acc = 
            try 
                let line = input_line ic in
                read_lines (line :: acc)
            with End_of_file -> 
                close_in ic;
                List.rev acc
        in
        let lines = read_lines [] in
        String.concat "\n" lines
    with 
    | Sys_error msg -> 
      Printf.printf "Error reading file: %s\n" msg;
      ""


(* Load json from the file *)
let load_json () = 
    Printf.printf "Loading JSON from file: data/jsons/roomplan_data.json\n";
    let json_content = read_json_file "data/jsons/roomplan_data.json" in
    if String.length json_content > 0 then (
        Printf.printf "✅ Successfully loaded JSON file (%d characters)\n" (String.length json_content);
        json_content
    ) else (
        Printf.printf "❌ Failed to load JSON file, using fallback data\n";
        (* Fallback to a minimal JSON if file reading fails *)
        {|{"Rooms": []}|}
    )

(* JSON Parsing Functions*)
(* Yojson parsing functions*)

(* Parse Position *)
let parse_position_json pos_json = 
    {
        x = pos_json |> member "x" |> to_float;
        y = pos_json |> member "y" |> to_float;
        z = pos_json |> member "z" |> to_float;
    }

(* Parse Device *)
let parse_device_json device_json = 
    {
        name = device_json |> member "name" |> to_string;
        id = device_json |> member "id" |> to_string;
        position = device_json |> member "position" |> parse_position_json;
    }

(* Parse Furniture*)
let parse_furniture_json furniture_json =
  let id = furniture_json |> member "id" |> to_string in
  let category = furniture_json |> member "category" |> to_string in
  
  (* Try "location" first, then "position" as fallback *)
  let location_json = furniture_json |> member "location" in
  let position_json = furniture_json |> member "position" in
  
  let position = 
    try parse_position_json location_json
    with _ -> parse_position_json position_json
  in
  { id; category; position }
  
(* Parse Room *)
let parse_room_json room_name room_json = 
    Printf.printf "  Parsing room: %s\n" room_name;

    (* Parse devices *)
    let devices = try
        let iot_devices_json = room_json |> member "iot_devices" |> to_list in
        List.map parse_device_json iot_devices_json
    with _ -> [] in

    (* Parse furniture from objects.furniture and objects.fixture while handling missing keys *)
    let furniture = try
        let objects_json = room_json |> member "objects" in
        
        (* Check if furniture key exists and is not null *)
        let furniture_items = 
            let furniture_json = objects_json |> member "furniture" in
            match furniture_json with
            | `Null -> []  (* Key doesn't exist or is null *)
            | _ -> 
                try furniture_json |> to_list |> List.map parse_furniture_json
                with _ -> []
        in


        (* Check if fixture key exists and is not null *)
        let fixture_items = 
            let fixture_json = objects_json |> member "fixture" in
            match fixture_json with
            | `Null -> []  (* Key doesn't exist or is null *)
            | _ -> 
                try fixture_json |> to_list |> List.map parse_furniture_json
                with _ -> []
        in        
        
        Printf.printf "    DEBUG: Found %d furniture + %d fixtures\n" 
            (List.length furniture_items) (List.length fixture_items);
        (* TODO: Might need to add more than furnitures and fixtures*)

        furniture_items @ fixture_items
    with exn ->
        Printf.printf "    DEBUG: Error in objects section: %s\n" (Printexc.to_string exn);
        [] in

    Printf.printf "    Found %d devices, %d furniture items\n" 
    (List.length devices) (List.length furniture);
  
    { name = room_name; devices; furniture }
(* Yojson parsing *)
let parse_yojson json_string =
  Printf.printf "Parsing JSON with Yojson...\n";
  try  
    (* Parse JSON string *)
    let json = Yojson.Safe.from_string json_string in
    
    (*Extract Room Array*)
    let rooms_array = json |> member "Rooms" |> to_list in
    let rooms = ref [] in
    
    (* Process each room dynamically *)
    List.iter (fun room_obj ->
      let room_assoc = room_obj |> to_assoc in
      (* Each room_assoc is like [("Bathroom", room_data); ("Meeting Room", room_data)] *)
      List.iter (fun (room_name, room_data) ->
        Printf.printf "Found room: %s\n" room_name;
        let parsed_room = parse_room_json room_name room_data in
        rooms := parsed_room :: !rooms
      ) room_assoc
    ) rooms_array;
    
    Printf.printf "✅ Yojson parsing found %d rooms\n\n" (List.length !rooms);
    List.rev !rooms
  with
  | Yojson.Json_error msg ->
    Printf.printf "❌ JSON parsing error: %s\n" msg;
    []
  | exn ->
    Printf.printf "❌ Parsing error: %s\n" (Printexc.to_string exn);
    []


(* Bigraph Integration*)
type bigraph_node = {
    node_id : int; 
    control_name: string; (*"Building", "Room", "Device", "Furniture"*)
    properties: (string*string) list; (*Store position, name, etc..*)
    children: int list; (* List of child node IDs *)
}

type simple_bigraph = {
    nodes: (int * bigraph_node) list;
    next_id: int; 
}


let create_empty_bigraph () = 
    { nodes = []; next_id = 1 }

let add_bigraph_node bigraph control_name properties = 
    let node = {
        node_id = bigraph.next_id;
        control_name;
        properties;
        children = [];
    } in 

    let new_bigraph = {
        nodes = (bigraph.next_id, node) :: bigraph.nodes;
        next_id = bigraph.next_id + 1;
    } in

    (node.node_id, new_bigraph)

let add_child_to_node bigraph parent_id child_id =
    let updated_nodes = List.map (fun (id, node) -> 
        if id = parent_id then
            (id, {node with children = child_id :: node.children})
        else
            (id, node)
    ) bigraph.nodes in

    { bigraph with nodes = updated_nodes }

let position_to_properties pos = [
    ("x", string_of_float pos.x);
    ("y", string_of_float pos.y);
    ("z", string_of_float pos.z)
]


(* Fix the rooms_to_bigraphs function with better variable names *)
let rooms_to_bigraphs rooms =
  Printf.printf "Converting bifrost bigraphs structure...\n";

  (* Start with an empty bigraph *)
  let bigraph0 = create_empty_bigraph () in

  (* Add the building root node *)
  let (building_id, bigraph1) =
    add_bigraph_node bigraph0 "Building" [("name", "iPhone_Scan")]
  in

  (* Fold over each room, accumulating (room_ids, bigraph) *)
  let (room_ids, bigraph_final) =
    List.fold_left
      (fun (acc_room_ids, bg) (room : room) ->
         Printf.printf "  Creating bigraph nodes for room: %s\n" room.name;

         (* 1) Create the Room node and attach under Building *)
         let (room_id, bg1) =
           add_bigraph_node bg "Room" [("room_name", room.name)]
         in
         let bg2 = add_child_to_node bg1 building_id room_id in

         (* 2) Add each Device under this Room *)
         let bg3 =
           List.fold_left
             (fun bg_acc (dev : device) ->
                let device_props =
                  [ ("device_name", dev.name)
                  ; ("device_id",   dev.id) ]
                  @ position_to_properties dev.position
                in
                let (dev_id, bg_new) =
                  add_bigraph_node bg_acc "Device" device_props
                in
                add_child_to_node bg_new room_id dev_id
             )
             bg2
             room.devices
         in

         (* 3) Add each Furniture under this Room *)
         let bg4 =
           List.fold_left
             (fun bg_acc (furn : furniture) ->
                let furniture_props =
                  [ ("furniture_id", furn.id)
                  ; ("category",     furn.category) ]
                  @ position_to_properties furn.position
                in
                let (furn_id, bg_new) =
                  add_bigraph_node bg_acc "Furniture" furniture_props
                in
                add_child_to_node bg_new room_id furn_id
             )
             bg3
             room.furniture
         in

         (room_id :: acc_room_ids, bg4)
      )
      ([], bigraph1)
      rooms
  in

  (* Report summary *)
  Printf.printf "✅ Created bigraph with %d nodes\n" (List.length bigraph_final.nodes);
  Printf.printf "   - 1 Building node\n";
  Printf.printf "   - %d Room nodes\n" (List.length room_ids);
  let total_devices   = List.fold_left (fun acc r -> acc + List.length r.devices)   0 rooms in
  let total_furniture = List.fold_left (fun acc r -> acc + List.length r.furniture) 0 rooms in
  Printf.printf "   - %d Device nodes\n" total_devices;
  Printf.printf "   - %d Furniture nodes\n\n" total_furniture;

  bigraph_final




let display_bigraph bigraph =
  Printf.printf "Bigraph Structure:\n";
  Printf.printf "================\n";
  
  List.iter (fun (id, node) ->
    Printf.printf "Node %d (%s):\n" id node.control_name;
    List.iter (fun (key, value) ->
      Printf.printf "  %s: %s\n" key value
    ) node.properties;
    if List.length node.children > 0 then (
      Printf.printf "  Children: [%s]\n" 
        (String.concat "; " (List.map string_of_int node.children))
    );
    Printf.printf "\n"
  ) (List.rev bigraph.nodes)


(* Main test with real Yojson *)
let () =
  Printf.printf "=== YOJSON PARSING ===\n\n";
  
  (* Load JSON from file *)
  let json_content = load_json () in
  
  (* Parse with real Yojson library *)
  let rooms = parse_yojson json_content in
  
  (* Display parsed rooms *)
  Printf.printf "Parsed Rooms with Yojson:\n";
  create_place_graph_from_rooms rooms;
  
  (* Convert to bigraph *)
  let bigraph = rooms_to_bigraphs rooms in
  
  (* Display bigraph structure *)
  display_bigraph bigraph;
  
  Printf.printf "🚀 Yojson parsing + Bigraph integration! ✅\n";





