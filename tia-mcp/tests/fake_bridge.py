"""Nep-bridge voor het testen van de MCP-laag zonder TIA Portal (zelfde JSON-regelprotocol)."""
import json, sys
for line in sys.stdin:
    req = json.loads(line)
    c = req["cmd"]
    if c == "get_project_info":
        res = {"projectName": "Demo", "plcs": [{"plcName": "PLC_1", "deviceName": "PLC_1"}]}
    elif c == "list_blocks":
        res = {"plc": "PLC_1", "count": 1, "blocks": [{"name": "Main", "type": "OB", "number": 1, "language": "LAD", "group": ""}]}
    elif c == "read_block":
        res = {"name": req["args"]["name"], "xml": "<Document/>", "truncated": False}
    else:
        print(json.dumps({"id": req["id"], "ok": False, "error": "Onbekend commando: " + c}), flush=True); continue
    print(json.dumps({"id": req["id"], "ok": True, "result": res}), flush=True)
