"""
scene-inspect.py — Blender script: dumps scene state to JSON after building.
Run this as the LAST part of any Blender script to get a full scene report.

Usage: append to end of any .py script:
  exec(open('/path/to/scene-inspect.py').read())

Or run standalone after a scene is built:
  blender --background <scene.blend> --python scene-inspect.py
"""
import bpy, json, os, math

def inspect_scene(out_path=None):
    scene = bpy.context.scene
    data = {
        'frame': scene.frame_current,
        'engine': scene.render.engine,
        'resolution': [scene.render.resolution_x, scene.render.resolution_y],
        'objects': [],
        'lights': [],
        'cameras': [],
        'materials': [],
    }

    for obj in scene.objects:
        loc  = [round(v, 4) for v in obj.location]
        rot  = [round(math.degrees(v), 2) for v in obj.rotation_euler]
        scl  = [round(v, 4) for v in obj.scale]
        bb   = None
        if obj.type == 'MESH' and obj.data:
            # World-space bounding box
            bb_corners = [obj.matrix_world @ bpy.types.Object.bound_box.fget(obj)[i]
                          for i in range(8)] if hasattr(obj, 'bound_box') else []
            if bb_corners:
                xs = [c[0] for c in bb_corners if hasattr(c, '__getitem__')]
                ys = [c[1] for c in bb_corners if hasattr(c, '__getitem__')]
                zs = [c[2] for c in bb_corners if hasattr(c, '__getitem__')]
                if xs:
                    bb = {
                        'x': [round(min(xs),4), round(max(xs),4)],
                        'y': [round(min(ys),4), round(max(ys),4)],
                        'z': [round(min(zs),4), round(max(zs),4)],
                        'size': [round(max(xs)-min(xs),4), round(max(ys)-min(ys),4), round(max(zs)-min(zs),4)],
                    }

        entry = {
            'name': obj.name, 'type': obj.type,
            'location': loc, 'rotation_deg': rot, 'scale': scl,
            'parent': obj.parent.name if obj.parent else None,
            'visible': not obj.hide_render,
        }
        if hasattr(obj.data, 'materials'):
            entry['materials'] = [m.name if m else 'None' for m in obj.data.materials]
        if bb: entry['bounding_box'] = bb
        if obj.type == 'MESH' and obj.data:
            entry['verts'] = len(obj.data.vertices)
            entry['faces'] = len(obj.data.polygons)
            entry['modifiers'] = [m.type for m in obj.modifiers]

        if obj.type == 'LIGHT':
            entry['energy'] = round(obj.data.energy, 1)
            entry['color']  = [round(c, 3) for c in obj.data.color]
            entry['light_type'] = obj.data.type
            data['lights'].append(entry)
        elif obj.type == 'CAMERA':
            entry['lens'] = round(obj.data.lens, 1)
            entry['cam_type'] = obj.data.type
            entry['is_active'] = (scene.camera == obj)
            data['cameras'].append(entry)
        else:
            data['objects'].append(entry)

    for mat in bpy.data.materials:
        data['materials'].append({
            'name': mat.name,
            'use_nodes': mat.use_nodes,
        })

    out = out_path or os.environ.get('_BL_SCENE_DUMP', '/tmp/blender_scene_inspect.json')
    with open(out, 'w') as f:
        json.dump(data, f, indent=2)

    print(f"\n[scene-inspect] {'='*50}")
    print(f"[scene-inspect] Objects:  {len(data['objects'])}")
    print(f"[scene-inspect] Lights:   {len(data['lights'])}")
    print(f"[scene-inspect] Cameras:  {len(data['cameras'])}")
    print(f"[scene-inspect] Materials:{len(data['materials'])}")
    print(f"[scene-inspect] Output:   {out}")
    print(f"[scene-inspect] {'='*50}")

    # Print object summary
    for o in data['objects']:
        mods = f" [{','.join(o.get('modifiers',[]))}]" if o.get('modifiers') else ''
        mat  = f" mat:{o['materials'][0]}" if o.get('materials') else ''
        print(f"  {o['type']:6} {o['name']:25} loc={o['location']}  scl={o['scale']}{mods}{mat}")

    return data

inspect_scene()
