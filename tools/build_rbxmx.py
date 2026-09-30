#!/usr/bin/env python3
"""Builds dist/TerrainGenerator.rbxmx (a Roblox XML model) from src/, mirroring the Rojo mapping rules used by
default.project.json:  init.luau -> the folder becomes a ModuleScript; *.server.luau -> Script;
*.luau -> ModuleScript; folders -> Folder; init.meta.json / X.meta.json override className / properties.

    python tools/build_rbxmx.py
Import in Studio: right-click ServerScriptService > Insert from File... > dist/TerrainGenerator.rbxmx
"""
import json
import sys
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
OUT = ROOT / "dist" / "TerrainGenerator.rbxmx"

_counter = 0


def referent() -> str:
    global _counter
    _counter += 1
    return f"RBX{_counter:05d}"


def cdata(text: str) -> str:
    return "<![CDATA[" + text.replace("]]>", "]]]]><![CDATA[>") + "]]>"


def props_xml(name: str, source: str | None, extra: dict) -> str:
    out = [f'<string name="Name">{escape(name)}</string>']
    for key, value in extra.items():
        if isinstance(value, bool):
            out.append(f'<bool name="{key}">{"true" if value else "false"}</bool>')
        elif isinstance(value, (int, float)):
            out.append(f'<double name="{key}">{value}</double>')
        else:
            out.append(f'<string name="{key}">{escape(str(value))}</string>')
    if source is not None:
        out.append(f'<ProtectedString name="Source">{cdata(source)}</ProtectedString>')
    return "<Properties>" + "".join(out) + "</Properties>"


def read_meta(path: Path) -> dict:
    return json.loads(path.read_text()) if path.exists() else {}


def script_class(filename: str) -> tuple[str, str]:
    """Returns (instance name, class) for a .luau file."""
    if filename.endswith(".server.luau"):
        return filename[: -len(".server.luau")], "Script"
    if filename.endswith(".client.luau"):
        return filename[: -len(".client.luau")], "LocalScript"
    return filename[: -len(".luau")], "ModuleScript"


def file_item(path: Path) -> str:
    name, cls = script_class(path.name)
    meta = read_meta(path.with_name(name + ".meta.json"))
    cls = meta.get("className", cls)
    return f'<Item class="{cls}" referent="{referent()}">{props_xml(name, path.read_text(), meta.get("properties", {}))}</Item>'


def dir_item(path: Path) -> str:
    init = next((path / f"init{ext}" for ext in (".luau", ".server.luau", ".client.luau") if (path / f"init{ext}").exists()), None)
    meta = read_meta(path / "init.meta.json")
    children = []
    for child in sorted(path.iterdir()):
        if child.name.startswith("init.") or child.name.endswith(".meta.json"):
            continue
        if child.is_dir():
            children.append(dir_item(child))
        elif child.suffix == ".luau":
            children.append(file_item(child))
    if init is not None:
        _, cls = script_class(init.name if init.name != "init.luau" else "init.luau")
        cls = meta.get("className", cls)
        source = init.read_text()
    else:
        cls = meta.get("className", "Folder")
        source = None
    return f'<Item class="{cls}" referent="{referent()}">{props_xml(path.name, source, meta.get("properties", {}))}' + "".join(children) + "</Item>"


def main() -> int:
    items = [dir_item(SRC / "TerrainGenerator"), file_item(SRC / "TerrainGeneratorRunner.server.luau")]
    xml = (
        '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">\n'
        "<Meta name=\"ExplicitAutoJoints\">true</Meta>\n" + "\n".join(items) + "\n</roblox>\n"
    )
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(xml, encoding="utf-8")
    print(f"{OUT.relative_to(ROOT)}  {OUT.stat().st_size / 1024:.0f} KB, {_counter} instances")
    return 0


if __name__ == "__main__":
    sys.exit(main())
