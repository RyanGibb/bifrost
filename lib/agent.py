from bigraph_dsl import Bigraph, Rule

import re
import os
import subprocess
    
import anthropic

class ClaudeLLM:
    def __init__(self, model="claude-3-7-sonnet-latest"):
        self.client = anthropic.Anthropic(os.getenv("ANTHROPIC_API_KEY"))
        self.model = model

    def chat(self, user_prompt):
        response = self.client.messages.create(
            model=self.model,
            max_tokens=1024,
            temperature=0.2,
            system="""
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
            """,
            messages=[
                {"role": "user", "content": user_prompt}
            ]
        )
        return response.content[0].text.strip()

def print_bigraph(bg: Bigraph):
    for node, parent in bg._flatten_nodes():
        print(f"{node} (parent: {parent})")

def flatten_state(bg: Bigraph):
    return "\n".join(f"{n.control}(id={n.id}, parent={p})" for n, p in bg._flatten_nodes())

def strip_fenced_code_block(text):
    if "```" in text:
        return re.sub(r"^```(?:python)?\n([\s\S]*?)```$", r"\1", text.strip(), flags=re.MULTILINE)
    return text

def apply_rule(rule: Rule, target_path="target.capnp"):
    rule.save("rule.capnp")
    result = subprocess.run(
        ["../_build/default/dsl/bridge.exe", "rule.capnp", target_path],
        capture_output=True,
        text=True)
    return result.stdout

def main():
    target = Bigraph.load("target.capnp")

    while True:
        instruction = input("\nPrompt: ")
        prompt = f"""
            Below is the current bigraph state:
            {flatten_state(target)}

            Instruction: "{instruction}"

            Now write the rule using only Python code. Do not explain anything. Just emit Python code.
            """
        generated_code = llm.chat(prompt)
        generated_code = strip_fenced_code_block(generated_code)

        try:
            if "<" in generated_code and ">" in generated_code:
                raise ValueError("LLM output contains invalid content.")

            local_env = {}
            exec(generated_code, globals(), local_env)

            print(generated_code)

            rule = next((v for v in local_env.values() if isinstance(v, Rule)), None)
            if not rule:
                raise ValueError("No Rule object found.")
            
            # print(rule)
            # print(target)

            output = apply_rule(rule)
            print(output)

        except Exception as e:
            print(f"❌ Error: {e}")

if __name__ == "__main__":
    llm = ClaudeLLM()
    main()
