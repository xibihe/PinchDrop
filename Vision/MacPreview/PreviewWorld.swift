import Foundation
import Metal
import MetalSplatter
import simd

struct PreviewWorld {
    let renderer: SplatRenderer
    let release: Reveal
    static let background = MTLClearColor(red: 0.032, green: 0.035, blue: 0.040, alpha: 1)

    init(scene: PhotoScene, props: Bool, device: MTLDevice) async throws {
        let image = try scene.cover(maxSize: 600)
        guard let colors = PhotoColors(image: image) else { throw CocoaError(.fileReadCorruptFile) }
        let (points, samples) = try await scene.load(includeProps: props, layout: .accent, density: 1,
                                                      leafWidth: 1, colors: colors)
        let splats = try SplatRenderer(device: device, colorFormat: .bgra8Unorm_srgb, depthFormat: .depth32Float,
            sampleCount: 1, maxViewCount: 1, maxSimultaneousRenders: 2, highQualityDepth: true, clearColor: Self.background)
        try await splats.prepareScene(points, device: device)
        renderer = splats
        release = Reveal(seed: [0.12, -0.18, -0.46], head: matrix_identity_float4x4, points: samples, now: 0)
    }

    func draw(to texture: MTLTexture, depth: MTLTexture, at elapsed: Double, heightCM: Double, depthCM: Double = 0,
              command: MTLCommandBuffer, timeout: CFTimeInterval = 0) throws -> Bool {
        let w = texture.width, h = texture.height
        let f: Float = 1.14 * min(1, Float(w) / Float(h) / 1.36)
        let projection = simd_float4x4(SIMD4(f * Float(h) / Float(w),0,0,0), SIMD4(0,f,0,0),
                                       SIMD4(0,0,0,-1), SIMD4(0,0,0.025,0))
        let offset = release.placementOffset(height: Float(heightCM) / 100, depth: Float(depthCM) / 100)
        let vp = SplatRenderer.ViewportDescriptor(viewport: MTLViewport(originX: 0, originY: 0,
            width: Double(w), height: Double(h), znear: 0, zfar: 1), projectionMatrix: projection,
            viewMatrix: release.model(elapsed, offset: offset), screenSize: SIMD2(w,h))
        return try renderer.render(viewports: [vp], colorTexture: texture, colorStoreAction: .store,
            depthTexture: depth, rasterizationRateMap: nil, renderTargetArrayLength: 1,
            revealEffect: release.effect(at: elapsed, offset: offset),
            accessTimeout: timeout, sortTimeout: timeout, to: command)
    }
}
