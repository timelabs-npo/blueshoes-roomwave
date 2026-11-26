# Controlled avatar-data comparison, 26 November 2026

This diagnostic starts from `a18833df27687b1021b7d476756852b3f3c3661b`. It restores only the actual layered USDZ, its validation record and source/runtime manifest from `41ed282b47bc2231f5b444914f1c8389e5635859`. The known earlier successful run is [45686764139](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45686764139); that historical success is not a pass for this new source.

The exact-source [a188 recheck](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45724693704) failed with service METAL 101 and application METAL 102 on a different registered runner. Both exported app crash reports include `SkeletalPoseBufferComponent.update` after service loss. This motivates an asset-data comparison; it does not prove that the asset or skeleton caused the first GPU error.

## Controlled variable

The older actual asset is 607,617 bytes, SHA-256 `9c1c0a0af0952fa30f91918048bfcd5553d52556ba83c720598aeba5b9cd5c8d`. It retains Skin, Coat, SkeletonOverlay and MuscleOverlay, 66 joints per layer, four rigs, and the two-second RoomwaveGlide animation with 61 samples at 30 fps. Its historical validation records 36 skinned meshes and 22,912 triangles.

The current a188 asset is 682,785 bytes, SHA-256 `1eff38b20f3c443e04f5dc80f526067e35a4441ac4bae7aca6abe04a5ecb6d3f`. Its historical validation records 42 skinned meshes and 26,892 triangles. Upstream glTF/bin/license files are unchanged.

The scene geometry, animation-owner logic, simulator shadow settings, simulation, input, UI, audio, render/input assertions and CI scripts remain byte-identical to a188. No alternate test game, placeholder rider or disabled-animation pass is introduced.

## Provenance and interpretation

`scripts/assets` still contains the newer generator. To reproduce the comparison asset, use the pinned old producer revision above; running the current generator would change the controlled variable. Existing newer-art proof images and art notes remain historical records for their original source, not proof of this comparison's runtime appearance. The restored JSON metadata is the record corresponding to the actual restored bytes.

No native, visual, physical-device or release pass is claimed at commit time. The diagnostic uses the SDK-matched runtime and the full existing gate. Its run ID, exact source, runtime and artifact digests must be recorded and reviewed after execution. A successful comparison would localize a relevant data difference, not establish a final art direction or automatically authorize TestFlight upload.
