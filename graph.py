import sys
import pathlib

sys.path.append(str(pathlib.Path(__file__).parent / "lib"))

from bigraph_dsl import Bigraph, Node

# TODO pick a layout/scenario

master = Bigraph([
    Node("Building", id=1, name="HQ", node_type="Building", children=[
        Node("Floor", id=10, name="floor_1", node_type="Floor", children=[

            Node("MidServer", id=9001, name="mid_floor_1", node_type="MidServer",
                 properties={"mid_id": "mid_floor_1"}),

            Node("Room", id=100, name="ExecutiveConference", node_type="Room",
                 properties={"name": "ExecutiveConference", "hub_id": "exec"}, children=[
                Node("Hub", id=9110, name="hub_exec", node_type="Hub",
                     properties={"hub_id": "exec"}),

                Node("Light", id=101, name="light_exec_1", node_type="Light",
                     properties={"brightness": 0, "mode": "normal"}),
                Node("Display", id=102, name="display_exec_main", node_type="Display",
                     properties={"on": False, "mode": "meeting_info"}),
                Node("PIR", id=103, name="pir_exec_1", node_type="PIR",
                     properties={"motion_detected": False}),
                Node("TranscriptionUnit", id=104, name="transcribe_exec", node_type="TranscriptionUnit",
                     properties={"active": False, "recording": False}),
                Node("AudioSystem", id=107, name="audio_exec", node_type="AudioSystem",
                     properties={"on": False, "volume": 50, "mode": "conference"}),
            ]),

            Node("Room", id=200, name="TeamRoom_A", node_type="Room",
                 properties={"name": "TeamRoom_A", "hub_id": "alpha"}, children=[
                Node("Light", id=201, name="light_alpha_1", node_type="Light",
                     properties={"brightness": 100}),
                Node("Display", id=202, name="display_alpha", node_type="Display",
                     properties={"on": True, "content_url": ""}),
                Node("PIR", id=203, name="pir_alpha", node_type="PIR",
                     properties={"motion_detected": False}),
                Node("TranscriptionUnit", id=204, name="transcribe_alpha", node_type="TranscriptionUnit",
                     properties={"active": False}),
            ]),

            Node("Room", id=300, name="TeamRoom_B", node_type="Room",
                 properties={"name": "TeamRoom_B", "hub_id": "beta"}, children=[
                Node("Light", id=301, name="light_beta_1", node_type="Light",
                     properties={"brightness": 0}),
                Node("Display", id=302, name="display_beta", node_type="Display",
                     properties={"on": False}),
                Node("PIR", id=303, name="pir_beta", node_type="PIR",
                     properties={"motion_detected": False}),
                Node("TranscriptionUnit", id=304, name="transcribe_beta", node_type="TranscriptionUnit",
                     properties={"active": False}),
            ]),
        ]),

        Node("Floor", id=20, name="floor_2", node_type="Floor", children=[
            Node("Room", id=400, name="OpenOffice", node_type="Room",
                 properties={"name": "OpenOffice", "hub_id": "open"}, children=[
                Node("Light", id=401, name="light_open_1", node_type="Light",
                     properties={"brightness": 80}),
                Node("Light", id=402, name="light_open_2", node_type="Light",
                     properties={"brightness": 80}),
                Node("PIR", id=403, name="pir_open", node_type="PIR",
                     properties={"motion_detected": True}),
            ]),
        ]),
    ]),
])

master.save("graph.capnp")
