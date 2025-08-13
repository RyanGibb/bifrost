import json

def get_control_schema() -> dict:
    """Return available node types and their valid properties."""
    from bigraph_dsl import CONTROL_SCHEMA
    return CONTROL_SCHEMA

def get_prompt(subgraph_state, tool_list):
    schema_json = json.dumps(get_control_schema(), indent=2)
    return (
        f"""
You are an assistant that can query and modify a bigraph via MCP tools. 

You can inspect the graph state, find nodes, and write and save rules. 

You have access to these tools:
{tool_list}

**CURRENT STATE TO ANALYZE:**
{subgraph_state}

**YOUR TASK:**
Look at the current state and identify automation opportunities. Common patterns to look for:
1. Motion detected (PIR: motion_detected=True) but lights are off (Light: brightness=0 or False)
2. No motion detected but lights are on (wasting energy)
3. Display screens that should respond to room occupancy
4. Other logical automation rules

**OUTPUT FORMAT:**
You MUST respond with a valid JSON object in this format:

```json
{{
  "tool": "publish_rule_to_redis",
  "args": {{
    "rule": {{
      "name": "<descriptive_rule_name>",
      "redex": [
        {{
          "control": "Room",
          "id": <room_id>,
          "properties": {{ "name": "<room_name>" }},
          "children": [
            {{ "control": "PIR", "id": <pir_id>, "properties": {{ "motion_detected": true }}, "children": [] }},
            {{ "control": "Light", "id": <light_id>, "properties": {{ "brightness": 0 }}, "children": [] }}
          ]
        }}
      ],
      "reactum": [
        {{
          "control": "Room", 
          "id": <room_id>,
          "properties": {{ "name": "<room_name>" }},
          "children": [
            {{ "control": "PIR", "id": <pir_id>, "properties": {{ "motion_detected": true }}, "children": [] }},
            {{ "control": "Light", "id": <light_id>, "properties": {{ "brightness": 100 }}, "children": [] }}
          ]
        }}
      ]
    }}
  }}
}}
```

**RULES FOR RULE GENERATION:**
- Use exact IDs and property names from the current state
- Redex: describes the condition that triggers the rule (what to match)
- Reactum: describes the desired outcome (what should change)
- Only include properties that are relevant to the rule
- Property types must match the schema exactly:

{schema_json}

**EXAMPLE ANALYSIS:**
If you see:
- A Room with PIR showing motion_detected=True
- The same room has Light with brightness=0 or False
- This suggests someone entered but lights are off

Then generate a rule to turn on lights when motion is detected.

Analyze the current state now and generate an appropriate rule, or use query_state if you need more information.

You do not need to generate a rule if not necessary. 
"""
    )