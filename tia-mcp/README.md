# TIA Portal MCP-server (V19) — stap 1: lezen

Laat Claude werken in een **geopend** TIA Portal V19-project via TIA Openness.
Opzet: `server/tia_mcp_server.py` (Python, MCP over stdio) ↔ `bridge/TiaBridge` (C#, net48, Openness) via JSON-regels.
Waarom: Openness vereist .NET Framework 4.8; de MCP-SDK daarop draaien geeft afhankelijkheidsgedoe. De bridge blijft draaien, dus Attach gebeurt één keer.

**Status:** alleen stap 1 — `get_project_info`, `list_blocks`, `read_block`. Download naar PLC/PLCSIM wordt nooit gebouwd.
De bridge is **nog niet gecompileerd of getest tegen een echte TIA** (de MCP-laag is wel getest met een nepbridge: `python tests/test_server.py`).

## Vereisten
- Windows, TIA Portal V19 met een project open, Python 3.10+, .NET SDK (voor `dotnet build`).
- Gebruiker in de Windows-groep **Siemens TIA Openness** (opnieuw inloggen na toevoegen). `get_project_info` meldt of dit klopt.
- `C:\Program Files\Siemens\Automation\Portal V19\PublicAPI\V19\net48\Siemens.Engineering.dll`

## Bouwen
```
cd bridge\TiaBridge
dotnet build -c Release
pip install -r ..\..\server\requirements.txt
```
Ander DLL-pad: `dotnet build -c Release -p:TiaOpennessDll="D:\...\Siemens.Engineering.dll"`.
Compileerfouten op API-namen = melden, dan pas ik die aan.

## Configuratie
Claude Code:
```
claude mcp add tia-portal -e TIA_BRIDGE_EXE="C:\pad\tia-mcp\bridge\TiaBridge\bin\Release\net48\TiaBridge.exe" -- python C:\pad\tia-mcp\server\tia_mcp_server.py
```
Claude Desktop (`claude_desktop_config.json`):
```json
{ "mcpServers": { "tia-portal": {
  "command": "python",
  "args": ["C:\\pad\\tia-mcp\\server\\tia_mcp_server.py"],
  "env": { "TIA_BRIDGE_EXE": "C:\\pad\\tia-mcp\\bridge\\TiaBridge\\bin\\Release\\net48\\TiaBridge.exe" }
} } }
```
De eerste koppeling toont in TIA een **Openness-toestemmingsvenster** — bevestig dit.

## Veiligheid
Werk op een kopie of gearchiveerd project. Stap 1 is read-only. Latere schrijfacties komen in `ExclusiveAccess` + `Transaction`, nooit zonder `overwrite: true` over bestaande blokken.
