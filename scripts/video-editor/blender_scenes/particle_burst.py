"""
particle_burst.py — Blender particle burst around a stat/number
Reads props from env vars set by render-blender.sh

Props (JSON in _BL_PROPS):
  value    : str   — the number/stat to display (default "23")
  label    : str   — label above number (default "TASKS DONE")
  color    : str   — hex color (default "#4ade80")
  particles: int   — particle count (default 120)
"""
import bpy, os, json, math, random

# ── Read env params ────────────────────────────────────────────────────────────
props           = json.loads(os.environ.get('_BL_PROPS', '{}'))
duration_frames = int(os.environ.get('_BL_DURATION_FRAMES', '90'))
fps             = int(os.environ.get('_BL_FPS', '30'))
width           = int(os.environ.get('_BL_WIDTH', '1080'))
height          = int(os.environ.get('_BL_HEIGHT', '1920'))
frames_dir      = os.environ.get('_BL_FRAMES_DIR', '/tmp/blender-frames')

value      = str(props.get('value', '23'))
label      = props.get('label', 'TASKS DONE')
color_hex  = props.get('color', '#4ade80')
n_particles = int(props.get('particles', 120))

def hex_to_rgba(h):
    h = h.lstrip('#')
    return (int(h[0:2],16)/255, int(h[2:4],16)/255, int(h[4:6],16)/255, 1.0)

color_rgba = hex_to_rgba(color_hex)

# ── Clear scene ────────────────────────────────────────────────────────────────
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.frame_start = 1
scene.frame_end   = duration_frames

# ── Render settings ────────────────────────────────────────────────────────────
scene.render.engine                     = 'CYCLES'
scene.render.film_transparent           = True
scene.render.resolution_x               = width
scene.render.resolution_y               = height
scene.render.fps                        = fps
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode  = 'RGBA'
scene.render.filepath                   = os.path.join(frames_dir, 'frame_')

scene.cycles.samples       = 8
scene.cycles.use_denoising = False
try:
    prefs = bpy.context.preferences.addons['cycles'].preferences
    prefs.compute_device_type = 'METAL'
    prefs.get_devices()
    for d in prefs.devices: d.use = True
    scene.cycles.device = 'GPU'
except Exception:
    pass

def make_emission_mat(name, rgba, strength=3.0):
    mat = bpy.data.materials.new(name=name)
    nodes = mat.node_tree.nodes
    links = mat.node_tree.links
    nodes.clear()
    em  = nodes.new('ShaderNodeEmission')
    out = nodes.new('ShaderNodeOutputMaterial')
    em.inputs['Color'].default_value    = rgba
    em.inputs['Strength'].default_value = strength
    links.new(em.outputs['Emission'], out.inputs['Surface'])
    return mat

# Set BEZIER interpolation globally (Blender 5 compatible)
bpy.context.preferences.edit.keyframe_new_interpolation_type = 'BEZIER'
bpy.context.preferences.edit.keyframe_new_handle_type = 'AUTO_CLAMPED'

is_vertical = height > width
val_size     = 0.7 if is_vertical else 0.45
label_size   = val_size * 0.28

# ── Value text ────────────────────────────────────────────────────────────────
bpy.ops.object.text_add(location=(0, 0, 0))
t = bpy.context.active_object
t.data.body         = value
t.data.extrude      = 0.08
t.data.bevel_depth  = 0.01
t.data.align_x      = 'CENTER'
t.data.align_y      = 'CENTER'
t.data.size         = val_size
bpy.ops.object.convert(target='MESH')
val_obj = bpy.context.active_object
val_obj.name = 'ValueText'
val_obj.data.materials.append(make_emission_mat('ValMat', color_rgba, strength=4.0))

# ── Label text ────────────────────────────────────────────────────────────────
if label:
    bpy.ops.object.text_add(location=(0, 0, val_size * 0.65))
    l = bpy.context.active_object
    l.data.body        = label.upper()
    l.data.extrude     = 0.02
    l.data.align_x     = 'CENTER'
    l.data.align_y     = 'CENTER'
    l.data.size        = label_size
    bpy.ops.object.convert(target='MESH')
    lbl_obj = bpy.context.active_object
    lbl_obj.name = 'LabelText'
    lbl_obj.data.materials.append(make_emission_mat('LblMat', (0.8,0.8,0.8,1.0), strength=2.5))

# ── Particle emitter: small glowing spheres ───────────────────────────────────
bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=0.015, location=(0, 0, 0))
emitter = bpy.context.active_object
emitter.name = 'ParticleEmitter'

# Particle material — same colour as text
emitter.data.materials.append(make_emission_mat('ParticleMat', color_rgba, strength=6.0))

# Particle system
ps = emitter.modifiers.new('Burst', 'PARTICLE_SYSTEM')
psys = emitter.particle_systems[0].settings
psys.count          = n_particles
psys.frame_start    = 5
psys.frame_end      = 8          # burst = all particles emitted in 3 frames
psys.lifetime       = duration_frames - 10
psys.normal_factor  = 3.0        # explosive outward velocity
psys.factor_random  = 0.8
psys.render_type    = 'OBJECT'
psys.instance_object = emitter   # particles look like the emitter (sphere)

# Make particles start tiny and grow then shrink
psys.particle_size         = 0.4
psys.size_random           = 0.5
psys.use_size_deflect      = False

# Gravity off — floating particles
scene.use_gravity = False

# ── Entry animation on value text ─────────────────────────────────────────────
ENTRY_END = 18
val_obj.scale = (0.1, 0.1, 0.1)
val_obj.keyframe_insert('scale', frame=1)
val_obj.scale = (1.0, 1.0, 1.0)
val_obj.keyframe_insert('scale', frame=ENTRY_END)

# ── Camera ────────────────────────────────────────────────────────────────────
cam_dist = 3.5 if is_vertical else 2.5
bpy.ops.object.camera_add(location=(0, -cam_dist, 0))
cam_obj = bpy.context.active_object
cam_obj.rotation_euler = (math.pi/2, 0, 0)
cam_obj.data.lens = 50
scene.camera = cam_obj

# ── Lighting ──────────────────────────────────────────────────────────────────
bpy.ops.object.light_add(type='AREA', location=(2, -2, 3))
key = bpy.context.active_object
key.data.energy = 400
key.data.size   = 5

# ── Render ────────────────────────────────────────────────────────────────────
bpy.ops.render.render(animation=True)
print(f'[particle_burst] Rendered {duration_frames} frames to {frames_dir}')
