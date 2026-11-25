"""Reproducible USD Skel export of the derived CC0 Roomwave character."""
import sys,pathlib,json,re,hashlib,math
ROOT=pathlib.Path(__file__).resolve().parents[2]

from pxr import Usd,UsdGeom,UsdSkel,UsdShade,UsdUtils,Gf,Vt,Sdf,Tf

OUT=ROOT/'build/character'; data=json.loads((OUT/'character_data.json').read_text())
# Validate the authored source before serializing a rig. These are real mesh
# weights/coordinates, not a filename or animation-name assertion.
assert len(data['bones'])==66
assert {obj['layer'] for obj in data['meshes']}=={'Skin','Coat','SkeletonOverlay','MuscleOverlay'}
for obj in data['meshes']:
    assert len(obj['weights'])==len(obj['points'])
    assert all(math.isfinite(value) for point in obj['points'] for value in point)
    for influences in obj['weights']:
        assert len(influences)==4
        assert all(isinstance(index,int) and 0<=index<len(data['bones']) and
                   math.isfinite(weight) and weight>=0 for index,weight in influences)
        assert abs(sum(weight for _,weight in influences)-1)<1e-6
path=OUT/'RoomwavePilot.usdc';stage=Usd.Stage.CreateNew(str(path))
UsdGeom.SetStageUpAxis(stage,UsdGeom.Tokens.y);UsdGeom.SetStageMetersPerUnit(stage,1.)
stage.SetStartTimeCode(0);stage.SetEndTimeCode(60);stage.SetTimeCodesPerSecond(30);stage.SetFramesPerSecond(30)
root=UsdGeom.Xform.Define(stage,'/RoomwavePilot');stage.SetDefaultPrim(root.GetPrim())
root.GetPrim().SetMetadata('documentation','CC0 Quaternius base; Roomwave-derived clothing and stylized overlay helpers. Not anatomical or physiological simulation.')
root.GetPrim().CreateAttribute('roomwave:forward',Sdf.ValueTypeNames.Token).Set('-Z')
groups=['Skin','Coat','SkeletonOverlay','MuscleOverlay']
Usd.ModelAPI(root).SetKind('assembly')
for group in groups:
    layer_root=UsdSkel.Root.Define(stage,'/RoomwavePilot/'+group)
    Usd.ModelAPI(layer_root).SetKind('component')

material_paths={}
for name,rgba in data['materials'].items():
    mat=UsdShade.Material.Define(stage,'/RoomwavePilot/Materials/'+name)
    shader=UsdShade.Shader.Define(stage,mat.GetPath().AppendChild('PreviewSurface'))
    shader.CreateIdAttr('UsdPreviewSurface')
    shader.CreateInput('diffuseColor',Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(*rgba[:3]))
    surface=data['surfaces'][name]
    shader.CreateInput('roughness',Sdf.ValueTypeNames.Float).Set(surface['roughness'])
    shader.CreateInput('metallic',Sdf.ValueTypeNames.Float).Set(surface['metallic'])
    if name in ['Cyan','Eye']:
        shader.CreateInput('emissiveColor',Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(*[x*.7 for x in rgba[:3]]))
    mat.CreateSurfaceOutput().ConnectToSource(shader.ConnectableAPI(),'surface')
    material_paths[name]=mat

def matrix(m):return Gf.Matrix4d(*[float(m[c][r]) for r in range(4) for c in range(4)])
bonepaths={}
for b in data['bones']:
    name=Tf.MakeValidIdentifier(b['name'])
    bonepaths[b['name']]=(bonepaths[b['parent']]+'/' if b['parent'] else '')+name
joints=Vt.TokenArray([bonepaths[b['name']] for b in data['bones']])
bind=[matrix(b['bind']) for b in data['bones']]
byname={b['name']:m for b,m in zip(data['bones'],bind)}
rest=[m*byname[b['parent']].GetInverse() if b['parent'] else m for b,m in zip(data['bones'],bind)]
# RealityKit gathers meshes sharing one SkelRoot into a skinned render entity.
# Give each independently toggled layer its own SkelRoot and equivalent rig.
# Every mesh still has exactly one skeleton; all four rigs use the same motion.
skeletons={}
for group in groups:
    base='/RoomwavePilot/'+group
    skel=UsdSkel.Skeleton.Define(stage,base+'/skeletonRig')
    skeletons[group]=skel
    skel.CreateJointsAttr(joints)
    skel.CreateBindTransformsAttr(Vt.Matrix4dArray(bind))
    skel.CreateRestTransformsAttr(Vt.Matrix4dArray(rest))
    animation=UsdSkel.Animation.Define(stage,base+'/RoomwaveGlide')
    animation.CreateJointsAttr(joints)
    for sample in data['animation']:
        transforms=[Gf.Transform(matrix(m)) for m in sample['local_transforms']]
        translations=[Gf.Vec3f(*t.GetTranslation()) for t in transforms]
        rotations=[]
        for t in transforms:
            q=t.GetRotation().GetQuat();rotations.append(Gf.Quatf(q.GetReal(),Gf.Vec3f(*q.GetImaginary())))
        scales=[Gf.Vec3h(*t.GetScale()) for t in transforms]
        animation.CreateTranslationsAttr().Set(Vt.Vec3fArray(translations),sample['frame'])
        animation.CreateRotationsAttr().Set(Vt.QuatfArray(rotations),sample['frame'])
        animation.CreateScalesAttr().Set(Vt.Vec3hArray(scales),sample['frame'])
    UsdSkel.BindingAPI.Apply(skel.GetPrim()).CreateAnimationSourceRel().SetTargets([animation.GetPath()])
    layer_binding=UsdSkel.BindingAPI.Apply(stage.GetPrimAtPath(base))
    layer_binding.CreateSkeletonRel().SetTargets([skel.GetPath()])

for obj in data['meshes']:
    mesh=UsdGeom.Mesh.Define(stage,'/RoomwavePilot/'+obj['layer']+'/'+Tf.MakeValidIdentifier(obj['name']))
    mesh.CreatePointsAttr(Vt.Vec3fArray([Gf.Vec3f(*p) for p in obj['points']]))
    mesh.CreateFaceVertexCountsAttr([3]*len(obj['triangles']))
    mesh.CreateFaceVertexIndicesAttr([i for tri in obj['triangles'] for i in tri])
    mesh.CreateSubdivisionSchemeAttr('none');mesh.CreateDoubleSidedAttr(True)
    points=obj['points'];mesh.CreateExtentAttr(Vt.Vec3fArray([Gf.Vec3f(*[min(p[i] for p in points) for i in range(3)]),Gf.Vec3f(*[max(p[i] for p in points) for i in range(3)])]))
    UsdShade.MaterialBindingAPI.Apply(mesh.GetPrim()).Bind(material_paths[obj['material']])
    binding=UsdSkel.BindingAPI.Apply(mesh.GetPrim())
    binding.CreateSkeletonRel().SetTargets([skeletons[obj['layer']].GetPath()]);binding.CreateGeomBindTransformAttr(Gf.Matrix4d(1))
    binding.CreateJointsAttr(joints)
    binding.CreateSkinningMethodAttr('classicLinear')
    binding.CreateJointIndicesPrimvar(False,4).Set([int(i) for pairs in obj['weights'] for i,w in pairs])
    binding.CreateJointWeightsPrimvar(False,4).Set([float(w) for pairs in obj['weights'] for i,w in pairs])

# Evaluate every authored frame, validate the planted soles/loop closure, and
# author conservative animated extents at each SkelRoot for runtime culling.
cache=UsdSkel.Cache()
animation_bounds={}
loop_max_error=0.
for group in groups:
    layer_root=UsdSkel.Root(stage.GetPrimAtPath('/RoomwavePilot/'+group))
    cache.Populate(layer_root,Usd.PrimDefaultPredicate)
    query=cache.GetSkelQuery(skeletons[group])
    bounds=[];first_points={};floors=[];motion_max=0.
    for time in range(61):
        transforms=query.ComputeSkinningTransforms(time)
        all_points=[]
        for prim in Usd.PrimRange(layer_root.GetPrim()):
            if prim.IsA(UsdGeom.Mesh):
                points=UsdGeom.Mesh(prim).GetPointsAttr().Get()
                assert cache.GetSkinningQuery(prim).ComputeSkinnedPoints(transforms,points,time)
                assert all(math.isfinite(float(value)) for point in points for value in point)
                key=str(prim.GetPath())
                if time==0:first_points[key]=list(points)
                if time>0:
                    motion_max=max(motion_max,max((point-start).GetLength()
                        for point,start in zip(points,first_points[key])))
                if time==60:
                    loop_max_error=max(loop_max_error,max((point-start).GetLength()
                        for point,start in zip(points,first_points[key])))
                all_points.extend(points)
        bounds.extend(all_points)
        floors.append(min(point[1] for point in all_points))
    lower=[min(p[i] for p in bounds) for i in range(3)]
    upper=[max(p[i] for p in bounds) for i in range(3)]
    animation_bounds[group]={'min':lower,'max':upper,
        'minimum_y_range':[min(floors),max(floors)],
        'maximum_motion_from_first_sample':motion_max}
    assert motion_max>.001, f'{group} has no observed skinned animation'
    layer_root.CreateExtentAttr(Vt.Vec3fArray([
        Gf.Vec3f(*[value-.03 for value in lower]),
        Gf.Vec3f(*[value+.03 for value in upper])]))
assert loop_max_error<1e-5,loop_max_error
assert max(abs(value) for value in animation_bounds['Skin']['minimum_y_range'])<.008
assert animation_bounds['Coat']['min'][1]>-.02
stage.GetRootLayer().Save()
stage.Export(str(OUT/'RoomwavePilot.usda'))
assert UsdUtils.CreateNewUsdzPackage(Sdf.AssetPath(str(path)),str(OUT/'RoomwavePilot.usdz'))
opened=Usd.Stage.Open(str(OUT/'RoomwavePilot.usdz'));assert opened
cache=UsdSkel.Cache()
for group in groups:
    cache.Populate(UsdSkel.Root(opened.GetPrimAtPath('/RoomwavePilot/'+group)),Usd.PrimDefaultPredicate)
    query=cache.GetSkelQuery(UsdSkel.Skeleton(opened.GetPrimAtPath('/RoomwavePilot/'+group+'/skeletonRig')))
    assert query and len(query.GetJointOrder())==len(data['bones'])
topology=UsdSkel.Topology(joints);valid,reason=topology.Validate();assert valid,reason
skinned=0
for prim in opened.Traverse():
    if prim.IsA(UsdGeom.Mesh):
        skin=cache.GetSkinningQuery(prim)
        assert skin and skin.HasJointInfluences(),str(prim.GetPath())
        skinned+=1
info={'format':'USDZ/UsdSkel','height_metres_rest':1.0,'up':'Y','forward':'-Z',
      'layers':groups,'joints_per_layer':len(data['bones']),'skeletons':len(groups),
      'hierarchy':'Xform root with four independently skinned named SkelRoot layers',
      'skinned_meshes':skinned,'triangles':sum(len(m['triangles']) for m in data['meshes']),
      'animation':{'name':'RoomwaveGlide','duration_seconds':2,'samples':61,'fps':30},
      'animated_validation':{'evaluated_samples_per_layer':61,
          'loop_endpoint_max_error_metres':loop_max_error,
          'finite_coordinates':True,'normalized_weights':True,
          'layer_bounds_metres':animation_bounds},
      'sha256':hashlib.sha256((OUT/'RoomwavePilot.usdz').read_bytes()).hexdigest(),
      'bytes':(OUT/'RoomwavePilot.usdz').stat().st_size,
      'validation':'USD stage reopened; topology and normalized skinning validated; all 61 animated samples finite; soles planted and loop endpoints matched. New asset requires native import/playback revalidation; physical iPhone playback not tested.'}
(OUT/'MODEL_VALIDATION.json').write_text(json.dumps(info,indent=2)+'\n')
print(json.dumps(info,indent=2))
