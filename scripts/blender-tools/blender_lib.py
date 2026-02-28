"""
blender_lib.py — Amalfi AI Blender Standard Library
Reusable components for all Blender work: materials, lights, cameras,
mesh helpers, animation, scene setup, and reference tools.

Usage in any Blender script:
  import sys; sys.path.insert(0, '/path/to/blender-tools')
  from blender_lib import *
  setup_scene(engine='CYCLES', resolution=(800,800), samples=256)
  M = mat_principled('Body', (0.85, 0.06, 0.03))
  make_sphere(1.7, (0,0,0), mat=M)
  lights_three_point()
  cam_front(distance=12)
"""
import bpy, math, mathutils, os

# ─────────────────────────────────────────────────────────────────────────────
# SCENE SETUP
# ─────────────────────────────────────────────────────────────────────────────

def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)

def enable_metal_gpu():
    try:
        prefs = bpy.context.preferences.addons['cycles'].preferences
        prefs.compute_device_type = 'METAL'
        prefs.get_devices()
        for d in prefs.devices: d.use = True
        bpy.context.scene.cycles.device = 'GPU'
    except Exception:
        pass

def setup_scene(engine='CYCLES', resolution=(800, 800), samples=256,
                fps=24, frame_start=1, frame_end=1,
                transparent=False, filmic=True, denoise=True,
                output_dir='/tmp/blender_out', filename='frame_'):
    """One-call scene configuration."""
    scene = bpy.context.scene
    scene.frame_start = frame_start
    scene.frame_end   = frame_end
    scene.render.fps  = fps

    if engine == 'CYCLES':
        scene.render.engine = 'CYCLES'
        scene.cycles.samples = samples
        scene.cycles.use_denoising = denoise
        enable_metal_gpu()
    elif engine == 'EEVEE':
        scene.render.engine = 'BLENDER_EEVEE_NEXT'
        try:
            scene.eevee.taa_render_samples = max(16, samples // 4)
            scene.eevee.use_gtao = True
            scene.eevee.use_bloom = True
        except Exception:
            pass

    scene.render.resolution_x = resolution[0]
    scene.render.resolution_y = resolution[1]
    scene.render.film_transparent = transparent
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode  = 'RGBA' if transparent else 'RGB'

    if filmic:
        scene.view_settings.view_transform = 'Filmic'
        scene.view_settings.look = 'Medium High Contrast'
    else:
        scene.view_settings.view_transform = 'Standard'

    os.makedirs(output_dir, exist_ok=True)
    scene.render.filepath = os.path.join(output_dir, filename)
    return scene

def world_dark(color=(0.02, 0.01, 0.01), strength=1.0):
    """Dark moody background."""
    world = bpy.data.worlds.new('World')
    bpy.context.scene.world = world
    world.use_nodes = True
    wn = world.node_tree.nodes
    wn.clear()
    bg = wn.new('ShaderNodeBackground')
    bg.inputs['Color'].default_value    = (*color, 1.0)
    bg.inputs['Strength'].default_value = strength
    out = wn.new('ShaderNodeOutputWorld')
    world.node_tree.links.new(bg.outputs['Background'], out.inputs['Surface'])
    return world

def world_gradient(top=(0.05, 0.05, 0.10), bottom=(0.01, 0.01, 0.02)):
    """Gradient sky background."""
    world = bpy.data.worlds.new('World')
    bpy.context.scene.world = world
    world.use_nodes = True
    wn = world.node_tree.nodes
    wn.clear()
    tc  = wn.new('ShaderNodeTexCoord')
    map_ = wn.new('ShaderNodeMapping')
    grad = wn.new('ShaderNodeTexGradient')
    ramp = wn.new('ShaderNodeValToRGB')
    ramp.color_ramp.elements[0].color = (*bottom, 1.0)
    ramp.color_ramp.elements[1].color = (*top, 1.0)
    bg  = wn.new('ShaderNodeBackground')
    out = wn.new('ShaderNodeOutputWorld')
    lk  = world.node_tree.links.new
    lk(tc.outputs['Generated'], map_.inputs['Vector'])
    lk(map_.outputs['Vector'],  grad.inputs['Vector'])
    lk(grad.outputs['Color'],   ramp.inputs['Fac'])
    lk(ramp.outputs['Color'],   bg.inputs['Color'])
    lk(bg.outputs['Background'], out.inputs['Surface'])
    return world

# ─────────────────────────────────────────────────────────────────────────────
# MATERIALS
# ─────────────────────────────────────────────────────────────────────────────

def mat_principled(name, base_color, roughness=0.45, metallic=0.0,
                   subsurface=0.10, spec=0.3, alpha=1.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nodes = m.node_tree.nodes
    links = m.node_tree.links
    nodes.clear()
    p = nodes.new('ShaderNodeBsdfPrincipled')
    p.inputs['Base Color'].default_value   = (*base_color[:3], 1.0)
    p.inputs['Roughness'].default_value    = roughness
    p.inputs['Metallic'].default_value     = metallic
    p.inputs['Subsurface Weight'].default_value = subsurface
    p.inputs['Subsurface Radius'].default_value = (0.9, 0.2, 0.2)
    try: p.inputs['Specular IOR Level'].default_value = spec
    except Exception: pass
    if alpha < 1.0:
        p.inputs['Alpha'].default_value = alpha
        m.blend_method = 'BLEND'
    o = nodes.new('ShaderNodeOutputMaterial')
    links.new(p.outputs['BSDF'], o.inputs['Surface'])
    return m

def mat_emission(name, color, strength=1.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nodes = m.node_tree.nodes
    links = m.node_tree.links
    nodes.clear()
    e = nodes.new('ShaderNodeEmission')
    e.inputs['Color'].default_value    = (*color[:3], 1.0)
    e.inputs['Strength'].default_value = strength
    o = nodes.new('ShaderNodeOutputMaterial')
    links.new(e.outputs['Emission'], o.inputs['Surface'])
    return m

def mat_glass(name, color=(1, 1, 1), ior=1.45, roughness=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nodes = m.node_tree.nodes
    links = m.node_tree.links
    nodes.clear()
    p = nodes.new('ShaderNodeBsdfPrincipled')
    p.inputs['Base Color'].default_value  = (*color[:3], 1.0)
    p.inputs['Roughness'].default_value   = roughness
    p.inputs['Transmission Weight'].default_value = 1.0
    try: p.inputs['IOR'].default_value = ior
    except Exception: pass
    m.blend_method = 'BLEND'
    o = nodes.new('ShaderNodeOutputMaterial')
    links.new(p.outputs['BSDF'], o.inputs['Surface'])
    return m

def mat_metal(name, color, roughness=0.25):
    return mat_principled(name, color, roughness=roughness, metallic=1.0, subsurface=0)

# Preset palette for clawbot / character work
PALETTE = {
    'clawbot_body':  (0.85, 0.06, 0.03),
    'clawbot_arm':   (0.70, 0.04, 0.02),
    'clawbot_eye':   (0.05, 0.85, 0.90),   # cyan glow
    'clawbot_ant':   (0.80, 0.05, 0.03),
    'chart_blue':    (0.15, 0.45, 0.95),
    'chart_green':   (0.10, 0.80, 0.35),
    'chart_yellow':  (0.95, 0.85, 0.10),
    'chart_red':     (0.90, 0.15, 0.10),
    'chart_purple':  (0.60, 0.20, 0.90),
    'ui_dark':       (0.05, 0.05, 0.08),
    'ui_light':      (0.90, 0.90, 0.95),
    'gold':          (0.85, 0.65, 0.10),
    'silver':        (0.75, 0.75, 0.78),
}

# ─────────────────────────────────────────────────────────────────────────────
# MESH HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def smooth_shade(obj):
    for poly in obj.data.polygons:
        poly.use_smooth = True
    obj.data.update()

def add_subsurf(obj, levels=2, simple=False):
    mod = obj.modifiers.new('Subsurf', 'SUBSURF')
    mod.levels = levels
    mod.render_levels = levels
    if simple:
        mod.subdivision_type = 'SIMPLE'
    return mod

def add_bevel(obj, width=0.02, segments=3):
    mod = obj.modifiers.new('Bevel', 'BEVEL')
    mod.width = width
    mod.segments = segments
    return mod

def apply_transforms(obj):
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)

def make_empty(name, location=(0,0,0), parent=None):
    e = bpy.data.objects.new(name, None)
    e.location = location
    bpy.context.scene.collection.objects.link(e)
    if parent:
        e.parent = parent
    return e

def make_sphere(radius, location=(0,0,0), segments=64, rings=32, mat=None,
                smooth=True, subsurf=2, scale=(1,1,1), name='Sphere', parent=None):
    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=radius, location=location, segments=segments, ring_count=rings)
    obj = bpy.context.view_layer.objects.active
    obj.name = name
    if scale != (1,1,1):
        obj.scale = scale
        apply_transforms(obj)
    if mat:
        obj.data.materials.append(mat)
    if smooth:
        smooth_shade(obj)
    if subsurf:
        add_subsurf(obj, subsurf)
    if parent:
        obj.parent = parent
    obj.location = location
    return obj

def make_cube(size=1.0, location=(0,0,0), scale=(1,1,1), mat=None,
              smooth=False, subsurf=0, bevel=0.0, name='Cube', parent=None):
    bpy.ops.mesh.primitive_cube_add(size=size, location=location)
    obj = bpy.context.view_layer.objects.active
    obj.name = name
    if scale != (1,1,1):
        obj.scale = scale
        apply_transforms(obj)
    if mat:
        obj.data.materials.append(mat)
    if smooth:
        smooth_shade(obj)
    if subsurf:
        add_subsurf(obj, subsurf)
    if bevel:
        add_bevel(obj, width=bevel)
    if parent:
        obj.parent = parent
    obj.location = location
    return obj

def make_cylinder(radius=1.0, depth=2.0, location=(0,0,0), vertices=32,
                  mat=None, smooth=True, name='Cylinder', parent=None, rotation=(0,0,0)):
    bpy.ops.mesh.primitive_cylinder_add(
        radius=radius, depth=depth, vertices=vertices, location=location)
    obj = bpy.context.view_layer.objects.active
    obj.name = name
    if rotation != (0,0,0):
        obj.rotation_euler = (math.radians(rotation[0]),
                              math.radians(rotation[1]),
                              math.radians(rotation[2]))
        apply_transforms(obj)
    if mat:
        obj.data.materials.append(mat)
    if smooth:
        smooth_shade(obj)
    if parent:
        obj.parent = parent
    return obj

def make_plane(size=2.0, location=(0,0,0), rotation=(0,0,0), mat=None, name='Plane'):
    bpy.ops.mesh.primitive_plane_add(size=size, location=location)
    obj = bpy.context.view_layer.objects.active
    obj.name = name
    if rotation != (0,0,0):
        obj.rotation_euler = tuple(math.radians(r) for r in rotation)
    if mat:
        obj.data.materials.append(mat)
    return obj

def make_bezier_wire(points, thickness=0.055, mat=None, name='Wire', parent=None):
    """
    Create a bezier curve wire.
    points: list of dicts with 'co', 'handle_left', 'handle_right'
    """
    curve_data = bpy.data.curves.new(name, type='CURVE')
    curve_data.dimensions    = '3D'
    curve_data.bevel_depth   = thickness
    curve_data.bevel_resolution = 6
    curve_data.use_fill_caps = True

    spline = curve_data.splines.new('BEZIER')
    spline.bezier_points.add(len(points) - 1)

    for i, pt in enumerate(points):
        bp = spline.bezier_points[i]
        bp.co = pt['co']
        bp.handle_left  = pt.get('handle_left',  pt['co'])
        bp.handle_right = pt.get('handle_right', pt['co'])
        bp.handle_left_type  = pt.get('left_type',  'FREE')
        bp.handle_right_type = pt.get('right_type', 'FREE')

    obj = bpy.data.objects.new(name, curve_data)
    if mat:
        obj.data.materials.append(mat)
    bpy.context.scene.collection.objects.link(obj)
    if parent:
        obj.parent = parent
    return obj

def make_reference_plane(image_path, location=(0, 2.0, 0), scale=5.0,
                          rotation=(90, 0, 0), name='Reference'):
    """
    Place reference image as a plane in the scene — essential for building to reference.
    Camera looks at z=0, reference plane sits behind at y=+2.
    Use with orthographic camera to line up geometry exactly.
    """
    bpy.ops.mesh.primitive_plane_add(size=1.0, location=location)
    plane = bpy.context.view_layer.objects.active
    plane.name = name
    plane.scale = (scale, scale * 0.56, scale)  # approx 16:9, adjust for image
    plane.rotation_euler = tuple(math.radians(r) for r in rotation)

    # Create image material
    m = bpy.data.materials.new(f'{name}_mat')
    m.use_nodes = True
    nodes = m.node_tree.nodes
    links = m.node_tree.links
    nodes.clear()

    img_node = nodes.new('ShaderNodeTexImage')
    try:
        img_node.image = bpy.data.images.load(str(image_path))
    except Exception as e:
        print(f"[blender_lib] Warning: could not load reference image: {e}")

    emit = nodes.new('ShaderNodeEmission')
    emit.inputs['Strength'].default_value = 0.8
    out  = nodes.new('ShaderNodeOutputMaterial')
    links.new(img_node.outputs['Color'], emit.inputs['Color'])
    links.new(emit.outputs['Emission'], out.inputs['Surface'])
    plane.data.materials.append(m)

    # Make it non-renderable (just viewport guide) — comment out for overlay renders
    plane.hide_render = True
    print(f"[blender_lib] Reference plane added at {location} (hide_render=True)")
    print(f"[blender_lib] Set plane.hide_render=False to include in render overlay")
    return plane

# ─────────────────────────────────────────────────────────────────────────────
# LIGHTING RIGS
# ─────────────────────────────────────────────────────────────────────────────

def lights_three_point(key_energy=800, fill_energy=500, rim_energy=300,
                        key_color=(1.0, 0.85, 0.80),
                        fill_color=(0.8, 0.5, 0.5),
                        rim_color=(1.0, 0.15, 0.05),
                        key_loc=(-5, -7, 5), fill_loc=(5, -4, 0), rim_loc=(0, 4, -3)):
    """Classic 3-point moody lighting — default for character renders."""
    bpy.ops.object.light_add(type='AREA', location=key_loc)
    key = bpy.context.view_layer.objects.active
    key.name = 'Key'
    key.data.energy = key_energy
    key.data.size   = 6
    key.data.color  = key_color
    key.rotation_euler = (math.radians(45), 0, math.radians(-35))

    bpy.ops.object.light_add(type='AREA', location=fill_loc)
    fill = bpy.context.view_layer.objects.active
    fill.name = 'Fill'
    fill.data.energy = fill_energy
    fill.data.size   = 8
    fill.data.color  = fill_color

    bpy.ops.object.light_add(type='AREA', location=rim_loc)
    rim = bpy.context.view_layer.objects.active
    rim.name = 'Rim'
    rim.data.energy = rim_energy
    rim.data.size   = 8
    rim.data.color  = rim_color
    rim.rotation_euler = (math.radians(-30), 0, 0)

    return key, fill, rim

def lights_studio(energy=600, color=(1.0, 0.98, 0.95)):
    """Soft even studio lighting (4 area lights in ring)."""
    lights = []
    for i, (x, y, z) in enumerate([(-4,-4,4), (4,-4,4), (4,4,4), (-4,4,4)]):
        bpy.ops.object.light_add(type='AREA', location=(x, y, z))
        l = bpy.context.view_layer.objects.active
        l.data.energy = energy / 4
        l.data.size   = 5
        l.data.color  = color
        lights.append(l)
    return lights

def lights_dramatic(key_energy=1200, rim_energy=200,
                     key_color=(1.0, 0.90, 0.75), rim_color=(0.3, 0.5, 1.0)):
    """Dramatic single key + subtle rim — for hero renders."""
    bpy.ops.object.light_add(type='SPOT', location=(-6, -8, 8))
    key = bpy.context.view_layer.objects.active
    key.name = 'DramaticKey'
    key.data.energy = key_energy
    key.data.color  = key_color
    key.data.spot_size = math.radians(35)
    key.rotation_euler = (math.radians(40), 0, math.radians(-30))

    bpy.ops.object.light_add(type='AREA', location=(5, 5, 3))
    rim = bpy.context.view_layer.objects.active
    rim.name = 'DramaticRim'
    rim.data.energy = rim_energy
    rim.data.size   = 4
    rim.data.color  = rim_color
    return key, rim

def add_point_light(location, energy=200, color=(1,1,1), radius=0.1, name='Point'):
    bpy.ops.object.light_add(type='POINT', location=location)
    l = bpy.context.view_layer.objects.active
    l.name = name
    l.data.energy = energy
    l.data.color = color
    l.data.shadow_soft_size = radius
    return l

# ─────────────────────────────────────────────────────────────────────────────
# CAMERAS
# ─────────────────────────────────────────────────────────────────────────────

def cam_front(distance=12, height=0.0, lens=52, target=(0, 0, 0)):
    """Camera looking straight at origin from front."""
    loc = mathutils.Vector((0, -distance, height))
    bpy.ops.object.camera_add(location=loc)
    cam = bpy.context.view_layer.objects.active
    cam.data.lens = lens
    direction = mathutils.Vector(target) - loc
    cam.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
    bpy.context.scene.camera = cam
    return cam

def cam_three_quarter(distance=12, height=2.0, angle_deg=35, lens=52, target=(0, 0, 0)):
    """Classic 3/4 view (front-right-above)."""
    rad = math.radians(angle_deg)
    loc = mathutils.Vector((math.sin(rad) * distance * 0.6, -math.cos(rad) * distance, height))
    bpy.ops.object.camera_add(location=loc)
    cam = bpy.context.view_layer.objects.active
    cam.data.lens = lens
    direction = mathutils.Vector(target) - loc
    cam.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
    bpy.context.scene.camera = cam
    return cam

def cam_ortho_front(scale=8.0, distance=20, target=(0, 0, 0)):
    """Orthographic front view — for proportion checking against reference."""
    loc = mathutils.Vector((0, -distance, 0))
    bpy.ops.object.camera_add(location=loc)
    cam = bpy.context.view_layer.objects.active
    cam.data.type = 'ORTHO'
    cam.data.ortho_scale = scale
    direction = mathutils.Vector(target) - loc
    cam.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
    bpy.context.scene.camera = cam
    return cam

def cam_auto_frame(objects_or_radius, padding=1.3, lens=52, distance=None):
    """
    Auto-position camera to frame all objects.
    objects_or_radius: list of bpy objects OR a single radius float for simple framing.
    """
    if isinstance(objects_or_radius, (int, float)):
        radius = objects_or_radius
    else:
        # Compute bounding sphere of all objects
        all_pts = []
        for obj in objects_or_radius:
            for v in obj.bound_box:
                all_pts.append(obj.matrix_world @ mathutils.Vector(v))
        if not all_pts:
            radius = 3.0
        else:
            center = sum(all_pts, mathutils.Vector()) / len(all_pts)
            radius = max((p - center).length for p in all_pts)

    # FOV from lens (36mm sensor)
    fov = 2 * math.atan(18.0 / lens)  # vertical half-FOV
    dist = distance or (radius * padding / math.tan(fov / 2))

    return cam_front(distance=dist, lens=lens)

# ─────────────────────────────────────────────────────────────────────────────
# ANIMATION HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def set_looping_interpolation():
    bpy.context.preferences.edit.keyframe_new_interpolation_type = 'BEZIER'

def anim_sine_bob(obj, amplitude=0.12, frames=48, axis='Z', offset_frames=0):
    """Gentle sine-wave bob on any axis (0=X, 1=Y, 2=Z)."""
    axis_idx = {'X': 0, 'Y': 1, 'Z': 2}[axis.upper()]
    for f in range(1, frames + 1):
        t = (f - 1 + offset_frames) / frames
        val = amplitude * math.sin(2 * math.pi * t)
        if axis_idx == 0: obj.location.x = val
        elif axis_idx == 1: obj.location.y = val
        else: obj.location.z = val
        obj.keyframe_insert('location', index=axis_idx, frame=f)

def anim_sine_rot(obj, amplitude_deg=3.0, frames=48, axis='Z', offset_deg=0):
    """Gentle rotation rock."""
    axis_idx = {'X': 0, 'Y': 1, 'Z': 2}[axis.upper()]
    amp = math.radians(amplitude_deg)
    for f in range(1, frames + 1):
        t = (f - 1) / frames
        val = amp * math.sin(2 * math.pi * t + math.radians(offset_deg))
        if axis_idx == 0: obj.rotation_euler.x = val
        elif axis_idx == 1: obj.rotation_euler.y = val
        else: obj.rotation_euler.z = val
        obj.keyframe_insert('rotation_euler', index=axis_idx, frame=f)

def anim_arm_wave(arm_parent, amplitude_deg=22, frames=48, axis='Y',
                   phase_offset_deg=0):
    """Arm raise/lower animation."""
    anim_sine_rot(arm_parent, amplitude_deg, frames, axis, phase_offset_deg)

def anim_antenna_wiggle(ant_parent, amplitude_deg=15, frames=48, freq=2,
                         phase_offset_deg=0, axis='Z'):
    """Antenna wiggle at 2x frequency."""
    axis_idx = {'X': 0, 'Y': 1, 'Z': 2}[axis.upper()]
    amp = math.radians(amplitude_deg)
    for f in range(1, frames + 1):
        t = (f - 1) / frames
        val = amp * math.sin(freq * 2 * math.pi * t + math.radians(phase_offset_deg))
        if axis_idx == 0: ant_parent.rotation_euler.x = val
        elif axis_idx == 1: ant_parent.rotation_euler.y = val
        else: ant_parent.rotation_euler.z = val
        ant_parent.keyframe_insert('rotation_euler', index=axis_idx, frame=f)

def anim_bar_grow(obj, target_scale_z, frames_start=1, frames_end=30,
                   ease='smooth', axis='Z'):
    """Animate a bar growing from 0 to target_scale_z."""
    axis_idx = {'X': 0, 'Y': 1, 'Z': 2}[axis.upper()]
    # Frame before start: scale = 0
    if axis_idx == 0: obj.scale.x = 0.001
    elif axis_idx == 1: obj.scale.y = 0.001
    else: obj.scale.z = 0.001
    obj.keyframe_insert('scale', index=axis_idx, frame=frames_start - 1)

    # End frame: full scale
    if axis_idx == 0: obj.scale.x = target_scale_z
    elif axis_idx == 1: obj.scale.y = target_scale_z
    else: obj.scale.z = target_scale_z
    obj.keyframe_insert('scale', index=axis_idx, frame=frames_end)

    # Set easing
    if obj.animation_data and obj.animation_data.action:
        for fc in obj.animation_data.action.fcurves:
            if fc.data_path == 'scale' and fc.array_index == axis_idx:
                for kp in fc.keyframe_points:
                    if ease == 'smooth':
                        kp.interpolation = 'BEZIER'
                        kp.easing = 'EASE_IN_OUT'
                    elif ease == 'bounce':
                        kp.interpolation = 'BACK'

def anim_fade_in(obj, frames_start=1, frames_end=15):
    """Fade object in using material alpha or scale from 0."""
    obj.scale = (0.01, 0.01, 0.01)
    obj.keyframe_insert('scale', frame=frames_start)
    obj.scale = (1.0, 1.0, 1.0)
    obj.keyframe_insert('scale', frame=frames_end)

def anim_counter(text_obj, start_val, end_val, frames_start=1, frames_end=60,
                  prefix='', suffix='', decimals=0):
    """Animate a text object counting from start_val to end_val."""
    total_frames = frames_end - frames_start
    for f in range(frames_start, frames_end + 1):
        t = (f - frames_start) / total_frames
        # Ease in-out
        t_eased = t * t * (3 - 2 * t)
        val = start_val + (end_val - start_val) * t_eased
        fmt = f'.{decimals}f'
        text_obj.data.body = f'{prefix}{val:{fmt}}{suffix}'
        text_obj.data.keyframe_insert('body', frame=f)

# ─────────────────────────────────────────────────────────────────────────────
# CHART HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def make_bar_chart(data, bar_width=0.7, gap=0.3, max_height=5.0,
                   colors=None, animate=True, frames_per_bar=20,
                   base_location=(0, 0, 0), mat_fn=None):
    """
    Create a 3D animated bar chart.
    data: list of (label, value) tuples
    Returns list of bar objects.
    """
    if colors is None:
        colors = [PALETTE['chart_blue'], PALETTE['chart_green'],
                  PALETTE['chart_yellow'], PALETTE['chart_red'], PALETTE['chart_purple']]
    max_val = max(v for _, v in data)
    bars = []
    scene_cols = list(bpy.context.scene.collection.objects)

    for i, (label, value) in enumerate(data):
        height = (value / max_val) * max_height
        x = base_location[0] + i * (bar_width + gap)
        y = base_location[1]
        z = base_location[2]

        color = colors[i % len(colors)]
        if mat_fn:
            mat = mat_fn(f'Bar_{i}', color)
        else:
            mat = mat_principled(f'Bar_{i}', color, roughness=0.4, subsurface=0)

        bar = make_cube(size=1.0,
                        location=(x, y, z + height / 2),
                        scale=(bar_width, bar_width * 0.6, height),
                        mat=mat, smooth=True, bevel=0.03,
                        name=f'Bar_{i}_{label}')
        bars.append(bar)

        if animate:
            start_f = 1 + i * (frames_per_bar // 3)
            end_f   = start_f + frames_per_bar
            anim_bar_grow(bar, height, start_f, end_f)

    return bars

def make_progress_ring(pct, radius=2.0, thickness=0.3, depth=0.2,
                        color=None, bg_color=(0.1, 0.1, 0.15),
                        location=(0,0,0), name='Ring'):
    """Create a progress/donut ring showing a percentage."""
    # This uses a torus approximation — for animation, animate rotation of a masking object
    mat_bg  = mat_principled(f'{name}_bg',  bg_color,    roughness=0.8, subsurface=0)
    mat_fg  = mat_emission  (f'{name}_fg',  color or PALETTE['chart_blue'], strength=2.0)

    bpy.ops.mesh.primitive_torus_add(
        location=location,
        major_radius=radius,
        minor_radius=thickness,
        major_segments=128,
        minor_segments=24
    )
    ring_bg = bpy.context.view_layer.objects.active
    ring_bg.name = f'{name}_bg'
    ring_bg.data.materials.append(mat_bg)

    # Foreground arc — same torus but only shows pct of it
    # For a full implementation, use a boolean or geometry nodes
    # Simple approach: scale the fg torus
    bpy.ops.mesh.primitive_torus_add(
        location=location,
        major_radius=radius,
        minor_radius=thickness * 0.9,
        major_segments=max(4, int(128 * pct)),
        minor_segments=24
    )
    ring_fg = bpy.context.view_layer.objects.active
    ring_fg.name = f'{name}_fg'
    ring_fg.data.materials.append(mat_fg)

    return ring_bg, ring_fg

# ─────────────────────────────────────────────────────────────────────────────
# TEXT / TITLES
# ─────────────────────────────────────────────────────────────────────────────

def make_text(text, size=1.0, location=(0,0,0), rotation=(0,0,0),
              mat=None, extrude=0.05, align='CENTER', font_path=None, name='Text'):
    bpy.ops.object.text_add(location=location)
    obj = bpy.context.view_layer.objects.active
    obj.name = name
    obj.data.body = text
    obj.data.size = size
    obj.data.extrude = extrude
    obj.data.align_x = align
    if font_path:
        try:
            font = bpy.data.fonts.load(font_path)
            obj.data.font = font
        except Exception:
            pass
    if rotation != (0,0,0):
        obj.rotation_euler = tuple(math.radians(r) for r in rotation)
    if mat:
        obj.data.materials.append(mat)
    return obj

# ─────────────────────────────────────────────────────────────────────────────
# SCENE UTILITIES
# ─────────────────────────────────────────────────────────────────────────────

def dump_scene(output_path=None):
    """Dump all objects in scene to JSON — for debugging and iteration tracking."""
    import json
    scene_data = {'objects': []}
    for obj in bpy.context.scene.objects:
        entry = {
            'name':     obj.name,
            'type':     obj.type,
            'location': list(obj.location),
            'rotation': list(obj.rotation_euler),
            'scale':    list(obj.scale),
            'parent':   obj.parent.name if obj.parent else None,
            'materials': [m.name for m in obj.data.materials] if hasattr(obj.data, 'materials') else [],
        }
        if obj.type == 'MESH' and obj.data:
            entry['verts'] = len(obj.data.vertices)
        scene_data['objects'].append(entry)
    out = output_path or '/tmp/blender_scene_dump.json'
    with open(out, 'w') as f:
        json.dump(scene_data, f, indent=2)
    print(f"[blender_lib] Scene dumped: {out}  ({len(scene_data['objects'])} objects)")
    return scene_data

def render_and_open(output_path='/tmp/bl_render.png', open_after=True):
    """Render current frame and open result."""
    bpy.context.scene.render.filepath = output_path
    bpy.ops.render.render(write_still=True)
    if open_after:
        import subprocess
        subprocess.Popen(['open', output_path])
    return output_path

def px_to_bu(px_measurement, px_per_bu):
    """Convert pixel measurement from reference to Blender units."""
    return round(px_measurement / px_per_bu, 4)

def bu_to_px(bu_measurement, px_per_bu):
    """Convert Blender units to expected pixel size in reference."""
    return round(bu_measurement * px_per_bu, 1)

# ─────────────────────────────────────────────────────────────────────────────
# STANDARD CHARACTER RIG TEMPLATE
# ─────────────────────────────────────────────────────────────────────────────

def make_character_rig(name='Character'):
    """
    Creates the standard hierarchy for an animated creature/mascot:
    Root (empty)
      Body (mesh)
      Eyes[] (meshes)
      LArmPivot (empty) → LArm (mesh)
      RArmPivot (empty) → RArm (mesh)
      Legs[] (meshes)
      LAntPivot (empty) → LAnt (curve)
      RAntPivot (empty) → RAnt (curve)
    Returns dict of all empties for animation access.
    """
    sc = bpy.context.scene.collection
    root = bpy.data.objects.new(f'{name}_Root', None)
    root.location = (0, 0, 0)
    sc.objects.link(root)

    larm_p = bpy.data.objects.new(f'{name}_LArmPivot', None)
    larm_p.location = (-2.0, 0, 0)
    sc.objects.link(larm_p)
    larm_p.parent = root

    rarm_p = bpy.data.objects.new(f'{name}_RArmPivot', None)
    rarm_p.location = (2.0, 0, 0)
    sc.objects.link(rarm_p)
    rarm_p.parent = root

    lant_p = bpy.data.objects.new(f'{name}_LAntPivot', None)
    lant_p.location = (-0.5, -1.3, 1.5)
    sc.objects.link(lant_p)
    lant_p.parent = root

    rant_p = bpy.data.objects.new(f'{name}_RAntPivot', None)
    rant_p.location = (0.5, -1.3, 1.5)
    sc.objects.link(rant_p)
    rant_p.parent = root

    print(f"[blender_lib] Character rig created: {name}")
    print(f"[blender_lib] Hierarchy: Root → Body/Eyes/Legs (direct), ArmPivots → Arms, AntPivots → Antennae")

    return {
        'root':   root,
        'larm_p': larm_p,
        'rarm_p': rarm_p,
        'lant_p': lant_p,
        'rant_p': rant_p,
    }
