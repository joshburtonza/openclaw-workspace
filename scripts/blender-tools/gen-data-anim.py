#!/usr/bin/env python3
"""
gen-data-anim.py — Generate a Blender animation script from a data mention JSON.
Renders RGBA PNG sequences with transparent background for ffmpeg compositing.
"""
import json, sys, os
from pathlib import Path

ZONES = {
    'lower_right':  {'w': 0.46, 'h': 0.28},
    'lower_left':   {'w': 0.46, 'h': 0.28},
    'lower_center': {'w': 0.80, 'h': 0.22},
    'center_right': {'w': 0.46, 'h': 0.28},
    'upper_right':  {'w': 0.46, 'h': 0.26},
}

def generate_script(mention, width, height, out_dir, frames_dir=None):
    anim_type    = mention.get('type', 'counter')
    data         = mention.get('data', {})
    position     = mention.get('position', 'lower_right')
    duration     = float(mention.get('overlay_duration', 3.0))
    fps          = 30
    total_frames = max(30, int(duration * fps))
    zone         = ZONES.get(position, ZONES['lower_right'])
    card_w       = max(420, int(width  * zone['w']))
    card_h       = max(200, int(height * zone['h']))
    frames_out   = frames_dir or f'/tmp/data_anim_{anim_type}'

    script = f'''"""Auto-generated: {anim_type} | {json.dumps(data)[:80]}"""
import bpy, math, os, sys
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.frame_start = 1
scene.frame_end   = {total_frames}
scene.render.fps  = {fps}
scene.render.engine = 'BLENDER_EEVEE'
try:
    scene.eevee.taa_render_samples  = 64
    scene.eevee.use_bloom           = True
    scene.eevee.bloom_intensity     = 0.30
    scene.eevee.bloom_threshold     = 0.80
    scene.eevee.bloom_radius        = 4.0
    scene.eevee.use_gtao            = False
except Exception: pass
scene.render.resolution_x          = {card_w}
scene.render.resolution_y          = {card_h}
scene.render.film_transparent       = True
scene.render.image_settings.file_format  = 'PNG'
scene.render.image_settings.color_mode  = 'RGBA'
os.makedirs('{frames_out}', exist_ok=True)
scene.render.filepath = '{frames_out}/frame_'

# Transparent world
world = bpy.data.worlds.new('W')
scene.world = world
world.use_nodes = True
wn = world.node_tree.nodes; wn.clear()
bg = wn.new('ShaderNodeBackground')
bg.inputs['Color'].default_value    = (0,0,0,0)
bg.inputs['Strength'].default_value = 0
wo = wn.new('ShaderNodeOutputWorld')
world.node_tree.links.new(bg.outputs['Background'], wo.inputs['Surface'])

# Camera — orthographic, looks along +Y
bpy.ops.object.camera_add(location=(0,-10,0))
cam = bpy.context.view_layer.objects.active
cam.data.type        = 'ORTHO'
cam.data.ortho_scale = 4.2
cam.rotation_euler   = (math.radians(90),0,0)
scene.camera = cam

# Soft fill light
bpy.ops.object.light_add(type='AREA', location=(0,-8,3))
li = bpy.context.view_layer.objects.active
li.data.energy = 200; li.data.size = 10

def mat_emit(name, rgb, strength=1.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    ns = m.node_tree.nodes; ls = m.node_tree.links; ns.clear()
    e = ns.new('ShaderNodeEmission')
    e.inputs['Color'].default_value    = (*rgb, 1.0)
    e.inputs['Strength'].default_value = strength
    o = ns.new('ShaderNodeOutputMaterial')
    ls.new(e.outputs['Emission'], o.inputs['Surface'])
    return m

def mat_alpha(name, rgb=(0.05,0.06,0.12), alpha=0.40):
    """Semi-transparent pill background."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True; m.blend_method = 'BLEND'
    ns = m.node_tree.nodes; ls = m.node_tree.links; ns.clear()
    mix = ns.new('ShaderNodeMixShader')
    mix.inputs['Fac'].default_value = alpha
    tr  = ns.new('ShaderNodeBsdfTransparent')
    diff = ns.new('ShaderNodeBsdfDiffuse')
    diff.inputs['Color'].default_value = (*rgb, 1.0)
    o   = ns.new('ShaderNodeOutputMaterial')
    ls.new(tr.outputs['BSDF'],   mix.inputs[1])
    ls.new(diff.outputs['BSDF'], mix.inputs[2])
    ls.new(mix.outputs['Shader'], o.inputs['Surface'])
    return m

def make_pill(w, h, d, location, mat):
    """Rounded rect background pill."""
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=location)
    o = bpy.context.view_layer.objects.active
    o.scale = (w, d, h)
    bpy.ops.object.transform_apply(scale=True)
    mod = o.modifiers.new('Bevel','BEVEL')
    mod.width = 0.18; mod.segments = 6
    o.data.materials.append(mat)
    return o

def make_text(body, size, loc, mat, align='CENTER'):
    bpy.ops.object.text_add(location=loc)
    o = bpy.context.view_layer.objects.active
    o.data.body    = body
    o.data.size    = size
    o.data.align_x = align
    o.data.extrude = 0.0
    o.rotation_euler = (math.radians(90),0,0)
    o.data.materials.append(mat)
    return o

def make_bar(w, h, d, loc, mat):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=loc)
    o = bpy.context.view_layer.objects.active
    o.scale = (w, d, h)
    bpy.ops.object.transform_apply(scale=True)
    o.data.materials.append(mat)
    return o

def ease_out_back(t, ov=1.3):
    t -= 1; return t*t*((ov+1)*t+ov)+1

def smooth(t):
    return t*t*(3-2*t)

TOTAL = {total_frames}
FPS   = {fps}
'''

    if   anim_type == 'counter':      script += _counter_anim(data, total_frames)
    elif anim_type == 'growth_arrow':  script += _growth_arrow_anim(data, total_frames)
    elif anim_type == 'progress_ring': script += _progress_ring_anim(data, total_frames)
    elif anim_type == 'bar_chart':     script += _bar_chart_anim(data, total_frames)
    elif anim_type == 'comparison':    script += _comparison_anim(data, total_frames)
    else:                              script += _counter_anim(data, total_frames)

    script += '\nbpy.ops.render.render(animation=True)\nprint("[data-anim] DONE")\n'
    return script


# ─────────────────────────────────────────────────────────────────────────────
#  COUNTER  —  Gold pill, number counts up, slides in from right
# ─────────────────────────────────────────────────────────────────────────────
def _counter_anim(data, total_frames):
    display   = data.get('display', str(data.get('value','0')))
    label     = data.get('label', '')
    trend     = data.get('trend', 'neutral')
    raw_value = data.get('value', 0)

    # Color scheme by trend
    if trend == 'up':
        val_rgb  = str((1.00, 0.80, 0.05))   # gold
        acc_rgb  = str((1.00, 0.80, 0.05))
        pill_rgb = str((0.08, 0.06, 0.02))   # warm dark
    elif trend == 'down':
        val_rgb  = str((1.00, 0.25, 0.18))   # red
        acc_rgb  = str((1.00, 0.25, 0.18))
        pill_rgb = str((0.10, 0.02, 0.02))
    else:
        val_rgb  = str((0.20, 0.70, 1.00))   # blue
        acc_rgb  = str((0.20, 0.70, 1.00))
        pill_rgb = str((0.02, 0.05, 0.12))

    return f'''
# ── COUNTER ───────────────────────────────────────────────────────────────────
M_PILL  = mat_alpha('Pill', rgb={pill_rgb}, alpha=0.55)
M_VAL   = mat_emit('Val',  {val_rgb},  strength=7.0)
M_LBL   = mat_emit('Lbl',  (0.90, 0.90, 0.95), strength=3.5)
M_ACC   = mat_emit('Acc',  {acc_rgb},  strength=6.0)
M_GLOW  = mat_emit('Glow', {acc_rgb},  strength=2.0)

# Slim translucent pill background
pill = make_pill(3.4, 1.50, 0.06, (0,0,0), M_PILL)

# Glow halo behind value (slightly larger, dimmer, same color)
glow_obj = make_pill(3.0, 0.90, 0.04, (0, 0.01, 0.10), M_GLOW)

# Thick accent bar at TOP of pill
acc = make_bar(2.80, 0.065, 0.04, (0, 0.04, 0.62), M_ACC)

# Main value — BIG, counts up from 0
val_obj = make_text('0', 1.20, (0, -0.03, 0.10), M_VAL)

# Label below
lbl_obj = make_text('{label}', 0.24, (0, -0.03, -0.50), M_LBL)

# ── Dynamic counter via frame_change_pre ──────────────────────────────────────
_RAW  = {raw_value}
_DISP = '{display}'
_VN   = val_obj.name

def _fmt(n):
    d = _DISP
    if '$' in d:
        if 'B' in d: return f"${{n/1e9:.1f}}B"
        if 'M' in d: return f"${{n/1e6:.1f}}M"
        if 'K' in d: return f"${{n/1e3:.0f}}K"
        return f"${{int(n):,}}"
    if '%' in d: return f"{{int(n)}}%"
    if _RAW >= 1e6: return f"{{n/1e6:.1f}}M"
    if _RAW >= 1e3: return f"{{n/1e3:.0f}}K"
    return f"{{int(n):,}}"

import bpy.app.handlers
@bpy.app.handlers.persistent
def _cnt_upd(scene):
    f = scene.frame_current
    if f < 1 or f > TOTAL: return
    t  = (f-1)/max(TOTAL-1,1)
    ct = max(0.0, min(1.0, (t-0.25)/0.55))
    o  = bpy.data.objects.get(_VN)
    if o: o.data.body = _fmt(smooth(ct) * _RAW)
bpy.app.handlers.frame_change_pre.append(_cnt_upd)

# ── Keyframe: everything slides in from right ─────────────────────────────────
_BZ = {{pill:0.0, glow_obj:0.10, val_obj:0.10, lbl_obj:-0.50, acc:0.62}}
for f in range(1, TOTAL+1):
    t  = (f-1)/max(TOTAL-1,1)
    st = min(1.0, t/0.28)
    ox = 4.5*(1.0 - ease_out_back(st, 1.15))
    fz = 0.018*math.sin(max(0.0,t-0.32)*2*math.pi*0.85)
    for obj in [pill, glow_obj, val_obj, lbl_obj, acc]:
        obj.location.x = ox
        obj.location.z = _BZ[obj]+fz
        obj.keyframe_insert('location', index=0, frame=f)
        obj.keyframe_insert('location', index=2, frame=f)
    pulse = 1.0 + (0.07*math.sin((t-0.78)/0.10*math.pi) if 0.78<t<0.88 else 0)
    val_obj.scale = (pulse, pulse, pulse)
    val_obj.keyframe_insert('scale', frame=f)
'''


# ─────────────────────────────────────────────────────────────────────────────
#  GROWTH ARROW  —  Lime green, arrow draws itself, value counts up
# ─────────────────────────────────────────────────────────────────────────────
def _growth_arrow_anim(data, total_frames):
    value     = data.get('value', 0)
    unit      = data.get('unit', '%')
    direction = data.get('direction', 'up')
    label     = data.get('label', 'Growth')
    period    = data.get('period', '')
    sign      = '+' if direction == 'up' else '-'
    arrow_dir = 1 if direction == 'up' else -1
    if direction == 'up':
        val_rgb  = str((0.10, 1.00, 0.40))   # lime green
        acc_rgb  = str((0.10, 1.00, 0.40))
        pill_rgb = str((0.02, 0.08, 0.03))
    else:
        val_rgb  = str((1.00, 0.22, 0.16))
        acc_rgb  = str((1.00, 0.22, 0.16))
        pill_rgb = str((0.10, 0.02, 0.02))

    return f'''
# ── GROWTH ARROW ──────────────────────────────────────────────────────────────
M_PILL  = mat_alpha('Pill', rgb={pill_rgb}, alpha=0.55)
M_VAL   = mat_emit('Val',  {val_rgb},  strength=7.0)
M_LBL   = mat_emit('Lbl',  (0.88, 0.88, 0.92), strength=3.0)
M_ARR   = mat_emit('Arr',  {val_rgb},  strength=6.0)
M_GLOW  = mat_emit('Glow', {val_rgb},  strength=1.8)

pill = make_pill(3.4, 1.50, 0.06, (0,0,0), M_PILL)

# Arrow shaft — grows from z=0 outward
bpy.ops.mesh.primitive_cube_add(size=1.0, location=(-1.05, -0.02, 0.0))
shaft = bpy.context.view_layer.objects.active
shaft.scale = (0.07, 0.025, 0.50); bpy.ops.object.transform_apply(scale=True)
shaft.data.materials.append(M_ARR)

# Arrow head — diamond (4-vert cone)
bpy.ops.mesh.primitive_cone_add(vertices=4, radius1=0.26, depth=0.32,
    location=(-1.05, -0.02, {arrow_dir*0.58}))
head = bpy.context.view_layer.objects.active
if {arrow_dir} < 0: head.rotation_euler.x = math.radians(180)
head.data.materials.append(M_ARR)

# Glow halo on arrow
bpy.ops.mesh.primitive_uv_sphere_add(radius=0.18, location=(-1.05,-0.04,{arrow_dir*0.58}))
aglow = bpy.context.view_layer.objects.active
aglow.data.materials.append(M_GLOW)

# Value + label — right side
val_obj = make_text('{sign}0{unit}', 1.15, (0.62, -0.03, 0.12), M_VAL)
lbl_text = '{label}' + (' · {period}' if '{period}' else '')
lbl_obj  = make_text(lbl_text, 0.23, (0.62, -0.03, -0.48), M_LBL)

# Accent bar under value
acc = make_bar(1.90, 0.060, 0.04, (0.62, 0.04, -0.75), M_ARR)

# ── Dynamic value count ───────────────────────────────────────────────────────
_GVAL = {value}; _SIGN = '{sign}'; _UNIT = '{unit}'; _GVN = val_obj.name
import bpy.app.handlers
@bpy.app.handlers.persistent
def _arr_upd(scene):
    f = scene.frame_current
    if f < 1 or f > TOTAL: return
    t  = (f-1)/max(TOTAL-1,1)
    vt = max(0.0, min(1.0, (t-0.30)/0.45))
    o  = bpy.data.objects.get(_GVN)
    if o: o.data.body = f"{{_SIGN}}{{int(smooth(vt)*_GVAL)}}{{_UNIT}}"
bpy.app.handlers.frame_change_pre.append(_arr_upd)

# ── Keyframes ─────────────────────────────────────────────────────────────────
for f in range(1, TOTAL+1):
    t = (f-1)/max(TOTAL-1,1)

    # Pill + label slide in from LEFT
    st = min(1.0, t/0.28)
    ox_l = -4.5*(1.0 - ease_out_back(st, 1.10))
    for obj in [pill, lbl_obj, acc]:
        obj.location.x = ox_l
        obj.keyframe_insert('location', index=0, frame=f)

    # Shaft grows (scale z)
    gt = min(1.0, t/0.38); ge = ease_out_back(gt)
    shaft.scale.z = max(0.001, ge)*0.50
    shaft.keyframe_insert('scale', index=2, frame=f)

    # Arrow head pops in
    hs = max(0.001, min(1.0, (t-0.28)/0.14))
    head.scale = (hs,hs,hs); head.keyframe_insert('scale', frame=f)
    aglow.scale = (hs,hs,hs); aglow.keyframe_insert('scale', frame=f)

    # Value text scales in + subtle bounce
    vt2 = max(0, min(1.0, (t-0.28)/0.28)); ve = ease_out_back(vt2, 1.25)
    val_obj.scale = (max(0.001,ve),)*3; val_obj.keyframe_insert('scale', frame=f)

    # Gentle float on everything
    fz = 0.016*math.sin(max(0.0,t-0.35)*2*math.pi*0.90)
    for obj in [shaft, head, aglow, val_obj]:
        obj.location.z = obj.location.z * 0 + fz + (
            0.0  if obj is shaft else
            {arrow_dir*0.58} if obj is head else
            {arrow_dir*0.58} if obj is aglow else 0.12
        )
        obj.keyframe_insert('location', index=2, frame=f)
'''


# ─────────────────────────────────────────────────────────────────────────────
#  PROGRESS RING  —  Cyan sweep, value counts up, no heavy card
# ─────────────────────────────────────────────────────────────────────────────
def _progress_ring_anim(data, total_frames):
    value   = float(data.get('value', 75))
    label   = data.get('label', '')
    unit    = data.get('unit', '%')
    pct     = value / 100.0
    # Cyan-teal color
    fg_rgb  = (0.05, 0.85, 1.00)

    return f'''
# ── PROGRESS RING ─────────────────────────────────────────────────────────────
M_PILL  = mat_alpha('Pill', rgb=(0.03,0.06,0.10), alpha=0.55)
M_BG    = mat_emit('RBg',  (0.08, 0.10, 0.16), strength=1.5)
M_FG    = mat_emit('RFg',  {fg_rgb},  strength=6.0)
M_GLOW  = mat_emit('RGl',  {fg_rgb},  strength=2.0)
M_VAL   = mat_emit('Val',  {fg_rgb},  strength=6.5)
M_LBL   = mat_emit('Lbl',  (0.88, 0.88, 0.93), strength=3.0)

# Slim backing pill
pill = make_pill(3.4, 2.10, 0.06, (0,0,0), M_PILL)

# BG ring (full torus)
bpy.ops.mesh.primitive_torus_add(location=(0,-0.02,0.06),
    major_radius=0.78, minor_radius=0.10, major_segments=96, minor_segments=12)
ring_bg = bpy.context.view_layer.objects.active
ring_bg.rotation_euler.x = math.radians(90)
ring_bg.data.materials.append(M_BG)

# Glow ring (slightly larger, dim) — bloom source
bpy.ops.mesh.primitive_torus_add(location=(0,-0.05,0.06),
    major_radius=0.78, minor_radius=0.14, major_segments=96, minor_segments=8)
ring_glow = bpy.context.view_layer.objects.active
ring_glow.rotation_euler.x = math.radians(90)
ring_glow.data.materials.append(M_GLOW)

# FG arc — OPEN bezier circle, bevel sweeps 0→pct via frame handler
bpy.ops.curve.primitive_bezier_circle_add(radius=0.78, location=(0,-0.04,0.06))
ring_fg = bpy.context.view_layer.objects.active
ring_fg.data.splines[0].use_cyclic_u = False
ring_fg.data.bevel_depth       = 0.10
ring_fg.data.bevel_resolution  = 4
ring_fg.data.bevel_factor_end  = 0.0
ring_fg.rotation_euler.x       = math.radians(90)
ring_fg.data.materials.append(M_FG)

# Value text — center, counts up
val_obj = make_text('0{unit}', 0.72, (0,-0.08,0.06), M_VAL)
lbl_obj = make_text('{label}', 0.175, (0,-0.08,-1.00), M_LBL)

# ── frame_change_pre: sweep arc + count value ─────────────────────────────────
_RPCT = {value}; _PCT = {pct}; _RUNIT = '{unit}'
_RVN = val_obj.name; _RFGDN = ring_fg.data.name
import bpy.app.handlers
@bpy.app.handlers.persistent
def _ring_upd(scene):
    f = scene.frame_current
    if f < 1 or f > TOTAL: return
    t    = (f-1)/max(TOTAL-1,1)
    ft   = max(0.0, min(1.0,(t-0.12)/0.68))
    ease = smooth(ft)
    c = bpy.data.curves.get(_RFGDN)
    if c: c.bevel_factor_end = ease*_PCT
    o = bpy.data.objects.get(_RVN)
    if o: o.data.body = f"{{int(ease*_RPCT)}}{{_RUNIT}}"
bpy.app.handlers.frame_change_pre.append(_ring_upd)

# ── Keyframes ─────────────────────────────────────────────────────────────────
# BG ring + glow: scale pop-in
for obj in [ring_bg, ring_glow]:
    obj.scale = (0.001,0.001,0.001)
for f in range(1, TOTAL+1):
    t = (f-1)/max(TOTAL-1,1)
    rt = min(1.0,t/0.22); re = ease_out_back(rt,1.12)
    s  = max(0.001, re)
    for obj in [ring_bg, ring_glow]:
        obj.scale = (s,s,s); obj.keyframe_insert('scale', frame=f)

# Pill slides up from below
pill.location.z = -3.0
for f in range(1, TOTAL+1):
    t = (f-1)/max(TOTAL-1,1)
    pt = min(1.0, t/0.24); pe = ease_out_back(pt,1.08)
    pill.location.z = -3.0 + 3.0*pe
    pill.keyframe_insert('location', index=2, frame=f)

# Value + label pop in
val_obj.scale = (0.001,0.001,0.001); lbl_obj.scale = (0.001,0.001,0.001)
for f in range(1, TOTAL+1):
    t  = (f-1)/max(TOTAL-1,1)
    vt = max(0.0, min(1.0,(t-0.58)/0.26)); ve = ease_out_back(vt,1.30)
    sv = max(0.001,ve)
    val_obj.scale=(sv,sv,sv); val_obj.keyframe_insert('scale', frame=f)
    lbl_obj.scale=(sv*0.9,sv*0.9,sv*0.9); lbl_obj.keyframe_insert('scale', frame=f)
'''


# ─────────────────────────────────────────────────────────────────────────────
#  BAR CHART  (unchanged from previous)
# ─────────────────────────────────────────────────────────────────────────────
def _bar_chart_anim(data, total_frames):
    bars      = data.get('bars', [{'label':'A','value':1},{'label':'B','value':2}])
    unit      = data.get('unit', '')
    title     = data.get('title', '')
    max_val   = max(b['value'] for b in bars) if bars else 1
    bars_json = json.dumps(bars)
    return f'''
import json
bars=({bars_json}); max_val={max_val}; unit="{unit}"; title_text="{title}"; n_bars=len(bars)
M_PILL  = mat_alpha('Pill', alpha=0.50)
M_TITLE = mat_emit('Title',(0.88,0.88,0.93),strength=3.0)
M_LABEL = mat_emit('Label',(0.65,0.65,0.72),strength=2.0)
BAR_COLORS=[(0.20,0.65,1.00),(0.10,1.00,0.40),(1.00,0.78,0.05),(1.00,0.25,0.18),(0.72,0.30,1.00)]
pill=make_pill(4.2,2.3,0.06,(0,0,0),M_PILL)
if title_text: make_text(title_text,0.21,(0,-0.04,0.90),M_TITLE)
bw=min(0.52,3.0/max(n_bars,1)-0.10); tw=n_bars*(bw+0.10)-0.10; sx=-tw/2+bw/2
bar_objs=[]
for i,bar in enumerate(bars):
    x=sx+i*(bw+0.10); h=max(0.05,(bar['value']/max_val)*1.20)
    mat=mat_emit(f'B{{i}}',BAR_COLORS[i%len(BAR_COLORS)],strength=4.0)
    bpy.ops.mesh.primitive_cube_add(size=1.0,location=(x,-0.02,-0.55+h/2))
    bo=bpy.context.view_layer.objects.active; bo.scale=(bw*0.88,0.07,h)
    bpy.ops.object.transform_apply(scale=True); bo.data.materials.append(mat); bar_objs.append((bo,h,bar,x))
    make_text(f"{{bar['value']}}"+f"{{unit}}" if unit else f"{{bar['value']}}",0.18,(x,-0.02,-0.55+h+0.15),mat_emit(f'VL{{i}}',BAR_COLORS[i%len(BAR_COLORS)],4.0))
    make_text(bar['label'],0.16,(x,-0.02,-0.88),M_LABEL)
for f in range(1,TOTAL+1):
    t=(f-1)/max(TOTAL-1,1)
    for i,(bo,h,bar,x) in enumerate(bar_objs):
        bt=max(0,min(1.0,(t-i*0.08)/0.52)); be=ease_out_back(bt,1.12)
        bo.scale.z=max(0.001,be*h); bo.keyframe_insert('scale',index=2,frame=f)
        bo.location.z=-0.55+(be*h)/2; bo.keyframe_insert('location',index=2,frame=f)
'''


# ─────────────────────────────────────────────────────────────────────────────
#  COMPARISON (unchanged)
# ─────────────────────────────────────────────────────────────────────────────
def _comparison_anim(data, total_frames):
    before = data.get('before',{'value':1.0,'label':'Before'})
    after  = data.get('after', {'value':2.0,'label':'After'})
    unit   = data.get('unit', '')
    max_v  = max(before['value'], after['value'])
    return f'''
before={json.dumps(before)}; after={json.dumps(after)}; unit="{unit}"; max_v={max_v}
M_PILL=mat_alpha('Pill',alpha=0.50)
M_BEF=mat_emit('Bef',(0.42,0.52,0.92),strength=4.5)
M_AFT=mat_emit('Aft',(0.10,1.00,0.40),strength=4.5)
M_LBL=mat_emit('Lbl',(0.80,0.80,0.88),strength=3.0)
pill=make_pill(4.0,2.0,0.06,(0,0,0),M_PILL)
bh=(before['value']/max_v)*1.20; ah=(after['value']/max_v)*1.20
bpy.ops.mesh.primitive_cube_add(size=1.0,location=(-0.82,-0.02,-0.55+bh/2))
bar_b=bpy.context.view_layer.objects.active; bar_b.scale=(0.52,0.07,bh)
bpy.ops.object.transform_apply(scale=True); bar_b.data.materials.append(M_BEF)
make_text(f"{{before['value']}}"+unit,0.28,(-0.82,-0.02,-0.55+bh+0.14),M_BEF)
make_text(before['label'],0.17,(-0.82,-0.02,-0.86),M_LBL)
bpy.ops.mesh.primitive_cube_add(size=1.0,location=(0.82,-0.02,-0.55+ah/2))
bar_a=bpy.context.view_layer.objects.active; bar_a.scale=(0.52,0.07,ah)
bpy.ops.object.transform_apply(scale=True); bar_a.data.materials.append(M_AFT)
make_text(f"{{after['value']}}"+unit,0.28,(0.82,-0.02,-0.55+ah+0.14),M_AFT)
make_text(after['label'],0.17,(0.82,-0.02,-0.86),M_LBL)
pct=round((after['value']-before['value'])/max(before['value'],0.001)*100,0)
make_text(f"{{'+' if pct>0 else ''}}{{pct:.0f}}%",0.22,(0,-0.02,0.42),mat_emit('Pct',(0.10,1.00,0.40) if pct>0 else (1.00,0.22,0.16),4.0))
for f in range(1,TOTAL+1):
    t=(f-1)/max(TOTAL-1,1)
    bt=min(1.0,t/0.38); be=ease_out_back(bt)
    bar_b.scale.z=max(0.001,be*bh); bar_b.keyframe_insert('scale',index=2,frame=f)
    bar_b.location.z=-0.55+(be*bh)/2; bar_b.keyframe_insert('location',index=2,frame=f)
    at=max(0,min(1.0,(t-0.22)/0.38)); ae=ease_out_back(at,1.18)
    bar_a.scale.z=max(0.001,ae*ah); bar_a.keyframe_insert('scale',index=2,frame=f)
    bar_a.location.z=-0.55+(ae*ah)/2; bar_a.keyframe_insert('location',index=2,frame=f)
'''


if __name__ == '__main__':
    if len(sys.argv) < 5:
        print("Usage: gen-data-anim.py '<mention_json>' <width> <height> <out_script.py> [frames_dir]")
        sys.exit(1)
    mention    = json.loads(sys.argv[1])
    width      = int(sys.argv[2])
    height     = int(sys.argv[3])
    out_script = sys.argv[4]
    frames_dir = sys.argv[5] if len(sys.argv) > 5 else None
    script = generate_script(mention, width, height, os.path.dirname(out_script), frames_dir)
    with open(out_script, 'w') as f:
        f.write(script)
    print(f"[gen-data-anim] Generated: {out_script}")
    print(f"[gen-data-anim] Type: {mention.get('type')}  Duration: {mention.get('overlay_duration',3)}s")
