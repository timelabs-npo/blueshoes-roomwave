# Twitter Surfer privacy policy

Effective: 26 November 2026. Applies to the Twitter Surfer arcade beta distributed under the existing bundle `org.timelabs.moleculefoundry` by Time Labs NPO.

## Playing and local records

The game works without an account. Preferences, personal bests and any locally retained input replay are stored in the app's private storage on your device. Twitter Surfer does not send these records to a game server. Removing the app removes its local records, subject to your device backup settings.

Twitter Surfer does not include advertising, advertising identifiers, tracking SDKs, third-party analytics or a social-login requirement. It uses elapsed time to update gameplay and to judge whether a capture is still fresh; it does not use this information to fingerprint devices.

## Optional photo and LiDAR creation

Photo access starts only when you choose a picture through Apple's system photo picker. Analysis runs on your device. Camera access starts only when you explicitly choose device capture and grant permission. LiDAR capture requires a compatible device and uses ARKit mesh data to derive a stylized course.

Raw photographs, EXIF metadata, camera frames, mesh samples and local capture identifiers are not uploaded by Twitter Surfer or included in a share card or challenge link. Temporary raw capture data is discarded when processing ends or is cancelled. Derived course geometry is a creative game representation; it is not a measured reconstruction of your room.

## Sharing

Sharing requires an explicit action. A score card or challenge link contains the game result and course identity shown to you. Choosing a destination in the system share sheet sends that selected content through the app you chose, under that service's own privacy policy. Twitter Surfer does not automatically post to X or reward likes and reposts with score. Opening the X composer does not confirm that a post was published. Do not include personal details in feedback or public issue reports unless you intend to disclose them.

## Optional X connection and activity

When the developer has configured an X application, you may connect your own X account through X’s authorization screen. The game never asks for your X password. It requests read access to your identity and posts, and permission to refresh that authorization. X may require its own account eligibility and API access. Without that configuration or permission, the game remains playable and the connection is shown as unavailable.

An explicit refresh reads public engagement counters from your recent posts or the community topic you choose through the official X API. Account/post identifiers and counters are held in memory to compare observations. The game uses bounded numeric aggregates to shape a new course. It does not retain post text, profile photographs, direct messages, follower lists or a copy of your timeline. The network session does not cache API responses on disk. Requests go directly to X; its privacy policy applies to those requests. No game backend receives your X tokens, scans or activity.

OAuth access and refresh tokens are stored in this app’s device-only Keychain, accessible while the device is unlocked. Disconnecting clears the local tokens and in-memory activity and attempts to revoke authorization at X. If X cannot be reached, local removal still occurs; you can also revoke the app in your X connected-app settings.

A social course freezes the observed numeric aggregate for that run. A derived course may combine that aggregate with an already generated LiDAR course, but does not send the scan to X. Course identities and score cards exclude account/post identifiers and raw activity records. An abstract course identity is not a guarantee of anonymity.

## TestFlight and diagnostics

Apple operates TestFlight and may provide the developer with installation, usage, crash and feedback information according to Apple's TestFlight terms and your settings. A screenshot or message you deliberately send as TestFlight feedback may contain information visible on your screen. Such feedback is used to diagnose and improve this beta. This is separate from the app's local-only gameplay and capture processing.

## Questions and requests

Use **Send Beta Feedback** in TestFlight to contact the developer privately about this beta or request help concerning submitted feedback. General product issues can also be reported at [the Roomwave repository](https://github.com/timelabs-npo/blueshoes-roomwave/issues); GitHub issues are public. Do not put private photographs, home scans, credentials or contact details into a public issue.

The beta does not require an X account to play the authored courses or create a local course. The policy will be updated before adding backend activity delivery, a new data destination, or a different use of social data.
