from bigraph_dsl import Bigraph, Rule

from prompt_utils import make_prompt

from mlx_lm import load, generate

import re
import subprocess

class Mistral:
    def __init__(self, model_path="mlx-community/Mistral-7B-Instruct-v0.3-4bit"):
        self.model, self.tokenizer = load(model_path)

    def chat(self, user_prompt):
        messages = [{"role": "user", "content": user_prompt}]
        prompt = self.tokenizer.apply_chat_template(messages, add_generation_prompt=True)
        response = generate(self.model, self.tokenizer, prompt=prompt, max_tokens=256, verbose=False)
        return response.strip()

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
        instruction = input("\nWrite me a rule: ")
        prompt = make_prompt(current_state=flatten_state(target), instruction=instruction)
        generated_code = llm.chat(prompt)

        print("\n--- Generated Code ---\n")

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
            print("\n Generated content was likely not valid.")

if __name__ == "__main__":
    llm = Mistral()
    main()
