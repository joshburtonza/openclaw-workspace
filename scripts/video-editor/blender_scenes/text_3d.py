"""
text_3d.py — Blender 3D extruded text scene
Reads props from env vars set by render-blender.sh

Props (JSON in _BL_PROPS):
  text     : str   — main text content (default "AMALFI AI")
  subtitle : str   — smaller text below (optional)
  color    : str   — hex color for emission (default "#4B9EFF")
  style    : str   — "spin" | "rise" | "zoom" (default "spin")
"""
import bpy, os, json, math

# ── Read env params ────────────────────────────────────────────────────────────
props           = json.loads(os.environ.get('_BL_PROPS', '{}'))
duration_frames = int(os.environ.get('_BL_DURATION_FRAMES', '90'))
fps             = int(os.environ.get('_BL_FPS', '30'))
width           = int(os.environ.get('_BL_WIDTH', '1080'))
height          = int(os.environ.get('_BL_HEIGHT', '1920'))
frames_dir      = os.environ.get('_BL_FRAMES_DIR', '/tmp/blender-frames')

text_content = props.get('text', 'AMALFI AI')
subtitle     = props.get('subtitle', '')
color_hex    = props.get('color', '#4B9EFF')
style        = props.get('style', 'spin')   # spin | rise | zoom

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
# Cycles: works headless on macOS (EEVEE requires a display context)
scene.render.engine                       = 'CYCLES'
scene.render.film_transparent             = True
scene.render.resolution_x                 = width
scene.render.resolution_y                 = height
scene.render.fps                          = fps
scene.render.image_settings.file_format   = 'PNG'
scene.render.image_settings.color_mode    = 'RGBA'
scene.render.image_settings.color_depth   = '8'
scene.render.filepath                     = os.path.join(frames_dir, 'frame_')

# Low sample count — emission materials need very few samples (no GI needed)
scene.cycles.samples       = 8
scene.cycles.use_denoising = False

# Use Metal GPU on Apple Silicon
try:
    prefs = bpy.context.preferences.addons['cycles'].preferences
    prefs.compute_device_type = 'METAL'
    prefs.get_devices()
    for d in prefs.devices:
        d.use = True
    scene.cycles.device = 'GPU'
except Exception:
    pass

# ── Helper: make emission material ────────────────────────────────────────────
def make_emission_mat(name, rgba, strength=4.0):
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

# ── Set global keyframe interpolation to BEZIER (Blender 5 compatible) ────────
bpy.context.preferences.edit.keyframe_new_interpolation_type = 'BEZIER'
bpy.context.preferences.edit.keyframe_new_handle_type = 'AUTO_CLAMPED'

is_vertical = height > width

# ── For portrait video, render as a landscape banner (3:1 wide) ───────────────
# 3D text motion graphics on portrait video look best as a wide horizontal strip
# centred vertically on the frame. Re-interpret width/height if needed.
if is_vertical:
    render_w = width          # e.g. 756
    render_h = round(width * 0.33)  # e.g. 249 — landscape banner aspect
else:
    render_w = width
    render_h = height

scene.render.resolution_x = render_w
scene.render.resolution_y = render_h

# ── Text sizing for 3:1 landscape camera ──────────────────────────────────────
text_size = 0.55   # tuned for 50mm perspective at y=-3.5 in landscape
sub_size  = text_size * 0.42

# ── Add main text ─────────────────────────────────────────────────────────────
bpy.ops.object.text_add(location=(0, 0, 0))
t = bpy.context.active_object
t.data.body             = text_content
t.data.extrude          = 0.025   # shallow — readable depth without looking blocky
t.data.bevel_depth      = 0.004
t.data.bevel_resolution = 4
t.data.align_x          = 'CENTER'
t.data.align_y          = 'CENTER'
t.data.size             = text_size
bpy.ops.object.convert(target='MESH')
main_obj = bpy.context.active_object
main_obj.name = 'MainText'
bpy.ops.object.origin_set(type='ORIGIN_GEOMETRY', center='BOUNDS')

# Two-material setup: bright front face, dimmer sides → readable 3D text
# Material index 0 = front/back faces, index 1 = sides/bevel
mat_front = make_emission_mat('FrontMat', color_rgba, strength=5.0)
mat_side  = make_emission_mat('SideMat',  (color_rgba[0]*0.3, color_rgba[1]*0.3, color_rgba[2]*0.3, 1.0), strength=1.5)
main_obj.data.materials.append(mat_front)
main_obj.data.materials.append(mat_side)
# Assign side material to extrude/bevel faces
for poly in main_obj.data.polygons:
    # Front/back faces have normals pointing mostly along Y axis
    if abs(poly.normal.y) > 0.5:
        poly.material_index = 0  # front/back — bright
    else:
        poly.material_index = 1  # sides/bevel — dim

# ── Add subtitle text ──────────────────────────────────────────────────────────
sub_obj = None
if subtitle:
    bpy.ops.object.text_add(location=(0, 0, -(text_size * 0.68)))
    s = bpy.context.active_object
    s.data.body             = subtitle
    s.data.extrude          = 0.008
    s.data.bevel_depth      = 0.001
    s.data.align_x          = 'CENTER'
    s.data.align_y          = 'CENTER'
    s.data.size             = sub_size
    bpy.ops.object.convert(target='MESH')
    sub_obj = bpy.context.active_object
    sub_obj.name = 'SubText'
    bpy.ops.object.origin_set(type='ORIGIN_GEOMETRY', center='BOUNDS')
    sub_obj.data.materials.append(make_emission_mat('SubMat', (0.85,0.85,0.85,1.0), strength=2.5))

# ── Camera: perspective, slight downward angle for 3D depth ───────────────────
# Positioned slightly above-front so you see the top of the extruded letters
cam_x = 0
cam_y = -3.5
cam_z = 0.4   # slightly above
bpy.ops.object.camera_add(location=(cam_x, cam_y, cam_z))
cam_obj = bpy.context.active_object
# Point at origin (text center)
import mathutils
direction = mathutils.Vector((0, 0, 0)) - mathutils.Vector((cam_x, cam_y, cam_z))
rot_quat  = direction.to_track_quat('-Z', 'Y')
cam_obj.rotation_euler = rot_quat.to_euler()
cam_obj.data.type  = 'PERSP'
cam_obj.data.lens  = 50   # 50mm — good balance of perspective and readability
scene.camera = cam_obj

# ── Animation by style ────────────────────────────────────────────────────────
ENTRY_END = min(22, duration_frames - 4)  # entry animation ends here

if style == 'spin':
    # Spin in from Y-axis rotation
    for obj in ([main_obj] + ([sub_obj] if sub_obj else [])):
        obj.rotation_euler = (0, -math.pi * 0.55, 0)
        obj.scale          = (0.6, 0.6, 0.6)
        obj.keyframe_insert('rotation_euler', frame=1)
        obj.keyframe_insert('scale', frame=1)
        obj.rotation_euler = (0, 0, 0)
        obj.scale          = (1.0, 1.0, 1.0)
        obj.keyframe_insert('rotation_euler', frame=ENTRY_END)
        obj.keyframe_insert('scale', frame=ENTRY_END)

elif style == 'rise':
    # Rise from below
    for obj in ([main_obj] + ([sub_obj] if sub_obj else [])):
        orig_z = obj.location.z
        obj.location.z = orig_z - 1.0
        obj.scale      = (0.8, 0.8, 0.8)
        obj.keyframe_insert('location', frame=1)
        obj.keyframe_insert('scale', frame=1)
        obj.location.z = orig_z
        obj.scale      = (1.0, 1.0, 1.0)
        obj.keyframe_insert('location', frame=ENTRY_END)
        obj.keyframe_insert('scale', frame=ENTRY_END)

elif style == 'zoom':
    # Zoom in from large scale
    for obj in ([main_obj] + ([sub_obj] if sub_obj else [])):
        obj.scale = (2.5, 2.5, 2.5)
        obj.keyframe_insert('scale', frame=1)
        obj.scale = (1.0, 1.0, 1.0)
        obj.keyframe_insert('scale', frame=ENTRY_END)

# Hold for rest of duration (already at resting state after ENTRY_END keyframe)

# ── Lighting ──────────────────────────────────────────────────────────────────
# Key light — adds depth to extrusion
bpy.ops.object.light_add(type='AREA', location=(1.5, -3, 2))
key = bpy.context.active_object
key.data.energy = 500
key.data.size   = 4
key.data.color  = (1, 1, 1)
key.rotation_euler = (math.radians(45), 0, math.radians(30))

# Rim light — colour-matched glow
bpy.ops.object.light_add(type='AREA', location=(-1.5, -1, 1))
rim = bpy.context.active_object
rim.data.energy = 150
rim.data.size   = 3
rim.data.color  = color_rgba[:3]
rim.rotation_euler = (math.radians(-45), 0, math.radians(-30))

# ── Render ────────────────────────────────────────────────────────────────────
bpy.ops.render.render(animation=True)
print(f'[text_3d] Rendered {duration_frames} frames to {frames_dir}')
