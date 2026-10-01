"""Builds a rigged, animated low-poly stone golem and exports Golem.fbx / Golem.glb.

Run:  pip install bpy==4.2.0 && python build_golem.py [--preview DIR]
Animations (separate takes): Idle, Walk, Run, Attack.
Model faces +Y in Blender (exports as -Z, Roblox's forward direction).
"""
import math, os, random, sys
import bpy, bmesh
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.dirname(HERE)
PREVIEW = sys.argv[sys.argv.index("--preview") + 1] if "--preview" in sys.argv else None

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.fps = 30

STONE = (0.43, 0.44, 0.46, 1)
DARK = (0.30, 0.31, 0.34, 1)
MOSS = (0.30, 0.47, 0.23, 1)
GLOW = (1.0, 0.62, 0.12, 1)

random.seed(7)
parts = []  # mesh objects to be joined


def srgb_to_lin(c):
    return tuple((v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4) for v in c[:3]) + (1,)


def box(name, center, size, color, bone, rot=(0, 0, 0), rough=0.18, cuts=1):
    """Chunky rocky box: subdivided, jittered, bevel-less. Fully weighted to `bone`."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    if cuts:
        bmesh.ops.subdivide_edges(bm, edges=bm.edges[:], cuts=cuts, use_grid_fill=True)
    for v in bm.verts:
        v.co.x *= size[0]; v.co.y *= size[1]; v.co.z *= size[2]
        if rough:
            v.co += Vector([random.uniform(-rough, rough) for _ in range(3)])
    bm.normal_update()
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new(name, me)
    scene.collection.objects.link(ob)
    ob.rotation_euler = tuple(math.radians(a) for a in rot)
    ob.location = center
    finish(ob, color, bone)
    return ob


def spike(name, center, color, bone, rot):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=5, radius1=0.7, radius2=0.0, depth=2.0)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new(name, me)
    scene.collection.objects.link(ob)
    ob.rotation_euler = tuple(math.radians(a) for a in rot)
    ob.location = center
    finish(ob, color, bone)


def finish(ob, color, bone):
    bpy.context.view_layer.objects.active = ob
    ob.select_set(True)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    ob.select_set(False)
    me = ob.data
    attr = me.color_attributes.new("Col", 'BYTE_COLOR', 'CORNER')
    lin = srgb_to_lin(color)
    for d in attr.data:
        d.color = lin
    for p in me.polygons:
        p.use_smooth = False
    vg = ob.vertex_groups.new(name=bone)
    vg.add([v.index for v in me.vertices], 1.0, 'REPLACE')
    parts.append(ob)


# ---------------------------------------------------------------- geometry
# Torso / hips / head
box("Torso", (0, 0, 8.0), (6, 3.5, 6), STONE, "Torso")
box("Hips", (0, 0, 5.3), (5, 3, 1.6), DARK, "Torso")
box("Head", (0, 0.2, 12.5), (3.2, 3, 3), DARK, "Head")
box("Brow", (0, 1.6, 13.3), (3.5, 0.7, 0.7), STONE, "Head", cuts=0)
box("EyeL", (-0.8, 1.7, 12.7), (0.8, 0.25, 0.5), GLOW, "Head", rough=0, cuts=0)
box("EyeR", (0.8, 1.7, 12.7), (0.8, 0.25, 0.5), GLOW, "Head", rough=0, cuts=0)
box("Core", (0, 1.95, 8.6), (1.3, 0.5, 1.3), GLOW, "Torso", rot=(0, 45, 0), rough=0, cuts=0)
box("MossBack", (0, -0.2, 11.15), (4, 2.2, 0.6), MOSS, "Torso")
box("MossHead", (0.5, -0.2, 14.1), (2, 1.6, 0.5), MOSS, "Head")
for i, x in enumerate((-1.6, 0, 1.6)):
    spike(f"Spike{i}", (x, -2.2, 9.8 - abs(x) * 0.5), DARK, "Torso", (90, 0, 0))

# Arms (+x = right of the model when it faces +Y is -x; names follow the model's own sides)
for side, sx in (("L", 4.3), ("R", -4.3)):
    b = f"Arm.{side}"
    box(f"Arm{side}", (sx, 0, 7.8), (2.6, 2.6, 7), DARK, b)
    box(f"Pauldron{side}", (sx * 1.04, 0, 11.4), (3.7, 3.7, 2.2), STONE, b)
    box(f"Fist{side}", (sx, 0.2, 3.8), (3.5, 3.5, 2.6), STONE, b)
    box(f"MossArm{side}", (sx, -0.6, 9.2), (2.8, 1.4, 0.6), MOSS, b)

# Legs
for side, sx in (("L", 1.7), ("R", -1.7)):
    b = f"Leg.{side}"
    box(f"Leg{side}", (sx, 0, 3.1), (2.9, 2.9, 5.2), DARK, b)
    box(f"Foot{side}", (sx, 0.5, 0.55), (3.5, 4.2, 1.1), STONE, b)
    box(f"MossLeg{side}", (sx, -0.5, 5.2), (3, 1.6, 0.5), MOSS, b)

# Join into a single skinned mesh
bpy.ops.object.select_all(action='DESELECT')
for o in parts:
    o.select_set(True)
bpy.context.view_layer.objects.active = parts[0]
bpy.ops.object.join()
mesh_ob = bpy.context.view_layer.objects.active
mesh_ob.name = "GolemMesh"

mat = bpy.data.materials.new("GolemMat")
mat.use_nodes = True
nt = mat.node_tree
bsdf = nt.nodes["Principled BSDF"]
attr_node = nt.nodes.new("ShaderNodeAttribute")
attr_node.attribute_name = "Col"
nt.links.new(attr_node.outputs["Color"], bsdf.inputs["Base Color"])
bsdf.inputs["Roughness"].default_value = 0.85
mesh_ob.data.materials.append(mat)

# ---------------------------------------------------------------- rig
arm_data = bpy.data.armatures.new("GolemRig")
rig = bpy.data.objects.new("GolemRig", arm_data)
scene.collection.objects.link(rig)
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode='EDIT')
BONES = [
    ("Root", (0, 0, 0), None),
    ("Torso", (0, 0, 5), "Root"),
    ("Head", (0, 0, 11), "Torso"),
    ("Arm.L", (4.3, 0, 11), "Torso"),
    ("Arm.R", (-4.3, 0, 11), "Torso"),
    ("Leg.L", (1.7, 0, 5), "Root"),
    ("Leg.R", (-1.7, 0, 5), "Root"),
]
for name, head, parent in BONES:
    eb = arm_data.edit_bones.new(name)
    eb.head = head
    eb.tail = (head[0], head[1], head[2] + (6 if name == "Torso" else 3 if name == "Head" else 1.5))
    if parent:
        eb.parent = arm_data.edit_bones[parent]
bpy.ops.object.mode_set(mode='OBJECT')

mesh_ob.parent = rig
mod = mesh_ob.modifiers.new("Armature", 'ARMATURE')
mod.object = rig

# ---------------------------------------------------------------- animation
rig.animation_data_create()
for pb in rig.pose.bones:
    pb.rotation_mode = 'XYZ'


def build_action(name, length, fn, step):
    """fn(frame) -> {bone: (rx, ry, rz, dz)} in degrees / units; keyed every `step` frames."""
    act = bpy.data.actions.new(name)
    rig.animation_data.action = act
    for pb in rig.pose.bones:
        pb.rotation_euler = (0, 0, 0)
        pb.location = (0, 0, 0)
    for f in list(range(0, length, step)) + [length]:
        pose = fn(f)
        for pb in rig.pose.bones:
            rx, ry, rz, dz = pose.get(pb.name, (0, 0, 0, 0))
            pb.rotation_euler = (math.radians(rx), math.radians(ry), math.radians(rz))
            pb.location = (0, dz, 0)  # local Y of an up-pointing bone == world Z
            pb.keyframe_insert("rotation_euler", frame=f + 1)
            pb.keyframe_insert("location", frame=f + 1)
    act.use_fake_user = True
    return act


def cyc(length, leg, arm, bob, lean, twist):
    def fn(f):
        p = 2 * math.pi * f / length
        s = math.sin(p)
        return {
            "Leg.L": (leg * s, 0, 0, 0),
            "Leg.R": (-leg * s, 0, 0, 0),
            "Arm.L": (-arm * s, 0, 0, 0),
            "Arm.R": (arm * s, 0, 0, 0),
            "Torso": (lean, 0, twist * s, bob * math.cos(2 * p)),
            "Head": (-lean * 0.7, 0, -twist * s * 0.6, 0),
            "Root": (0, 0, 0, 0),
        }
    return fn


def idle(f):
    s = math.sin(2 * math.pi * f / 60)
    return {"Torso": (0, 0, 0, 0.12 * s), "Arm.L": (4 * s, 0, 3, 0), "Arm.R": (4 * s, 0, -3, 0),
            "Head": (2 * s, 0, 0, 0)}


def attack(f):
    # key table: frame -> (arm rx, torso rx, head rx, leg rx)
    K = [(0, 0, 0, 0, 0), (12, 175, 14, -4, 6), (20, 185, 16, -4, 8), (26, 35, -26, 10, -10),
         (32, 28, -22, 8, -8), (48, 0, 0, 0, 0)]
    for (f0, *a), (f1, *b) in zip(K, K[1:]):
        if f0 <= f <= f1:
            t = (f - f0) / (f1 - f0)
            t = t * t * (3 - 2 * t) if f1 != 26 else t ** 0.5  # snap into the slam
            v = [x + (y - x) * t for x, y in zip(a, b)]
            arm, torso, head, leg = v
            return {"Arm.L": (arm, 0, 0, 0), "Arm.R": (arm, 0, 0, 0), "Torso": (torso, 0, 0, 0),
                    "Head": (head, 0, 0, 0), "Leg.L": (leg, 0, 0, 0), "Leg.R": (-leg * 0.5, 0, 0, 0)}
    return {}


ACTIONS = [
    ("Idle", 60, idle, 15),
    ("Walk", 32, cyc(32, 34, 26, 0.3, -3, 5), 4),
    ("Run", 18, cyc(18, 55, 55, 0.7, -14, 7), 3),
    ("Attack", 48, attack, 2),
]
acts = []
for name, length, fn, step in ACTIONS:
    acts.append(build_action(name, length, fn, step))

for pb in rig.pose.bones:
    pb.rotation_euler = (0, 0, 0)
    pb.location = (0, 0, 0)
scene.frame_start, scene.frame_end = 1, 61
rig.animation_data.action = None
for act in acts:
    tr = rig.animation_data.nla_tracks.new()
    tr.name = act.name
    tr.strips.new(act.name, 1, act)

# ---------------------------------------------------------------- preview renders
def preview():
    scene.render.engine = 'CYCLES'
    scene.cycles.samples = 24
    scene.cycles.device = 'CPU'
    scene.render.resolution_x = scene.render.resolution_y = 420
    w = bpy.data.worlds.new("w"); w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.55, 0.65, 0.8, 1)
    scene.world = w
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", 'SUN'))
    sun.data.energy = 4
    sun.rotation_euler = (math.radians(50), 0, math.radians(35))
    scene.collection.objects.link(sun)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.location = (20, 24, 11)
    cam.rotation_euler = (Vector((0, 0, 7)) - cam.location).to_track_quat('-Z', 'Y').to_euler()
    os.makedirs(PREVIEW, exist_ok=True)
    rig.animation_data.action = None
    shots = [("Idle", 0), ("Walk", 8), ("Walk", 24), ("Run", 4), ("Attack", 18), ("Attack", 27)]
    for name, f in shots:
        act = bpy.data.actions[name]
        rig.animation_data.action = act
        for tr in rig.animation_data.nla_tracks:
            tr.mute = True
        scene.frame_set(f + 1)
        scene.render.filepath = os.path.join(PREVIEW, f"{name}_{f}.png")
        bpy.ops.render.render(write_still=True)


if PREVIEW:
    preview()
    rig.animation_data.action = None
    for tr in rig.animation_data.nla_tracks:
        tr.mute = False

# ---------------------------------------------------------------- export
bpy.ops.object.select_all(action='DESELECT')
rig.select_set(True); mesh_ob.select_set(True)
bpy.context.view_layer.objects.active = rig
bpy.ops.export_scene.fbx(
    filepath=os.path.join(OUT, "Golem.fbx"), use_selection=True, object_types={'ARMATURE', 'MESH'},
    add_leaf_bones=False, bake_anim=True, bake_anim_use_all_actions=True,
    bake_anim_use_nla_strips=False, bake_anim_use_all_bones=True, bake_anim_force_startend_keying=True,
    bake_anim_simplify_factor=0, path_mode='COPY', embed_textures=False, axis_forward='-Z', axis_up='Y',
    mesh_smooth_type='FACE', colors_type='SRGB', apply_unit_scale=True,
)
bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "Golem.glb"), export_format='GLB',
                          export_animation_mode='ACTIONS', use_selection=True, export_yup=True)
print("done")
