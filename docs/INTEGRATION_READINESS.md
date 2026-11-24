# First-slice integration status

This branch combines three real, bounded Codex CLI worker outputs. It is a structural prototype and is not yet a balanced or verified playable game.

## Implemented source boundaries

- Scan normalization preserves the source marker. The generator makes a bounded quantized ellipse using coarse normalized aspect ratio and seeded variation. This is a **placeholder route generator**, not a faithful room-driven layout or proof of race reachability.
- Race/replay code has fixed simulation ticks, gate banking, half-width checks, score state and replay consistency checks. A zero-steering run currently follows the centerline automatically: there is no curvature drift, obstacle course or meaningful need to bank. Do not claim a skill challenge.
- The iOS source shell requests camera access explicitly, checks ARKit mesh capability, copies bounded vertices through anchor transforms, stops capture before preview/racing, and offers a visibly synthetic demo.
- Native bank control is armed until a bank is observed or explicitly cancelled, rather than being dropped after one off-gate tick.
- Sharing is reviewed local ChallengeDescriptor JSON through the system sheet. There is no public challenge URL, X OAuth/API/post, social score signal, server anti-cheat, remote Hugging Face inference, upload or video renderer.

## Verification boundaries

The workers ran on Windows without Swift/Xcode/XcodeGen. Their authored Swift tests and the iOS app were not compiled by those workers. Source review and whitespace checks cannot establish a build or device pass. The unsigned CI workflow is the next executable gate; its actual run result must be read before reporting success.

The workflow targets the xcode-27 hosted image, explicitly selects stable Xcode 27.2, prints SDK/tool versions, runs swift test, generates the Xcode project and builds for a generic iOS Simulator with signing disabled. It has a 20-minute timeout and does not upload to Apple. Simulator compilation cannot validate LiDAR, camera lifecycle or thermal/frame-rate behavior on physical hardware.

The launcher captured thread IDs and turn completion logs, but its PowerShell process exit-code read returned null after process exit. Original receipts are preserved. Separate coordinator verification records distinguish observed turn.completed from an unavailable process exit code; no exit-zero claim is inferred from that event.

## Next acceptance gates

1. Add intentional skill pressure with versioned simulation semantics. On a curated bend/hazard, zero input must fail and a correcting input sequence must succeed. Keep old replays tied to the old rules version.
2. Replace the ellipse placeholder with a room-influenced generator that validates connectedness, clearance, turn limits and an admissible playable corridor. Sparse/poor scans must be rejected or retried explicitly.
3. Establish coverage/tracking quality before admitting a device ScanSample; point count alone is insufficient. Test partial scans, mirrors, sparse furniture, tracking loss and relocalization on a LiDAR device.
4. Replace sleep-based tick scheduling with an accumulator/display-link loop. Fixed simulation dt does not mean 90 seconds of simulation currently equals 90 seconds of wall time.
5. Verify bank arming/cancellation, steering, width/gate rendering, share-sheet lifecycle and cleanup on simulator/device. Capture currently has no live camera preview.
6. Add an importable challenge representation and a replay-based clip renderer before making social-sharing claims. Keep race score independent of popularity.
7. Record actual Swift-test, Xcode-build and physical-device evidence separately. Signing, App Store registration, TestFlight, contest submissions and public publication remain later actions.

## Reference environment

- Deployment target: iOS 27.0.
- Stable build tool requested: Xcode 27.2; print its actual Swift/SDK versions in CI.
- Canonical track identity uses CryptoKit on Apple; unsupported platforms report that explicitly.
- Root design references: PRODUCT_BRIEF_RU.md, LIDAR_SPEC.md and CONTRACTS.md.
