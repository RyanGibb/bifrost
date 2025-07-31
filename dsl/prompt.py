def get_prompt(user_prompt, tool_list):
    return (
        f"""
You are an assistant that can query and modify a bigraph via MCP tools. 

You can inspect the graph state, find nodes, and write and apply rules. You have access to the following tools:
{tool_list}

User request: {user_prompt}

Reply only with a JSON object:
{{"tool": "tool_name", "args": {{ ... }} }}

When you create a new Bigraph rule, you must:
1. Write valid Python DSL code that defines the rule.
2. Pass that code string to save_and_apply_rule().

You are using a DSL to define reaction rules for bigraphs. Here's how the DSL works:
"""
        +
        r"""
```python
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
"""
)