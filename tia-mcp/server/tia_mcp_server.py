"""MCP-server (stdio) voor TIA Portal V19. Praat via JSON-regels met TiaBridge.exe (net48, Openness)."""
import json
import os
import subprocess
import sys
import threading
from typing import Optional

from mcp.server.fastmcp import FastMCP

BRIDGE_EXE = os.environ.get(
    "TIA_BRIDGE_EXE",
    os.path.join(os.path.dirname(__file__), "..", "bridge", "TiaBridge", "bin", "Release", "net48", "TiaBridge.exe"),
)


class BridgeError(RuntimeError):
    pass


class Bridge:
    """Houdt één TiaBridge-proces open (Attach is traag); herstart bij een crash."""

    def __init__(self, cmd):
        self._cmd = cmd
        self._proc = None
        self._lock = threading.Lock()
        self._next_id = 0

    def _ensure(self):
        if self._proc is None or self._proc.poll() is not None:
            self._proc = subprocess.Popen(
                self._cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=sys.stderr, text=True, encoding="utf-8", bufsize=1,
            )

    def call(self, cmd: str, **args):
        args = {k: v for k, v in args.items() if v is not None}
        with self._lock:
            self._ensure()
            self._next_id += 1
            req = {"id": self._next_id, "cmd": cmd, "args": args}
            try:
                self._proc.stdin.write(json.dumps(req) + "\n")
                self._proc.stdin.flush()
                line = self._proc.stdout.readline()
            except (BrokenPipeError, OSError) as e:
                self._proc = None
                raise BridgeError(f"TiaBridge niet bereikbaar: {e}")
            if not line:
                self._proc = None
                raise BridgeError("TiaBridge is gestopt (zie stderr / logs van de MCP-client).")
            reply = json.loads(line)
            if not reply.get("ok"):
                raise BridgeError(reply.get("error", "onbekende fout"))
            return reply.get("result")


bridge = Bridge([BRIDGE_EXE])
mcp = FastMCP("tia-portal")


@mcp.tool()
def get_project_info(processId: Optional[int] = None) -> dict:
    """Koppelt aan een draaiende TIA Portal en geeft projectnaam, PLC's en CPU-type.
    De eerste keer toont TIA een Openness-toestemmingsvenster: bevestig dat in TIA.
    processId alleen nodig als er meerdere TIA-instanties draaien."""
    return bridge.call("get_project_info", processId=processId)


@mcp.tool()
def list_blocks(plcName: Optional[str] = None, processId: Optional[int] = None) -> dict:
    """Alle blokken (OB/FB/FC/DB) met type, nummer, taal en groep (mapstructuur)."""
    return bridge.call("list_blocks", plcName=plcName, processId=processId)


@mcp.tool()
def read_block(name: str, plcName: Optional[str] = None, maxChars: Optional[int] = None,
               processId: Optional[int] = None) -> dict:
    """Exporteert een blok als SimaticML-XML en geeft die terug.
    name: 'Main' of een pad als 'Groep/Sub/FB_Motor'."""
    return bridge.call("read_block", name=name, plcName=plcName, maxChars=maxChars, processId=processId)


if __name__ == "__main__":
    mcp.run(transport="stdio")
