(* lib/simple_json_parser.ml - Corrected version *)

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

(* Process and display the spatial data *)
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
  ) rooms

(* Sample data for testing - matches JSON structure *)
let create_sample_data () =
  (* Bathroom devices *)
  let bathroom_light = {
    name = "Light";
    id = "EEE815F4-D517-4964-8243-2C118BFFDAB2";
    position = { x = -1.5658; y = 1.3479; z = 0.6831 };
  } in
  
  (* Meeting room devices *)
  let meeting_laptop = {
    name = "laptop";
    id = "73822E2E-A2EC-46F9-95A1-230D325D5C88";
    position = { x = -1.5594; y = 0.7607; z = 2.3639 };
  } in
  
  (* Meeting room furniture (from your JSON) *)
  let conference_table = {
    id = "EAFCDCB0-E1A1-46EC-AC90-FD2E0415F1B2";
    category = "table";
    position = { x = -1.5811; y = 0.3922; z = 2.3599 };
  } in
  
  let chair1 = {
    id = "9E74F31D-C4C5-4A48-8578-F65A8D439252";
    category = "chair";
    position = { x = -0.8379; y = 0.4281; z = 2.3599 };
  } in
  
  let chair2 = {
    id = "4746ADE1-70E9-46D5-B2B0-9476C99D3703";
    category = "chair";
    position = { x = -1.5811; y = 0.4281; z = 3.0933 };
  } in
  
  (* Create rooms *)
  let bathroom = {
    name = "Bathroom";
    devices = [bathroom_light];
    furniture = []; (* No furniture in bathroom from your JSON *)
  } in
  
  let meeting_room = {
    name = "Meeting Room";
    devices = [meeting_laptop];
    furniture = [conference_table; chair1; chair2];
  } in
  
  [bathroom; meeting_room]

(* Run a simple test *)
let () =
  let room_list = create_sample_data () in
  create_place_graph_from_rooms room_list;
  Printf.printf "\nStep 1 complete! ✅\n"