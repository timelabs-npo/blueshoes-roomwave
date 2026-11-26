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
                return Palette(sky: rgb(0.035, 0.045, 0.12), road: rgb(0.035, 0.105, 0.16),
                               terrain: rgb(0.035, 0.31, 0.34), peaks: rgb(0.28, 0.105, 0.39),
                               horizon: rgb(1, 0.51, 0.38))
            case .orbit:
                return Palette(sky: rgb(0.018, 0.025, 0.09), road: rgb(0.055, 0.075, 0.18),
                               terrain: rgb(0.12, 0.25, 0.42), peaks: rgb(0.34, 0.18, 0.49),
                               horizon: rgb(0.37, 0.52, 0.92))
            case .midnight:
                return Palette(sky: rgb(0.008, 0.014, 0.035), road: rgb(0.025, 0.065, 0.095),
                               terrain: rgb(0.035, 0.12, 0.16), peaks: rgb(0.10, 0.07, 0.20),
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
        var stations = try sample(course)
        if let first = stations.first {
            // A visual launch apron behind distance zero prevents the home rider
            // hanging over an exposed cut edge. The playable course is unchanged.
            let forward = normalized(simd_cross(first.normal, first.right), fallback: SIMD3(0, 0, -1))
            stations.insert(Station(distance: -16, center: first.center - forward * 16,
                                    right: first.right, normal: first.normal, width: first.width), at: 0)
        }
        try addRoadDetail(stations: stations, parent: root, palette: palette)
        // Width-relative offsets preserve the exact safe corridor at every station.
        for side in [Float(-1), Float(1)] {
            let edge = try ribbon(stations, name: "CyanEdge", low: side * 0.5 - 0.007,
                                  high: side * 0.5 + 0.007, lift: 0.025)
            root.addChild(ModelEntity(mesh: edge, materials: [UnlitMaterial(color: cyan)]))
            let halo = try ribbon(stations, name: "EdgeApron", low: side * 0.5 - 0.022,
                                  high: side * 0.5 + 0.022, lift: 0.012)
            root.addChild(ModelEntity(mesh: halo, materials: [UnlitMaterial(color: rgb(0.025, 0.28, 0.34))]))
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

    private static func addRoadDetail(stations: [Station], parent: Entity, palette: Palette) throws {
        var base = MeshBuilder(), shoulders = MeshBuilder(), panels = MeshBuilder()
        var ticks = MeshBuilder(), skirt = MeshBuilder()
        func point(_ station: Station, _ across: Float, _ lift: Float) -> SIMD3<Float> {
            station.center + station.right * station.width * across + SIMD3(0, lift, 0)
        }
        func strip(_ mesh: inout MeshBuilder, _ a: Station, _ b: Station, _ low: Float, _ high: Float) {
            // Adjacent material regions share the exact road surface. An opaque
            // raised overlay would cover the foil's 0.003 m deck; coplanar
            // overlapping layers would instead fight for depth on distant ramps.
            let al = point(a, low, 0), ar = point(a, high, 0)
            let bl = point(b, low, 0), br = point(b, high, 0)
            mesh.triangle(al, ar, bl); mesh.triangle(ar, br, bl)
        }
        for (a, b) in zip(stations, stations.dropFirst()) {
            strip(&base, a, b, -0.5, -0.48)
            strip(&base, a, b, 0.48, 0.5)
            strip(&shoulders, a, b, -0.48, -0.35)
            strip(&shoulders, a, b, 0.35, 0.48)
            if Int(floor(a.distance / 18)).isMultiple(of: 2) { strip(&panels, a, b, -0.35, 0.35) }
            else { strip(&base, a, b, -0.35, 0.35) }
            for side in [Float(-1), Float(1)] {
                let at = point(a, side * 0.5, 0), bt = point(b, side * 0.5, 0)
                let ab = at - SIMD3<Float>(0, 0.28, 0), bb = bt - SIMD3<Float>(0, 0.28, 0)
                if side > 0 { skirt.triangle(at, ab, bt); skirt.triangle(ab, bb, bt) }
                else { skirt.triangle(at, bt, ab); skirt.triangle(ab, bt, bb) }
            }
            if Int(floor(a.distance / 6)) != Int(floor(b.distance / 6)) {
                let forward = normalized(b.center - a.center, fallback: SIMD3(0, 0, -1)) * 0.18
                for side in [Float(-1), Float(1)] {
                    let left = point(b, min(side * 0.38, side * 0.46), 0.013)
                    let right = point(b, max(side * 0.38, side * 0.46), 0.013)
                    ticks.triangle(left, right, left + forward)
                    ticks.triangle(right, right + forward, left + forward)
                }
            }
        }
        let batches = [(base, palette.road, "ContinuousElevatedRibbon"),
                       (shoulders, mix(palette.road, palette.terrain, 0.20), "RibbonShoulders"),
                       (panels, mix(palette.road, palette.terrain, 0.065), "RibbonPulsePanels"),
                       (ticks, mix(palette.road, cyan, 0.22), "ShoulderCadence"),
                       (skirt, mix(palette.road, palette.sky, 0.55), "RibbonUnderside")]
        for (mesh, color, name) in batches where !mesh.indices.isEmpty {
            parent.addChild(ModelEntity(mesh: try mesh.resource(named: name), materials: [UnlitMaterial(color: color)]))
        }
    }

    private static let foilOutline: [SIMD2<Float>] = [SIMD2(0, -0.675), SIMD2(0.18, -0.48),
            SIMD2(0.275, 0.12), SIMD2(0.17, 0.59), SIMD2(0, 0.675),
            SIMD2(-0.17, 0.59), SIMD2(-0.275, 0.12), SIMD2(-0.18, -0.48)]
    private static func foilTop(_ p: SIMD2<Float>) -> SIMD3<Float> {
        SIMD3(p.x, 0.0345 + max(0, -p.y - 0.4) * 0.10, p.y)
    }

    /// Authored eight-point foil: a lifted nose, tapered tail and bevelled hull.
    /// Its footprint stays within the old 0.55 by 1.35 visual board envelope.
    static func surfboardHull() throws -> MeshResource {
        let outline = foilOutline
        var mesh = MeshBuilder()
        for index in outline.indices {
            let a = outline[index], b = outline[(index + 1) % outline.count]
            let at = foilTop(a), bt = foilTop(b)
            let ab = SIMD3<Float>(a.x * 0.79, -0.035, a.y * 0.94)
            let bb = SIMD3<Float>(b.x * 0.79, -0.035, b.y * 0.94)
            mesh.triangle(SIMD3(0, 0.035, 0), bt, at)
            mesh.triangle(SIMD3(0, -0.048, 0), ab, bb)
            mesh.triangle(at, bt, ab); mesh.triangle(bt, bb, ab)
        }
        return try mesh.resource(named: "TaperedSurfFoil")
    }

    static func surfboardRim() throws -> MeshResource {
        var mesh = MeshBuilder()
        for index in foilOutline.indices {
            let a = foilTop(foilOutline[index]), b = foilTop(foilOutline[(index + 1) % foilOutline.count])
            let outerA = SIMD3<Float>(a.x * 1.08, a.y, a.z * 1.03)
            let outerB = SIMD3<Float>(b.x * 1.08, b.y, b.z * 1.03)
            mesh.triangle(a, outerB, outerA); mesh.triangle(a, b, outerB)
        }
        return try mesh.resource(named: "FoilEnergyRim")
    }

    static func surfboardInlay() throws -> MeshResource {
        var mesh = MeshBuilder()
        func point(_ x: Float, _ z: Float) -> SIMD3<Float> {
            // Match the authored triangular deck instead of placing a flat decal
            // through its raised nose. This executes only during asset construction.
            for index in foilOutline.indices {
                let a = foilOutline[index], b = foilOutline[(index + 1) % foilOutline.count]
                let determinant = a.x * b.y - b.x * a.y
                let wa = (x * b.y - b.x * z) / determinant
                let wb = (a.x * z - x * a.y) / determinant
                let wc = 1 - wa - wb
                if min(wa, wb, wc) >= -0.0001 {
                    return SIMD3(x, foilTop(a).y * wa + foilTop(b).y * wb + 0.035 * wc + 0.001, z)
                }
            }
            return SIMD3(x, 0.036, z)
        }
        mesh.triangle(point(0, -0.48), point(-0.025, 0.34), point(0.025, 0.34))
        for side in [Float(-1), Float(1)] {
            let a = point(side * 0.06, -0.24)
            let b = point(side * 0.17, 0.23)
            let c = point(side * 0.12, 0.40)
            if side > 0 { mesh.triangle(a, c, b) } else { mesh.triangle(a, b, c) }
        }
        return try mesh.resource(named: "FoilEnergyInlay")
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
            // A thin road marking must remain below the foil rim/deck. It has no
            // collision thickness; encounter band/scoring are unchanged.
            root.position.y = Float(pose.center.y) + 0.0005
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
        var facets = [MeshBuilder(), MeshBuilder(), MeshBuilder(), MeshBuilder()]
        let strideCount = max(1, stations.count / 64)
        let sparse = stride(from: 0, to: stations.count, by: strideCount).map { stations[$0] }
        let biome = course.definition.biome
        // Original spans are linear, exactly like the dense visual sampler. Using
        // their maximum endpoint width keeps the same conservative corridor while
        // avoiding a dense-sample scan for every new decorative facet.
        var corridor = course.definition.samples.map { (center: vector($0.center), width: Float($0.width)) }
        if let first = stations.first, first.distance < 0 {
            corridor.insert((center: first.center, width: first.width), at: 0)
        }
        func outsideRoad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Bool {
            for pair in zip(corridor, corridor.dropFirst()) {
                let safety = max(pair.0.width, pair.1.width) * 0.5 + 2.5
                if triangleTouchesCorridor(a, b, c, pair.0.center, pair.1.center, radius: safety) { return false }
            }
            return true
        }
        func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, shade: Int) {
            if outsideRoad(a, b, c) { facets[shade % 4].triangle(a, b, c) }
        }
        for index in sparse.indices {
            let station = sparse[index]
            let forward = normalized(simd_cross(station.normal, station.right), fallback: SIMD3(0, 0, -1))
            for side in [Float(-1), Float(1)] {
                let phase = Float(index) * 2.173 + side * 3.7 + Float(course.definition.seed % 97)
                let variation = abs(sin(phase))
                let height: Float = biome == .midnight ? 12 + 20 * variation : 6 + 19 * variation
                let extentX: Float = biome == .dawn ? 5 + 9 * abs(cos(phase * 0.8)) : 2.4 + 4 * abs(cos(phase))
                let extentZ: Float = biome == .dawn ? 6 + 10 * abs(sin(phase * 0.6)) : 3 + 5 * variation
                let radius = station.width * 0.5 + 4.8 + extentX + 6 * abs(sin(phase * 1.3))
                let center = station.center + station.right * side * radius + forward * (sin(phase) * 7) +
                    SIMD3<Float>(0, biome == .orbit ? -3 : -4, 0)
                let lean = station.right * (side * height * 0.13) + forward * (cos(phase) * 3)
                let crownRadius: Float = index % 5 == 0 && biome == .dawn ? 0.30 : 0.035
                var base: [SIMD3<Float>] = [], shoulder: [SIMD3<Float>] = [], crown: [SIMD3<Float>] = []
                for corner in 0..<6 {
                    let angle = Float(corner) * (.pi / 3) + phase * 0.13
                    let uneven = 0.77 + 0.23 * abs(sin(phase + Float(corner) * 1.91))
                    let radial = station.right * (cos(angle) * extentX * uneven) + forward * (sin(angle) * extentZ)
                    base.append(center + radial)
                    shoulder.append(center + radial * (0.48 + 0.12 * sin(angle + phase)) + lean * 0.38 +
                                    SIMD3<Float>(0, height * (0.43 + 0.13 * sin(angle * 2 + phase)), 0))
                    crown.append(center + radial * crownRadius + lean + SIMD3<Float>(0, height, 0))
                }
                let summit = center + lean + SIMD3<Float>(0, height + (crownRadius < 0.1 ? 0.8 : 0), 0)
                for face in 0..<6 {
                    let next = (face + 1) % 6
                    let shade = (face + index) % 4
                    add(base[face], base[next], shoulder[face], shade: shade)
                    add(base[next], shoulder[next], shoulder[face], shade: (shade + 1) % 4)
                    add(shoulder[face], shoulder[next], crown[face], shade: shade)
                    add(shoulder[next], crown[next], crown[face], shade: (shade + 3) % 4)
                    add(crown[face], crown[next], summit, shade: 1)
                    if biome == .orbit {
                        let lowerTip = center - lean * 0.6 - SIMD3<Float>(0, 6 + height * 0.35, 0)
                        add(base[face], lowerTip, base[next], shade: (shade + 2) % 4)
                    }
                }
                if biome != .orbit, index + 1 < sparse.count {
                    // Joined terraces replace disconnected triangular apron wedges.
                    let next = sparse[index + 1]
                    let a = station.center + station.right * side * (station.width * 0.5 + 2.8) - SIMD3<Float>(0, 1.8, 0)
                    let b = next.center + next.right * side * (next.width * 0.5 + 2.8) - SIMD3<Float>(0, 1.8, 0)
                    let c = station.center + station.right * side * (station.width * 0.5 + 29) - SIMD3<Float>(0, 3.5, 0)
                    let d = next.center + next.right * side * (next.width * 0.5 + 29) - SIMD3<Float>(0, 3.5, 0)
                    if side > 0 { add(a, c, b, shade: 3); add(b, c, d, shade: 0) }
                    else { add(a, b, c, shade: 3); add(b, d, c, shade: 0) }
                }
            }
        }
        let colors = [palette.terrain, mix(palette.terrain, palette.horizon, 0.16),
                      palette.peaks, mix(palette.peaks, palette.sky, 0.48)]
        for index in facets.indices where !facets[index].indices.isEmpty {
            parent.addChild(ModelEntity(mesh: try facets[index].resource(named: "LandscapeFacets_\(index)"),
                                        materials: [UnlitMaterial(color: colors[index])]))
        }
    }

    private static func buildHorizon(course: CompiledSurfCourse, palette: Palette) throws -> Entity {
        let sky = Entity()
        sky.name = "DistantHorizon"
        let first = course.pose(at: 0)
        let forward = normalized(SIMD3(Float(first.forward.x), 0, Float(first.forward.z)), fallback: SIMD3(0, 0, -1))
        let right = simd_cross(forward, SIMD3<Float>(0, 1, 0))
        let isOrbit = course.definition.biome == .orbit
        // Three distant silhouettes give atmospheric depth through deliberate
        // value/color separation. These are batched geometry, not simulated fog.
        for layer in 0..<3 {
            var ridge = MeshBuilder()
            let distance: Float = 1080 - Float(layer) * 120
            let baseY: Float = -145 + Float(layer) * 14
            for index in 0..<24 {
                let x = Float(index - 12) * 85
                let phase = Float(index) * 1.37 + Float(layer) * 2.6
                let height: Float = 10 + Float(layer) * 10 + 65 * abs(sin(phase))
                let a = forward * distance + right * x + SIMD3<Float>(0, baseY, 0)
                let b = forward * distance + right * (x + 100) + SIMD3<Float>(0, baseY, 0)
                let peak = forward * distance + right * (x + 28 + 35 * abs(cos(phase))) + SIMD3<Float>(0, height, 0)
                ridge.triangle(a, b, peak)
            }
            let tint = layer == 0 ? mix(palette.sky, palette.horizon, 0.13) :
                mix(palette.sky, layer == 1 ? palette.peaks : palette.terrain, layer == 1 ? 0.27 : 0.37)
            sky.addChild(ModelEntity(mesh: try ridge.resource(named: "AtmosphericRidge_\(layer)"),
                                     materials: [UnlitMaterial(color: tint)]))
        }
        let radius: Float = isOrbit ? 74 : (course.definition.biome == .dawn ? 44 : 22)
        let body = ModelEntity(mesh: .generateSphere(radius: radius), materials: [UnlitMaterial(color: palette.horizon)])
        // Keep the planet/sun inside the repaired portrait camera's field instead
        // of cropping most of the landmark above the status bar or side edge.
        body.position = forward * 1150 + right * (isOrbit ? -145 : 145) + SIMD3<Float>(0, isOrbit ? 18 : 24, 0)
        sky.addChild(body)
        if isOrbit {
            let orbit = ModelEntity(mesh: try openRing(radiusX: 108, radiusY: 28, thickness: 1.4, depth: 0.5),
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
    static func mix(_ a: UIColor, _ b: UIColor, _ amount: CGFloat) -> UIColor {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let t = min(1, max(0, amount))
        return rgb(ar + (br - ar) * t, ag + (bg - ag) * t, ab + (bb - ab) * t)
    }
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }
}
