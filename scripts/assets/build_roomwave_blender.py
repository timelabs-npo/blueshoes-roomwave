"""Adapt the CC0 Quaternius free base into the Roomwave pilot character.

Visible skeleton and muscle layers below are stylized animation helpers authored
for this project, not medical anatomy or a physiological simulation.
"""
import bpy, math, json, pathlib
from mathutils import Vector, Matrix

ROOT=pathlib.Path(__file__).resolve().parents[2]
OUT=ROOT/'build/character'; OUT.mkdir(parents=True,exist_ok=True)
source=ROOT/'Assets/ThirdParty/QuaterniusUniversalBaseCharacters'
gltf=json.loads((source/'Superhero_Male_FullBody.gltf').read_text())
for key in ['images','textures','samplers']:gltf.pop(key,None)
for material_ in gltf.get('materials',[]):
    for key in ['normalTexture','occlusionTexture','emissiveTexture']:material_.pop(key,None)
    pbr=material_.get('pbrMetallicRoughness',{})
    for key in ['baseColorTexture','metallicRoughnessTexture']:pbr.pop(key,None)
gltf['buffers'][0]['uri']=str((source/'Superhero_Male_FullBody.bin').resolve())
(OUT/'geometry_input.gltf').write_text(json.dumps(gltf))
bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
bpy.ops.import_scene.gltf(filepath=str(OUT/'geometry_input.gltf'))
arm=bpy.data.objects['Armature']; body=bpy.data.objects['SuperHero_Male']
for obj in list(bpy.context.scene.objects):
    if obj.type not in {'MESH','ARMATURE'} or obj.name=='Icosphere':
        bpy.data.objects.remove(obj,do_unlink=True)

COLORS={
    'Skin':(0.085,0.24,0.33,1), 'Eye':(0.12,0.9,1,1),
    'Coat':(0.015,0.024,0.085,1),'Cyan':(0.03,0.74,1,1),
    'Bone':(0.88,0.91,0.75,1),'Muscle':(0.8,0.13,0.3,1),
    'Purple':(0.5,0.03,0.9,1)
}
mats={}
for name,rgba in COLORS.items():
    m=bpy.data.materials.new('RW_'+name);m.diffuse_color=rgba;m.use_nodes=True
    p=m.node_tree.nodes.get('Principled BSDF');p.inputs['Base Color'].default_value=rgba
    p.inputs['Roughness'].default_value=.34;p.inputs['Metallic'].default_value=.25
    if name in {'Cyan','Eye'}:
        p.inputs['Emission Color'].default_value=rgba;p.inputs['Emission Strength'].default_value=.7
    mats[name]=m

def material(obj,key):
    obj.data.materials.clear();obj.data.materials.append(mats[key]);obj['material_key']=key

def skinning(obj, bone=None):
    obj.parent=arm
    mod=obj.modifiers.new('SharedSkeleton','ARMATURE');mod.object=arm
    if bone:
        g=obj.vertex_groups.new(name=bone);g.add(range(len(obj.data.vertices)),1,'REPLACE')

for name in ['SuperHero_Male','Eyebrows','Eyes']:
    obj=bpy.data.objects[name];obj['layer']='Skin'
    material(obj,'Eye' if name=='Eyes' else ('Coat' if name=='Eyebrows' else 'Skin'))

def shell(name,predicate,key,offset):
    old=body.data; faces=[list(f.vertices) for f in old.polygons if predicate(sum((old.vertices[i].co for i in f.vertices),Vector())/len(f.vertices))]
    used=sorted({i for f in faces for i in f});remap={v:i for i,v in enumerate(used)}
    mesh=bpy.data.meshes.new(name)
    mesh.from_pydata([old.vertices[i].co+old.vertices[i].normal*offset for i in used],[],[[remap[i] for i in f] for f in faces]);mesh.update()
    obj=bpy.data.objects.new(name,mesh);bpy.context.collection.objects.link(obj)
    obj['layer']='Coat';material(obj,key);skinning(obj)
    for vg in body.vertex_groups:obj.vertex_groups.new(name=vg.name)
    for new,idx in enumerate(used):
        for group in old.vertices[idx].groups:obj.vertex_groups[group.group].add([new],group.weight,'REPLACE')
    return obj

shell('Coat_Jacket',lambda p:.91<p.z<1.49 and abs(p.x)<.29,'Coat',.011)
shell('Coat_BlueBoots',lambda p:p.z<.19,'Cyan',.009)
shell('Coat_Gauntlets',lambda p:abs(p.x)>.51 and p.z<1.5,'Coat',.008)

bpy.context.view_layer.objects.active=arm;arm.select_set(True)
bpy.ops.object.mode_set(mode='EDIT')
tail=arm.data.edit_bones.new('roomwave_coat_tail');tail.head=(0,.13,1.38);tail.tail=(0,.36,.86)
tail.parent=arm.data.edit_bones['spine_03'];tail.use_deform=True
bpy.ops.object.mode_set(mode='OBJECT')

verts=[];faces=[]
for row in range(6):
    t=row/5
    for col in range(5):
        u=col/4-.5
        verts.append((u*(.42+.15*t),.14+.19*t,1.4-.56*t))
for row in range(5):
    for col in range(4):
        a=row*5+col;faces.append((a,a+1,a+6,a+5))
mesh=bpy.data.meshes.new('CoatTailMesh');mesh.from_pydata(verts,[],faces);mesh.update()
cape=bpy.data.objects.new('Coat_Tail',mesh);bpy.context.collection.objects.link(cape);cape['layer']='Coat';material(cape,'Purple');skinning(cape)
vg0=cape.vertex_groups.new(name='spine_03');vg1=cape.vertex_groups.new(name='roomwave_coat_tail')
for i in range(len(verts)):
    t=(i//5)/5;vg0.add([i],1-t,'REPLACE');vg1.add([i],t,'REPLACE')

major=['pelvis','spine_01','spine_02','spine_03','neck_01','Head',
       'upperarm_l','lowerarm_l','upperarm_r','lowerarm_r',
       'thigh_l','calf_l','thigh_r','calf_r']
for name in major:
    b=arm.data.bones[name];head=b.head_local;tail=b.tail_local;delta=tail-head
    for layer,key,radius in [('SkeletonOverlay','Bone',.013),('MuscleOverlay','Muscle',.046 if ('thigh' in name or 'spine' in name) else .031)]:
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=2 if layer=='MuscleOverlay' else 1,radius=1,location=(head+tail)/2)
        obj=bpy.context.object;obj.name=layer+'_'+name
        obj.rotation_mode='QUATERNION';obj.rotation_quaternion=Vector((0,0,1)).rotation_difference(delta.normalized())
        obj.scale=(radius,radius,max(delta.length*.44,.012));bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
        obj['layer']=layer;material(obj,key);skinning(obj,name)

# Small project-authored chest emblem, weighted to the upper spine.
bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1,radius=1,location=(0,-.153,1.35))
emblem=bpy.context.object;emblem.name='Coat_CyanDiamond';emblem.scale=(.038,.012,.06)
bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
emblem['layer']='Coat';material(emblem,'Cyan');skinning(emblem,'spine_03')

scene=bpy.context.scene;scene.render.fps=30;scene.frame_start=1;scene.frame_end=61
for frame in range(1,62):
    phase=2*math.pi*(frame-1)/60
    for p in arm.pose.bones:p.matrix_basis=Matrix.Identity(4)
    for side,sign in [('l',1),('r',-1)]:
        p=arm.pose.bones['upperarm_'+side];h=p.bone.head_local
        angle=sign*(.42+.07*math.sin(phase))
        p.matrix=Matrix.Translation(h)@Matrix.Rotation(angle,4,'Y')@Matrix.Translation(-h)@p.bone.matrix_local
    root=arm.pose.bones['root'];root.location.z=.026*(1-math.cos(phase))
    ct=arm.pose.bones['roomwave_coat_tail'];ct.rotation_mode='XYZ';ct.rotation_euler.x=.15*math.sin(phase+.7)
    for p in arm.pose.bones:
        p.rotation_mode='QUATERNION'
        p.keyframe_insert(data_path='location',frame=frame)
        p.keyframe_insert(data_path='rotation_quaternion',frame=frame)
        p.keyframe_insert(data_path='scale',frame=frame)
if arm.animation_data and arm.animation_data.action:arm.animation_data.action.name='RoomwaveGlide'

scene.frame_set(1)
height=max(v.co.z for v in body.data.vertices)-min(v.co.z for v in body.data.vertices)
bottom=min(v.co.z for v in body.data.vertices);scale=1/height
# Blender Z-up/-Y-forward -> USD Y-up/-Z-forward, height one metre.
M=Matrix(((-scale,0,0,0),(0,0,scale,-bottom*scale),(0,scale,0,0),(0,0,0,1)))
def matrix_list(mat):return [list(row) for row in mat]
bones=list(arm.data.bones);bone_index={b.name:i for i,b in enumerate(bones)}
data={'coordinate_system':{'up':'Y','forward':'-Z','height_metres':1},'materials':COLORS,'bones':[], 'meshes':[],'animation':[]}
for b in bones:
    data['bones'].append({'name':b.name,'parent':b.parent.name if b.parent else None,'bind':matrix_list(M@arm.matrix_world@b.matrix_local)})
for obj in scene.objects:
    if obj.type!='MESH' or 'layer' not in obj:continue
    mesh=obj.data;mesh.calc_loop_triangles()
    positions=[list(M@obj.matrix_world@v.co) for v in mesh.vertices]
    weights=[]
    for vertex in mesh.vertices:
        pairs=[(bone_index[obj.vertex_groups[g.group].name],g.weight) for g in vertex.groups if obj.vertex_groups[g.group].name in bone_index and g.weight>0]
        pairs=sorted(pairs,key=lambda x:x[1],reverse=True)[:4]
        if not pairs:pairs=[(bone_index['root'],1.)]
        total=sum(w for _,w in pairs);pairs=[(i,w/total) for i,w in pairs]
        pairs += [(0,0.)]*(4-len(pairs));weights.append(pairs)
    data['meshes'].append({'name':obj.name,'layer':obj['layer'],'material':obj['material_key'],'points':positions,'triangles':[list(t.vertices) for t in mesh.loop_triangles],'weights':weights})
for frame in range(1,62):
    scene.frame_set(frame);bpy.context.view_layer.update()
    world={b.name:M@arm.matrix_world@arm.pose.bones[b.name].matrix for b in bones}
    locals_=[world[b.parent.name].inverted()@world[b.name] if b.parent else world[b.name] for b in bones]
    data['animation'].append({'frame':frame-1,'local_transforms':[matrix_list(m) for m in locals_]})
(OUT/'character_data.json').write_text(json.dumps(data,separators=(',',':')))
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'RoomwavePilot_Source.blend'))
print('EXPORTED_MESH_DATA',len(data['meshes']),len(bones),'joints',sum(len(m['triangles']) for m in data['meshes']),'triangles',flush=True)

# Proof image and icon: render the actual derived character, no user photos.
for obj in scene.objects:
    if obj.get('layer') in {'SkeletonOverlay','MuscleOverlay'}:obj.hide_render=True
scene.frame_set(20)
bpy.ops.mesh.primitive_cube_add(size=1,location=(0,0,-.065));board=bpy.context.object
board.name='IconSurfboard';board.scale=(.65,1.35,.08);bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
bevel=board.modifiers.new('RoundedBoard','BEVEL');bevel.width=.1;bevel.segments=4;material(board,'Cyan')
for radius,z,key in [(1.25,-.15,'Purple'),(1.65,-.23,'Cyan')]:
    bpy.ops.mesh.primitive_torus_add(major_radius=radius,minor_radius=.024,major_segments=80,minor_segments=8,location=(0,0,z))
    obj=bpy.context.object;obj.scale.y=.62;material(obj,key)
bpy.ops.mesh.primitive_plane_add(size=200,location=(0,0,-.3));material(bpy.context.object,'Coat')
world=bpy.data.worlds.new('RoomwaveNight');world.use_nodes=True;world.node_tree.nodes['Background'].inputs[0].default_value=(.015,.025,.065,1);world.node_tree.nodes['Background'].inputs[1].default_value=.5;scene.world=world
def light(name,loc,color,power,size):
    data=bpy.data.lights.new(name,'AREA');data.energy=power;data.color=color;data.shape='DISK';data.size=size
    ob=bpy.data.objects.new(name,data);scene.collection.objects.link(ob);ob.location=loc;ob.rotation_euler=(Vector((0,0,1))-ob.location).to_track_quat('-Z','Y').to_euler()
light('Key',(2,-4,5),(.4,.85,1),900,4)
light('Rim',(-2,2,3),(.6,.15,1),1100,3)
light('Fill',(-3,-2,2),(.3,1,.85),500,3)
camdata=bpy.data.cameras.new('ProofCamera');cam=bpy.data.objects.new('ProofCamera',camdata);scene.collection.objects.link(cam)
cam.location=(2.5,-4.5,2.55);cam.rotation_euler=(Vector((0,0,.82))-cam.location).to_track_quat('-Z','Y').to_euler();camdata.type='ORTHO';camdata.ortho_scale=3.6;scene.camera=cam
scene.render.engine='CYCLES';scene.cycles.device='CPU';scene.cycles.samples=64;scene.cycles.use_denoising=False
scene.render.resolution_x=1024;scene.render.resolution_y=1024;scene.render.resolution_percentage=100
scene.render.image_settings.file_format='PNG';scene.render.image_settings.color_mode='RGB';scene.render.film_transparent=False
scene.render.filepath=str(OUT/'AppIcon-1024.png');bpy.ops.render.render(write_still=True)
print('APP_ICON_RENDERED',flush=True)
