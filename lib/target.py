from bigraph_dsl import Node, Bigraph

target = Bigraph([
    Node("Room", id=0, arity=0, children=[
        Node("Person", id=1, arity=0),
        Node("Light", id=2, arity=0, properties={"power": False}),
        ])
    ])

target.save("target.capnp")

