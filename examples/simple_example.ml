open Bifrost.Bigraph
open Bifrost.Operations
open Bifrost.Utils
open Bifrost.Matching

let create_room_example () =
  Printf.printf "Creating a simple room model with bigraphs\n";
  Printf.printf "=========================================\n\n";

  let signature =
    [
      create_control "Room" 0;
      create_control "Person" 1;
      create_control "Door" 2;
    ]
  in

  let bigraph = empty_bigraph signature in

  let room1 =
    create_node ~name:"room1" ~node_type:"Room" 1 (create_control "Room" 0)
  in
  let room2 =
    create_node ~name:"room2" ~node_type:"Room" 2 (create_control "Room" 0)
  in
  let person =
    create_node ~name:"person1" ~node_type:"Person" 3
      (create_control "Person" 1)
  in
  let door =
    create_node ~name:"door1" ~node_type:"Door" 4 (create_control "Door" 2)
  in

  let bigraph =
    List.fold_left add_node_to_root bigraph [ room1; room2; person; door ]
  in

  let door_port1 = List.nth door.ports 0 in
  let door_port2 = List.nth door.ports 1 in

  let bigraph = connect_ports bigraph door_port1 door_port2 1 in

  Printf.printf "Created bigraph with:\n";
  print_bigraph bigraph;

  Printf.printf "\nValidation result: %b\n\n" (validate_bigraph bigraph);

  bigraph

let create_movement_rule () =
  Printf.printf "Creating a movement rule\n";
  Printf.printf "======================\n\n";

  let signature = [ create_control "Room" 0; create_control "Person" 1 ] in

  let person_in_room1 =
    let bg = empty_bigraph signature in
    let person =
      create_node ~name:"person" ~node_type:"Person" 1
        (create_control "Person" 1)
    in
    let room =
      create_node ~name:"room" ~node_type:"Room" 2 (create_control "Room" 0)
    in
    add_node_to_root (add_node_to_root bg person) room
  in

  let person_in_room2 =
    let bg = empty_bigraph signature in
    let person =
      create_node ~name:"person" ~node_type:"Person" 1
        (create_control "Person" 1)
    in
    let room =
      create_node ~name:"room" ~node_type:"Room" 3 (create_control "Room" 0)
    in
    add_node_to_root (add_node_to_root bg person) room
  in

  let redex =
    {
      bigraph = person_in_room1;
      inner = { sites = 0; names = [] };
      outer = { sites = 0; names = [] };
    }
  in

  let reactum =
    {
      bigraph = person_in_room2;
      inner = { sites = 0; names = [] };
      outer = { sites = 0; names = [] };
    }
  in

  let movement_rule = create_rule "move_person" redex reactum in

  Printf.printf "Created movement rule: %s\n\n" movement_rule.name;

  movement_rule

let demonstrate_composition () =
  Printf.printf "Demonstrating bigraph composition\n";
  Printf.printf "===============================\n\n";

  let signature = [ create_control "Node" 1 ] in

  let interface_a = { sites = 1; names = [ "x" ] } in
  let interface_b = { sites = 1; names = [ "y" ] } in
  let interface_c = { sites = 1; names = [ "z" ] } in

  let bigraph1 =
    {
      bigraph = empty_bigraph signature;
      inner = interface_a;
      outer = interface_b;
    }
  in

  let bigraph2 =
    {
      bigraph = empty_bigraph signature;
      inner = interface_b;
      outer = interface_c;
    }
  in

  Printf.printf "Composing two bigraphs:\n";
  Printf.printf "B1: %d sites -> %d sites\n" bigraph1.inner.sites
    bigraph1.outer.sites;
  Printf.printf "B2: %d sites -> %d sites\n" bigraph2.inner.sites
    bigraph2.outer.sites;

  let composed = compose bigraph1 bigraph2 in

  Printf.printf "Result: %d sites -> %d sites\n\n" composed.inner.sites
    composed.outer.sites;

  composed

let run_examples () =
  Printf.printf "Bifrost Bigraph Library Examples\n";
  Printf.printf "==============================\n\n";

  let _ = create_room_example () in
  let _ = create_movement_rule () in
  let _ = demonstrate_composition () in

  Printf.printf "Examples completed successfully!\n"

let () = run_examples ()
