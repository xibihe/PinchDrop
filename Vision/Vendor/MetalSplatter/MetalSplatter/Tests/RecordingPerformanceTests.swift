import XCTest
import Foundation
import Metal
import SplatIO
import simd
import Synchronization
import QuartzCore
import ImageIO
import UniformTypeIdentifiers
@testable import MetalSplatter

// Manual GPU benchmark of the real scene. Opt in explicitly; normal unit runs skip it.
final class RecordingPerformanceTests: XCTestCase {
    func testCenterHeadMotionRenderCost() async throws {
        guard ProcessInfo.processInfo.environment["GB_RECORD_BENCHMARK"] == "1" ||
              ProcessInfo.processInfo.environment["TEST_RUNNER_GB_RECORD_BENCHMARK"] == "1" else {
            throw XCTSkip("Set GB_RECORD_BENCHMARK=1 for the scene recording benchmark")
        }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let output = root.appending(path: "build/recording-investigation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let asset = root.appending(path: "GaussianBreathVision/SceneAssets/subway_overgrown_with_flowers.spz")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let reader = try AutodetectSceneReader(asset)
        var points = [SplatPoint]()
        for try await batch in try await reader.read() { points.append(contentsOf: batch) }
        print("GB_BENCH: loaded \(points.count) splats on \(device.name)")
        let chunk = try SplatChunk(device: device, from: points)
        points.removeAll()
        let width = 1280, height = 720
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
            width: width, height: height, mipmapped: false)
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .private
        let color = try XCTUnwrap(device.makeTexture(descriptor: colorDescriptor))
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
            width: width, height: height, mipmapped: false)
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        let depth = try XCTUnwrap(device.makeTexture(descriptor: depthDescriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try SplatRenderer(device: device, colorFormat: .bgra8Unorm_srgb,
            depthFormat: .depth32Float, sampleCount: 1, maxViewCount: 1,
            maxSimultaneousRenders: 8, highQualityDepth: true)
        let sorts = Mutex([Double]())
        let sorted = Mutex(false)
        renderer.onSortComplete = { duration in
            sorts.withLock { $0.append(duration) }
            sorted.withLock { $0 = true }
        }
        await renderer.addChunk(chunk)
        while !sorted.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(2)) }
        let f: Float = 1 / tan(90 * .pi / 360)
        let projection = simd_float4x4(columns: (
            SIMD4(f / (Float(width) / Float(height)), 0, 0, 0),
            SIMD4(0, f, 0, 0), SIMD4(0, 0, 0, -1), SIMD4(0, 0, 0.02, 0)))
        let label = ProcessInfo.processInfo.environment["GB_BENCH_LABEL"] ??
            ProcessInfo.processInfo.environment["TEST_RUNNER_GB_BENCH_LABEL"] ?? "run"
        let duty = Double(ProcessInfo.processInfo.environment["GB_BENCH_SORT_DUTY"] ??
            ProcessInfo.processInfo.environment["TEST_RUNNER_GB_BENCH_SORT_DUTY"] ?? "1") ?? 1
        var csv = "case,frame,yaw_degrees,cpu_encode_ms,gpu_ms,sorts_completed\n"
        for motion in ["still", "slow", "fast"] {
            var gpuTimes = [Double](), cpuTimes = [Double]()
            let start = CACurrentMediaTime()
            for frame in 0..<96 {
                let t = Float(frame) / 90
                let angle: Float = motion == "still" ? 0 :
                    (motion == "slow" ? 0.35 * sin(t * 2 * .pi * 0.6) : sin(t * 2 * .pi * 2.5))
                var camera = simd_float4x4(simd_quatf(angle: angle, axis: SIMD3(0, 1, 0)))
                // Neck rotation produces a small real camera translation as well as rotation.
                camera.columns.3 = SIMD4(0.06 * sin(angle), -2.65, 0.06 * (cos(angle) - 1), 1)
                let viewport = SplatRenderer.ViewportDescriptor(
                    viewport: MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1),
                    projectionMatrix: projection, viewMatrix: camera.inverse,
                    screenSize: SIMD2(width, height))
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                let encodeStart = CACurrentMediaTime()
                XCTAssertTrue(try renderer.render(viewports: [viewport], colorTexture: color,
                    colorStoreAction: .store, depthTexture: depth, rasterizationRateMap: nil,
                    renderTargetArrayLength: 1, sortWorkFraction: duty, to: command))
                let cpu = (CACurrentMediaTime() - encodeStart) * 1000
                await withCheckedContinuation { continuation in
                    command.addCompletedHandler { _ in continuation.resume() }
                    command.commit()
                }
                XCTAssertNil(command.error)
                let gpu = (command.gpuEndTime - command.gpuStartTime) * 1000
                if frame >= 6 { gpuTimes.append(gpu); cpuTimes.append(cpu) }
                let count = sorts.withLock { $0.count }
                csv += "\(motion),\(frame),\(angle * 180 / .pi),\(cpu),\(gpu),\(count)\n"
                if frame == 48 {
                    let readback = try XCTUnwrap(device.makeBuffer(length: width * height * 4, options: .storageModeShared))
                    let copy = try XCTUnwrap(queue.makeCommandBuffer())
                    let encoder = try XCTUnwrap(copy.makeBlitCommandEncoder())
                    encoder.copy(from: color, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                        sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback,
                        destinationOffset: 0, destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
                    encoder.endEncoding()
                    await withCheckedContinuation { continuation in
                        copy.addCompletedHandler { _ in continuation.resume() }
                        copy.commit()
                    }
                    let data = Data(bytes: readback.contents(), count: width * height * 4)
                    let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
                    let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
                        bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
                    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
                        output.appending(path: "\(label)-\(motion).png") as CFURL, UTType.png.identifier as CFString, 1, nil))
                    CGImageDestinationAddImage(destination, image, nil)
                    XCTAssertTrue(CGImageDestinationFinalize(destination))
                }
                let remaining = Double(frame + 1) / 90 - (CACurrentMediaTime() - start)
                if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            }
            let sortedGPU = gpuTimes.sorted()
            print("GB_BENCH \(label) \(motion): GPU mean=\(gpuTimes.reduce(0,+)/Double(gpuTimes.count)) ms p95=\(sortedGPU[Int(Double(sortedGPU.count-1)*0.95)]) ms max=\(sortedGPU.last!) ms CPU mean=\(cpuTimes.reduce(0,+)/Double(cpuTimes.count)) ms")
        }
        try csv.write(to: output.appending(path: "\(label)-frames.csv"), atomically: true, encoding: .utf8)
        print("GB_BENCH sorts: \(sorts.withLock { $0 })")
        await renderer.removeAllChunks()
    }
}
