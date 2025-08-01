(* test_simple.ml *)
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

let test_device = {
  name = "Test Device";
  id = "123";
  position = { x = 1.0; y = 2.0; z = 3.0 };
}

let () = 
  Printf.printf "Device: %s at (%.1f, %.1f, %.1f)\n"
    test_device.name 
    test_device.position.x 
    test_device.position.y 
    test_device.position.z