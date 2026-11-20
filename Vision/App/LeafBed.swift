import Foundation
import SplatIO
import simd

enum LeafLayout: String, CaseIterable, Codable, Sendable {
    case accent, foreground, chair, both, none

    func label(_ lang: AppLanguage) -> String {
        switch self {
        case .accent: lang.text("边缘几片", "Along the edge")
        case .foreground: lang.text("前景两侧", "Foreground edges")
        case .chair: lang.text("椅子周围", "Around the chair")
        case .both: lang.text("两处都铺", "Both areas")
        case .none: lang.text("关闭", "Off")
        }
    }
}

struct LeafBed: Decodable {
    private struct Patch: Decodable {
        let zone: LeafLayout
        let center, radii: SIMD2<Float>
        let count: Int
        let groundOffset: Float
    }
    private let groundY: SIMD3<Float> // RDF：截距、左右坡度、前后坡度。
    private let patches: [Patch]

    static func points(preset: URL, samples: URL, colors: PhotoColors,
                       layout: LeafLayout, density: Double, width: Double) throws -> [SplatPoint] {
        guard layout != .none, density > 0 else { return [] }
        let decoder = JSONDecoder()
        let bed = try decoder.decode(LeafBed.self, from: Data(contentsOf: preset))
        let texels = try decoder.decode([[Float]].self, from: Data(contentsOf: samples))
        let leaf = texels.compactMap { row -> (position: SIMD3<Float>, color: SIMD3<Float>)? in
            guard row.count == 6, row.allSatisfy(\.isFinite) else { return nil }
            return (SIMD3(row[0], row[1], row[2]), SIMD3(row[3], row[4], row[5]))
        }
        guard !leaf.isEmpty else { throw CocoaError(.fileReadCorruptFile) }

        var random: UInt64 = 0x253D_173A
        func unit() -> Float {
            random = random &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            return Float((random >> 40) & 0xff_ffff) / 16_777_216
        }
        var result = [SplatPoint]()
        let normal = simd_normalize(SIMD3(-bed.groundY.y, 1, -bed.groundY.z))
        let tilt = simd_quatf(from: [0, 1, 0], to: normal)
        for (patchIndex, patch) in bed.patches.enumerated() where patch.zone == layout || (layout == .both && patch.zone != .accent) {
            random = 0x253D_173A &+ UInt64(patchIndex) &* 0x12D7
            let baseCount = min(160, max(0, patch.count))
            let count = layout == .accent ? baseCount : Int((Double(baseCount) * min(1.65, density)).rounded())
            for index in 0..<count {
                // 同一种子下，切换铺设区不会重新打乱另一块区域。
                let bearing = unit() * 2 * Float.pi
                let distance = pow(unit(), 0.65)
                let x = patch.center.x + cos(bearing) * distance * patch.radii.x
                let z = patch.center.y + sin(bearing) * distance * patch.radii.y
                let yaw = simd_quatf(angle: unit() * 2 * Float.pi, axis: [0, 1, 0])
                let scale = (layout == .accent ? 0.78 : Float(min(1.6, max(0.55, width)))) * (0.65 + 0.62 * unit())
                let floor = bed.groundY.x + bed.groundY.y * x + bed.groundY.z * z + patch.groundOffset
                // 在同一照片位置读取明暗，让阴影里的叶子随地面压暗。
                let source = colors.sample(0.5 + 0.91 * x / z, 0.5 + 0.91 * floor / z)
                let ground = SIMD3(Float(source & 255), Float((source >> 8) & 255), Float((source >> 16) & 255))
                let luma = simd_dot(ground, [0.2126, 0.7152, 0.0722]) / 255
                let light = (0.58 + 0.42 * unit()) * min(0.94, 0.38 + 0.99 * luma)
                let amber = 0.84 + 0.20 * unit()
                let ambient = ground * 0.14
                let origin = SIMD3(x, floor - 0.009 - 0.0035 * Float(index % 3), z)
                for sample in leaf {
                    // GML1 的 Y 是叶片厚度；SOG 的 Y 向下。
                    let local = SIMD3(sample.position.x, -sample.position.y, sample.position.z)
                    let albedo = sample.color * SIMD3(light, light * amber, light * 0.78) + ambient
                    let color = SIMD3<UInt8>(UInt8(clamping: Int(albedo.x)),
                                             UInt8(clamping: Int(albedo.y)),
                                             UInt8(clamping: Int(albedo.z)))
                    result.append(SplatPoint(position: origin + tilt.act(yaw.act(local * scale)),
                                             color: .sRGBUInt8(color), opacity: .linearFloat(0.87),
                                             scale: .linearFloat(SIMD3(0.00235, 0.0008, 0.00235) * scale),
                                             rotation: tilt))
                }
            }
        }
        return result
    }
}
