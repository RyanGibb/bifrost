from bigraph_dsl import Node, Bigraph, Rule

redex = Bigraph([
    Node("Room", id=0, arity=0, children=[
        Node("Person", id=1, arity=0)
    ]),
    Node("Room", id=2, arity=0)
])

reactum = Bigraph([
    Node("Room", id=0, arity=0),
    Node("Room", id=2, arity=0, children=[
        Node("Person", id=1, arity=0)
    ])
])

move_room_rule = Rule("move_room", redex, reactum)
move_room_rule.save("rule.capnp")

