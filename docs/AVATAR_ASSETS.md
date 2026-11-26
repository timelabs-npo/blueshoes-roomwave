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
| `Coat` | Project-derived jacket, trousers, knee panels, hood, boots and gauntlets, plus split coat tails, narrow cyan piping and a warm chest emblem. |
| `SkeletonOverlay` | Project-created stylized joint/bone helper geometry. |
| `MuscleOverlay` | Project-created stylized muscle-shaped helper geometry. |
| `skeletonRig` | An equivalent rig within each layer: Quaternius humanoid joints plus a project-created cape joint. |

The overlay shapes are **not anatomical skeleton/muscle models**. They do not
simulate muscles, tissue or cloth physics. All four mesh layers use joint skinning;
the cape has a simple authored motion. These boundaries must remain visible in the
pilot's layer inspector and documentation.

The asset is Y-up, faces -Z, and has approximately 1 metre rest height. It contains
66 joints per layer, 42 skinned mesh parts and 26,892 triangles. `RoomwaveGlide` is a project-
authored two-second loop, 61 samples at 30 fps. Use a parent entity for game-driven
lean/hover. Toggle the four named layer containers recursively; skin and clothing
normally occlude the internal helper layers. The runtime may default helpers off.

The November 25 arcade art revision changes the neutral outstretched pose to a
crouched stance with lowered, bent arms and restrained torso balance. Both legs
hold the same flex throughout the loop; the authored root corrects to the actual
deformed sole height rather than adding a floating bob. Skin minimum Y remains
0.000034 m across all 61 exported samples; the clothing sole extends to -0.004818 m.
The highest animated skin point is 0.9122 m and the highest clothing point 0.9199 m.
The original one-metre rest scale, game root placement and equivalent layer rigs
remain intact. This is authored character motion, not muscle or cloth simulation.

The split coat has a centre opening and shaped folds instead of the previous flat
magenta panel. Navy/teal materials use roughness 0.64 and metallic 0.025, with small
cyan and warm accents. These are material inputs, not a claim about their exact
appearance under every runtime light. The controlled front/rear Blender proofs in
`docs/previews/Avatar-Surf-Stance-Front.png` and `Avatar-Surf-Stance-Rear.png` show the
actual revised mesh and animation pose; they are not game screenshots. Their board
is a proof-scene prop, not the runtime board.

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
- Evaluated every skinned vertex at all 61 authored samples for each of the four
  layers. Coordinates are finite, joint weights are normalized, soles are planted,
  every layer has measurable motion and loop endpoints agree exactly in the export.
  The detailed measured bounds and maximum motion are in `AVATAR_ASSET_VALIDATION.json`.
- Rendered the revised mesh from the front and rear with Blender Cycles, then
  inspected both images. The existing shipped app icon predates this art revision;
  the rebuild also emits a candidate icon for the coordinator to review separately.
- Ran the committed rebuild pipeline from the glTF/bin source snapshot: all
  generated mesh/joint/animation data matched the source preparation output.
- Rendered each layer independently; see `docs/previews` for actual isolated views.

The preceding asset revision passed the native layer/animation tests in run
`45686764139`. The new USDZ must pass that native gate again: the checks above do
**not** establish its RealityKit import, animation playback, frame rate or visual
quality on an iPhone. Simulator/device asset loading is a separate gate.

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
