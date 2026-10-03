# Minecraft 1.20.1 terrain for Roblox

A port of Minecraft Java **1.20.1**'s overworld generator to Roblox `Terrain`, written in Luau. It reproduces
Minecraft's actual pipeline (the real noise router, splines, biome parameter table, aquifers, ore veins, surface
rules, cave and canyon carvers).

* **Terrain is drawn by each client**, around that player (plus every *locked* chunk). The server writes no terrain.
* **The server decides everything that is not terrain** — trees, ores, structures — and announces each one by calling
  a single function, `placeThing(thingType, location, info)` (`Placement.luau`). It only prints for now; you write the
  placing code.
* You can **configure where and how often** every tree, ore and structure spawns, **add** your own, **add/remove
  biomes**, **remap Terrain materials**, and **load or lock chunks** from scripts.
* 1 Minecraft block = 1 Terrain voxel = **4 studs**. The world is 384 blocks (1536 studs) tall; with `BedrockLevel = 0`
  sea level is at Y = 508. Minecraft `x, z` = studs / 4.

See [Fidelity](#fidelity--what-is-and-is-not-verified) for exactly what "same as Minecraft" covers.

## Install

**Option A – model file (no tools):** in Studio right-click `ServerScriptService` → *Insert from File…* →
`dist/TerrainGenerator.rbxmx`. This adds the `TerrainGenerator` module and a `TerrainGeneratorRunner` script. Delete any
older `TerrainGenerator` module/script first.

**Option B – Rojo:** `rojo serve` (or `rojo build -o Terrain.rbxl`) with the included `default.project.json`.
`python3 tools/build_rbxmx.py` regenerates the model file from `src/`.

Then press Play. Nothing else to place: on start the server copies the module to `ReplicatedStorage` (clients need its
code) and installs a client runner into `StarterPlayerScripts`.

* Leave `Workspace.StreamingEnabled` **off** in the default client mode (the server has no terrain to stream).
* Change settings in a server Script **before** `Start()`; they are copied to every client:

```lua
local TerrainGenerator = require(game.ServerScriptService.TerrainGenerator)
TerrainGenerator.Config.Seed = "MyWorldName"        -- number or string, like Minecraft's level-seed
TerrainGenerator.Config.Trees["Oak Tree"].Biomes = { "plains", "forest" }
TerrainGenerator.Start()
```

## How it fits together

```
 server                                                        each client
 ──────                                                        ───────────
 Start(): publishes Config + spawn point + lock list ───────▶  StartClient() (installed automatically)
 server workers (Actors): full pipeline per chunk              client workers (Actors): same pipeline,
   → trees / ores / structures → Placement.placeThing            → Terrain:WriteVoxels (local to this client)
 chunk windows around every player + locks                     chunk window around this player + all locks
 LockChunk / LoadChunk / ...  ── lock list (attributes) ────▶  draws locked chunks, also for late joiners
 spawns characters once the client reports "ready" ◀────────   ClientReady (RemoteEvent)
                                                               wandering pig at the spawn point
```

* The server has **no terrain**, so server-side physics/raycasts/NPCs see an empty world. Players walk on their own
  client's terrain (network ownership). If you need a normal server-side terrain, set `Config.TerrainMode = "Server"`:
  the server writes the terrain (replicated to everybody) and clients only run the pig.
* Characters are held (`CharacterAutoLoads = false`) until the player's client has drawn the area around the spawn
  point; the spawn area is *locked*, so respawns are always safe. Disable with `Spawn.AutoSpawn = false`.

## `placeThing` — the hook where you place things

`src/TerrainGenerator/Placement.luau`:

```lua
placeThing(thingType: string, location: Vector3, info)
--   thingType  "Oak Tree", "Iron Ore", "Village", "Medieval Castle", ... (names from Config.Trees/Ores/Structures)
--   location   studs. Trees & structures: the ground point. Ores: the centre of the vein.
--   info       { Kind = "Tree"|"Ore"|"Structure", Biome, Chunk = Vector2, Seed, Rotation (structures, degrees),
--                Size (ore vein blocks), Height (tree trunk height) }
removeThings(chunkX, chunkZ)    -- the chunk unloaded: remove what you placed there
```

Both only **print** (`Add Place Structure/Ore Code Here ...`, rate limited by `Placement.MaxPrintsPerSecond`; silence
with `Config.Placement.Print = false`). Write your code in those functions, or install handlers without editing the module:

```lua
TerrainGenerator.SetPlacementHandler(function(thingType, location, info) ... end)
TerrainGenerator.SetRemovalHandler(function(chunkX, chunkZ) ... end)
```

Placing is deterministic: a chunk that unloads and loads again places exactly the same things again (call
`removeThings` first). Default thing names: trees — Oak, Fancy Oak, Swamp Oak, Birch, Tall Birch, Spruce, Pine, Giant
Spruce, Giant Pine, Jungle Tree, Giant Jungle Tree, Jungle Bush, Acacia, Dark Oak, Mangrove, Tall Mangrove, Cherry
(…"Tree"), Huge Red/Brown Mushroom; ores — Coal, Iron, Copper, Gold, Redstone, Lapis Lazuli, Diamond, Emerald (…"Ore");
structures — Village, Medieval Castle, Watchtower, Well, Campsite, Lone Cabin, Ruined Tower, Stone Circle, Mountain
Shrine. `TerrainGenerator.GetThingNames()` lists them all.

## Configuration

`TerrainGenerator.Config` (defaults and comments in `src/TerrainGenerator/Config.luau`):

| Key | Default | Meaning |
|---|---|---|
| `Seed` | `12345` | number, numeric string (64-bit), or any string (Java `hashCode`, as Minecraft does) |
| `Width`, `Length` | `1024` | studs of terrain around every player (`Client.Width/Length` override what clients draw) |
| `BedrockLevel` | `0` | Workspace Y of the world floor (Minecraft y = −64), multiple of 4 |
| `TerrainMode` | `"Client"` | `"Client"`: each client draws its terrain; `"Server"`: the server writes it |
| `SmoothTerrain` | `true` | sub-voxel occupancy from the density gradient (smooth hills) instead of 4-stud cubes |
| `Decoration` | `false` | Terrain grass blades (`false` is a big client FPS saver) |
| `Streaming.UnloadMargin` | `2` | chunks kept around each window before unloading (prevents flicker) |
| `Streaming.AdaptiveLoad`, `TargetFrameMs` | `true`, `25` | fewer concurrent jobs, or a pause, while frames are slow |
| `Server.Width`, `Length` | `nil` | how far around each player the *server* places things (nil = `Width`/`Length`; smaller = less server CPU) |
| `Workers.Enabled/Count/SliceMs` | `true`, `3`, `6` | server workers (they only compute where things go) |
| `Client.Workers/SliceMs/WriteBudgetMs` | `2`, `4`, `2` | per-client workers, ms of work per frame per worker, ms of Terrain writes per frame |
| `Placement.Print`, `MaxPrintsPerSecond` | `true`, `40` | the placeholder printing |
| `Spawn.AutoSpawn`, `ReadyRadiusChunks` | `true`, `2` | hold characters until their client is ready; size of the locked spawn area |
| `Mobs.Pig` | `true` | the wandering pig at the spawn point |

### Where things spawn

Spawn rates are multipliers on Minecraft's own density (`1` = same as Minecraft). They multiply:
`Spawning.TreeRate/OreRate` × `Spawning.BiomeTreeRate[biome]/BiomeOreRate[biome]` × `Rate` × `BiomeRate[biome]` of the
thing. `Config.Trees` and `Config.Ores` have an entry for every default tree and ore:

```lua
Config.Trees["Oak Tree"].Biomes = { "plains", "forest" }   -- oaks only there (nil = wherever Minecraft spawns them)
Config.Trees["Birch Tree"].Rate = 0.5                       -- half as many
Config.Trees["Dark Oak Tree"].BiomeRate = { dark_forest = 2 }
Config.Trees["Cherry Tree"].Extra = { plains = 0.3 }        -- also ~0.3 per chunk in biomes Minecraft does not use
Config.Ores["Coal Ore"].BiomeRate = { desert = 0 }
Config.Spawning.BiomeTreeRate.forest = 1.5                  -- every tree in forests; one entry per biome, all 1
Config.Trees["Oak Tree"].Enabled = false
```

`Rate < 1` thins Minecraft's placements, `Rate > 1` adds copies a few blocks from the originals. All decisions use a
seeded random, so the world is stable.

**Structures** (`Config.Structures`): Village, Medieval Castle (snowy mountains) and seven small ones, all configurable:

```lua
Village = { Enabled = true, Spacing = 34, Separation = 8, Salt = 10387312,
            Biomes = { "plains", "sunflower_plains", "meadow", "forest", "flower_forest", "birch_forest" },
            Placement = "Land", MaxSlope = 6 },
```

`Spacing/Separation/Salt` are Minecraft's `random_spread` numbers — one structure per `Spacing`×`Spacing` chunk region,
at least `Separation` chunks apart. Village uses vanilla's own values, and the chunk selection is computed exactly as
Minecraft does (`tests/structures_ref.py` checks it), so villages *start in the same chunks* as in Minecraft for the same
seed (the biome filter is yours, not vanilla's). Other fields: `Chance`, `Placement` (`"Land"`, `"Water"` = sea floor,
`"Any"`), `MaxSlope`, `Rotate`, `SpreadType`.

### Adding things

```lua
TerrainGenerator.RegisterTree({ Name = "Crystal Tree", Biomes = { "meadow" }, PerChunk = 3 })
TerrainGenerator.RegisterOre({ Name = "Mythril Ore", PerChunk = 1.5, MinY = -60, MaxY = 0, Size = 6 })
TerrainGenerator.RegisterStructure({ Name = "Desert Pyramid", Spacing = 32, Separation = 8, Salt = 14357617, Biomes = { "desert" } })
TerrainGenerator.RegisterBiome({ id = "crystal_meadow", base = "meadow", climate = { temperature = { -0.3, 0.6 } },
    region = { scale = 700, threshold = 0.45 }, surface = { top = "crystal_stone", filler = "crystal_stone" } })
TerrainGenerator.RegisterBlock({ Name = "crystal_stone", Material = "Glacier", Color = Color3.fromRGB(120, 200, 255) })
TerrainGenerator.RemoveBiome("badlands")   -- also removes a registered custom biome; RestoreBiome undoes it
```

All of these must run before `Start()`. `Examples/CustomThings.luau` shows every call.

* **Custom biomes** overlay the vanilla map where their climate ranges *and* region noise match (highest `priority`
  first); `base` is the vanilla biome whose surface rules, carvers and features they inherit; `GetClimateAt(position)`
  helps tuning. Examples: `Examples/MagicalBiomes.luau`.
* **Removing a biome** deletes its points from Minecraft's climate table, so the nearest remaining biome takes over its
  territory. Terrain shape does not change (it comes from the noise router, not the biomes).
* **Materials.** Roblox Terrain has only ~22 materials and no per-voxel colour, so several Minecraft blocks share one.
  `Config.Materials.Blocks = { grass_block = "LeafyGrass" }` shows a block with another material,
  `Materials.Colors = { Grass = Color3... }` recolours a material, `Materials.Variants = { Grass = "MyVariant" }` applies a
  `MaterialVariant` (custom textures, from `MaterialService`) to a base material, and `RegisterBlock` adds blocks for
  custom biome surfaces. You cannot add a 23rd base material — that is a Roblox limit.

## Loading and locking chunks (server)

A chunk is `64 × 64` studs (16 blocks); `TerrainGenerator.WorldToChunk(position)` converts.

```lua
TerrainGenerator.LockChunk(cx, cz, owner?)           TerrainGenerator.UnlockChunk(cx, cz, owner?)
TerrainGenerator.LockArea(cx0, cz0, cx1, cz1, owner?) TerrainGenerator.UnlockArea(cx0, cz0, cx1, cz1, owner?)
TerrainGenerator.UnlockAll(owner?)                   TerrainGenerator.IsChunkLocked(cx, cz, owner?)
TerrainGenerator.GetLockedChunks(owner?)
TerrainGenerator.LoadChunk(cx, cz, { Lock = true, Owner = "LoadChunk", Wait = true, Timeout = 60, HoldSeconds = 10 })
```

* A **locked** chunk is loaded and kept for everyone — the server keeps its things, **every client draws it**, also
  clients that join later (the lock list is replicated state) — however far all players are, until it is unlocked.
* Locks have **owners** (default `"default"`): a chunk stays locked while any owner holds it, so scripts cannot unlock
  each other's chunks. Locks can be set before `Start()`.
* `LoadChunk` yields until the chunk is loaded on the server (generated, things placed) and, by default, locks it.
  `Lock = false` keeps it only `HoldSeconds`.
* Signals: `ChunkLoaded`, `ChunkUnloaded` (chunkX, chunkZ), `SpawnAreaReady`, `InitialAreaLoaded`.

## Other API

```lua
TerrainGenerator.Start()  /  Stop()                 -- Start() works on server and client; StartServer()/StartClient()
TerrainGenerator.GetBiomeAt(Vector3)  --> name, info  (or (x, z) using the surface height; works anywhere, also on clients)
TerrainGenerator.GetClimateAt(Vector3)               TerrainGenerator.GetHeightAt(x, z)  --> studs
TerrainGenerator.WorldToBlock / BlockToWorld / WorldToChunk
TerrainGenerator.GetSpawnPoint()  GetBiomeNames()  GetThingNames()  IsChunkLoaded(cx, cz)  GetStats()
```

`GetBiomeAt` needs no loaded terrain and is exact (it runs Minecraft's biome lookup, including the fuzzy zoom used for
block-level queries). The first call builds a query generator (~0.2 s).

## The pig

One pig wanders around the spawn point. It is a client-side mob: every client animates the same pig, because its walk is
a pure function of the world seed and the server clock (no network traffic, nothing for the server to simulate), and it
follows the client's own terrain with a downward raycast. It hides while the terrain under it is not loaded and never
walks into water. Turn it off with `Config.Mobs.Pig = false`.

## Multiplayer streaming

`Streaming/ChunkManager.luau` is a pure state machine (no Roblox APIs, unit-tested). Every player (and a start-up
"anchor") is a *source* wanting a rectangular window of chunks; locked chunks are an extra, immovable demand.

* A chunk is **wanted** while inside *any* window or lock, and **kept** while inside any window grown by
  `UnloadMargin`. Only chunks that nobody keeps are unloaded.
* Lifecycle `queued → inflight → loaded`. Queued chunks nobody wants are dropped; in-flight chunks (a worker can't be
  interrupted) are flagged and unloaded when they finish, unless someone wants them again; stale job results are ignored.
* Loading is nearest-to-any-player first (locked chunks far from everyone load after those); a player without a
  character keeps its last window for `PlayerGraceSeconds`.
* `tests/manager.luau` checks the invariants over randomised scenarios (join/leave/teleport/random worker completion
  order, and owners locking/unlocking rectangles): *no chunk is ever unloaded while a live source or a lock wants it,
  everything wanted ends up loaded, nothing is orphaned, job counts stay consistent.*

Terrain edits made by players are not persisted: an unloaded chunk regenerates from the seed when needed again.

## Architecture

```
src/TerrainGenerator/
  init.luau                  public API (queries, registration, locks, Start)
  Config.luau  Placement.luau                       settings · the placeThing / removeThings hook
  ClientRunner.client.luau   installed into StarterPlayerScripts by the server (template, disabled)
  Runtime/                   Server.luau (publishing, players, spawn, locks, things) · Client.luau (terrain, locks,
                             ready handshake, pig) · Shared.luau (what is published, option builders)
  Mobs/Pig.luau
  Core/                      Int64 (hi/lo pairs), Xoroshiro128++, java.util.Random, MD5, SHA-256
  Noise/                     ImprovedNoise, PerlinNoise, NormalNoise, BlendedNoise, Simplex(+Perlin)
  Density/Compiler.luau      vanilla density-function graph -> Luau closures (cell interpolation, flat caches, …)
  Data/                      GENERATED from vanilla JSON by tools/ (noise params, density graph, surface rules,
                             biomes, features, carvers) – data only
  World/
    RandomState, BiomeRegistry, Climate, OverworldBiomeBuilder, BiomeSource (+ fuzzy BiomeManager zoom)
    NoiseFill (terrain), Aquifer, OreVeins, SurfaceSystem (+ vanilla surface rules), Carvers, Features, Blocks
    Placements (spawn rules), Structures (random_spread), ThingNames
    ChunkGenerator.luau      pipeline: noise -> surface -> carvers -> features -> spawn rules
  Streaming/                 ChunkManager, LockRegistry, LoadGovernor, ChunkWriter (Terrain writes), WorkerPool,
                             WorkerMain + WorkerTemplate (Actor with a Script for the server, a LocalScript for clients)
  Examples/                  MagicalBiomes.luau, CustomThings.luau
```

Pipeline per 16×16-block chunk (in an Actor, parallel): density lattice at cell corners (4×8×4 blocks) → bulk fill of
provably solid/air cells, per-voxel evaluation elsewhere (aquifer + ore veins) → surface rules → carvers (replaying the
17×17 neighbouring chunks with Java's `Random`) → features (ores, disks, trees, snow/ice) → spawn rules → structures.
Clients skip the tree/ore/structure work; the server skips the sub-voxel occupancy. Then, in the serial phase,
`ChunkWriter` writes voxels (`FillBlock` for uniform 16-block sections, `WriteVoxels` otherwise).

## Performance

Measured single-threaded in a plain Luau VM with native codegen (`--!native`, as the modules declare): ≈ 90–100 ms of
CPU per chunk for both roles (noise fill ≈ 55, surface ≈ 25, carvers ≈ 7, features ≈ 7–13; ≈ 250 ms without native
codegen). The engine's own `WriteVoxels` time is not measured here. Roblox-side numbers may differ.

What keeps the game smooth:

* **No terrain on the server and no terrain traffic** (default mode): the server only computes where things go.
* **Time-sliced generation**: workers hand the frame back after `SliceMs` (6 ms server, 4 ms client), so no parallel task
  holds a frame for a whole chunk; terrain writes are budgeted per frame (`Client.WriteBudgetMs`), reuse their voxel
  tables, and unloading only clears the height that was written.
* **Adaptive load**: each machine feeds its own frame time to a governor that lowers the number of concurrent chunk jobs,
  pauses generation when frames are very slow (but never while the chunk under the player is missing), and ramps up
  again when they recover. At most one job runs per worker.
* `Decoration = false` (no Terrain grass blades), a modest default window (`1024 × 1024` studs), and nearest-first loading.

On a device with few cores lower `Client.Workers` to 1. Memory: every worker Actor holds its own copy of the generator —
about 12 MB after initialisation and about 18 MB once its caches are warm.

## Fidelity — what is and is not verified

**Bit-exact against independent reference implementations** (see `tests/run_all.sh`):
* `Int64` arithmetic, Xoroshiro128++, seed upgrade, positional randoms, `Mth.getSeed`, `java.util.Random`,
  `setLargeFeatureSeed`, MD5, SHA-256 — vs Python big-int code (and standard test vectors).
* Improved/Perlin/Normal/legacy-Blended noise for several seeds — vs an independent Python transcription.
* The compiled density functions (all six climate fields, initial/final density, aquifer, vein noises — 1800 samples)
  — vs a naive interpreter of the *original vanilla JSON*, so the dedupe, constant folding, spline evaluation and
  min/max short-circuits provably change nothing.
* The bulk-fill shortcuts (solid cells, the aquifer "above everything" cut-off) — vs brute-force per-voxel evaluation.
* Structure start chunks (`random_spread` with `java.util.Random`) — vs a Python transcription (the formula and
  Village's spacing 34 / separation 8 / salt 10387312 are from memory of the Java source and the vanilla data pack).

**Ported from memory of the Java source, with structural checks but no reference to compare against here:** the biome
parameter table (7,593 points; every biome reachable; no gaps in the climate space; nearest search equals brute force),
`BiomeManager` zoom, aquifers, ore veins, `SurfaceSystem`/rules interpreter, carvers, feature placement. **I could not run
a real Minecraft to diff chunks** (its servers, the wiki and Roblox docs are not reachable from the environment this was
built in), so "same seed, same world" is a design goal I believe holds for noise, climate and terrain shape, not something
I have confirmed against the game. To check: `GetBiomeAt` at a few coordinates versus chunkbase / `/locate biome`.

**Known deliberate differences / not implemented**
* **Tree and ore positions are not Minecraft's.** Features use a per-feature, per-chunk random rather than vanilla's
  decoration seeds (and trees/ores are not simulated block by block), so *what* spawns *where* statistically follows
  Minecraft (counts, height ranges, biome rules, species mixes) but individual coordinates differ. Making them
  bit-identical needs the full feature-order sort, per-feature seeding and every tree/ore placement algorithm.
* Not generated: structure *contents* (only start points are announced; vanilla villages/mineshafts/… do not exist),
  lakes/springs, geodes, fossils, vegetation patches (grass, flowers, kelp, corals…), dripstone/moss decoration.
* Carver/spline arithmetic uses doubles instead of Java `float`s (sub-block boundary effects only).
* `SmoothTerrain` (sub-voxel occupancy) is a Roblox-specific addition, not vanilla.
* Terrain edits are not persisted; there is no multi-server world sharing.
* **Roblox-side code is tested against a mock of the Roblox API, not in Studio**: Actors on the server *and on
  clients*, `RunContext`-free LocalScript/Script workers, client-side Terrain writes, attribute replication of the lock
  list, the runtime clone of the module into `ReplicatedStorage`, `SetBaseMaterialOverride`, and the `RemoteEvent`
  handshake all follow the documented Roblox behaviour but have not been seen running.

## Development

```
python3 tools/fetch_vanilla.py     # downloads vanilla 1.20.1 worldgen JSON (misode/mcmeta) into tools/.cache
python3 tools/build_data.py        # regenerates src/TerrainGenerator/Data/*.luau
python3 tools/build_rbxmx.py       # regenerates dist/TerrainGenerator.rbxmx
tests/run_all.sh                   # needs the `luau` CLI on PATH (github.com/luau-lang/luau/releases) and python3
```

The vanilla data comes from the `1.20.1-data-json` tag of `misode/mcmeta`, a mirror of the game's data pack.
