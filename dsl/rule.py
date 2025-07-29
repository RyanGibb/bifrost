from bigraph_dsl import Node, Bigraph, Rule

redex = Bigraph([
    Node("Room", id=0, children=[
        Node("Person", id=1, properties={"authorised": False}),
        Node("Person", id=2, properties={"authorised": True}),
        Node("Safe", id=4),
        ])
])

reactum = Bigraph([
    Node("Room", id=0, children=[
        Node("Person", id=1, properties={"authorised": False}),
        Node("Person", id=2, properties={"authorised": True}),
        Node("Safe", id=4, properties={"locked": False}),
        ])
])

unlock_safe = Rule("unlock_safe", redex, reactum)
unlock_safe.save("rule.capnp")
