import sys, pathlib
sys.path.append(str(pathlib.Path(__file__).parent.parent / "lib"))
from bigraph_dsl import Bigraph, Node, Rule

redex = Bigraph([
    Node("Building", id=0, node_type="Building")
])

reactum = Bigraph([
    Node("Building", id=0, node_type="Building", children=[
        Node("Person", id=1, node_type="Person",
             properties={"name": "Ryan Gibb", "email": "ryan.gibb@cl.cam.ac.uk"})
    ])
])

rule = Rule("spawn", redex, reactum)
rule.save("spawn_rule.capnp")
print("saved -> spawn_rule.capnp")

