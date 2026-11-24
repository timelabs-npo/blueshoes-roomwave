# Native iOS lane readiness

Status: **source shell prepared; compilation and device acceptance NOT VERIFIED**.

Owned additions: `apps/ios/project.yml`, `apps/ios/Roomwave/Info.plist`,
`RoomwaveApp.swift`, `RoomwaveModel.swift`, `ContentView.swift`, `TrackScene.swift`,
`ChallengeReviewView.swift`, and `apps/ios/README.md`.

The shell separates synthetic demo, explicit camera permission, bounded ARKit
mesh capture, frozen preview, race and JSON review/export. Samples are at most
32 anchors × 64 vertices, transformed into the session world frame. Capture
stops after 20 seconds or Finish; inactive/background cancels active capture and
race, with pending permission invalidated on background. No automatic resume.
ARKit's provenance marker is not remote attestation. The generated track must
retain the input source, validate, and be previewed before racing or sharing.

RealityKit draws the finalized closed circuit and a player; drag controls core
steering and Bank submits a one-tick gate request. Banked/chain values come only
from RaceSimulation. No likes/reposts or networking affect race state.

Sharing requires review then explicit export through UIActivityViewController.
Only ChallengeDescriptor is encoded; raw ScanSample, capture identifiers and
camera data have no export path. No URL service, upload, OAuth, remote AI,
replay/clip recording or distribution implementation is claimed. Derived
geometry remains potentially revealing, so the review explicitly warns users.

## Checks actually executed on Windows

- Read `AGENTS.md`, `docs/CONTRACTS.md`, frozen `Contracts.swift` and `Package.swift`.
- `Get-Command swift,xcodebuild,xcodegen -ErrorAction SilentlyContinue`: none
  found in PATH. No Swift compilation, Xcode generation, simulator, core tests
  or device test was executed.
- Parsed `Info.plist` as XML with PowerShell; camera usage key is present.
- Source search checked permission/capability/start/pause paths and export
  construction; no URLSession/network transport appears in native Swift files.
- `git diff --check` passed for tracked content. PowerShell scanned all nine
  new owned files for trailing whitespace: PASS.
- `git status --porcelain=v1 --untracked-files=all` listed only the nine owned
  additions. `git diff --exit-code -- AGENTS.md docs/CONTRACTS.md
  Sources/RoomwaveCore/Contracts.swift Package.swift` confirmed no frozen-file
  changes.
- PowerShell source assertions: no native Swift network transport symbols or
  HTTP endpoints; export encodes `descriptor`, not `sample`; project text
  declares iOS 27, `../..` local package and the explicit camera-usage plist.
  These are textual checks, not YAML parsing, compilation or a privacy runtime
  test. The final lifecycle edit was rechecked with the same assertions.

## Integration risks and next checks

At inspection, core sources contained only `Contracts.swift`; ScanNormalizer,
TrackGenerator, TrackValidator, TrackIdentity and RaceSimulation are pending
other-lane dependencies. Their agreed calls remain intact. No fallback core
implementation or frozen interface change was made. Compilation depends on
their integration, XcodeGen availability and an actual iOS 27 SDK.

Main-thread mesh polling/copying, AR lifecycle/permission timing, RealityKit
camera framing and player alignment, one-finger controls, tick pacing, Bank
timing, share-sheet presentation and temporary-file cleanup remain unverified.
The simple sleep scheduler does not guarantee real-time tick pacing. Failed or
empty device captures surface an error; they never fabricate device data.

Expected Mac build commands and the concrete simulator/LiDAR/privacy test
matrix are in `apps/ios/README.md`. No signing team or credential was added.
