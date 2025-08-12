from bigraph_dsl import Node, Bigraph

target = Bigraph([
    Node("Room", id=0, arity=0, children=[
        Node("Person", id=1, arity=0, properties={"authorised": False}),
        Node("Person", id=2, arity=0, properties={"authorised": False}),
        Node("Person", id=3, arity=0, properties={"authorised": True}),
        Node("Safe", id=4, arity=0, properties={"locked": True}),
        Node("Light", id=5, arity=0, properties={"brightness": 0}),
        ])
    ])

target.save("target.capnp")

