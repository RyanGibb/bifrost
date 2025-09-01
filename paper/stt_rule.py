# paper/stt_rule.py
import sys, pathlib
sys.path.append(str(pathlib.Path(__file__).parent.parent / "lib"))
from bigraph_dsl import Bigraph, Node, Rule

redex = Bigraph([
    Node("Building", id=0, node_type="Building", children=[
        # Level F subtree first (to respect sibling order)
        Node("Level", id=10, node_type="Level",
             properties={"level_index": 1, "label": "F"}, children=[
            Node("Zone", id=11, node_type="Zone",
                 properties={"wing": "West", "floor": "First"}, children=[
                Node("Room", id=12, node_type="Room",
                     properties={"code": "FW15", "floor": "First", "wing": "West", "type": "Room"}, children=[
                    Node("STT", id=13, node_type="STT",
                         properties={"active": False, "lang": "en"})
                ])
            ])
        ]),
        # Person *after* the levels (matches how spawn appends)
        Node("Person", id=1, node_type="Person",
             properties={"email": "ryan.gibb@cl.cam.ac.uk", "name": "Ryan Gibb"}),
    ])
])

reactum = Bigraph([
    Node("Building", id=0, node_type="Building", children=[
        Node("Level", id=10, node_type="Level",
             properties={"level_index": 1, "label": "F"}, children=[
            Node("Zone", id=11, node_type="Zone",
                 properties={"wing": "West", "floor": "First"}, children=[
                Node("Room", id=12, node_type="Room",
                     properties={"code": "FW15", "floor": "First", "wing": "West", "type": "Room"}, children=[
                    Node("STT", id=13, node_type="STT",
                         properties={"active": True, "lang": "en"})
                ])
            ])
        ]),
        Node("Person", id=1, node_type="Person",
             properties={"email": "ryan.gibb@cl.cam.ac.uk", "name": "Ryan Gibb"}),
    ])
])

rule = Rule("stt", redex, reactum)
rule.save("stt_rule.capnp")
print("saved -> stt_rule.capnp")
