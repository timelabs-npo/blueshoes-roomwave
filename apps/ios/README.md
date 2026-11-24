# Roomwave native pilot

The app targets iOS **27.0**, Swift 6, and the local RoomwaveCore package. Development and CI use stable **Xcode 27.2** and XcodeGen. iPhone 18 Pro Max is the reference device.

The first successful native runtime gate is [CI run 45487555481](https://github.com/timelabs-npo/blueshoes-roomwave/actions/runs/45487555481) at commit `497445b`. It compiled and launched the app in an iOS simulator, loaded four renderable USDZ layers and animation resources, exercised independent layer visibility, and verified that two actual decoded images produce different valid tracks. Those results establish the tested code and asset behavior; signing and physical LiDAR quality have separate acceptance steps.

## Distribution identity

The owner authorized the Roomwave pilot to use the existing MoleculeFoundry Apple app record: bundle `org.timelabs.moleculefoundry`, Apple app ID `6837899703`, team `398XACWZ7G`, beta version `0.2.0`. The product/module/display name remains Roomwave. Unsigned validation uses build 1; the protected release workflow assigns its own monotonically increasing build number. See [TestFlight delivery](../../docs/TESTFLIGHT_DELIVERY.md) for the actual release gates.

## Build and verify

From the repository root on a suitable Mac:

```sh
swift test
xcodegen generate --spec apps/ios/project.yml --project apps/ios
xcodebuild -project apps/ios/Roomwave.xcodeproj -scheme Roomwave \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

The unsigned CI workflow also runs the hosted native tests on an available iOS 27 iPhone simulator, captures actual demo/race screenshots, verifies the compiled identity/privacy/resources, and creates an unsigned generic iOS Release archive. Its visible artifact directories are `build/native-test-results` and `build/pilot-artifacts`. An unsigned archive still needs valid signing before installation on a physical iPhone or distribution through TestFlight.

## App flow

- **Photo:** PhotosPicker supplies real image bytes. ImageIO applies orientation and bounded downsampling; on-device Vision saliency plus contrast/edge features generate a `.photoDerived` stylized sample. Analysis does not upload, persist or export the source photograph or EXIF. It infers a map without claiming measured depth or room dimensions.
- **LiDAR:** a supported device can show a live capture preview and sample its actual ARKit mesh. Capture is bounded to 20 seconds, 32 anchor snapshots and 64 sampled vertices per anchor. Local vertices are transformed into a shared gravity-aligned frame; stale or limited-tracking samples cannot silently become synthetic data. Capture stops and raw samples clear on cancellation/background.
- **Demo:** 128 invented points remain explicitly `.synthetic` through track generation and export. No camera or photo permission is required.
- **Race:** a validated frozen circuit previews before racing. A close camera follows the rider. Drag to counter bend pressure, release to stop steering, and arm Bank for the next gate. CADisplayLink feeds fixed simulation ticks; interrupted pacing stops a run explicitly. Haptics mark banking and the result.
- **Rider:** the bundled CC0-derived humanoid has four independent rigged layer groups and authored glide animation. Skin and coat are enabled by default. Skeleton and muscle overlays are stylized animation helpers. Loading/fallback is identified in the scene if the real model cannot load.
- **Export:** the user reviews final track geometry/rules before UIActivityViewController shares exactly those JSON bytes. Source photographs, raw mesh, anchor IDs and capture IDs are excluded. Temporary exports are removed when the share sheet dismisses.

## Physical-device acceptance still required

Exercise LiDAR coverage, allow/deny/restricted camera access, cancellation during the permission dialog, empty mesh, limited tracking, manual/automatic capture completion, and background transitions on an actual supported iPhone. Inspect steering comfort, camera motion, haptics, frame-rate and thermal behavior. Test reviewed/exported bytes and system sharing on iPhone and iPad.

The DEBUG-only launch arguments `--pilot-demo` and `--pilot-race` exercise the normal app paths for CI screenshots. They are absent from Release builds. Public challenge hosting, X OAuth/API, video capture and server-side score verification remain future work.
