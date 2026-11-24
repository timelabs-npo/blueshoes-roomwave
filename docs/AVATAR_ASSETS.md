# Roomwave pilot character assets

The shipped `RoomwavePilot.usdz` is a derivative of **Quaternius — Universal Base
Characters, free Standard edition**, licensed **CC0 1.0 Universal**. The original
license text, selected glTF and binary geometry, source URLs and checksums are in
`Assets/ThirdParty/QuaterniusUniversalBaseCharacters`. No paid Source-edition files
or noncommercial-only assets were used.

## Four visible layers and the rig

| Entity name | Content and provenance |
| --- | --- |
| `Skin` | Quaternius base body, eyes and eyebrows, with project-created flat materials. |
| `Coat` | Project-derived jacket, boots and gauntlets, plus a new cape and emblem. |
| `SkeletonOverlay` | Project-created stylized joint/bone helper geometry. |
| `MuscleOverlay` | Project-created stylized muscle-shaped helper geometry. |
| `skeletonRig` | An equivalent rig within each layer: Quaternius humanoid joints plus a project-created cape joint. |

The overlay shapes are **not anatomical skeleton/muscle models**. They do not
simulate muscles, tissue or cloth physics. All four mesh layers use joint skinning;
the cape has a simple authored motion. These boundaries must remain visible in the
pilot's layer inspector and documentation.

The asset is Y-up, faces -Z, and has approximately 1 metre rest height. It contains
66 joints per layer, 36 skinned mesh parts and 22,912 triangles. `RoomwaveGlide` is a project-
authored two-second loop, 61 samples at 30 fps. Use a parent entity for game-driven
lean/hover. Toggle the four named layer containers recursively; skin and clothing
normally occlude the internal helper layers. The runtime may default helpers off.

Each named layer is its own `SkelRoot` under an ordinary top-level `Xform` and has
an equivalent 66-joint skeleton and loop. A mesh is bound to only one skeleton.
This avoids collecting all layers into the same skinned render entity. The first
export used one shared `SkelRoot`; an actual iOS 27.2 simulator run preserved the
four names but found no renderable components within those containers. That
version failed the runtime gate. The revised layout requires the same native
renderable-component and animation checks before release.

## Verification actually performed

- Downloaded the free Standard archive through its public free-download flow.
- Read the included CC0 license and recorded the archive and selected-file hashes.
- Imported the glTF into Blender 4.3.2 and authored the derived layers and action.
- Exported through OpenUSD `usd-core` 26.11 and reopened the resulting USDZ.
- Validated joint topology and skinning queries for every mesh.
- Evaluated skinned vertices at loop samples 0, 15, 30 and 60; bounds were finite,
  approximately one metre high, and loop endpoints agreed.
- Rendered the derived model for the opaque app icon and preview.
- Ran the committed rebuild pipeline from the glTF/bin source snapshot: all
  generated mesh/joint/animation data matched the source preparation output.
- Rendered each layer independently; see `docs/previews` for actual isolated views.

These checks do **not** establish RealityKit import, animation playback, frame rate
or visual quality on an iPhone. Simulator/device asset loading is a separate gate.

## Rebuilding

With Blender 4.3.2 and Python 3.12, install `scripts/assets/requirements.txt` in a
virtual environment, then run:

```sh
blender --background --factory-startup --python scripts/assets/build_roomwave_blender.py
python scripts/assets/export_roomwave_usd.py
```

The scripts write into `build/character`. Copy the validated USDZ into
`apps/ios/Roomwave/Assets/RoomwavePilot.usdz` and update the validation manifest
after any change. The Blender preparation intentionally strips the upstream image
texture references and replaces them with project-authored flat materials. Original
texture files are not needed or bundled. Source glTF and bin bytes remain unchanged.

The project-authored/derived asset geometry and animation are also dedicated under
CC0 1.0. Rebuild scripts remain under the repository's MIT license. Attribution is
retained voluntarily so future maintainers can audit provenance.

Primary sources:

- https://quaternius.com/packs/universalbasecharacters.html
- https://quaternius.itch.io/universal-base-characters
- https://creativecommons.org/publicdomain/zero/1.0/
