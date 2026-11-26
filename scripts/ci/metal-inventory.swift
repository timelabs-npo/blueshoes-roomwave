import Foundation
import Metal

// Capability observations only. No serial numbers, registry IDs or account data.
// A listed GPU or supported family does not establish successful game rendering.
let devices: [[String: Any]] = MTLCopyAllDevices().map { device in
    ["name": device.name,
     "low_power": device.isLowPower,
     "headless": device.isHeadless,
     "supports_apple7": device.supportsFamily(.apple7),
     "supports_mac2": device.supportsFamily(.mac2),
     "recommended_working_set_bytes": device.recommendedMaxWorkingSetSize]
}
let record: [String: Any] = [
    "schema_version": 1,
    "observed_at": ISO8601DateFormatter().string(from: Date()),
    "devices": devices,
    "render_validation": "requires the unchanged native input/render gate"
]
let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
