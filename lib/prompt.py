import json

def get_control_schema() -> dict:
    from bigraph_dsl import CONTROL_SCHEMA
    return CONTROL_SCHEMA

def get_prompt(subgraph_state, tool_signatures, event_data, conversation_history, rule_published=False):
    schema_json = json.dumps(get_control_schema(), indent=2)

    event_desc = ""
    if event_data:
        event_type = event_data.get('type', 'Unknown')
        event_data_str = json.dumps(event_data.get('data', {}), indent=2)
        event_desc = f"""
    EVENT THAT TRIGGERED THIS ESCALATION:
    Type: {event_type}
    Data: {event_data_str}
    """

    history_str = ""
    if conversation_history:
        history_str = "\nPREVIOUS TOOL CALLS IN THIS CONVERSATION:\n"
        for call in conversation_history:
            if "error" in call:
                history_str += f"\nTried: {call['tool']}({json.dumps(call['args'])})\nError: {call['error']}\n"
            else:
                history_str += f"\nCalled: {call['tool']}({json.dumps(call['args'])})\nResult: {json.dumps(call['result'], indent=2)}\n"

    if rule_published:
        history_str += "\n[Rule(s) have been published. You can publish more if needed or finish.]"

    return f"""
You are a hierarchical automation assistant. You can query and modify a bigraph model of a space. You can inspect the graph state, find nodes, and write and save rules.
- **MID TIER HARD RULE:** You MUST NOT use any non-local tools or external context. If you need them, STOP and return a null tool selection so the system can escalate.
- **CLOUD TIER:** You may use external tools when necessary.

{event_desc}

CURRENT STATE:
{subgraph_state}

AVAILABLE TOOLS (* = required parameter):
{tool_signatures}

{history_str}

YOUR TASK:
1. Understand the event and current state.
2. Use tools to gather any additional **allowed** context.
3. Create **one or more rules** to handle this situation at the appropriate tier.
   - For escalation triggers at the hub, publish **bigraph rules** named with the prefix `ESCALATE__` whose reactum is identical to the redex (no-op). Hubs treat these as escalate-on-match.

RULE CREATION OPTIONS:
- publish_rule_to_redis: Publish a single bigraph reaction rule
- publish_rules_batch: Publish multiple related rules at once (preferred for complex scenarios)

RULE CREATION MUSTS:
- Use exact IDs from the current state
- Use only available types and properties for each node
- In redex: match the pattern 
- In reactum: change only what's needed 
- Include all nodes from redex in reactum, even unchanged ones
- Each node needs: control, id, properties, children (can be empty [])

IMPORTANT:
- Call ONE tool at a time
- Use exact parameter names shown in tool signatures
- Then create rule(s) that would handle this event type automatically

AVAILABLE NODE TYPES AND PROPERTIES:
{schema_json}

OUTPUT FORMAT (single rule):
{{
  "tool": "publish_rule_to_redis",
  "args": {{
    "rule": {{
      "name": "<descriptive_rule_name>",
      "redex": [{{"control": "<node_type>", "id": <id>, "properties": {{}} , "children": []}}],
      "reactum": [{{"control": "<node_type>", "id": <id>, "properties": {{}} , "children": []}}],
      "hub_id": "<hub_id>"
    }}
  }}
}}

OR (batch):
{{
  "tool": "publish_rules_batch",
  "args": {{
    "rules": [ ... ],
    "hub_id": "<hub_id>"
  }}
}}
"""
