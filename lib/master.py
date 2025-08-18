from bigraph_dsl import Bigraph, Node

master = Bigraph([
    Node("Room", id=1, properties={"name": "MeetingRoom42"}, 
            name="MeetingRoom42", node_type="Room", children=[
        Node("Light", id=2, properties={"brightness": 100}, 
                name="light_meeting_1", node_type="Light"),
        Node("Display", id=3, properties={"on": False}, 
                name="display_meeting_1", node_type="Display"),
        Node("PIR", id=4, properties={"motion_detected": False}, 
                name="pir_meeting_1", node_type="PIR"),
    ]),
    Node("Room", id=10, properties={"name": "Office1"}, 
            name="Office1", node_type="Room", children=[
        Node("Light", id=11, properties={"brightness": 100}, 
                name="light_office_1", node_type="Light"),
        Node("PIR", id=12, properties={"motion_detected": False}, 
                name="pir_office_1", node_type="PIR"),
    ]),
    Node("Room", id=20, properties={"name": "ConferenceA"}, 
            name="ConferenceA", node_type="Room", children=[
        Node("Light", id=21, properties={"brightness": 100}, 
                name="light_conf_1", node_type="Light"),
        Node("PIR", id=22, properties={"motion_detected": False}, 
                name="pir_conf_1", node_type="PIR"),
    ])
])
master.save("master_building_graph.capnp")
print("Master graph created.")