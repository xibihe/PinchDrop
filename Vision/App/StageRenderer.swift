// CompositorServices frame lifecycle adapted from the MIT-licensed MetalSplatter sample.
import ARKit
import CompositorServices
import ImageIO
import Metal
import MetalSplatter
import OSLog
import QuartzCore
import SplatIO
import SwiftUI
import Synchronization
import simd

struct StageConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.colorFormat = .bgra8Unorm_srgb
        configuration.depthFormat = .depth32Float
        configuration.isFoveationEnabled = capabilities.supportsFoveation
        if capabilities.supportsFoveation {
            configuration.maxRenderQuality = .init(CFG.renderQuality)
        }
        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions =
            capabilities.supportsFoveation ? [.foveationEnabled] : []
        configuration.layout = capabilities.supportedLayouts(options: options).contains(.layered)
            ? .layered : .dedicated
    }
}

final class StageRenderer: @unchecked Sendable {
    private struct World {
        let readyMessage: String
        let renderer: SplatRenderer
        let samples: [SIMD3<Float>]
    }

    private struct Eye {
        let vp: simd_float4x4
        let right, up, pixelScale: SIMD4<Float>
    }

    private static let log = Logger(subsystem: "art.xibihe.PinchDrop", category: "SceneStartup")
    private let lang = AppLanguage.current
    private let layer: LayerRenderer
    private let control: StageControl
    private let queue: MTLCommandQueue
    private let glowPipeline: MTLRenderPipelineState
    private let surfacePipeline: MTLRenderPipelineState
    private let glowDepth: MTLDepthStencilState
    private let glowVertices: MTLBuffer
    private let gate = RenderInFlightGate()
    private let session = ARKitSession()
    private let head = WorldTrackingProvider()
    private let hands = HandTrackingProvider()
    private let world = Mutex<World?>(nil)
    private struct InteractionTracking {
        var handsAvailable = false
        var image: ImageTrackingProvider?
    }
    private let interaction = Mutex<InteractionTracking?>(nil)
    private var interactionTask: Task<Void, Never>?
    private var imageProvider: ImageTrackingProvider? { interaction.withLock { $0?.image } }
    private var photoTracking = PhotoTracking()
    private var handEnabled: Bool { interaction.withLock { $0?.handsAvailable == true } }
    private let scene: PhotoScene
    private var preview: Reveal?
    private var actionRevision = 0
    private let width: Float
    private let cover: CGImage
    private let photoColors: PhotoColors
    private var dance: Choreography
    private var calibrationAt: Double?
    private var manualPhone: PhonePose?
    private let transparent = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

    private init(_ layer: LayerRenderer, _ control: StageControl) throws {
        self.layer = layer
        self.control = control
        width = Float(control.state.withLock { $0.widthMM }) / 1000
        let selectedID = control.state.withLock { $0.sceneID }
        guard let selected = PhotoScene.all.first(where: { $0.id == selectedID }) else { throw StageError.asset }
        scene = selected
        let image = try selected.cover(maxSize: 1600)
        guard let colors = PhotoColors(image: image) else { throw StageError.photo }
        cover = image
        photoColors = colors
        dance = Choreography(colors: colors)

        let device = layer.device
        guard let commands = device.makeCommandQueue(),
              let vertices = device.makeBuffer(length: CFG.maxParticles * MemoryLayout<Glow>.stride,
                                               options: .storageModeShared),
              let lib = device.makeDefaultLibrary(),
              let vert = lib.makeFunction(name: "glowVertex"),
              let frag = lib.makeFunction(name: "glowFragment"),
              let surfaceVert = lib.makeFunction(name: "surfaceVertex"),
              let surfaceFrag = lib.makeFunction(name: "surfaceFragment") else {
            throw StageError.pipeline
        }
        queue = commands
        glowVertices = vertices
        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.vertexFunction = vert
        pipeline.fragmentFunction = frag
        pipeline.maxVertexAmplificationCount = layer.properties.viewCount
        let color = pipeline.colorAttachments[0]!
        color.pixelFormat = layer.configuration.colorFormat
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline.depthAttachmentPixelFormat = layer.configuration.depthFormat
        glowPipeline = try device.makeRenderPipelineState(descriptor: pipeline)
        pipeline.vertexFunction = surfaceVert
        pipeline.fragmentFunction = surfaceFrag
        surfacePipeline = try device.makeRenderPipelineState(descriptor: pipeline)
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .greaterEqual // CompositorServices 反向 Z。
        depth.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: depth) else {
            throw StageError.pipeline
        }
        glowDepth = state
    }

    static func start(_ layer: LayerRenderer, control: StageControl) {
        // The compositor hands this layer to its own render executor exactly once.
        nonisolated(unsafe) let renderLayer = layer
        Task.detached(executorPreference: StageExecutor(), priority: .userInitiated) {
            do {
                log.info("Opening immersive session \(control.id, privacy: .public)")
                let stage = try StageRenderer(renderLayer, control)
                await stage.run()
                control.state.withLock { $0.closed = true }
            } catch {
                log.error("Renderer setup failed: \(error.localizedDescription, privacy: .public)")
                control.fail(error.localizedDescription)
            }
        }
    }

    private func startInteractionTracking() {
        guard interactionTask == nil else { return }
        interactionTask = Task.detached(priority: .userInitiated) {
            do { try await self.enableInteractionTracking() }
            catch is CancellationError { }
            catch { self.control.fail(self.lang.text("互动追踪启动失败：\(error.localizedDescription)", "Interaction tracking failed: \(error.localizedDescription)")) }
        }
    }

    private func enableInteractionTracking() async throws {
        let supportsHands = HandTrackingProvider.isSupported
        let supportsImage = ImageTrackingProvider.isSupported
        let requests: [ARKitSession.AuthorizationType] =
            (supportsHands ? [.handTracking] : []) + (supportsImage ? [.worldSensing] : [])
        let permissions = requests.isEmpty ? [:] : await session.requestAuthorization(for: requests)
        try Task.checkCancellation()
        guard !stopping else { return }
        let handEnabled = supportsHands && permissions[.handTracking] == .allowed
        var providers: [any DataProvider] = [head]
        if handEnabled { providers.append(hands) }

        var imageProvider: ImageTrackingProvider?
        if supportsImage, permissions[.worldSensing] == .allowed {
            var reference = ReferenceImage(cgimage: cover, physicalSize: CGSize(
                width: Double(width), height: Double(width) * Double(cover.height) / Double(cover.width)),
                orientation: .up)
            reference.name = scene.id
            imageProvider = ImageTrackingProvider(referenceImages: [reference])
        }

        if let imageProvider { providers.append(imageProvider) }
        if providers.count > 1 { try await session.run(providers) }
        try Task.checkCancellation()
        interaction.withLock { $0 = InteractionTracking(handsAvailable: handEnabled, image: imageProvider) }
    }

    private var stopping: Bool {
        control.state.withLock { $0.stopRequested || $0.closed } || layer.state == .invalidated
    }

    private func run() async {
        guard !stopping else { return }
        if layer.configuration.isFoveationEnabled { layer.renderQuality = .init(CFG.renderQuality) }
        let loading = Task.detached(priority: .userInitiated) {
            do { try await self.load() }
            catch is CancellationError { }
            catch { self.control.fail(self.lang.text("场景加载失败：\(error.localizedDescription)", "Could not load the scene: \(error.localizedDescription)")) }
        }
        defer {
            loading.cancel()
            interactionTask?.cancel()
            session.stop()
        }
        do { try await session.run([head]) }
        catch {
            control.fail(lang.text("头部追踪启动失败：\(error.localizedDescription)", "Head tracking failed: \(error.localizedDescription)"))
            return
        }
        while !stopping {
            if layer.state == .running {
                if control.state.withLock({ $0.action != .preview }) { startInteractionTracking() }
                autoreleasepool { frame() }
            } else {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func load() async throws {
        let settings = control.state.withLock { $0 }
        let (points, samples) = try await scene.load(includeProps: settings.includeProps, layout: settings.leafLayout,
            density: settings.leafDensity, leafWidth: settings.leafWidth, colors: photoColors)

        let renderer = try SplatRenderer(device: layer.device, colorFormat: layer.configuration.colorFormat,
            depthFormat: layer.configuration.depthFormat, sampleCount: 1, maxViewCount: layer.properties.viewCount,
            maxSimultaneousRenders: 8, highQualityDepth: true, clearColor: transparent)
        try await renderer.prepareScene(points, device: layer.device)
        try Task.checkCancellation()
        Self.log.info("Prepared \(points.count) Gaussians for session \(self.control.id, privacy: .public)")
        let ready = lang.text("已加载 · \(scene.title) · \(points.count.formatted()) 个高斯", "Loaded · \(scene.label(.english)) · \(points.count.formatted()) Gaussians")
        control.state.withLock {
            guard !$0.closed, !$0.stopRequested else { return }
            $0.message = self.lang.text("模型就绪，等待头显定位和首帧…", "Model ready. Waiting for head tracking and the first frame…")
        }
        world.withLock { $0 = World(readyMessage: ready, renderer: renderer, samples: samples) }
    }

    private func pinch(at timestamp: Double) -> PinchSample? {
        guard handEnabled, hands.state == .running,
              let right = hands.handAnchors(at: timestamp).rightHand, right.isTracked,
              let skeleton = right.handSkeleton else { return nil }
        let thumb = skeleton.joint(.thumbTip)
        let index = skeleton.joint(.indexFingerTip)
        func position(_ joint: HandSkeleton.Joint) -> SIMD3<Float> {
            (right.originFromAnchorTransform * joint.anchorFromJointTransform).columns.3.xyz
        }
        let wrist = skeleton.joint(.wrist)
        let middle = skeleton.joint(.middleFingerKnuckle)
        let radial = skeleton.joint(.indexFingerKnuckle)
        let ulnar = skeleton.joint(.littleFingerKnuckle)
        var palm: PalmPose?
        if wrist.isTracked, middle.isTracked, radial.isTracked, ulnar.isTracked {
            let wristPoint = position(wrist)
            let along = position(middle) - wristPoint
            let normal = simd_cross(position(radial) - position(ulnar), along)
            if simd_length_squared(normal) > 1e-8 {
                let outward = simd_normalize(normal)
                palm = PalmPose(center: wristPoint + along * 0.57 + outward * 0.021, normal: outward)
            }
        }
        if thumb.isTracked, index.isTracked {
            let a = position(thumb)
            let b = position(index)
            return PinchSample(center: (a + b) / 2, tip: b, gap: simd_distance(a, b), palm: palm)
        }
        guard let palm else { return nil }
        return PinchSample(center: palm.center, tip: palm.center, gap: nil, palm: palm)
    }

    private func trackedPhone(at now: Double, head: SIMD3<Float>) -> PhonePose? {
        guard let imageProvider, imageProvider.state == .running else {
            photoTracking.clear()
            return nil
        }
        let candidates = imageProvider.allAnchors.filter { $0.isTracked && $0.referenceImage.name == scene.id }
        let current = candidates.first { $0.id == photoTracking.anchorID }
        guard let anchor = current ?? (candidates.count == 1 ? candidates.first : nil) else {
            photoTracking.clear()
            return nil
        }
        let scale = anchor.estimatedScaleFactor
        let physicalWidth = scale.isFinite && scale > 0 ? width * scale : width
        photoTracking.observe(id: anchor.id, transform: anchor.originFromAnchorTransform,
                              width: physicalWidth, timestamp: anchor.timestamp, now: now)
        return photoTracking.pose(at: now, head: head)
    }

    private func update(timestamp: Double, pose: simd_float4x4, asset: World, surface: inout PhotoSurface?) -> [Glow] {
        let now = CACurrentMediaTime()
        let hand = pinch(at: timestamp)
        let (action, revision) = control.state.withLock { ($0.action, $0.revision) }
        if revision != actionRevision {
            actionRevision = revision
            preview = nil
            dance.reset()
            calibrationAt = nil
            switch action {
            case .capture:
                manualPhone = nil
                photoTracking.clear()
            case .calibrate: calibrationAt = now + 3
            case .preview:
                let seed = hand?.palm?.center ?? (pose * SIMD4<Float>(0.12, -0.18, -0.46, 1)).xyz
                preview = Reveal(seed: seed, head: pose, points: asset.samples, now: now)
            }
        }
        if preview != nil {
            setHint(self.lang.text("预览中 · 可调整远近和高度，或点「回到捏取」开始拍摄。", "Previewing. Adjust distance and height, or choose Back to pickup."))
            return []
        }
        if let when = calibrationAt {
            if now >= when, let hand, hand.gap != nil {
                var matrix = pose
                matrix.columns.3 = SIMD4(hand.tip, 1)
                manualPhone = PhonePose(matrix: matrix, head: pose.columns.3.xyz, width: width, isManual: true)
                calibrationAt = nil
                dance.reset()
            } else if now > when + 3 {
                calibrationAt = nil
            } else {
                setHint(self.lang.text("用右手食指轻点照片中心并停住 · \(max(0, Int(ceil(when - now))))", "Hold your right index finger at the center of the photo · \(max(0, Int(ceil(when - now))))"))
                return []
            }
        }
        let phone = manualPhone ?? trackedPhone(at: now, head: pose.columns.3.xyz)
        var glows = dance.step(hand: hand, phone: phone, head: pose, samples: asset.samples, now: now)
        surface = dance.photoSurface(on: phone, at: now)
        if dance.reveal != nil {
            setHint(self.lang.text("松手后，空间会留在原处。", "The scene stays in place after release."))
        } else if dance.hasReceived {
            setHint(self.lang.text("掌心已收到。张开右手，展开照片。", "The colors have arrived. Open your right hand to reveal the scene."))
        } else if dance.isTransferring {
            setHint(self.lang.text("正在传到掌心…", "The colors are moving into your palm…"))
        } else if interaction.withLock({ $0 == nil }) {
            setHint(lang.text("正在启动互动追踪，请留意系统权限提示。", "Starting interaction tracking. Check for a permission prompt."))
        } else if !handEnabled {
            setHint(self.lang.text("请允许手部追踪后重新打开。", "Allow hand tracking, then reopen the experience."))
        } else if let phone {
            setHint(manualPhone != nil ? self.lang.text("已手动定位。手机保持静止；点「回到捏取」可重新自动识别。", "Phone placed manually. Keep it still, or choose Back to pickup to track it again.") : self.lang.text("四角对齐后，在任意可追踪位置张开右手，再捏住。", "Once the four dots line up, open and pinch your right hand anywhere it can be tracked."))
            if glows.isEmpty {
                let halfRight = phone.right * phone.width * 0.5
                let halfUp = phone.up * (phone.width / photoColors.aspect * 0.5)
                for x: Float in [-1, 1] {
                    for y: Float in [-1, 1] {
                        let p = phone.center + halfRight * x + halfUp * y + phone.normal * 0.0015
                        glows.append(Glow(center: SIMD4(p, 0.85), radius: 0.001, softness: 0.30, lift: 0.12))
                    }
                }
            }
        } else if photoTracking.anchorID != nil {
            setHint(self.lang.text("正在确认照片位置，请持稳片刻。", "Hold the photo still while its position settles."))
        } else {
            setHint(imageProvider == nil ? self.lang.text("自动识别不可用。请开启世界感知权限，或使用手动定位。", "Allow world sensing to track the photo, or choose manual placement.") :
                    self.lang.text("等待识别「\(scene.title)」。在 iPhone 上完整显示配对照片，避开反光。", "Looking for \(scene.label(.english)). Show the whole photo on your phone and avoid glare."))
        }
        return glows
    }

    private func setHint(_ hint: String) {
        control.state.withLock { if $0.hint != hint { $0.hint = hint } }
    }

    private func frame() {
        guard gate.acquire(limit: 1) else { return }
        var submitted = false
        defer { if !submitted { gate.release() } }
        guard layer.state == .running, let frame = layer.queryNextFrame() else { return }
        guard let timing = frame.predictTiming() else { return }
        frame.startUpdate()
        frame.endUpdate()
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        guard layer.state == .running, !stopping else { return }
        frame.startSubmission()
        defer { frame.endSubmission() }
        let drawables = frame.queryDrawables().sorted { $0.target == .builtIn && $1.target != .builtIn }
        let asset = world.withLock { $0 }
        var glowCount = 0
        var surface: PhotoSurface?
        var prior: MTLCommandBuffer?

        for (i, drawable) in drawables.enumerated() {
            guard let commands = queue.makeCommandBuffer() else { continue }
            let duration = LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime)
            let timestamp = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            let anchor = head.state == .running ? head.queryDeviceAnchor(atTimestamp: timestamp) : nil
            guard let anchor, anchor.isTracked else { continue }
            let pose = anchor.originFromAnchorTransform
            drawable.deviceAnchor = anchor
            if i == 0, let asset {
                var glows = update(timestamp: timestamp, pose: pose, asset: asset, surface: &surface)
                // 近处的软边叠在远处的颗粒上。单帧 in-flight 结束后才能覆写顶点。
                let backward = pose.columns.2.xyz
                glows.sort { simd_dot($0.center.xyz, backward) < simd_dot($1.center.xyz, backward) }
                glowCount = glows.count
                if glowCount > 0 {
                    glows.withUnsafeBytes {
                        glowVertices.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count)
                    }
                }
            }
            let time = CACurrentMediaTime()
            let reveal = preview ?? dance.reveal
            let (height, depth) = control.state.withLock { (Float($0.heightCM) / 100, Float($0.depthCM) / 100) }
            let offset = reveal?.placementOffset(height: height, depth: depth) ?? .zero
            let model = reveal?.model(time, offset: offset) ?? matrix_identity_float4x4
            let layered = layer.configuration.layout == .layered
            let groups = layered ? [Array(drawable.views.indices)] : drawable.views.indices.map { [$0] }
            var ready = true
            for indices in groups where ready {
                let textureIndex = layered ? 0 : indices[0]
                let arrayLength = layered ? drawable.views.count : 1
                let rateMap = drawable.rasterizationRateMaps.isEmpty ? nil
                    : drawable.rasterizationRateMaps[min(textureIndex, drawable.rasterizationRateMaps.count - 1)]
                let colorTexture = drawable.colorTextures[textureIndex]
                let depthTexture = drawable.depthTextures[textureIndex]
                let viewports = indices.map { drawable.views[$0].textureMap.viewport }
                let cameras = indices.map { pose * drawable.views[$0].transform }
                let projections = indices.map { drawable.computeProjection(viewIndex: $0) }
                let paintWorld = reveal != nil && asset != nil
                if paintWorld, let reveal, let asset {
                    let vp = zip(viewports.indices, viewports).map { index, viewport in
                        SplatRenderer.ViewportDescriptor(viewport: viewport,
                            projectionMatrix: projections[index], viewMatrix: cameras[index].inverse * model,
                            screenSize: SIMD2(Int(viewport.width), Int(viewport.height)))
                    }
                    do {
                        ready = try asset.renderer.render(viewports: vp, colorTexture: colorTexture,
                            colorStoreAction: .store, depthTexture: depthTexture, rasterizationRateMap: rateMap,
                            renderTargetArrayLength: arrayLength,
                            revealEffect: reveal.effect(at: time, offset: offset),
                            accessTimeout: 0, sortTimeout: 0, to: commands)
                    } catch {
                        ready = false
                        control.state.withLock { $0.message = self.lang.text("渲染失败：\(error.localizedDescription)", "Rendering failed: \(error.localizedDescription)") }
                    }
                }
                guard ready else { break }
                let hasOverlay = glowCount > 0 || surface != nil
                if !paintWorld || hasOverlay {
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = colorTexture
                    pass.colorAttachments[0].loadAction = paintWorld ? .load : .clear
                    pass.colorAttachments[0].storeAction = .store
                    pass.colorAttachments[0].clearColor = transparent
                    pass.depthAttachment.texture = depthTexture
                    pass.depthAttachment.loadAction = paintWorld ? .load : .clear
                    pass.depthAttachment.storeAction = .store
                    pass.depthAttachment.clearDepth = 0
                    pass.rasterizationRateMap = rateMap
                    pass.renderTargetArrayLength = arrayLength
                    guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { ready = false; break }
                    if hasOverlay {
                        encoder.setDepthStencilState(glowDepth)
                        encoder.setViewports(viewports)
                        if indices.count > 1 {
                            var mappings = indices.indices.map {
                                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                                   renderTargetArrayIndexOffset: UInt32($0))
                            }
                            encoder.setVertexAmplificationCount(mappings.count, viewMappings: &mappings)
                        }
                        let eyes = cameras.indices.map { index in
                            let projection = projections[index]
                            let pixelScale = 2 / max(1, abs(projection.columns.1.y) * Float(viewports[index].height))
                            return Eye(vp: projection * cameras[index].inverse,
                                       right: cameras[index].columns.0, up: cameras[index].columns.1,
                                       pixelScale: [pixelScale, 0, 0, 0])
                        }
                        eyes.withUnsafeBytes {
                            encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
                        }
                        if var surface {
                            encoder.setRenderPipelineState(surfacePipeline)
                            encoder.setVertexBytes(&surface, length: MemoryLayout<PhotoSurface>.stride, index: 0)
                            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                        }
                        if glowCount > 0 {
                            encoder.setRenderPipelineState(glowPipeline)
                            encoder.setVertexBuffer(glowVertices, offset: 0, index: 0)
                            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: glowCount)
                        }
                    }
                    encoder.endEncoding()
                }
            }
            if ready {
                drawable.encodePresent(commandBuffer: commands)
                let revision = actionRevision
                if drawable.target == .builtIn, let asset,
                   control.state.withLock({ $0.revision == revision && $0.readyRevision != revision }) {
                    let message = asset.readyMessage
                    commands.addCompletedHandler { [control] buffer in
                        if buffer.status == .completed, control.frameCompleted(revision: revision, message: message) {
                            Self.log.info("First anchored frame completed for session \(control.id, privacy: .public), action \(revision)")
                        }
                    }
                }
            }
            prior?.commit()
            prior = commands
        }

        if let prior {
            let gate = gate
            prior.addCompletedHandler { _ in gate.release() }
            submitted = true
            prior.commit()
        }
    }
}

private enum StageError: LocalizedError {
    case pipeline, asset, photo
    var errorDescription: String? {
        switch self {
        case .pipeline: AppLanguage.current.text("无法创建光粒的 Metal 渲染通道。", "Could not create the Metal particle pipeline.")
        case .asset: AppLanguage.current.text("找不到所选场景的高斯资产。", "The Gaussian asset for this scene is missing.")
        case .photo: AppLanguage.current.text("找不到用于定位和取色的秋日照片。", "The scene’s reference photo is missing.")
        }
    }
}

private final class StageExecutor: TaskExecutor {
    private let queue = DispatchQueue(label: "Pinchspace.Compositor", qos: .userInteractive)
    func enqueue(_ job: UnownedJob) {
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}
