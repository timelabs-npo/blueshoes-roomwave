import Foundation
import RealityKit
import RoomwaveArcade
import UIKit
import simd

// All meshes are created during load. Game-space Y is up; a model faces local -Z.
@MainActor
enum ArcadeGeometry {
    @MainActor struct Palette {
        let sky: UIColor
        let road: UIColor
        let terrain: UIColor
        let peaks: UIColor
        let horizon: UIColor
        static func forBiome(_ biome: SurfBiome) -> Palette {
            switch biome {
            case .dawn:
                return Palette(sky: rgb(0.035, 0.045, 0.12), road: rgb(0.055, 0.16, 0.22),
                               terrain: rgb(0.045, 0.26, 0.29), peaks: rgb(0.25, 0.12, 0.39),
                               horizon: rgb(1, 0.51, 0.38))
            case .orbit:
                return Palette(sky: rgb(0.018, 0.025, 0.09), road: rgb(0.07, 0.11, 0.23),
                               terrain: rgb(0.17, 0.23, 0.38), peaks: rgb(0.28, 0.19, 0.48),
                               horizon: rgb(0.37, 0.52, 0.92))
            case .midnight:
                return Palette(sky: rgb(0.008, 0.014, 0.035), road: rgb(0.025, 0.07, 0.11),
                               terrain: rgb(0.025, 0.055, 0.085), peaks: rgb(0.075, 0.10, 0.17),
                               horizon: rgb(0.20, 0.34, 0.49))
            }
        }
    }

    static let cyan = rgb(0.12, 0.94, 1)
    static let gold = rgb(1, 0.76, 0.23)
    static let coral = rgb(1, 0.27, 0.30)

    struct EncounterArt {
        let encounter: SurfEncounter
        let entity: Entity
        var consumed = false
    }

    @MainActor final class CourseArt {
        let root: Entity
        let sky: Entity
        let palette: Palette
        var encounters: [EncounterArt]
        let stationCount: Int

        init(root: Entity, sky: Entity, palette: Palette, encounters: [EncounterArt], stationCount: Int) {
            self.root = root; self.sky = sky; self.palette = palette
            self.encounters = encounters; self.stationCount = stationCount
        }
    }

    private struct Station {
        let distance: Double
        let center: SIMD3<Float>
        let right: SIMD3<Float>
        let normal: SIMD3<Float>
        let width: Float
    }

    // Explicit triangle winding and normals; no dependency on a double-sided material.
    @MainActor struct MeshBuilder {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        mutating func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            let cross = simd_cross(b - a, c - a)
            guard simd_length_squared(cross) > 0.0000001 else { return }
            let normal = simd_normalize(cross)
            let start = UInt32(positions.count)
            positions.append(contentsOf: [a, b, c])
            normals.append(contentsOf: [normal, normal, normal])
            // Project along the dominant face normal so vertical ring faces also
            // have non-degenerate UVs rather than collapsing onto the XZ plane.
            func uv(_ point: SIMD3<Float>) -> SIMD2<Float> {
                if abs(normal.y) >= abs(normal.x), abs(normal.y) >= abs(normal.z) {
                    return SIMD2(point.x, point.z) * 0.05
                } else if abs(normal.z) >= abs(normal.x) {
                    return SIMD2(point.x, point.y) * 0.05
                }
                return SIMD2(point.z, point.y) * 0.05
            }
            uvs.append(contentsOf: [uv(a), uv(b), uv(c)])
            indices.append(contentsOf: [start, start + 1, start + 2])
        }

        func resource(named name: String) throws -> MeshResource {
            guard !indices.isEmpty, positions.count == normals.count,
                  positions.count == uvs.count else {
                throw ArcadeSceneError.invalidMesh(name)
            }
            var descriptor = MeshDescriptor(name: name)
            descriptor.positions = MeshBuffers.Positions(positions)
            descriptor.normals = MeshBuffers.Normals(normals)
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
            descriptor.primitives = .triangles(indices)
            return try MeshResource.generate(from: [descriptor])
        }
    }

    static func build(course: CompiledSurfCourse) throws -> CourseArt {
        let palette = Palette.forBiome(course.definition.biome)
        let root = Entity()
        root.name = "SurfCourse_" + course.definition.id
        let stations = try sample(course)
        let road = try ribbon(stations, name: "ContinuousElevatedRibbon", low: -0.5, high: 0.5)
        root.addChild(ModelEntity(mesh: road,
                                 materials: [SimpleMaterial(color: palette.road, roughness: 0.64,
                                                            isMetallic: false)]))
        // Width-relative offsets preserve the exact safe corridor at every station.
        for side in [Float(-1), Float(1)] {
            let edge = try ribbon(stations, name: "CyanEdge", low: side * 0.5 - 0.007,
                                  high: side * 0.5 + 0.007, lift: 0.025)
            root.addChild(ModelEntity(mesh: edge, materials: [UnlitMaterial(color: cyan)]))
            let halo = try ribbon(stations, name: "EdgeApron", low: side * 0.5 - 0.022,
                                  high: side * 0.5 + 0.022, lift: 0.012)
            root.addChild(ModelEntity(mesh: halo, materials: [UnlitMaterial(color: rgb(0.025, 0.28, 0.34))]))
        }
        var seams = MeshBuilder()
        for station in stations where Int(station.distance / 10) != Int(max(0, station.distance - 1.4) / 10) {
            let left = station.center - station.right * station.width * 0.46 + SIMD3<Float>(0, 0.008, 0)
            let right = station.center + station.right * station.width * 0.46 + SIMD3<Float>(0, 0.008, 0)
            let forward = simd_normalize(simd_cross(station.normal, station.right))
            seams.triangle(left, right, left + forward * 0.035)
            seams.triangle(right, right + forward * 0.035, left + forward * 0.035)
        }
        if !seams.indices.isEmpty {
            root.addChild(ModelEntity(mesh: try seams.resource(named: "ElevationContourSeams"),
                                     materials: [UnlitMaterial(color: rgb(0.07, 0.24, 0.29))]))
        }
        try buildLandscape(course: course, stations: stations, parent: root, palette: palette)
        let sky = try buildHorizon(course: course, palette: palette)
        root.addChild(sky)

        var encounters: [EncounterArt] = []
        for encounter in course.definition.encounters {
            let pose = course.pose(at: encounter.distance)
            let entity = try makeEncounter(encounter, pose: pose)
            entity.name = "Encounter_\(encounter.id)_\(encounter.kind.rawValue)"
            entity.isEnabled = false
            root.addChild(entity)
            encounters.append(EncounterArt(encounter: encounter, entity: entity))
        }
        return CourseArt(root: root, sky: sky, palette: palette,
                         encounters: encounters, stationCount: stations.count)
    }

    private static func sample(_ course: CompiledSurfCourse) throws -> [Station] {
        guard course.length.isFinite, course.length > 0,
              course.definition.samples.count >= 2 else { throw ArcadeSceneError.invalidMesh("course samples") }
        var distances: [Double] = [0]
        // Include every original sample exactly, subdividing rather than flattening hills.
        // Bound work defensively even though the compiler validates the authored course.
        for pair in zip(course.definition.samples, course.definition.samples.dropFirst()) {
            let span = pair.1.distance - pair.0.distance
            guard span > 0, span.isFinite, span < 100_000 else {
                throw ArcadeSceneError.invalidMesh("sample distances")
            }
            let divisions = max(1, Int(ceil(span / 1.4)))
            guard distances.count + divisions <= 32_000 else {
                throw ArcadeSceneError.invalidMesh("ribbon exceeds 32000 stations")
            }
            for part in 1...divisions {
                distances.append(pair.0.distance + span * Double(part) / Double(divisions))
            }
        }
        let poses = distances.map { course.pose(at: $0) }
        return poses.indices.map { index in
            let previous = vector(poses[max(0, index - 1)].center)
            let next = vector(poses[min(poses.count - 1, index + 1)].center)
            let tangent = normalized(next - previous, fallback: SIMD3(0, 0, -1))
            let right = normalized(simd_cross(tangent, SIMD3(0, 1, 0)), fallback: SIMD3(1, 0, 0))
            let normal = normalized(simd_cross(right, tangent), fallback: SIMD3(0, 1, 0))
            return Station(distance: distances[index], center: vector(poses[index].center),
                           right: right, normal: normal, width: Float(poses[index].width))
        }
    }

    private static func ribbon(_ stations: [Station], name: String, low: Float, high: Float,
                               lift: Float = 0) throws -> MeshResource {
        var mesh = MeshBuilder()
        for station in stations {
            let offset = SIMD3<Float>(0, lift, 0)
            mesh.positions.append(station.center + station.right * station.width * min(low, high) + offset)
            mesh.positions.append(station.center + station.right * station.width * max(low, high) + offset)
            mesh.normals.append(contentsOf: [station.normal, station.normal])
            mesh.uvs.append(contentsOf: [SIMD2(0, Float(station.distance / 4)), SIMD2(1, Float(station.distance / 4))])
        }
        for index in 0..<(stations.count - 1) {
            let start = UInt32(index * 2)
            mesh.indices.append(contentsOf: [start, start + 1, start + 2,
                                              start + 1, start + 3, start + 2])
        }
        return try mesh.resource(named: name)
    }

    private static func makeEncounter(_ encounter: SurfEncounter, pose: SurfPose) throws -> Entity {
        let root = Entity()
        root.position = vector(pose.center) + SIMD3(0, Float(encounter.height), 0)
        root.orientation = yaw(for: vector(pose.forward))
        let width = Float(pose.width)
        let halfHeight = Float(encounter.halfHeight)
        switch encounter.kind {
        case .ring:
            // Inner opening's top/bottom match the road-relative encounter band.
            // Gameplay compares its ring target at rider foot + 0.5 against this band.
            // Keep the plane vertical: following road pitch would move those Y bounds.
            let mesh = try openRing(radiusX: min(1.45, width * 0.28), radiusY: halfHeight,
                                    thickness: 0.075, depth: 0.12)
            root.addChild(ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: gold)]))
        case .barrier, .ceiling:
            let beam = ModelEntity(mesh: .generateBox(size: SIMD3(width, 2 * halfHeight, 0.32), cornerRadius: 0.035),
                                   materials: [SimpleMaterial(color: coral, roughness: 0.42, isMetallic: false)])
            root.addChild(beam)
            for sign in [Float(-1), Float(1)] {
                let rim = ModelEntity(mesh: .generateBox(size: SIMD3(width, 0.035, 0.345)),
                                      materials: [UnlitMaterial(color: coral)])
                rim.position.y = sign * max(0, halfHeight - 0.02)
                root.addChild(rim)
            }
            if encounter.kind == .ceiling {
                // Supports are OUTSIDE the road. No decorative post occupies the dive gap.
                let supportHeight = max(0.05, Float(encounter.height) + halfHeight)
                for sign in [Float(-1), Float(1)] {
                    let post = ModelEntity(mesh: .generateBox(size: SIMD3(0.11, supportHeight, 0.16)),
                                           materials: [UnlitMaterial(color: rgb(0.30, 0.11, 0.17))])
                    post.position = SIMD3(sign * (width * 0.5 + 0.35),
                                          supportHeight * 0.5 - Float(encounter.height), 0)
                    root.addChild(post)
                }
            }
        case .boost:
            // A traversable road marking, never a solid wall or raised collision cue.
            root.position.y = Float(pose.center.y) + 0.018
            root.orientation = root.orientation * simd_quatf(angle: Float(atan(pose.slope)), axis: SIMD3<Float>(1, 0, 0))
            var chevrons = MeshBuilder()
            for step in 0..<3 {
                let z = Float(step - 1) * 0.52
                for sign in [Float(-1), Float(1)] {
                    let a = SIMD3<Float>(0, 0, z - 0.30)
                    let b = SIMD3<Float>(sign * width * 0.31, 0, z + 0.18)
                    let c = b + SIMD3<Float>(0, 0, 0.14)
                    if sign > 0 { chevrons.triangle(a, c, b) }
                    else { chevrons.triangle(a, b, c) }
                }
            }
            root.addChild(ModelEntity(mesh: try chevrons.resource(named: "TraversableBoost"),
                                     materials: [UnlitMaterial(color: cyan)]))
        }
        return root
    }

    /// Closed annular tube, open center. Local XY plane; both faces have valid outward normals.
    static func openRing(radiusX: Float, radiusY: Float, thickness: Float,
                         depth: Float, segments: Int = 64) throws -> MeshResource {
        var mesh = MeshBuilder()
        func point(_ angle: Float, outer: Bool, front: Bool) -> SIMD3<Float> {
            SIMD3(cos(angle) * (radiusX + (outer ? thickness : 0)),
                  sin(angle) * (radiusY + (outer ? thickness : 0)), front ? depth * 0.5 : -depth * 0.5)
        }
        for index in 0..<segments {
            let a = Float(index) * 2 * .pi / Float(segments)
            let b = Float(index + 1) * 2 * .pi / Float(segments)
            let infA = point(a, outer: false, front: true), infB = point(b, outer: false, front: true)
            let outfA = point(a, outer: true, front: true), outfB = point(b, outer: true, front: true)
            let inbA = point(a, outer: false, front: false), inbB = point(b, outer: false, front: false)
            let outbA = point(a, outer: true, front: false), outbB = point(b, outer: true, front: false)
            mesh.triangle(infA, outfA, outfB); mesh.triangle(infA, outfB, infB)
            mesh.triangle(inbA, outbB, outbA); mesh.triangle(inbA, inbB, outbB)
            mesh.triangle(outfA, outbA, outbB); mesh.triangle(outfA, outbB, outfB)
            mesh.triangle(infA, inbB, inbA); mesh.triangle(infA, infB, inbB)
        }
        return try mesh.resource(named: "OpenAnnularRing")
    }

    static func contactPatch() throws -> MeshResource {
        var mesh = MeshBuilder()
        for index in 0..<32 {
            let a = Float(index) * 2 * .pi / 32
            let b = Float(index + 1) * 2 * .pi / 32
            // X cross -Z is +Y: the patch is visible from above the road.
            mesh.triangle(.zero, SIMD3(cos(a) * 0.45, 0, -sin(a) * 0.85),
                          SIMD3(cos(b) * 0.45, 0, -sin(b) * 0.85))
        }
        return try mesh.resource(named: "EllipticalContactShadow")
    }

    private static func buildLandscape(course: CompiledSurfCourse, stations: [Station], parent: Entity,
                                        palette: Palette) throws {
        var low = MeshBuilder(), high = MeshBuilder()
        let strideCount = max(1, stations.count / 72)
        let sparse = stride(from: 0, to: stations.count, by: strideCount).map { stations[$0] }
        let biome = course.definition.biome
        // A load-time corridor test removes triangles spanning another bend of the route.
        // Checking projected segment/triangle intersections protects the *whole* triangle,
        // including a hairpin entering it, rather than just testing its vertices.
        func outsideRoad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Bool {
            for pair in zip(stations, stations.dropFirst()) {
                let safety = max(pair.0.width, pair.1.width) * 0.5 + 2.5
                if triangleTouchesCorridor(a, b, c, pair.0.center, pair.1.center, radius: safety) { return false }
            }
            return true
        }
        for index in sparse.indices {
            let station = sparse[index]
            for side in [Float(-1), Float(1)] {
                let phase = Float(index) * 1.71 + side * 2.4 + Float(course.definition.seed % 97)
                let radius = station.width * 0.5 + (biome == .orbit ? 13 : 18) + 7 * abs(sin(phase))
                let height: Float = biome == .midnight ? 14 + 19 * abs(cos(phase)) : 7 + 14 * abs(sin(phase * 0.7))
                let center = station.center + station.right * side * radius + SIMD3<Float>(0, biome == .orbit ? -5 : -4, 0)
                let extent: Float = biome == .midnight ? 3.5 : (biome == .orbit ? 4.5 : 12)
                let tip = center + SIMD3<Float>(side * 1.8, height, -2)
                let bottom = center - SIMD3<Float>(0, biome == .orbit ? 10 : 3, 0)
                let corners = [center + SIMD3<Float>(-extent, 0, -extent), center + SIMD3<Float>(extent, 0, -extent),
                               center + SIMD3<Float>(extent, 0, extent), center + SIMD3<Float>(-extent, 0, extent)]
                for face in 0..<4 {
                    let a = corners[face], b = corners[(face + 1) % 4]
                    if outsideRoad(a, tip, b) {
                        if face % 2 == 0 { low.triangle(a, tip, b) } else { high.triangle(a, tip, b) }
                    }
                    if biome == .orbit, outsideRoad(a, b, bottom) { high.triangle(a, b, bottom) }
                }
                if biome != .orbit, index + 1 < sparse.count {
                    let next = sparse[index + 1]
                    let a = station.center + station.right * side * (station.width * 0.5 + 2.8) - SIMD3<Float>(0, 1.8, 0)
                    let b = next.center + next.right * side * (next.width * 0.5 + 2.8) - SIMD3<Float>(0, 1.8, 0)
                    let c = center - SIMD3<Float>(0, 3, 0)
                    if outsideRoad(a, b, c) {
                        // Keep the terrain apron facing the above-road camera on both sides.
                        if side > 0 { low.triangle(a, c, b) } else { low.triangle(a, b, c) }
                    }
                }
            }
        }
        for (mesh, color, name) in [(low, palette.terrain, "FacetedTerrain"), (high, palette.peaks, "PeakFaces")] {
            if !mesh.indices.isEmpty {
                parent.addChild(ModelEntity(mesh: try mesh.resource(named: name),
                                            materials: [SimpleMaterial(color: color, roughness: 0.95, isMetallic: false)]))
            }
        }
    }

    private static func buildHorizon(course: CompiledSurfCourse, palette: Palette) throws -> Entity {
        let sky = Entity()
        sky.name = "DistantHorizon"
        let first = course.pose(at: 0)
        let forward = normalized(SIMD3(Float(first.forward.x), 0, Float(first.forward.z)), fallback: SIMD3(0, 0, -1))
        let right = simd_cross(forward, SIMD3<Float>(0, 1, 0))
        let isOrbit = course.definition.biome == .orbit
        let radius: Float = isOrbit ? 95 : (course.definition.biome == .dawn ? 40 : 19)
        let body = ModelEntity(mesh: .generateSphere(radius: radius), materials: [UnlitMaterial(color: palette.horizon)])
        body.position = forward * 650 + right * (isOrbit ? -150 : 145) + SIMD3<Float>(0, isOrbit ? 145 : 58, 0)
        sky.addChild(body)
        if isOrbit {
            let orbit = ModelEntity(mesh: try openRing(radiusX: 142, radiusY: 36, thickness: 1.4, depth: 0.5),
                                    materials: [UnlitMaterial(color: rgb(0.30, 0.65, 0.78))])
            orbit.position = body.position
            orbit.orientation = yaw(for: forward) * simd_quatf(angle: -0.32, axis: SIMD3(0, 0, 1))
            sky.addChild(orbit)
            // Fixed, sparse stars. A single mesh, no independently spinning art.
            var stars = MeshBuilder()
            for index in 0..<54 {
                let angle = Float(index) * 2.39996
                let center = SIMD3<Float>(cos(angle) * 720, 120 + Float(index % 9) * 36, sin(angle) * 720)
                let toward = normalized(-center, fallback: SIMD3(0, 0, 1))
                let across = normalized(simd_cross(toward, SIMD3(0, 1, 0)), fallback: SIMD3(1, 0, 0)) * 0.65
                let top = SIMD3<Float>(0, 0.85, 0)
                stars.triangle(center + across, center - across, center + top)
            }
            sky.addChild(ModelEntity(mesh: try stars.resource(named: "FixedStars"),
                                     materials: [UnlitMaterial(color: rgb(0.55, 0.66, 0.85))]))
        } else {
            // A broad dim light band keeps the low horizon coherent without a giant floor.
            var horizonMaterial = UnlitMaterial(color: palette.horizon)
            horizonMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.28))
            let band = ModelEntity(mesh: .generateBox(size: SIMD3(1600, 5, 2)),
                                   materials: [horizonMaterial])
            band.position = forward * 850 + SIMD3<Float>(0, -12, 0)
            band.orientation = yaw(for: forward)
            sky.addChild(band)
        }
        return sky
    }

    // 2D distance/intersection tests are used ONLY at load time to keep scenery off the road.
    private static func triangleTouchesCorridor(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                                                _ p: SIMD3<Float>, _ q: SIMD3<Float>, radius: Float) -> Bool {
        let first = SIMD2(a.x, a.z), second = SIMD2(b.x, b.z), third = SIMD2(c.x, c.z)
        let start = SIMD2(p.x, p.z), end = SIMD2(q.x, q.z)
        let minX = min(first.x, second.x, third.x) - radius, maxX = max(first.x, second.x, third.x) + radius
        let minY = min(first.y, second.y, third.y) - radius, maxY = max(first.y, second.y, third.y) + radius
        if max(start.x, end.x) < minX || min(start.x, end.x) > maxX ||
            max(start.y, end.y) < minY || min(start.y, end.y) > maxY { return false }
        func cross(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float { u.x * v.y - u.y * v.x }
        func inside(_ point: SIMD2<Float>) -> Bool {
            let one = cross(second - first, point - first)
            let two = cross(third - second, point - second)
            let three = cross(first - third, point - third)
            return (one >= 0 && two >= 0 && three >= 0) || (one <= 0 && two <= 0 && three <= 0)
        }
        func distance(_ point: SIMD2<Float>, _ x: SIMD2<Float>, _ y: SIMD2<Float>) -> Float {
            let delta = y - x
            let fraction = max(0, min(1, simd_dot(point - x, delta) / max(0.0001, simd_length_squared(delta))))
            return simd_length(point - (x + delta * fraction))
        }
        if inside(start) || inside(end) { return true }
        for index in 0..<3 {
            let x = index == 0 ? first : (index == 1 ? second : third)
            let y = index == 0 ? second : (index == 1 ? third : first)
            if min(distance(x, start, end), distance(y, start, end), distance(start, x, y), distance(end, x, y)) < radius { return true }
            let d1 = cross(end - start, x - start), d2 = cross(end - start, y - start)
            let d3 = cross(y - x, start - x), d4 = cross(y - x, end - x)
            if d1 * d2 < 0, d3 * d4 < 0 { return true }
        }
        return false
    }

    static func vector(_ value: SurfVector) -> SIMD3<Float> { SIMD3(Float(value.x), Float(value.y), Float(value.z)) }
    static func normalized(_ value: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        simd_length_squared(value) > 0.000001 ? simd_normalize(value) : fallback
    }
    static func yaw(for forward: SIMD3<Float>) -> simd_quatf {
        simd_quatf(angle: atan2(-forward.x, -forward.z), axis: SIMD3(0, 1, 0))
    }
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }
}