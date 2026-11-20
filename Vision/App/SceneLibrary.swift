import Foundation
import ImageIO
import Metal
import MetalSplatter
import SplatIO
import simd

struct PhotoScene: Decodable, Identifiable, Hashable, Sendable {
    let id, title, photo, model, propTitle, sourcePhoto: String
    let pointBudget: Int?
    let prop: String?
    let titleEN, propTitleEN: String?
    func label(_ language: AppLanguage) -> String { language.text(title, titleEN ?? title) }
    func propLabel(_ language: AppLanguage) -> String { language.text(propTitle, propTitleEN ?? propTitle) }
    func menuTitle(_ language: AppLanguage) -> String { label(language) }
    var usesLeafBed: Bool { id == "00-autumn" }

    static var directory: URL { Bundle.main.resourceURL!.appendingPathComponent("SceneAssets") }
    static let all: [PhotoScene] = (try? JSONDecoder().decode([PhotoScene].self,
        from: Data(contentsOf: directory.appendingPathComponent("Scenes.json")))) ?? []
    var photoURL: URL { Self.directory.appendingPathComponent(photo) }

    func cover(maxSize: Int) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSize
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        return image
    }

    func load(includeProps: Bool, layout: LeafLayout, density: Double, leafWidth: Double,
              colors: PhotoColors) async throws -> (points: [SplatPoint], samples: [SIMD3<Float>]) {
        func readFile(_ relative: String) async throws -> [SplatPoint] {
            let reader = try AutodetectSceneReader(Self.directory.appendingPathComponent(relative))
            var result = [SplatPoint]()
            for try await batch in try await reader.read() {
                try Task.checkCancellation()
                result.append(contentsOf: batch.filter {
                    $0.position.z > 0.32 && $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite
                })
            }
            guard !result.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            return result
        }
        var points = try await readFile(model)
        let budget = max(1, pointBudget ?? CFG.worldPointBudget)
        if points.count > budget {
            let count = points.count
            points = (0..<budget).map { points[($0 * count + count / 2) / budget] }
        }
        if includeProps {
            if let prop {
                points += try await readFile(prop)
            } else if usesLeafBed {
                points += try LeafBed.points(preset: Self.directory.appendingPathComponent("LeafPreset.json"),
                    samples: Self.directory.appendingPathComponent("LeafSamples.json"), colors: colors,
                    layout: layout, density: density, width: leafWidth)
            }
        }
        let stride = max(1, points.count / 2048)
        return (points, Swift.stride(from: 0, to: points.count, by: stride).map { points[$0].position })
    }
}

enum PlacementAxis: String {
    case height = "heightCM"
    case depth = "depthCM"

    static let range = -300.0...300.0
    static let file = "Placement.json"
    static let presets = (try? JSONDecoder().decode([String: [String: Double]].self,
        from: Data(contentsOf: PhotoScene.directory.appendingPathComponent(file)))) ?? [:]
    private static let legacyHeights = (try? JSONDecoder().decode([String: Double].self,
        from: Data(contentsOf: PhotoScene.directory.appendingPathComponent("Heights.json")))) ?? [:]

    func value(for id: String) -> Double {
        let saved = UserDefaults.standard.object(forKey: rawValue + "." + id) as? NSNumber
        let fallback = self == .height ? Self.legacyHeights[id] : nil
        let cm = saved?.doubleValue ?? Self.presets[id]?[rawValue] ?? fallback ?? 0
        return cm.isFinite ? min(Self.range.upperBound, max(Self.range.lowerBound, cm)) : 0
    }

    func save(_ cm: Double, for id: String) {
        UserDefaults.standard.set(cm.rounded(), forKey: rawValue + "." + id)
    }

    func restore(_ id: String) -> Double {
        UserDefaults.standard.removeObject(forKey: rawValue + "." + id)
        return value(for: id)
    }
}

extension Reveal {
    func effect(at now: Double, offset: SIMD3<Float>) -> SplatRenderer.RevealEffect {
        let relative = finalModel.inverse * SIMD4(offset, 0)
        return .init(progress: progress(now), frontWidth: 0.27, seedRadius: 0.013,
                     origin: localSeed - relative.xyz, style: 5, radius: radius)
    }
}

extension SplatRenderer {
    /// addChunk installs drawable indices synchronously with insertion. The camera sort refines
    /// their order in the background and may complete before the first frame is requested.
    func prepareScene(_ points: [SplatPoint], device: MTLDevice) async throws {
        try Task.checkCancellation()
        try await addChunk(SplatChunk(device: device, from: points))
        try Task.checkCancellation()
        guard !points.isEmpty, renderableSplatCount == points.count else {
            let description = AppLanguage.current.text("无法准备场景的高斯索引。", "Could not prepare the scene’s Gaussian indices.")
            throw NSError(domain: "PinchDrop.SceneLoading", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
        }
    }
}
