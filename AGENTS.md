# Roomwave pilot parallel contract
Scope: only the current Roomwave worktree. Other projects, credentials and host configuration are out of scope.
This pilot replaces the first-slice ownership assignment with the coordinator-reviewed contract below, under the user's explicit request for a playable TestFlight pilot with photo maps and layered animation.

Read docs/PILOT_CONTRACTS.md and docs/CONTRACTS.md. Sources/RoomwaveCore/Contracts.swift and Package.swift are frozen after coordinator preparation. Do not duplicate types or change shared signatures.
Ownership:
- gameplay: Sources/RoomwaveCore/RaceSimulation.swift, TrackGenerator.swift, TrackValidator.swift; Tests/RoomwaveCoreTests/RaceTests.swift, ScanTests.swift, PilotGameplayTests.swift; docs/PILOT_GAMEPLAY.md.
- photo: Sources/RoomwaveCore/PhotoMapAnalyzer.swift; Tests/RoomwaveCoreTests/PhotoMapTests.swift; apps/ios/Roomwave/PhotoMapImporter.swift; docs/PILOT_PHOTO.md.
- avatar: apps/ios/Roomwave/LayeredAvatarController.swift; docs/PILOT_AVATAR.md.
Coordinator integrates RoomwaveModel, ContentView, TrackScene, timing and artwork. Release coordinator owns .github, project.yml, Info.plist and signing. Asset coordinator owns Assets and license notices. Do not edit these concurrently.

One bounded task, max20 minutes, no recursive spawning or daemons. Do not commit/push/merge/changebranches/installpackages/callremoteAI/postmessages/dispatchworkflows/mutateaccounts. No secrets or unrelated home-directory searches. Respect existing sandbox and approval controls.
Preserve synthetic, arkitMesh and photoDerived provenance. A photo map is inferred stylized geometry, not calibrated depth or a measured reconstruction. Export final track only, never photos/raw mesh/captureIDs.
Race scores depend on gameplay, not popularity. Report exactly executed verification; Windows withoutSwift/Xcode cannot prove iOS compilation or device operation. Leave concise lane notes and meaningful behavior tests.
