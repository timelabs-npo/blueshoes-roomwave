# Roomwave native readiness shell

Build status: **NOT VERIFIED**. This slice was authored on Windows; no Swift,
Xcode, XcodeGen, simulator or physical-device execution was available.

The XcodeGen target uses iOS **27.0**, Swift 6 and the local RoomwaveCore package
at `../..`. An Xcode installation with an iOS 27 SDK and an already available
XcodeGen are prerequisites. No dependencies were installed by this worker.

On a suitable Mac, from the repository root:

```sh
cd apps/ios
xcodegen generate --spec project.yml
xcodebuild -project Roomwave.xcodeproj -scheme Roomwave \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

These commands are expected checks, **not executed results**. Use a locally
selected signing team for a physical-device build; no team or credentials are
included. The core scan/race implementations must be integrated at their frozen
signatures. A generated project alone is not an app build or acceptance result.

## App flow

- **SYNTHETIC demo** uses 128 invented points and remains `.synthetic` through
  generation/export. It needs no camera permission or LiDAR.
- **Start device capture** checks world-tracking/mesh capability, then requests
  camera access. Unsupported devices have a disabled capture action; denial
  leaves the demo usable. There is no camera feed UI or recording.
- Capture polls the current AR frame four times per second for at most 20
  seconds. At most 32 anchor snapshots, each with 64 evenly sampled vertices,
  are copied. Each local vertex is multiplied by its anchor transform into the
  same gravity-aligned session world frame. Only normal-tracking frames count.
  This is coarse bounded sampling, not an accuracy or room-coverage claim.
- Finish pauses ARSession before normalization/generation. Cancellation,
  inactivity and background stop sampling and clear the app's raw-point buffer.
  Permission requests are cancelled logically on background; no automatic
  capture restart occurs. The ARKit origin label is client-reported, not attested.
- A validated frozen track is shown as a non-AR RealityKit tabletop circuit.
  Preview acceptance is required before racing. Drag one finger sideways to
  steer; release centers. Orange bars mark gates. Bank sends a one-tick request
  to the core. Crashes/finish and banked/chain score come from RaceSimulation.
  No physics-engine scoring, social scoring or replay/clip recording is added.
- The simple scheduler sleeps between fixed core ticks; wall-clock pacing,
  render comfort and geometry alignment require device tests. Background stops
  a race; the next run starts from the initial core state after preview.
- **Review local challenge JSON** encodes only ChallengeDescriptor. A second
  **Export reviewed JSON** action creates a protected temporary JSON file and
  opens UIActivityViewController. The exact reviewed bytes are exported. The
  app implements no remote destination; a destination chosen in the system
  share sheet can send the file itself. Temporary exports are removed when the
  activity sheet dismisses; interrupted process cleanup is left to iOS temp
  storage. No raw ScanSample, anchor IDs or camera data enters this file.

## Required acceptance on Mac/device

1. Generate/build with the iOS 27 SDK. Resolve Swift 6 isolation/API diagnostics
   in owned native files without changing shared contracts. Confirm camera
   usage text survives project generation and local package resolves.
2. Simulator/non-LiDAR: capture visibly disabled; demo can preview, steer, bank,
   crash/finish and export with a permanent synthetic origin marker.
3. LiDAR device: allow/deny/restricted permission, cancel during permission,
   empty mesh, limited tracking, 20-second stop and manual finish. Observe
   actual anchor transformations and bounded sample count; do not substitute
   synthetic measurements when capture fails.
4. Background/inactive during capture and race; background while permission is
   pending. Confirm camera indicator stops, no delayed request restarts capture,
   no partial raw sample can be exported, and race restarts only from preview.
5. Visually compare core track path/width/gates and player distance/offset in
   RealityKit. Check one-finger comfort, release-centering, one-tick Bank gate
   semantics and terminal scores. This renderer is not a reachability proof.
6. On iPhone and iPad, inspect reviewed JSON and exported JSON for exact bytes,
   identity, rules and provenance. Check absence of captureID/raw points/frames;
   cancel/reopen share, popover presentation, file cleanup and locked-device
   file protection. Review derived-geometry privacy before choosing a destination.

Public challenge URLs, uploads, OAuth/X/HF integration, replay verification,
video capture, remote attestation and distribution are outside this slice.
