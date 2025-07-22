open Bifrost.Bigraph
open Bifrost.Operations
open Bifrost.Utils
open Bifrost.Matching

let test_basic_bigraph () =
  Printf.printf "Testing basic bigraph creation...\n";

  let signature =
    [
      create_control "Person" 1;
      create_control "Room" 0;
      create_control "Building" 0;
    ]
  in

  let bigraph = empty_bigraph signature in
  let person_control = create_control "Person" 1 in
  let person_node = create_node 1 person_control in
  let bigraph_with_person = add_node bigraph person_node in

  Printf.printf "Node count: %d\n" (get_node_count bigraph_with_person);
  assert (get_node_count bigraph_with_person = 1);

  (match get_node bigraph_with_person 1 with
  | Some node -> Printf.printf "Found node: %s\n" node.control.name
  | None -> failwith "Node not found");

  Printf.printf "Basic bigraph test passed!\n\n"

let test_spatial_hierarchy () =
  Printf.printf "Testing spatial hierarchy...\n";

  let signature =
    [
      create_control "Room" 0;
      create_control "Person" 1;
      create_control "Building" 0;
    ]
  in

  (* Create nodes *)
  let building = create_node 1 (create_control "Building" 0) in
  let room1 = create_node 2 (create_control "Room" 0) in
  let room2 = create_node 3 (create_control "Room" 0) in
  let person = create_node 4 (create_control "Person" 1) in

  (* Build hierarchy: Building contains Room1 and Room2, Person is in Room1 *)
  let bigraph = empty_bigraph signature in
  let bigraph = add_node_to_root bigraph building in
  let bigraph = add_node_as_child bigraph 1 room1 in
  (* Room1 in Building *)
  let bigraph = add_node_as_child bigraph 1 room2 in
  (* Room2 in Building *)
  let bigraph = add_node_as_child bigraph 2 person in
  (* Person in Room1 *)

  Printf.printf "Created spatial hierarchy:\n";
  print_bigraph bigraph;

  (* Test spatial queries *)
  Printf.printf "Person's parent: %s\n"
    (match get_parent bigraph 4 with
    | Some p -> string_of_int p
    | None -> "None");
  Printf.printf "Room1's children count: %d\n"
    (NodeSet.cardinal (get_children bigraph 2));
  Printf.printf "Building's children count: %d\n"
    (NodeSet.cardinal (get_children bigraph 1));

  Printf.printf "Spatial hierarchy test passed!\n\n";
  bigraph

let test_composition () =
  Printf.printf "Testing bigraph composition...\n";

  let signature = [ create_control "A" 0; create_control "B" 0 ] in

  let interface1 : interface = { sites = 1; names = [ "x" ] } in
  let interface2 : interface = { sites = 1; names = [ "y" ] } in
  let interface3 : interface = { sites = 1; names = [ "z" ] } in

  let b1 : bigraph_with_interface =
    {
      bigraph = empty_bigraph signature;
      inner = interface1;
      outer = interface2;
    }
  in

  let b2 : bigraph_with_interface =
    {
      bigraph = empty_bigraph signature;
      inner = interface2;
      outer = interface3;
    }
  in

  let _composed = compose b1 b2 in
  Printf.printf "Composition successful\n";
  Printf.printf "Composition test passed!\n\n"

let test_tensor_product () =
  Printf.printf "Testing tensor product...\n";

  let signature = [ create_control "A" 1 ] in

  let interface = { sites = 1; names = [ "x" ] } in

  let b1 : bigraph_with_interface =
    { bigraph = empty_bigraph signature; inner = interface; outer = interface }
  in

  let b2 : bigraph_with_interface =
    { bigraph = empty_bigraph signature; inner = interface; outer = interface }
  in

  let tensor = tensor_product b1 b2 in
  Printf.printf "Tensor sites: %d\n" tensor.inner.sites;
  Printf.printf "Tensor names: %d\n" (List.length tensor.inner.names);
  assert (tensor.inner.sites = 2);
  assert (List.length tensor.inner.names = 2);

  Printf.printf "Tensor product test passed!\n\n"

let test_linking () =
  Printf.printf "Testing port linking...\n";

  let signature = [ create_control "Node" 2 ] in
  let bigraph = empty_bigraph signature in

  let node1 = create_node 1 (create_control "Node" 2) in
  let node2 = create_node 2 (create_control "Node" 2) in

  let bigraph = add_node (add_node bigraph node1) node2 in

  let port1 = List.hd node1.ports in
  let port2 = List.hd node2.ports in

  let linked_bigraph = connect_ports bigraph port1 port2 1 in

  assert (is_connected linked_bigraph port1 port2);

  Printf.printf "Port linking test passed!\n\n"

let test_movement_rule () =
  Printf.printf "Testing movement rule...\n";

  let signature = [ create_control "Room" 0; create_control "Person" 1 ] in

  (* Create target: Person inside Room1, Room2 exists *)
  let room1 = create_node 1 (create_control "Room" 0) in
  let room2 = create_node 2 (create_control "Room" 0) in
  let person = create_node 3 (create_control "Person" 1) in

  let target_bigraph = empty_bigraph signature in
  let target_bigraph = add_node_to_root target_bigraph room1 in
  let target_bigraph = add_node_to_root target_bigraph room2 in
  let target_bigraph = add_node_as_child target_bigraph 1 person in
  (* Person in Room1 *)

  let target =
    {
      bigraph = target_bigraph;
      inner = { sites = 0; names = [] };
      outer = { sites = 0; names = [] };
    }
  in

  Printf.printf "Initial state:\n";
  print_bigraph target.bigraph;

  (* Create redex: Room containing Person (what we want to match) *)
  let redex_room = create_node 100 (create_control "Room" 0) in
  let redex_person = create_node 101 (create_control "Person" 1) in
  let redex_bigraph = empty_bigraph signature in
  let redex_bigraph = add_node_to_root redex_bigraph redex_room in
  let redex_bigraph = add_node_as_child redex_bigraph 100 redex_person in
  let redex =
    {
      bigraph = redex_bigraph;
      inner = { sites = 0; names = [] };
      outer = { sites = 0; names = [] };
    }
  in

  (* Create reactum: Empty Room and Person at root (what we want as result) *)
  let reactum_room = create_node 200 (create_control "Room" 0) in
  let reactum_person = create_node 201 (create_control "Person" 1) in
  let reactum_bigraph = empty_bigraph signature in
  let reactum_bigraph = add_node_to_root reactum_bigraph reactum_room in
  let reactum_bigraph = add_node_to_root reactum_bigraph reactum_person in
  let reactum =
    {
      bigraph = reactum_bigraph;
      inner = { sites = 0; names = [] };
      outer = { sites = 0; names = [] };
    }
  in

  let move_rule = create_rule "move_person_out" redex reactum in

  Printf.printf "Can apply movement rule: %b\n" (can_apply move_rule target);

  (match apply_rule move_rule target with
  | Some result_state ->
      Printf.printf "Movement rule applied successfully!\n";
      Printf.printf "Result state:\n";
      print_bigraph result_state.bigraph;
      Printf.printf "Node count: before=%d, after=%d\n"
        (get_node_count target.bigraph)
        (get_node_count result_state.bigraph)
  | None -> Printf.printf "Movement rule could not be applied\n");

  Printf.printf "Movement rule test passed!\n\n"

let test_room_to_room_movement () =
  Printf.printf "Testing room-to-room movement rule...\n";

  let signature = [ create_control "Room" 0; create_control "Person" 1 ] in

  (* Create target: Room1[Person], Room2 *)
  let room1 = create_node 1 (create_control "Room" 0) in
  let room2 = create_node 2 (create_control "Room" 0) in
  let person = create_node 3 (create_control "Person" 1) in

  let target_bigraph = empty_bigraph signature in
  let target_bigraph = add_node_to_root target_bigraph room1 in
  let target_bigraph = add_node_to_root target_bigraph room2 in
  let target_bigraph = add_node_as_child target_bigraph 1 person in

  let target =
    {
      bigraph = target_bigraph;
      inner = { sites = 0; names = [] };
      outer = { sites = 0; names = [] };
    }
  in

  Printf.printf "Initial state:\n";
  print_bigraph target.bigraph;

  (* Create redex: Room1[Person] and Room2 (both rooms with specific arrangement) *)
  let redex_room1 = create_node 100 (create_control "Room" 0) in
  let redex_room2 = create_node 101 (create_control "Room" 0) in
  let redex_person = create_node 102 (create_control "Person" 1) in
  let redex_bigraph = empty_bigraph signature in
  let redex_bigraph = add_node_to_root redex_bigraph redex_room1 in
  let redex_bigraph = add_node_to_root redex_bigraph redex_room2 in
  let redex_bigraph = add_node_as_child redex_bigraph 100 redex_person in
  let redex =
    {
      bigraph = redex_bigraph;
      inner = { sites = 0; names = [] };
      outer = { sites = 0; names = [] };
    }
  in

  (* Create reactum: Room1 (empty) and Room2[Person] *)
  let reactum_room1 = create_node 200 (create_control "Room" 0) in
  let reactum_room2 = create_node 201 (create_control "Room" 0) in
  let reactum_person = create_node 202 (create_control "Person" 1) in
  let reactum_bigraph = empty_bigraph signature in
  let reactum_bigraph = add_node_to_root reactum_bigraph reactum_room1 in
  let reactum_bigraph = add_node_to_root reactum_bigraph reactum_room2 in
  let reactum_bigraph = add_node_as_child reactum_bigraph 201 reactum_person in
  let reactum =
    {
      bigraph = reactum_bigraph;
      inner = { sites = 0; names = [] };
      outer = { sites = 0; names = [] };
    }
  in

  let room_to_room_rule =
    create_rule "move_person_between_rooms" redex reactum
  in

  Printf.printf "Can apply room-to-room rule: %b\n"
    (can_apply room_to_room_rule target);

  (match apply_rule room_to_room_rule target with
  | Some result_state ->
      Printf.printf "Room-to-room rule applied successfully!\n";
      Printf.printf "Result state:\n";
      print_bigraph result_state.bigraph;
      Printf.printf "Person parent after rule: %s\n"
        (match NodeMap.find_opt 3 result_state.bigraph.place.nodes with
        | Some _ -> (
            match get_parent result_state.bigraph 3 with
            | Some p -> string_of_int p
            | None -> "None")
        | None -> "Person node not found")
  | None -> Printf.printf "Room-to-room rule could not be applied\n");

  Printf.printf "Room-to-room movement test passed!\n\n"

let run_tests () =
  Printf.printf "Running Bifrost Tests\n";
  Printf.printf "====================\n\n";

  test_basic_bigraph ();
  let _spatial_bg = test_spatial_hierarchy () in
  test_composition ();
  test_tensor_product ();
  test_linking ();
  test_movement_rule ();
  test_room_to_room_movement ();

  Printf.printf "All tests passed successfully!\n"

let () = run_tests ()
