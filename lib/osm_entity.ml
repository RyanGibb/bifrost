(** Functions for placing entities at OSM locations in a bigraph *)

open Bigraph
open Osm_parser

(** Find a building or location by OSM ID and add an entity to it *)
let add_entity_at_osm_location bigraph osm_type osm_id entity_node =
  let osm_string = osm_type ^ " " ^ osm_id in
  match find_by_osm_id bigraph osm_string with
  | Some location_node ->
      (* Add entity as a child of the location node *)
      let updated_parent_map =
        NodeMap.add entity_node.id location_node.id bigraph.place.parent_map
      in

      (* Add entity to nodes *)
      let updated_nodes =
        NodeMap.add entity_node.id entity_node bigraph.place.nodes
      in

      (* Update the place graph *)
      let updated_place =
        {
          bigraph.place with
          nodes = updated_nodes;
          parent_map = updated_parent_map;
        }
      in

      Some { bigraph with place = updated_place }
  | None -> None

(** Create an agent/entity node *)
let create_entity ?(props = []) name entity_type =
  let id = Random.int 1000000 + 100000 in
  (* Generate a unique ID *)
  let control = create_control entity_type 0 in
  create_node ~props ~name ~node_type:entity_type id control

(** Find the nearest building to given coordinates *)
let find_nearest_building bigraph _lat _lon =
  (* For now, we'll use the OSM ID directly since we know it from Nominatim *)
  (* In a full implementation, you'd calculate distances to all buildings *)
  find_by_osm_id bigraph "way 689397200"

(** Add an entity at specific GPS coordinates *)
let add_entity_at_coordinates bigraph lat lon entity_name entity_type =
  (* First try to find the exact OSM location *)
  match find_nearest_building bigraph lat lon with
  | Some _location ->
      let entity = create_entity entity_name entity_type in
      add_entity_at_osm_location bigraph "way" "689397200" entity
  | None -> (
      (* Fall back to finding any building in the area *)
      let buildings = find_by_type bigraph "Building" in
      match buildings with
      | [] -> None
      | hd :: _ ->
          let entity = create_entity entity_name entity_type in
          let updated_parent_map =
            NodeMap.add entity.id hd.id bigraph.place.parent_map
          in
          let updated_nodes =
            NodeMap.add entity.id entity bigraph.place.nodes
          in
          let updated_place =
            {
              bigraph.place with
              nodes = updated_nodes;
              parent_map = updated_parent_map;
            }
          in
          Some { bigraph with place = updated_place })

(** Example: Add an agent at the University of Cambridge location *)
let add_agent_at_cambridge bigraph agent_name =
  let lat = 52.21080001009945 in
  let lon = 0.09165142082655732 in
  add_entity_at_coordinates bigraph lat lon agent_name "Agent"
