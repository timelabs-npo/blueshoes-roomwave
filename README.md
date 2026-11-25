# Roomwave · Slipstream

**Hold to charge. Release to soar. Dive, release, and stick the landing.**

Roomwave is a native one-touch kinetic surfing arcade in a low-poly neon landscape. Timing changes your flight arc, momentum and score. The v0.3 rebuild replaces the original flat steering workbench with a full-screen game.

## The arcade

- **Neon Dawn:** learn charge, release and clean landings with a forgiving opening.
- **Low Orbit:** longer aerial lines and high gold rings.
- **Black Current:** barriers, low ceilings, dive windows and recovery.
- Shields, execution-based combo scoring, medals, saved personal bests and immediate retry.
- Original synthesized music and event sounds, haptics, pause/background recovery and Reduce Motion.
- A visibly animated, licensed layered rider. Skeleton/muscle helper layers stay out of the playfield.
- User-initiated score cards, authored-course challenge links and an editable X composer. Likes and reposts never add game points.

Photo and LiDAR creation are secondary. Actual local image/mesh features produce restrained terrain variations around a known encounter sequence. Raw input stays on the device. This is creative interpretation, not a measured room reconstruction. The latest created course remains selectable locally; custom routes are not falsely advertised as shared challenges.

## Beta status and evidence

The active target is **0.3.0**, using the existing authorized Apple bundle. The older internal TestFlight pilot **0.2.0 (1002.1)** is preserved in an archive branch. A public-beta URL will be added only after the new exact build receives external approval and the link is verified.

- [Arcade acceptance and actual worker receipts](docs/ARCADE_ACCEPTANCE.md)
- [Native validation runs](https://github.com/timelabs-npo/blueshoes-roomwave/actions/workflows/unsigned-ios.yml)
- [TestFlight delivery and historical pilot](docs/TESTFLIGHT_DELIVERY.md)
- [External beta operations](docs/PUBLIC_BETA.md)
- [Privacy policy](docs/PRIVACY.md)

A simulator pass does not establish physical-device frame pacing, thermal behavior, LiDAR quality or human enjoyment. Apple Arcade consideration and awards are separate outcomes.

## Build

Use stable Xcode 27.2 and XcodeGen. Deployment target: iOS 27.0; iPhone 18 Pro Max is the reference simulator/device target.

```sh
swift test
xcodegen generate --spec apps/ios/project.yml --project apps/ios
open apps/ios/Roomwave.xcodeproj
```

| Module | Responsibility |
| --- | --- |
| RoomwaveArcade | Fixed-step surfing, authored courses, encounters, scoring, replay |
| RoomwaveCreator | Bounded photo/mesh-inspired terrain adaptation |
| RealityKit scene | Elevated ribbon, rider, camera, biome geometry and effects |
| SwiftUI / UIKit | Full-screen flow, compact HUD, direct touch, accessibility |
| AVFoundation | Original cached audio and interruption handling |
| RoomwaveCore | Existing photo/scan normalization and isolated legacy pilot |

The native gate executes production Swift tests, hosted asset/photo tests and ordinary XCUITest touch input. It preserves real ARView captures, full UI screenshots/video and exact source identity. Signing and Apple credentials remain in protected release configuration.

## Continuity

Three bounded Codex lanes own gameplay, presentation and experience; one coordinator owns shared contracts and integration. Work persists through an atomic task store with leases, exact-base checks, explicit reviews, limited retries and duplicate-release claims.

```sh
python3 -m unittest discover -s tests/continuity -v
python3 scripts/continuity/supervisor.py --state-dir ops/continuity-state status
python3 scripts/continuity/supervisor.py --state-dir ops/continuity-state reconcile
```

Use one authoritative state directory per project coordinator. Existing Wd receipts are imported as observations, never treated as local PIDs. See [operating instructions](docs/CONTINUITY.md), [shared interfaces](docs/ARCADE_CONTRACTS.md) and [rebuild direction](docs/ARCADE_REBUILD.md).

## Assets and model resources

Code is MIT-licensed. Third-party art retains its own notices. The CC0 humanoid and derivative rig/layers have [source and provenance](docs/AVATAR_ASSETS.md). The skeleton/muscle overlays are stylized animation helpers, not medical anatomy.

The current photo path uses local ImageIO/Vision features. [Apple's Hugging Face Core ML depth model is a documented evaluation candidate](docs/PHOTO_MODEL_REVIEW.md); its weights are not bundled or claimed as already running.

[Community beta copy](docs/COMMUNITY_BETA_COPY.md) is a draft. Preparing it does not publish a post or invite testers.
