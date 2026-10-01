# Roblox Stone Golem

- `Golem.fbx` – rigged low-poly golem (7 bones) with 4 animation takes: **Idle, Walk, Run, Attack**. Import into Roblox.
- `Golem.glb` – same model for previewing in any 3D viewer.
- `blender/build_golem.py` – regenerates both (`pip install bpy==4.2.0 && python build_golem.py`).
- `Golem.server.lua` – earlier parts-only version with AI (no model import needed).

## Import into Roblox Studio
1. **Avatar tab → Import 3D** (or Asset Manager → Bulk Import) → choose `Golem.fbx`. Pick *Rig / Custom* if asked. Tick "Import as single MeshPart" is NOT needed; keep the rig.
2. Colors come from vertex colors. Scale the model in Studio if it's too big/small (≈14 studs tall by default).
3. For animations: with the rig selected open **Animation Editor** → ⋮ → **Import → From FBX**, and import `Golem.fbx` once per take (Idle/Walk/Run/Attack). Save each, then publish and use the animation IDs with an `Animator`.
4. If the golem faces backwards, rotate the root 180° on Y.
