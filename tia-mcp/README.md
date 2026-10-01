# TIA Portal MCP-server (V19)

Laat Claude werken in een **geopend** TIA Portal V19-project via TIA Openness.
Opzet: `server/tia_mcp_server.py` (Python, MCP over stdio) ↔ `bridge/TiaBridge` (C#, net48, Openness) via JSON-regels.
Waarom: Openness vereist .NET Framework 4.8; de MCP-SDK daarop draaien geeft afhankelijkheidsgedoe. De bridge blijft draaien, dus Attach gebeurt één keer.

**Status:** alle tools staan erin, maar de C#-bridge is **nog niet gecompileerd of getest tegen een echte TIA** (de MCP-laag is wel getest met een nepbridge: `python tests/test_server.py`; de FBD-generator is los doorgerekend). Verwacht compileerfouten op API-namen en importfouten op de XML: meld ze, dan pas ik ze aan. Download naar PLC/PLCSIM bestaat niet.

Tools: `get_project_info`, `list_blocks`, `read_block`, `list_tag_tables`, `read_tag_table`, `list_types`, `read_type`, `create_tag_table`, `upsert_tags`, `create_udt`, `create_global_db`, `create_instance_db`, `import_block_xml`, `compile_plc`, `get_fbd_template`, `build_fbd_block`, `append_networks`. FBD-formaat: `docs/simaticml-fbd.md`.

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
Werk op een kopie of gearchiveerd project. Schrijfacties lopen in `ExclusiveAccess` + `Transaction` (één Undo in TIA) en overschrijven nooit zonder `overwrite: true`. Hardware, beveiliging en online functies worden niet aangeraakt.

## Werkvoorbeeld: "maak een transportbandbesturing"
1. `list_blocks`, `list_tag_tables`, `list_types`: naamgeving en nummering overnemen.
2. `create_tag_table` + `upsert_tags` voor in- en uitgangen.
3. `create_udt` (data/status), `create_global_db` waar nodig.
4. `build_fbd_block` (FB/FC, `importIntoPlc: true`), dan `create_instance_db` voor de FB.
5. `append_networks` op `Main` met `overwrite: true`: FB/FC aanroepen, data via de DB's.
6. `compile_plc`, fouten lezen, corrigeren, herhalen tot 0 fouten.
