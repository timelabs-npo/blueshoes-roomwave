"""Reproducible USD Skel export of the derived CC0 Roomwave character."""
import sys,pathlib,json,re,hashlib
ROOT=pathlib.Path(__file__).resolve().parents[2]

from pxr import Usd,UsdGeom,UsdSkel,UsdShade,UsdUtils,Gf,Vt,Sdf,Tf

OUT=ROOT/'build/character'; data=json.loads((OUT/'character_data.json').read_text())
path=OUT/'RoomwavePilot.usdc';stage=Usd.Stage.CreateNew(str(path))
UsdGeom.SetStageUpAxis(stage,UsdGeom.Tokens.y);UsdGeom.SetStageMetersPerUnit(stage,1.)
stage.SetStartTimeCode(0);stage.SetEndTimeCode(60);stage.SetTimeCodesPerSecond(30);stage.SetFramesPerSecond(30)
root=UsdSkel.Root.Define(stage,'/RoomwavePilot');stage.SetDefaultPrim(root.GetPrim())
root.GetPrim().SetMetadata('documentation','CC0 Quaternius base; Roomwave-derived clothing and stylized overlay helpers. Not anatomical or physiological simulation.')
root.GetPrim().CreateAttribute('roomwave:forward',Sdf.ValueTypeNames.Token).Set('-Z')
for group in ['Skin','Coat','SkeletonOverlay','MuscleOverlay']:
    UsdGeom.Xform.Define(stage,'/RoomwavePilot/'+group)

material_paths={}
for name,rgba in data['materials'].items():
    mat=UsdShade.Material.Define(stage,'/RoomwavePilot/Materials/'+name)
    shader=UsdShade.Shader.Define(stage,mat.GetPath().AppendChild('PreviewSurface'))
    shader.CreateIdAttr('UsdPreviewSurface')
    shader.CreateInput('diffuseColor',Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(*rgba[:3]))
    shader.CreateInput('roughness',Sdf.ValueTypeNames.Float).Set(.34)
    shader.CreateInput('metallic',Sdf.ValueTypeNames.Float).Set(.25)
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
skel=UsdSkel.Skeleton.Define(stage,'/RoomwavePilot/skeletonRig')
skel.CreateJointsAttr(joints)
bind=[matrix(b['bind']) for b in data['bones']]
byname={b['name']:m for b,m in zip(data['bones'],bind)}
rest=[m*byname[b['parent']].GetInverse() if b['parent'] else m for b,m in zip(data['bones'],bind)]
skel.CreateBindTransformsAttr(Vt.Matrix4dArray(bind));skel.CreateRestTransformsAttr(Vt.Matrix4dArray(rest))
animation=UsdSkel.Animation.Define(stage,'/RoomwavePilot/RoomwaveGlide')
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

for obj in data['meshes']:
    mesh=UsdGeom.Mesh.Define(stage,'/RoomwavePilot/'+obj['layer']+'/'+Tf.MakeValidIdentifier(obj['name']))
    mesh.CreatePointsAttr(Vt.Vec3fArray([Gf.Vec3f(*p) for p in obj['points']]))
    mesh.CreateFaceVertexCountsAttr([3]*len(obj['triangles']))
    mesh.CreateFaceVertexIndicesAttr([i for tri in obj['triangles'] for i in tri])
    mesh.CreateSubdivisionSchemeAttr('none');mesh.CreateDoubleSidedAttr(True)
    points=obj['points'];mesh.CreateExtentAttr(Vt.Vec3fArray([Gf.Vec3f(*[min(p[i] for p in points) for i in range(3)]),Gf.Vec3f(*[max(p[i] for p in points) for i in range(3)])]))
    UsdShade.MaterialBindingAPI.Apply(mesh.GetPrim()).Bind(material_paths[obj['material']])
    binding=UsdSkel.BindingAPI.Apply(mesh.GetPrim())
    binding.CreateSkeletonRel().SetTargets([skel.GetPath()]);binding.CreateGeomBindTransformAttr(Gf.Matrix4d(1))
    binding.CreateJointsAttr(joints)
    binding.CreateSkinningMethodAttr('classicLinear')
    binding.CreateJointIndicesPrimvar(False,4).Set([int(i) for pairs in obj['weights'] for i,w in pairs])
    binding.CreateJointWeightsPrimvar(False,4).Set([float(w) for pairs in obj['weights'] for i,w in pairs])

stage.GetRootLayer().Save()
stage.Export(str(OUT/'RoomwavePilot.usda'))
assert UsdUtils.CreateNewUsdzPackage(Sdf.AssetPath(str(path)),str(OUT/'RoomwavePilot.usdz'))
opened=Usd.Stage.Open(str(OUT/'RoomwavePilot.usdz'));assert opened
cache=UsdSkel.Cache();cache.Populate(UsdSkel.Root(opened.GetDefaultPrim()),Usd.PrimDefaultPredicate)
query=cache.GetSkelQuery(UsdSkel.Skeleton(opened.GetPrimAtPath('/RoomwavePilot/skeletonRig')))
assert query and len(query.GetJointOrder())==len(data['bones'])
topology=UsdSkel.Topology(joints);valid,reason=topology.Validate();assert valid,reason
skinned=0
for prim in opened.Traverse():
    if prim.IsA(UsdGeom.Mesh):
        skin=cache.GetSkinningQuery(prim)
        assert skin and skin.HasJointInfluences(),str(prim.GetPath())
        skinned+=1
info={'format':'USDZ/UsdSkel','height_metres_rest':1.0,'up':'Y','forward':'-Z',
      'layers':['Skin','Coat','SkeletonOverlay','MuscleOverlay'],'joints':len(data['bones']),
      'skinned_meshes':skinned,'triangles':sum(len(m['triangles']) for m in data['meshes']),
      'animation':{'name':'RoomwaveGlide','duration_seconds':2,'samples':61,'fps':30},
      'sha256':hashlib.sha256((OUT/'RoomwavePilot.usdz').read_bytes()).hexdigest(),
      'bytes':(OUT/'RoomwavePilot.usdz').stat().st_size,
      'validation':'USD stage opened, topology validated, all meshes have skinned joint influences; Apple device playback not yet tested.'}
(OUT/'MODEL_VALIDATION.json').write_text(json.dumps(info,indent=2)+'\n')
print(json.dumps(info,indent=2))
