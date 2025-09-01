import sys, pathlib
sys.path.append(str(pathlib.Path(__file__).parent.parent / "lib"))
from bigraph_dsl import Bigraph, Node, Rule

# does this match?
redex = Bigraph([
    Node("Building", id=0, node_type="Building", children=[
        Node("Person", id=1, node_type="Person",
             properties={"name": "Ryan Gibb", "email": "ryan.gibb@cl.cam.ac.uk"}),
        Node("Room", id=2, node_type="Room",
             properties={"code": "FW15"}, children=[
            Node("STT", id=3, node_type="STT", properties={"active": False})
        ]),
    ])
])

reactum = Bigraph([
    Node("Building", id=0, node_type="Building", children=[
        Node("Person", id=1, node_type="Person",
             properties={"name": "Ryan Gibb", "email": "ryan.gibb@cl.cam.ac.uk"}),
        Node("Room", id=2, node_type="Room",
             properties={"code": "FW15"}, children=[
            Node("STT", id=3, node_type="STT", properties={"active": True, "lang": "EN"}),
            Node("TranscriptionSession", id=4, node_type="TranscriptionSession",
                 properties={
                    "status": "starting",
                    "session_id": "",
                    "participants_keyring": ["ryan.gibb@cl.cam.ac.uk"]
                 }),
        ]),
    ])
])

stt = Rule("stt", redex, reactum)
stt.save("stt.capnp")
print("saved → stt.capnp")
