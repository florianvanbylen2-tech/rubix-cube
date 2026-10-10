"""MCP-server (stdio) voor TIA Portal V19. Praat via JSON-regels met TiaBridge.exe (net48, Openness)."""
import json
import os
import subprocess
import sys
import threading
from typing import Any, Dict, List, Optional

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


@mcp.tool()
def list_tag_tables(plcName: Optional[str] = None) -> dict:
    """Alle tag tables met naam, groep en aantal tags."""
    return bridge.call("list_tag_tables", plcName=plcName)


@mcp.tool()
def read_tag_table(name: str, plcName: Optional[str] = None) -> dict:
    """Tags van een tag table: naam, datatype, adres, commentaar."""
    return bridge.call("read_tag_table", name=name, plcName=plcName)


@mcp.tool()
def create_tag_table(name: str, plcName: Optional[str] = None) -> dict:
    """Maakt een tag table aan (of geeft de bestaande terug)."""
    return bridge.call("create_tag_table", name=name, plcName=plcName)


@mcp.tool()
def upsert_tags(tableName: str, tags: List[Dict[str, Any]], plcName: Optional[str] = None) -> dict:
    """tags: lijst van {name, dataType, address, comment}. Maakt tags aan of werkt ze bij."""
    return bridge.call("upsert_tags", tableName=tableName, tags=tags, plcName=plcName)


@mcp.tool()
def list_types(plcName: Optional[str] = None) -> dict:
    """Alle UDT's (PLC data types)."""
    return bridge.call("list_types", plcName=plcName)


@mcp.tool()
def read_type(name: str, plcName: Optional[str] = None) -> dict:
    """Exporteert een UDT als XML."""
    return bridge.call("read_type", name=name, plcName=plcName)


@mcp.tool()
def create_udt(source: str, overwrite: bool = False, plcName: Optional[str] = None) -> dict:
    """UDT vanuit SCL-brontekst (TYPE "naam" ... END_TYPE). Bestaande naam alleen met overwrite=true."""
    return bridge.call("create_udt", source=source, overwrite=overwrite, plcName=plcName)


@mcp.tool()
def create_global_db(source: str, overwrite: bool = False, plcName: Optional[str] = None) -> dict:
    """Global DB vanuit brontekst (DATA_BLOCK "naam" ... END_DATA_BLOCK). Bestaande naam alleen met overwrite=true."""
    return bridge.call("create_global_db", source=source, overwrite=overwrite, plcName=plcName)


@mcp.tool()
def create_instance_db(name: str, fbName: str, number: Optional[int] = None, plcName: Optional[str] = None) -> dict:
    """Instance DB voor een bestaande FB. Zonder number wordt automatisch genummerd."""
    return bridge.call("create_instance_db", name=name, fbName=fbName, number=number, plcName=plcName)


@mcp.tool()
def import_block_xml(xml: str, overwrite: bool = False, groupPath: Optional[str] = None,
                     plcName: Optional[str] = None) -> dict:
    """Importeert een FC/FB/OB als SimaticML-XML. Een bestaand blok wordt alleen vervangen met overwrite=true."""
    return bridge.call("import_block_xml", xml=xml, overwrite=overwrite, groupPath=groupPath, plcName=plcName)


@mcp.tool()
def compile_plc(maxMessages: Optional[int] = None, plcName: Optional[str] = None) -> dict:
    """Compileert de PLC-software en geeft status, aantallen en alle meldingen (fouten eerst) terug."""
    return bridge.call("compile_plc", maxMessages=maxMessages, plcName=plcName)


@mcp.tool()
def get_fbd_template(blockName: Optional[str] = None, plcName: Optional[str] = None) -> dict:
    """Exporteert een bestaand FBD-blok als voorbeeld van de exacte V19-XML (zonder blockName: eerste FBD-blok)."""
    return bridge.call("get_fbd_template", blockName=blockName, plcName=plcName)


@mcp.tool()
def build_fbd_block(spec: Dict[str, Any], importIntoPlc: bool = False, overwrite: bool = False,
                    groupPath: Optional[str] = None, plcName: Optional[str] = None) -> dict:
    """Zet een JSON-beschrijving van een FBD-blok om naar SimaticML en importeert die optioneel.
    spec: {type: FC|FB|OB, name, number, interface: {Input|Output|InOut|Static|Temp|Constant: [{name,type,start?}]},
           networks: [{title?, comment?, logic: [statements]}]}.
    Statements:
      {type:assign, operand | operands:[..], kind:assign|set|reset|negassign, expr}
      {type:move, in, out, dataType?, en?}
      {type:call, name, blockType:FC|FB, instance?, en?, params:[{name,section,type,value}]}
    expr (boom): {operand:"#x"} | {and:[expr..]} | {or:[..]} | {xor:[..]} | {cmp:{op,dataType,in1,in2}};
      elk knooppunt mag neg:true krijgen (negatie op die ingang). Een kale string "#x" is een operand.
    Operanden: '#lokaal', '"Tag"', '"DB"."Member"', of literal (5, 2.5, TRUE, T#5s). Zie docs/simaticml-fbd.md."""
    return bridge.call("build_fbd_block", spec=spec, **{"import": importIntoPlc}, overwrite=overwrite,
                       groupPath=groupPath, plcName=plcName)


@mcp.tool()
def append_networks(blockName: str, networks: List[Dict[str, Any]], overwrite: bool = False,
                    plcName: Optional[str] = None) -> dict:
    """Voegt FBD-netwerken (zelfde formaat als build_fbd_block) toe aan een bestaand FBD-blok, bv. 'Main'.
    Exporteert het blok, voegt toe en importeert met Override: overwrite=true is verplicht."""
    return bridge.call("append_networks", blockName=blockName, networks=networks, overwrite=overwrite, plcName=plcName)


if __name__ == "__main__":
    mcp.run(transport="stdio")
