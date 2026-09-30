# Minecraft 1.20.1 terrain for Roblox

A port of Minecraft Java **1.20.1**'s overworld generator to Roblox `Terrain`, written in Luau.
It reproduces Minecraft's actual pipeline (the real noise router, splines, biome parameter table, aquifers, ore
veins, surface rules, cave and canyon carvers), streams the world around every player, and drops
placeholder `Tree` / `Ore_1…5` parts into a `GeneratedCollectables` folder instead of modelling anything.

* 1 Minecraft block = 1 Terrain voxel = **4 studs**. The world is 384 blocks (1536 studs) tall; with
  `BedrockLevel = 0` sea level is at Y = 508.
* The same seed gives the same biomes/terrain as Minecraft at the same coordinates (Minecraft `x, z` = studs / 4).
  See [Fidelity](#fidelity--what-is-and-is-not-verified) for exactly what that claim covers.

## Install

**Option A – model file (no tools):** in Studio right-click `ServerScriptService` → *Insert from File…* →
`dist/TerrainGenerator.rbxmx`. This adds the `TerrainGenerator` module and a `TerrainGeneratorRunner` script.
Delete any older `TerrainGenerator` module/script first.

**Option B – Rojo:** `rojo serve` (or `rojo build -o Terrain.rbxl`) with the included `default.project.json`.
`python3 tools/build_rbxmx.py` regenerates the model file from `src/`.

Then press Play. Recommended: enable `Workspace.StreamingEnabled` (the terrain is large).

```lua
-- optional, e.g. in your own Script before/instead of TerrainGeneratorRunner
local TerrainGenerator = require(game.ServerScriptService.TerrainGenerator)
TerrainGenerator.Config.Seed = "MyWorldName"      -- number or string, like Minecraft's level-seed
TerrainGenerator.Config.Width, TerrainGenerator.Config.Length = 2048, 2048
TerrainGenerator.Start()
```

## What it does

1. **Start-up:** generates a `Width × Length` stud area centred on (0, 0), nearest chunks first, in parallel
   (Actors). Characters are held until the area around the origin exists, then spawn on dry land.
2. **Streaming:** afterwards every player keeps a `Width × Length` window of terrain loaded around them.
   Chunks are unloaded only when they leave the windows of *all* players (plus a small margin), so players sharing
   an area never unload terrain from under each other. See [Multiplayer streaming](#multiplayer-streaming).
3. **Terrain:** Minecraft's terrain, water (oceans, rivers, lakes, aquifer-flooded caves), biomes, surface
   materials, snow/ice, caves (cheese/spaghetti/noodle + classic caves and ravines), ore veins.
4. **Collectables:** `Workspace.GeneratedCollectables/Chunk_x_z/` holds one plain `Part` per tree (`Tree`) and per ore
   vein (`Ore_1` … `Ore_5`, 5 = rarest). Nothing is modelled; attributes describe them.

### Collectable parts

| Part name | Attributes | Where |
|---|---|---|
| `Tree` | `Species` (oak, fancy_oak, birch, spruce, dark_oak, jungle_tree, mangrove, cherry, huge_red_mushroom, …), `Biome`, `Height` (trunk height in blocks) | on the ground, using each biome's vanilla tree selection and density |
| `Ore_1` … `Ore_5` | `OreType`, `Tier`, `Size` (blocks in the vein) | inside stone, at the centre of each vein |

Ore tiers (`Config.Collectables.OreTiers`): coal 1 · iron/copper 2 · redstone/lapis 3 · gold 4 · diamond/emerald 5.
Veins come from Minecraft's ore features (coal, iron, copper, gold, redstone, lapis, diamond, emerald, with their real
height ranges: emerald only in mountains, diamonds deep, coal common up high…) plus the giant copper/iron veins.

## Configuration

`TerrainGenerator.Config` (defaults in `src/TerrainGenerator/Config.luau`):

| Key | Default | Meaning |
|---|---|---|
| `Seed` | `12345` | number, numeric string (64-bit), or any string (Java `hashCode`, as Minecraft does) |
| `Width`, `Length` | `2048` | studs of loaded terrain around every player, and of the start-up area around (0,0) |
| `BedrockLevel` | `0` | Workspace Y of the world floor (Minecraft y = −64), multiple of 4 |
| `SmoothTerrain` | `true` | sub-voxel occupancy from the density gradient (smooth hills) instead of 4-stud cubes |
| `ApplyMaterialColors` | `true` | recolour Terrain materials to resemble Minecraft blocks |
| `ClearBeforeGenerating` | `true` | `Terrain:Clear()` at start |
| `Streaming.UnloadMargin` | `2` | chunks kept around each window before unloading (prevents flicker) |
| `Streaming.MaxChunksInFlight` | `8` | concurrent chunk jobs |
| `Streaming.PlayerGraceSeconds` | `30` | a player without a character keeps their window this long |
| `Streaming.KeepInitialArea` | `false` | never unload the start-up area |
| `Streaming.WriteBudgetMs` | `4` | terrain writes yield to the next frame after this many ms |
| `Workers.Enabled` / `Count` | `true` / `6` | Parallel Luau actors. Disabled = single thread (causes server hitches) |
| `Collectables.TreeDensity` | `1.0` | 1 = Minecraft's density. **Lower this for fewer trees** (0.5 = half) |
| `Collectables.OreDensity` | `0.5` | thins out ore parts; 1 = every vein |
| `Collectables.OreTiers`, `PartSize`, `ColorParts`, `FolderName`, `Enabled` | | see file |
| `Spawn.AutoSpawn` | `true` | hold characters until the origin area exists, then spawn them on land |

The old `SeaLevel`, `MaxHeight`, `HeightVariation`, `NoiseScale`, `Octaves`, … keys no longer exist: terrain shape now
comes from Minecraft's noise router. `Width`/`Length` at 2048 studs is only 512 blocks: Minecraft biomes are hundreds
of blocks wide, so a start-up area that size shows one or two biomes; more appear as players explore.

## API

```lua
TerrainGenerator.Start()                       -- yields until workers are ready, then streams in the background
TerrainGenerator.Stop()
TerrainGenerator.WaitForInitialArea()          -- yields until the start-up area is complete

TerrainGenerator.GetBiomeAt(Vector3)           --> name, info   (uses the Y of the position)
TerrainGenerator.GetBiomeAt(x, z)              --> name, info   (uses the surface height)
--   info = { Id, DisplayName, IsCustom, Base, Block = Vector3, Climate = { temperature, humidity, continentalness,
--            erosion, depth, weirdness } }
TerrainGenerator.GetClimateAt(Vector3)         --> the six raw climate values Minecraft uses
TerrainGenerator.GetHeightAt(x, z)             --> approximate surface height in studs (±1 block; ignores caves/features)
TerrainGenerator.WorldToBlock(Vector3) / BlockToWorld(bx, by, bz) / WorldToChunk(Vector3)
TerrainGenerator.IsChunkLoaded(cx, cz)
TerrainGenerator.GetStats()                    --> { loaded, queued, inflight, sources }
TerrainGenerator.RegisterBiome(definition)     -- custom biome, before Start()

-- signals
TerrainGenerator.ChunkLoaded / ChunkUnloaded   (chunkX, chunkZ)
TerrainGenerator.InitialAreaLoaded / SpawnAreaReady
```

`GetBiomeAt` needs no loaded terrain and works anywhere; it is exact (it runs Minecraft's biome lookup, including the
fuzzy zoom used for block-level queries). The first call builds a query generator (~0.2 s).

### Magical biomes

`TerrainGenerator.RegisterBiome({...})` (before `Start()`); definitions are plain data:

```lua
TerrainGenerator.RegisterBiome({
    id = "crystal_meadow", displayName = "Crystal Meadow",
    base = "meadow",                                   -- vanilla biome it inherits rules / carvers / features from
    climate = { temperature = {-0.3, 0.6}, continentalness = {0.03, 1.0}, erosion = {-0.4, 0.5} }, -- Minecraft's -1..1 units
    region = { scale = 700, threshold = 0.45 },        -- extra noise (blocks): appears only where noise > threshold
    priority = 2,
    surface = { top = "calcite", filler = "calcite", fillerDepth = 2 },
    trees = { { species = "crystal_tree", perChunk = 2 } },                       -- extra Tree parts
    ores = { { name = "mana", tier = 4, perChunk = 1.5, minY = -16, maxY = 60, size = 6 } }, -- extra Ore_4 parts
})
```

A custom biome overlays the vanilla map wherever its climate ranges *and* region noise match (highest `priority`
first). `GetClimateAt` shows the values at any spot, handy for tuning ranges. Examples:
`src/TerrainGenerator/Examples/MagicalBiomes.luau`. Blocks usable in `surface` are listed in `World/Blocks.luau`.

## Multiplayer streaming

`Streaming/ChunkManager.luau` is a pure state machine (no Roblox APIs, unit-tested). Every player (and a start-up
"anchor") is a *source* wanting a rectangular window of chunks.

* A chunk is **wanted** while inside *any* source's window, and **kept** while inside any window grown by
  `UnloadMargin`. Only chunks that nobody keeps are unloaded.
* Lifecycle `queued → inflight → loaded`. Queued chunks nobody wants are dropped; in-flight chunks (a worker can't be
  interrupted) are flagged and unloaded when they finish, unless someone wants them again; stale job results are ignored.
* Loading is nearest-to-any-player first; a player without a character (respawning) keeps its last window for
  `PlayerGraceSeconds`; joining, leaving and teleporting are all handled.
* `tests/manager.luau` checks the invariants over randomised scenarios (30 seeds × 6 players × 250 steps with random
  join/leave/teleport and random worker completion order): *no chunk is ever unloaded while a live source wants it,
  everything wanted ends up loaded, nothing is orphaned, job counts stay consistent.*

Terrain edits made by players are not persisted: an unloaded chunk regenerates from the seed when needed again.

## Architecture

```
src/TerrainGenerator/
  init.luau                  public API, start-up, spawn, player tracking
  Config.luau
  Core/                      Int64 (hi/lo pairs), Xoroshiro128++, java.util.Random, MD5, SHA-256
  Noise/                     ImprovedNoise, PerlinNoise, NormalNoise, BlendedNoise, Simplex(+Perlin)
  Density/Compiler.luau      vanilla density-function graph -> Luau closures (cell interpolation, flat caches, …)
  Data/                      GENERATED from vanilla JSON by tools/ (noise params, density graph, surface rules,
                             biomes, features, carvers) – data only
  World/
    RandomState, BiomeRegistry, Climate, OverworldBiomeBuilder, BiomeSource (+ fuzzy BiomeManager zoom)
    NoiseFill (terrain), Aquifer, OreVeins, SurfaceSystem (+ vanilla surface rules), Carvers, Features, Blocks
    ChunkGenerator.luau      pipeline: noise -> surface -> carvers -> features
  Streaming/                 ChunkManager (state machine), ChunkWriter (Terrain writes), WorkerTemplate (Actor)
  Examples/MagicalBiomes.luau
```

Pipeline per 16×16-block chunk (in an Actor, parallel): density lattice at cell corners (4×8×4 blocks) → bulk fill of
provably solid/air cells, per-voxel evaluation elsewhere (aquifer + ore veins) → surface rules → carvers (replaying the
17×17 neighbouring chunks with Java's `Random`) → features (ores, disks, trees, snow/ice). Then, in the serial phase,
`ChunkWriter` writes voxels (`FillBlock` for uniform 16-block sections, `WriteVoxels` otherwise) and creates parts.

Materials: Roblox Terrain has ~20 solid materials and no per-voxel colour, so several Minecraft blocks share one material
(`World/Blocks.luau` is the editable palette); grass uses `LeafyGrass` in forest-like biomes and `Grass` elsewhere.

## Performance

Measured single-threaded in a plain Luau VM with native codegen (`--!native`, as the modules declare), per chunk:
noise fill ≈ 55 ms, surface ≈ 25 ms, carvers ≈ 7 ms, features ≈ 13 ms → **≈ 100 ms** (≈ 250 ms without native
codegen). Writing a chunk costs ≈ 4 ms of Lua plus the engine's own `WriteVoxels`/`FillBlock` time (not measured here).
The default 2048×2048 start-up area is 1024 chunks ≈ 100 s of CPU, spread over the workers. Ways to go faster: fewer
`Width/Length`, more `Workers.Count`, lower `OreDensity`. Roblox-side numbers may differ from these.

Memory: every worker Actor holds its own copy of the generator — about 12 MB after initialisation (code, vanilla data,
noise tables) and about 18 MB once its caches are warm (`collectgarbage("count")` after 60 chunks). With the default
6 workers plus the main thread that is roughly 100–130 MB of Lua heap, on top of the Terrain itself.

## Fidelity — what is and is not verified

**Bit-exact against independent reference implementations** (see `tests/run_all.sh`):
* `Int64` arithmetic, Xoroshiro128++, seed upgrade, positional randoms, `Mth.getSeed`, `java.util.Random`,
  `setLargeFeatureSeed`, MD5, SHA-256 — vs Python big-int code (and standard test vectors).
* Improved/Perlin/Normal/legacy-Blended noise for several seeds — vs an independent Python transcription.
* The compiled density functions (all six climate fields, initial/final density, aquifer, vein noises — 1800 samples)
  — vs a naive interpreter of the *original vanilla JSON*, so the dedupe, constant folding, spline evaluation and
  min/max short-circuits provably change nothing.
* The bulk-fill shortcuts (solid cells, the aquifer "above everything" cut-off) — vs brute-force per-voxel evaluation.

**Ported from memory of the Java source, with structural checks but no reference to compare against here:** the biome
parameter table (7,593 points; every biome reachable; no gaps in the climate space; nearest search equals brute force),
`BiomeManager` zoom, aquifers, ore veins, `SurfaceSystem`/rules interpreter, carvers, feature placement. **I could not run
a real Minecraft to diff chunks** (its servers, the wiki and Roblox docs are not reachable from the environment this was
built in), so "same seed, same world" is a design goal I believe holds for noise, climate and terrain shape, not something
I have confirmed against the game. To check: `GetBiomeAt` at a few coordinates versus chunkbase / `/locate biome`.

**Known deliberate differences / not implemented**
* Feature *positions* use a per-feature, per-chunk random rather than vanilla's decoration seeds, so tree/ore coordinates
  are not Minecraft's, though densities, height ranges, biome rules and species mixes are. Ore blobs (granite, dirt…)
  are simulated across chunk borders; sand/clay/gravel disks are clipped at chunk borders.
* Not generated: structures (villages, mineshafts, strongholds…), lakes/springs, geodes, fossils, vegetation patches
  (grass, flowers, kelp, corals…), dripstone/moss decoration. Trees are placeholder parts.
* Carver/spline arithmetic uses doubles instead of Java `float`s (sub-block boundary effects only).
* `SmoothTerrain` (sub-voxel occupancy) is a Roblox-specific addition, not vanilla.
* Terrain edits are not persisted; there is no multi-server world sharing.
* Roblox-side code (Actors, `WriteVoxels`, spawn) is tested against a mock of the Roblox API, not in Studio.

## Development

```
python3 tools/fetch_vanilla.py     # downloads vanilla 1.20.1 worldgen JSON (misode/mcmeta) into tools/.cache
python3 tools/build_data.py        # regenerates src/TerrainGenerator/Data/*.luau
python3 tools/build_rbxmx.py       # regenerates dist/TerrainGenerator.rbxmx
tests/run_all.sh                   # needs the `luau` CLI on PATH (github.com/luau-lang/luau/releases) and python3
```

The vanilla data comes from the `1.20.1-data-json` tag of `misode/mcmeta`, a mirror of the game's data pack.
