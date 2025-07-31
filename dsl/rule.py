from bigraph_dsl import Node, Bigraph, Rule
redex = Bigraph([
    Node("Room", id=0, children=[
        Node("Person", id=1),
        Node("Light", id=2, properties={"power": False}),
    ])
])
reactum = Bigraph([
    Node("Room", id=0, children=[
        Node("Person", id=1),
        Node("Light", id=2, properties={"power": True}),
    ])
])
turn_on_light = Rule("turn_on_light", redex, reactum)
