import bpy, pathlib, math
from mathutils import Vector
root=pathlib.Path(__file__).resolve().parents[2]/'build/character'
bpy.ops.wm.open_mainfile(filepath=str(root/'RoomwavePilot_Source.blend'))
scene=bpy.context.scene;scene.frame_set(20)
world=bpy.data.worlds.new('LayerProofNight');world.use_nodes=True
world.node_tree.nodes['Background'].inputs[0].default_value=(.03,.04,.075,1)
world.node_tree.nodes['Background'].inputs[1].default_value=.6;scene.world=world
def area(name,loc,power,color):
    d=bpy.data.lights.new(name,'AREA');d.energy=power;d.size=4;d.color=color
    o=bpy.data.objects.new(name,d);scene.collection.objects.link(o);o.location=loc
    o.rotation_euler=(Vector((0,0,1))-o.location).to_track_quat('-Z','Y').to_euler()
area('Key',(2,-4,4),600,(.75,.9,1));area('Rim',(-3,1,3),700,(.6,.3,1))
d=bpy.data.cameras.new('LayerProofCamera');o=bpy.data.objects.new('LayerProofCamera',d);scene.collection.objects.link(o)
o.location=(1.5,-5,1.8);o.rotation_euler=(Vector((0,0,.93))-o.location).to_track_quat('-Z','Y').to_euler()
d.type='ORTHO';d.ortho_scale=2.3;scene.camera=o
scene.render.engine='CYCLES';scene.cycles.device='CPU';scene.cycles.samples=32;scene.cycles.use_denoising=False
scene.render.resolution_x=512;scene.render.resolution_y=512;scene.render.resolution_percentage=100
scene.render.image_settings.file_format='PNG';scene.render.image_settings.color_mode='RGB';scene.render.film_transparent=False
for layer in ['Skin','Coat','SkeletonOverlay','MuscleOverlay']:
    for obj in scene.objects:
        if obj.type=='MESH':obj.hide_render=obj.get('layer')!=layer
    scene.render.filepath=str(root/('Layer_'+layer+'.png'));bpy.ops.render.render(write_still=True)
    print('LAYER_PROOF',layer,flush=True)
