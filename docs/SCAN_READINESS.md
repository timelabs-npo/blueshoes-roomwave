# Scan lane readiness

Implemented locally, 2026-11-24. Swift compilation/tests and all Xcode/device execution: **NOT VERIFIED**. No Swift executable was found by `where.exe swift` on this Windows host. Zero dependencies added; frozen contracts and package manifest unchanged. Other lanes were not replaced or edited.

## Normalization and provenance

Accept 3...4096 finite points, each coordinate within [-1000,1000], each axis extent <=100, maximum horizontal extent >=0.05 (input coordinate units). Center the axis-aligned bounding box and divide all axes by half the largest extent. Reject horizontal covariance trace <=1e-8 or determinant <=1e-6 times squared trace; identical/collinear/nearly collinear horizontal data fail. Output coordinates lie within [-1,1], version 1. Capture ID is discarded. `ScanSource` is preserved exactly through normalization and generation; `arkitMesh` remains a caller/adapter label, not attestation. One invented synthetic fixture is local input only.

## Generated circuit and validation limits

Generator `coarse-ellipse-splitmix64-1` accepts only version-1 finite bounded intermediates (absolute coordinate <=1.000000001), repeats count/area admission, and uses horizontal bounding-box aspect ratio, clamped to [0.65,1]. It emits 32 planar ellipse points, implicit last-to-first closure, half-width 0.650, four gates at indices 0/8/16/24 and standard rules. Radii are `18 * clampedAxisRatio * (0.96 + 0.08*u)`; a third draw rotates the ellipse by `2*pi*u`. Points round to the nearest 0.001 game unit, ties away from zero, with positive zero. No raw bounds or capture ID enter TrackDefinition.

PRNG: SplitMix64, initial state = the full UInt64 seed. Before each draw add 0x9E3779B97F4A7C15 modulo 2^64; mix `z = (z xor (z >> 30)) * 0xBF58476D1CE4E5B9`, then `(z xor (z >> 27)) * 0x94D049BB133111EB`, both modulo 2^64, then `z xor (z >> 31)`. Divide its upper 53 bits by 2^53 to obtain [0,1). Exactly three draws control gameplay layout; no decorative randomness is consumed. Seed-42 reference first centers for the fixture: (-3.280,0,18.052), (-5.457,0,17.298), (-7.425,0,15.880). Determinism is scoped to this algorithm/toolchain: platform trigonometric rounding is not a universal cross-CPU guarantee.

Validator requires schema 1; nonempty generator/rule version strings <=128 UTF-8 bytes; 3...256 points; finite planar y=0, x/z in [-100,100], widths [0.25,5]; exact finalized 0.001 grid representations; at least one gate. Segment lengths must be >=max(0.1,1.5*maximum endpoint half-width). Turns must be <=135 degrees. Nonadjacent segment distance must exceed the sum of maximum endpoint half-widths (including closure). All invalid issues are reported where safe; point-count/nonfinite/bounds failures short-circuit expensive geometry checks. Pair checks are O(n^2), bounded at 256 points.

Rules: tickRate 1...240, durationTicks 1...864000; finite positive initialSpeed <= maximumSpeed <=100, acceleration [0,100], steeringSpeed (0,100], bankSpeedFactor (0,1], multiplierGain (0,10]. These are admission caps, not guarantees of race outcome. Static centerline/ribbon spacing and turn checks do not establish complete dynamic reachability, drivable 3D surfaces, full ribbon swept-volume separation at adjacent corners, or exact room reconstruction. Coarse stylization is not a claim of anonymizing a home; preview/consent still belongs in the native sharing flow.

## Canonical identity v1

`canonicalData` validates first and works with Foundation alone. Exact binary concatenation, without JSON or native integer layout:

1. ASCII `roomwave-track-identity-v1` plus one zero byte.
2. schemaVersion as unsigned 64-bit big-endian; generatorVersion string; source raw-value string; seed as unsigned 64-bit big-endian.
3. rules.version string; tickRate and durationTicks as unsigned 64-bit big-endian.
4. Rules' initialSpeed, maximumSpeed, acceleration, steeringSpeed, bankSpeedFactor, multiplierGain, in that order: IEEE-754 binary64 bit patterns as 8 big-endian bytes. Negative zero becomes positive zero.
5. Point count as unsigned 64-bit big-endian; each point in route order: x, y, z, halfWidth as signed 64-bit two's-complement big-endian integer milligame-units, then isGate as one byte 0 or 1. Integer conversion rounds ties away from zero after validation of exact grid representation.

Every string is its exact UTF-8 bytes preceded by a 4-byte unsigned big-endian byte count. No Unicode normalization, key ordering, rotation/cyclic reordering or reversal equivalence is applied. Geometry must already be finalized on the grid; canonicalization does not mutate an export. Source, seed, versions, point order, gate flags, widths and every rule field participate in identity. Local ScanSample/capture ID/raw points are never encoded. Identical gameplay geometry with different provenance or seed deliberately has a different ID.

`id` returns lowercase 64-character SHA-256 only on Apple platforms with CryptoKit; after validation, other platforms throw `RoomwaveError.unsupportedPlatform`. No fallback digest or invented ID is used. Identity is content addressing, not a signature, remote attestation or replay authenticity proof. The square protocol vector in ScanTests is 293 bytes and has reference SHA-256 `b966931b9cb91268f35a4f5cc03f27d642add4b99a95b959fd2e594b54187813`.

## Checks and integration

Executed: local contract reads; `where.exe swift` (not found); `git diff --check`; explicit whitespace/conflict-marker scan of all seven owned additions (PASS); frozen/control files compared unchanged against HEAD; fixture JSON parsing/provenance/count via PowerShell (PASS); independent JavaScript BigInt SplitMix64/reference byte encoding and .NET SHA-256 of the 293-byte protocol vector. These reference checks do not execute Swift. An initial reference-hash command used unavailable .NET `Convert.FromHexString`; corrected to explicit byte-pair decoding and obtained the digest above.

Authored Swift Testing cases cover invalid/oversized/nonfinite/degenerate input, caller-forged intermediates, provenance, capture-ID exclusion, normalized translation/scale behavior, fixed-seed output, seed extremes, bounded/closed geometry, crossing/clearance/curvature, invalid rules, protocol golden bytes, geometry/rule/metadata identity changes, signed zero, Apple SHA-256 and explicit unsupported behavior. They have not run here. Fixture test resolves the checkout from #filePath; it requires the fixture to remain beside the source checkout.

Remaining: run `swift test` with Swift 6 on a supported toolchain (including Apple CryptoKit identity vector), integrate the race lane's validator/identity calls, and verify native preview/share and actual iOS capture on Xcode/device. Unsupported-platform identity propagates to replay; no substitution is permitted. Challenge serialization tests inspect finalized field allowlists only; they do not establish native sharing consent or runtime replay acceptance. Race score/social networking behavior is outside this lane and unchanged.
