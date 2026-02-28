"""
claude_figure.py — Claude Code logo figure in 3D
The iconic orange diamond / geometric Claude Code mark.
"""
import bpy, math, mathutils, os

frames_dir = os.environ.get('_BL_FRAMES_DIR', '/tmp/blender-frames')

# ── Clear scene ────────────────────────────────────────────────────────────────
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.frame_start = 1
scene.frame_end   = 1

# ── Render settings ────────────────────────────────────────────────────────────
scene.render.engine                     = 'CYCLES'
scene.render.film_transparent           = True
scene.render.resolution_x               = 756
scene.render.resolution_y               = 756
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode  = 'RGBA'
scene.render.image_settings.color_depth = '8'
scene.render.filepath                   = os.path.join(frames_dir, 'frame_')
scene.cycles.samples                    = 32
scene.cycles.use_denoising              = False

try:
    prefs = bpy.context.preferences.addons['cycles'].preferences
    prefs.compute_device_type = 'METAL'
    prefs.get_devices()
    for d in prefs.devices:
        d.use = True
    scene.cycles.device = 'GPU'
except Exception:
    pass

# ── Materials ──────────────────────────────────────────────────────────────────
def emission_mat(name, color, strength=5.0):
    mat = bpy.data.materials.new(name=name)
    nodes = mat.node_tree.nodes
    links = mat.node_tree.links
    nodes.clear()
    em  = nodes.new('ShaderNodeEmission')
    out = nodes.new('ShaderNodeOutputMaterial')
    em.inputs['Color'].default_value    = (*color, 1.0)
    em.inputs['Strength'].default_value = strength
    links.new(em.outputs['Emission'], out.inputs['Surface'])
    return mat

# Claude Code orange palette
ORANGE      = (1.0,  0.42, 0.13)   # primary orange
ORANGE_DARK = (0.7,  0.25, 0.06)   # darker face
CREAM       = (0.96, 0.90, 0.80)   # light accent

mat_orange = emission_mat('Orange',     ORANGE,      strength=6.0)
mat_dark   = emission_mat('OrangeDark', ORANGE_DARK, strength=3.0)
mat_cream  = emission_mat('Cream',      CREAM,       strength=4.0)

# ── Build the diamond body ─────────────────────────────────────────────────────
# Claude Code logo is a rounded diamond (rhombus) shape — we approximate it with
# a cylinder with 4 verts (square cross-section), rotated 45° and given a bevel.

# Main diamond body
bpy.ops.mesh.primitive_cylinder_add(vertices=4, radius=1.0, depth=0.35,
                                     location=(0, 0, 0))
body = bpy.context.active_object
body.name = 'DiamondBody'
body.rotation_euler = (0, 0, math.radians(45))
# Scale to classic Claude diamond proportions (taller than wide)
body.scale = (0.72, 0.72, 1.0)
bpy.ops.object.transform_apply(scale=True, rotation=True)

# Bevel the edges for smooth diamond look
bpy.ops.object.modifier_add(type='BEVEL')
body.modifiers['Bevel'].width         = 0.06
body.modifiers['Bevel'].segments      = 4
body.modifiers['Bevel'].limit_method  = 'ANGLE'
body.modifiers['Bevel'].angle_limit   = math.radians(30)
bpy.ops.object.modifier_apply(modifier='Bevel')

body.data.materials.append(mat_orange)

# ── Inner cut / face ──────────────────────────────────────────────────────────
# Smaller concave diamond on the front face — the characteristic inner shape
bpy.ops.mesh.primitive_cylinder_add(vertices=4, radius=0.55, depth=0.42,
                                     location=(0, -0.17, 0))
inner = bpy.context.active_object
inner.name = 'InnerFace'
inner.rotation_euler = (0, 0, math.radians(45))
inner.scale = (0.72, 0.72, 1.0)
bpy.ops.object.transform_apply(scale=True, rotation=True)
inner.data.materials.append(mat_dark)

# ── Highlight dot — top of diamond ────────────────────────────────────────────
bpy.ops.mesh.primitive_uv_sphere_add(radius=0.09, location=(0, -0.2, 0.72))
dot = bpy.context.active_object
dot.name = 'HighlightDot'
dot.data.materials.append(mat_cream)

# ── Boolean: carve inner face into body ──────────────────────────────────────
# Use boolean difference to give the front face depth
bpy.context.view_layer.objects.active = body
bpy.ops.object.modifier_add(type='BOOLEAN')
body.modifiers['Boolean'].operation    = 'DIFFERENCE'
body.modifiers['Boolean'].object       = inner
body.modifiers['Boolean'].solver       = 'FLOAT'
bpy.ops.object.modifier_apply(modifier='Boolean')

# Re-add inner face as a visible object at the carved depth
inner.location.y = -0.18

# ── Two subtle legs (stubby bottom points) ────────────────────────────────────
for side in (-0.22, 0.22):
    bpy.ops.mesh.primitive_cylinder_add(vertices=6, radius=0.09, depth=0.28,
                                         location=(side, 0, -1.08))
    leg = bpy.context.active_object
    leg.name = f'Leg_{side}'
    leg.data.materials.append(mat_orange)

# ── Camera ────────────────────────────────────────────────────────────────────
bpy.ops.object.camera_add(location=(0, -3.8, 0.1))
cam = bpy.context.active_object
cam.data.type  = 'PERSP'
cam.data.lens  = 72
direction = mathutils.Vector((0, 0, 0)) - mathutils.Vector((0, -3.8, 0.1))
cam.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
scene.camera = cam

# ── Subtle rim light ──────────────────────────────────────────────────────────
bpy.ops.object.light_add(type='AREA', location=(2, -2, 2))
rim = bpy.context.active_object
rim.data.energy = 800
rim.data.size   = 3
rim.data.color  = ORANGE
rim.rotation_euler = (math.radians(45), 0, math.radians(45))

# ── Render ────────────────────────────────────────────────────────────────────
bpy.ops.render.render(animation=True)
print(f'[claude_figure] Rendered → {frames_dir}')
