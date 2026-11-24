# Blueshoes: Roomwave

Turn a space or a photo into a stylised racing circuit, ride a layered animated character, and bank your score before the next risky turn.

Roomwave is a native Swift/SwiftUI/ARKit/RealityKit pilot targeting iOS 27, with iPhone 18 Pro Max as the reference device. The project is MIT-licensed; third-party artwork retains its own notices.

## Pilot features

- **Photo maps:** ImageIO decodes and orients an image locally. Vision attention saliency, contrast and Sobel features produce an inferred 2.5D sample. The generated circuit depends on those features. A single photo is not treated as calibrated depth or a measured reconstruction.
- **LiDAR tracks:** capability-checked ARKit mesh samples are transformed into a common gravity-aligned frame, bounded, checked for freshness and converted into a stylised circuit. Scan coverage and device quality still require physical testing.
- **Playable bend pressure:** steering counters curvature-dependent outward pressure. An initial two-second grace period and three-second ramp allow orientation; a bank request saves the chain at the next gate.
- **Layered rider:** a redistributed CC0 humanoid, articulated rig, authored glide animation, and separately switchable Skin, Coat, SkeletonOverlay and MuscleOverlay groups. The visible skeleton/muscle overlays are stylised animation helpers, not medical anatomy or biological simulation.
- **Local sharing:** the user can review and export final track geometry and rules. Raw camera frames, photographs, mesh samples and local capture IDs are excluded from the challenge descriptor.
- **Synthetic demo:** an explicitly labelled, invented track source is available without camera or photo access.

## Development

Use stable Xcode 27.2 and XcodeGen. The deployment target is iOS 27.0.

```sh
swift test
cd apps/ios
xcodegen generate --spec project.yml
open Roomwave.xcodeproj
```

Shared gameplay and geometry live in Sources/RoomwaveCore. Native code lives in apps/ios/Roomwave.
The unsigned workflow separately checks the core, native build and simulator tests. A successful simulator result cannot establish LiDAR quality, frame-rate or thermal behavior on an iPhone.
Signing and TestFlight delivery use protected release configuration, never checked-in credentials.

## TestFlight identity

The owner has authorized this Roomwave pilot to use the existing **MoleculeFoundry** Apple app record.

| Setting | Pilot value |
|---|---|
| Bundle identifier | `org.timelabs.moleculefoundry` |
| Apple app ID | `6837899703` |
| Developer team | `398XACWZ7G` |
| Beta version | `0.2.0` |

The native product and its display name remain Roomwave. Signed delivery is controlled by the protected TestFlight workflow; successful upload, Apple processing and tester availability must each be verified for the actual build. See [delivery instructions](docs/TESTFLIGHT_DELIVERY.md).

## Design and verification

- [Product brief](docs/PRODUCT_BRIEF_RU.md)
- [LiDAR specification](docs/LIDAR_SPEC.md)
- [Pilot contracts](docs/PILOT_CONTRACTS.md)
- [Gameplay implementation](docs/PILOT_GAMEPLAY.md)
- [Photo analysis](docs/PILOT_PHOTO.md)
- [Avatar resources and provenance](docs/AVATAR_ASSETS.md)
- [Pilot swarm receipt](docs/PILOT_SWARM_RUN.md)

Photo analysis and race execution do not require a remote model service.
Public challenge hosting, X OAuth/API, social reputation, video capture and server-side score verification are separate future features.
