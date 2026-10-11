"""Reproducible original Discman-inspired model. Run with Blender --background --python."""
import bpy, math, json
from pathlib import Path
from mathutils import Vector
ROOT = Path(__file__).resolve().parents[1]
bpy.ops.object.select_all(action='SELECT'); bpy.ops.object.delete(use_global=False)

def material(name, color, metal=0, rough=.4):
 m=bpy.data.materials.new(name); m.diffuse_color=(*color,1); m.use_nodes=True
 p=m.node_tree.nodes.get('Principled BSDF'); p.inputs['Base Color'].default_value=(*color,1)
 p.inputs['Metallic'].default_value=metal; p.inputs['Roughness'].default_value=rough
 return m
silver=material('Satin aluminum',(.61,.65,.68),.8,.28)
edge=material('Polished chamfer',(.78,.82,.84),.9,.19)
black=material('Graphite polymer',(.022,.027,.03),.05,.37)
rubber=material('Rubber',(.01,.013,.012),0,.8)
ink=material('Printed graphite',(.065,.08,.09),0,.5)
white=material('Button legends',(.78,.83,.8),.1,.45)
orange=material('Persimmon play',(.95,.22,.045),.25,.27)
lcd=material('LCD',(.45,.54,.32),.05,.5)
cd=material('Optical disc',(.35,.57,.57),.85,.18)

def finish(o,name,mat,lid=False,action=None,bevel=0):
 o.name=name; o.data.materials.append(mat); o['lid']=lid
 if action:o['action']=action
 if bevel:
  m=o.modifiers.new('Machined edge','BEVEL'); m.width=bevel; m.segments=3
  o.modifiers.new('Weighted normals','WEIGHTED_NORMAL')
 if o.type=='MESH':
  for p in o.data.polygons:p.use_smooth=True
 return o

def cyl(name,r,d,loc,mat,lid=False,action=None,fill='NGON'):
 bpy.ops.mesh.primitive_cylinder_add(vertices=128,radius=r,depth=d,location=loc,end_fill_type=fill)
 return finish(bpy.context.object,name,mat,lid,action,.025)

def box(name,loc,scale,mat,lid=False,action=None,bevel=.04):
 bpy.ops.mesh.primitive_cube_add(size=1,location=loc); o=bpy.context.object; o.scale=scale
 bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
 return finish(o,name,mat,lid,action,bevel)

def text(name,words,loc,size,mat,lid=False):
 curve=bpy.data.curves.new(name,'FONT'); curve.body=words; curve.size=size; curve.align_x='CENTER'; curve.extrude=.0005
 o=bpy.data.objects.new(name,curve); bpy.context.collection.objects.link(o); o.location=loc
 return finish(o,name,mat,lid)

cyl('Lower shell',2.24,.34,(0,0,.15),black)
cyl('Silver chassis',2.27,.16,(0,0,.33),silver)
# Open-ended: a capped seam covered the disc whenever the lid opened.
cyl('Lid shadow seam',2.235,.06,(0,0,.44),rubber,fill='NOTHING')
cyl('Lid edge',2.23,.10,(0,0,.52),edge,True,'open')
cyl('Lid',2.20,.13,(0,0,.605),silver,True,'open')
cyl('Inset optical well',1.97,.025,(0,0,.43),black)
cyl('Disc',1.79,.015,(0,0,.449),cd)
for r in [1.74,1.69,.60,.40]:
 bpy.ops.mesh.primitive_torus_add(major_radius=r,minor_radius=.006,major_segments=128,minor_segments=6,location=(0,0,.461))
 finish(bpy.context.object,'Disc groove',edge)
cyl('Spindle',.24,.08,(0,0,.485),black)
cyl('Spindle cap',.14,.02,(0,0,.536),edge)
text('Disc label','SIDE A  /  CONTINUOUS PLAY',(0,.75,.47),.10,ink)
box('LCD surround',(0,-.66,.701),(1.88,.83,.065),black,True,bevel=.10)
box('LCD',(0,-.66,.739),(1.69,.63,.012),lcd,True,bevel=.035)
text('Brand','SIDE A',(0,.89,.68),.32,ink,True)
text('Subtitle','PERSONAL ACCOUNT PLAYER',(0,.62,.679),.076,ink,True)
text('Model','SA–01   /   DIGITAL CONTINUITY',(0,.36,.68),.059,ink,True)
text('Track label','ACCOUNT   /   TRACK',(0,-.14,.68),.069,ink,True)
for x,action,label,w,mat in [(-1.03,'previous','I<<',.46,black),(-.44,'stop','■',.40,black),(.16,'play','▶',.61,orange),(.92,'next','>>I',.46,black)]:
 box('button_'+action,(x,-1.48,.74),(w,.36,.13),mat,True,action,.085)
 text('legend_'+action,label,(x,-1.535,.814),.11,white,True)
text('Transport legend','SKIP          STOP       PLAY / PAUSE        SKIP',(0,-1.82,.68),.062,ink,True)
box('button_open',(0,-2.19,.31),(.67,.18,.16),silver,False,'open')
text('Open legend','OPEN',(0,-2.085,.41),.07,ink)
box('button_hold',(-1.95,-.24,.73),(.16,.49,.11),black,True,'hold')
text('Hold label','HOLD',(-1.74,-.22,.683),.058,ink,True)
box('button_mode',(1.91,-.2,.73),(.20,.45,.12),black,True,'mode')
text('Mode label','AUTO',(1.67,-.18,.683),.060,ink,True)
for x in [-.78,.78]:
 o=cyl('Hinge barrel',.10,.54,(x,2.05,.45),black); o.rotation_euler[1]=math.pi/2
for x,y in [(-1.35,-1.1),(1.35,-1.1),(-1.2,1.2),(1.2,1.2)]:
 cyl('Rubber foot',.16,.05,(x,y,-.041),rubber)
for i in range(9):
 box('Side vent',(-2.20,-.34+i*.1,.18),(.028,.047,.10),rubber,bevel=.012)
# The delivery JSON stores evaluated Blender geometry. Native SceneKit renders it
# without a webview or runtime primitive reconstruction. Blender remains source of truth.
objects=[]; deps=bpy.context.evaluated_depsgraph_get()
for obj in list(bpy.context.scene.objects):
 if obj.type not in {'MESH','FONT'}:continue
 evaluated=obj.evaluated_get(deps); mesh=evaluated.to_mesh(); mesh.calc_loop_triangles()
 verts=[]; normals=[]; inds=[]
 normal_matrix=obj.matrix_world.to_3x3().inverted().transposed()
 for tri in mesh.loop_triangles:
  for vi in tri.vertices:
   v=obj.matrix_world @ mesh.vertices[vi].co; n=(normal_matrix @ mesh.vertices[vi].normal).normalized()
   verts.extend([round(v.x,5),round(v.z,5),round(-v.y,5)])
   normals.extend([round(n.x,5),round(n.z,5),round(-n.y,5)]); inds.append(len(inds))
 mat=obj.data.materials[0]; p=mat.node_tree.nodes.get('Principled BSDF')
 objects.append(dict(name=obj.name,vertices=verts,normals=normals,indices=inds,color=list(mat.diffuse_color),metallic=p.inputs['Metallic'].default_value,roughness=p.inputs['Roughness'].default_value,lid=bool(obj.get('lid',False)),action=obj.get('action')))
 evaluated.to_mesh_clear()
path=ROOT/'Sources/SideA/Resources/discman.json'; path.write_text(json.dumps(objects,separators=(',',':')))
# Studio render and reusable Blender source.
world=bpy.context.scene.world; world.color=(.3,.3,.3)
for name,loc,power,size in [('Key',(-3,-4,7),650,5),('Rim',(4,2,6),800,4),('Fill',(-4,4,3),450,3)]:
 bpy.ops.object.light_add(type='AREA',location=loc); o=bpy.context.object; o.name=name; o.data.energy=power; o.data.shape='DISK'; o.data.size=size; o.rotation_euler=(Vector((0,0,.3))-o.location).to_track_quat('-Z','Y').to_euler()
bpy.ops.object.camera_add(location=(.4,-4.8,8.8)); cam=bpy.context.object; cam.rotation_euler=(Vector((0,0,.3))-cam.location).to_track_quat('-Z','Y').to_euler(); cam.data.type='ORTHO'; cam.data.ortho_scale=5.8
scene=bpy.context.scene; scene.camera=cam; scene.render.engine='CYCLES'; scene.cycles.samples=32
scene.render.resolution_x=1100; scene.render.resolution_y=1000; scene.render.resolution_percentage=100; scene.render.film_transparent=True
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'design/SideA.blend'))
scene.render.filepath=str(ROOT/'design/discman.png'); bpy.ops.render.render(write_still=True)
print('Exported',len(objects),'objects to',path)
