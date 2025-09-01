import sys, pathlib
sys.path.append(str(pathlib.Path(__file__).parent.parent / "lib"))
from bigraph_dsl import Bigraph, Node, Rule

redex = Bigraph([
    Node("Building", id=0, node_type="Building", children=[
        Node("Person", id=1, node_type="Person",
             properties={"name": "Ryan Gibb", "email": "ryan.gibb@cl.cam.ac.uk"})
    ])
])

reactum = Bigraph([
    Node("Building", id=0, node_type="Building")
])

rule = Rule("despawn", redex, reactum)
rule.save("despawn_rule.capnp")
print("saved -> despawn_rule.capnp")
