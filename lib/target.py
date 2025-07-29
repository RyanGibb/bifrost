from bigraph_dsl import Node, Bigraph

# target = Bigraph([
#     Node("Room", id=0, arity=0, children=[
#         Node("Person", id=1, arity=0)
#     ]),
#     Node("Room", id=2, arity=0)
# ])

target = Bigraph([
    Node("Room", id=0, arity=0, children=[
        Node("Person", id=1, arity=0),
        Node("Light", id=2, arity=0, children=[
            Node("Off", id=3, arity=0) # TODO; needs to be a 'state' of "Light"
        ])
    ])
])

target.save("target.capnp")

