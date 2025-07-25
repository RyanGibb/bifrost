def make_prompt(current_state, instruction):
    return f"""
You are a Python code generation assistant. Your task is to generate only valid Python code — no explanations.

You are using a DSL to define reaction rules for bigraphs.

Here's how the DSL works:

```python
from bigraph_dsl import Node, Bigraph, Rule

# This is an example rule
redex = Bigraph([
    Node("Room", id=0, children=[
        Node("Person", id=1),
        Node("Light", id=2, children=[
            Node("Off", id=3)
        ])
    ])
])

reactum = Bigraph([
    Node("Room", id=0, children=[
        Node("Person", id=1),
        Node("Light", id=2, children=[
            Node("On", id=3)
        ])
    ])
])

turn_on_light = Rule("turn_on_light", redex, reactum)
turn_on_light.save("rule.capnp")
Below is the current bigraph state:
{current_state}

Instruction: "{instruction}"

Now write the rule using only Python code. Do not explain anything. Just emit Python code.
"""