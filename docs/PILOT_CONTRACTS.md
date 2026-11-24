# Pilot 2 frozen interfaces and ownership
Coordinator-approved extension for the user's 24 Nov 2026 photo-map/layered-character TestFlight request.
ScanSource adds photoDerived. RaceRules.standard.version = roomwave-pilot-2.
All existing public types/signatures remain stable. The version includes simulation semantics. Existing roomwave-rules-1 interpretation must remain legacy-neutral if supported; reject unsupportedversions explicitly instead of silently misinterpreting.

## Gameplay lane
Own RaceSimulation.swift, TrackGenerator.swift, TrackValidator.swift, existing race/scan tests and newPilotGameplayTests.swift.
Introduce bounded, documented curvature pressure requiring corrective steering; same input/track gives same result. A concrete generated bend must crash withzero input and finish/survive with correcting input; implement meaningful regression tests. Input remains tick, steering[-1,1],bank and tickratefixed.
Keep bankatgates, closedseam, interpolatedwidth and determinism/replay consistent. Optimizeadmission ifnecessary withoutnewpublictypes.
TrackGenerator must use actual normalizedpoint layout/height distribution beyondAABBaspect. Use a small validated closedroute, preserveuniformhalfWidth to matchnativepreview. Quantize geometry on0.001grid. A planarroute isacceptable firstpilot ifshape evidence affects actual turns/widthorcurvature; optionalgentleheightrequiresvalidator/renderercorrespondence. No impossibleunvalidatedroutefallback advertisedasreal.
Do not edit Normalization, Contracts, PhotoMapAnalyzer, nativeapp.
Update sourcecomments/readiness forwhatworks andlimits.

## Photo lane
Add public enum PhotoMapAnalyzer:
public static func makeSample(luminance: [UInt8], width: Int, height: Int, saliency: [Float]? = nil) throws -> ScanSample
Inputs8...128pixelsperdimension, exactarraylength, finite saliency0...1 ifsupplied. PureFoundation implementation, noUIKit.
Create 2.5D styledsample sourced photoDerived from actualpixels, withboundedpoints<=4096. Contrast/edges/saliency must influencepointlayoutorheight materially. Rejectinvalid/featurelessinputs clearly. Neverclaimmetricdepth/photogrammetry. Preservephotocontentlocalonly.
Add @MainActor enum PhotoMapImporter:
static func sample(from data: Data) async throws -> ScanSample
Decodeorientanddownsample safely usingUIKit/CoreGraphics/ImageIO; use ondeviceVision saliency iffeasible, withdocumentedfeatureextractionfallback (notrandomfilenamehash). No network, savingphotos or EXIFexport. Boundedimagebyte/pixellimits; informativeerrors. NativecoordinatorwillusePhotosPicker andcallthisfunction; donoteditContentView/Model.
Tests verifyinvalidsizes,constantimagebehavior,twoimagesgeneratedifference,sameinputdeterminism,source.

## Avatar lane
Add @MainActor final class LayeredAvatarController {
 let root: Entity
 init()
 func loadBundledAsset() async
 func update(speed: Double, steering: Double, time: Double)
 func setLayerVisibility(skeleton: Bool, muscle: Bool, skin: Bool, coat: Bool)
}
Use RealityKit. Root entity is placed byTrackScene; allavatarpose/lean/squashwithinroot'schild, neveroverwriteexternalrootposition.
Asset arrives as bundled Assets/RoomwavePilot.usdz with named descendant layers Skin,Coat,SkeletonOverlay,MuscleOverlay; sourceCC0humanoid plusderived stylized overlays fromassetlane. Y up, forward -Z proposed; verifyassetnoteshandoff. SkeletonRig is articulationrig; skeleton/muscle visualoverlays arestylizedanimationhelpers, notmedicalanatomy.
Assetmissing mustshowclearlyfallback simpleavatar withoutclaimingthirdparty layersloaded. No network. UseavailableAnimations ifsafe, plusprocedurallean/hover/accent animation withspeed/steering.
Public load function handlesfailure, no throwingcrash. Expose @Published? noUIdependencyrequired; coordinator canread status string ifyouchoose publicprivate(set) varassetStatus:String (native only).
Do not create/download/licenseassets yourself or editTrackScene/ContentView/Project.
