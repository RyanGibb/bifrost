import re
import json
import asyncio
import subprocess

from fastmcp import Client

MCP_PATH = "server.py"
OLLAMA_MODEL = "qwen2.5-coder:3b"
graph_state = None

async def run_ollama(prompt: str) -> str:
    proc = subprocess.Popen(
        ["ollama", "run", OLLAMA_MODEL],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True)
    out, err = proc.communicate(prompt)
    if err:
        print("Ollama error:", err)
    return out.strip()

from prompt import get_prompt

async def main():
    global graph_state

    client = Client(MCP_PATH)

    async with client:
        tools = await client.list_tools()

        resp = await client.call_tool("load_bigraph_from_file", {"path": "target.capnp"})
        # print(f"Loaded graph: {resp}")

        while True:
            user_prompt = input("\nInstruction (or 'quit'): ")
            if user_prompt.lower() == "quit":
                break

            tool, args = await llm(user_prompt, tools)
            if not tool:
                continue

            if "graph_json" in args:
                args["graph_json"] = graph_state

            resp = await client.call_tool(tool, args)
            result = resp.data

            if isinstance(result, dict) and "nodes" in result:
                graph_state = result


async def llm(user_prompt: str, tools):
    tool_list = "\n".join(f"- {t.name}: {t.description}" for t in tools)

    output = await run_ollama(get_prompt(user_prompt, tool_list))

    cleaned = re.sub(r"^```(?:json)?|```$", "", output.strip(), flags=re.MULTILINE).strip()
    match = re.search(r"\{.*\}", cleaned, re.DOTALL)
    if match:
        cleaned = match.group(0)

    try:
        parsed = json.loads(cleaned)
        return parsed.get("tool"), parsed.get("args", {})
    except json.JSONDecodeError:
        print("Error: invalid JSON", output)
        return None, {}

if __name__ == "__main__":
    asyncio.run(main())

