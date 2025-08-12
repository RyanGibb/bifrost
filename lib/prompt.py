import json

def get_control_schema() -> dict:
    """Return available node types and their valid properties."""
    from bigraph_dsl import CONTROL_SCHEMA
    return CONTROL_SCHEMA

# TODO - could I constrain a bit more programatically?
def get_prompt(user_prompt, tool_list):
    schema_json = json.dumps(get_control_schema(), indent=2)
    return (
        f"""

User request: {user_prompt}

You are an assistant that can query and modify a bigraph via MCP tools. 

You can inspect the graph state, find nodes, and write and save rules. You have access to the following tools:
{tool_list}

You MUST output a **valid JSON object*:
{{"tool": "tool_name", "args": {{ ... }} }}

If you are authoring a rule, you MUST output a **valid JSON object** following this schema:

{{
  "tool": "publish_rule_to_redis",
  "args": {{
    "rule": {{
      "name": "<string>",
      "redex": [
        {{
          "control": "<ControlName>",
          "id": <int>,
          "properties": {{ "<prop_name>": <value> }},
          "children": [ ... nested nodes ... ]
        }}
      ],
      "reactum": [
        {{
          "control": "<ControlName>",
          "id": <int>,
          "properties": {{ "<prop_name>": <value> }},
          "children": [ ... nested nodes ... ]
        }}
      ]
    }}
  }}
}}

**SCHEMA CONSTRAINTS**:
- Controls and properties **must match exactly** one in this schema:
{schema_json}
- You may only use properties listed for that control.
- All property values must be of the correct type and within allowed ranges or sets.
- Only include properties in Reactum if they **change** from the Redex.

**RULE DESIGN**:
- Redex: minimal properties needed for matching.
- Reactum: only changed properties.
- Node IDs must be consistent between Redex and Reactum for the same logical node.
- Do NOT invent new controls or properties.
- Use nested `"children"` arrays to represent hierarchy.

Example output:

```json
{{
  "tool": "publish_rule_to_redis",
  "args": {{
    "rule": {{
      "name": "turn_on_light",
      "redex": [
        {{
          "control": "Room",
          "id": 0,
          "properties": {{}},
          "children": [
            {{ "control": "Person", "id": 1, "properties": {{}}, "children": [] }},
            {{ "control": "Light", "id": 2, "properties": {{"brightness": 0}}, "children": [] }}
          ]
        }}
      ],
      "reactum": [
        {{
          "control": "Room",
          "id": 0,
          "properties": {{}},
          "children": [
            {{ "control": "Person", "id": 1, "properties": {{}}, "children": [] }},
            {{ "control": "Light", "id": 2, "properties": {{"brightness": 100}}, "children": [] }}
          ]
        }}
      ]
    }}
  }}
}}
"""
)