import asyncio, os, sys, json
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

HERE = os.path.dirname(__file__)

async def main():
    params = StdioServerParameters(command=sys.executable, args=[
        "-c", "import sys; sys.path.insert(0, %r); import tia_mcp_server as s; "
              "s.bridge._cmd=[%r, %r]; s.mcp.run(transport='stdio')" % (
            os.path.join(HERE, "..", "server"), sys.executable, os.path.join(HERE, "fake_bridge.py"))])
    async with stdio_client(params) as (r, w):
        async with ClientSession(r, w) as s:
            await s.initialize()
            tools = [t.name for t in (await s.list_tools()).tools]
            assert len(tools) == 17 and "compile_plc" in tools and "append_networks" in tools, tools
            out = await s.call_tool("list_blocks", {})
            assert "Main" in out.content[0].text, out
            out = await s.call_tool("read_block", {"name": "Main"})
            assert "<Document/>" in out.content[0].text
            print("OK", tools)

asyncio.run(main())
