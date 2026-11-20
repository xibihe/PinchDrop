import AppKit
import MetalKit
import SwiftUI

@main
struct GalleryPreviewApp: App {
    var body: some Scene {
        WindowGroup("PinchDrop") { PreviewControls() }
            .defaultSize(width: 1040, height: 650)
    }
}

private struct PreviewControls: View {
    @AppStorage(AppLanguage.key) private var lang = AppLanguage.preferred
    @State private var id = PhotoScene.all.first?.id ?? ""
    @State private var props = true
    @State private var height = 0.0
    @State private var depth = 0.0
    @State private var start = 0.0
    @State private var world: PreviewWorld?
    @State private var status = ""
    private var scene: PhotoScene? { PhotoScene.all.first { $0.id == id } }
    private let device = MTLCreateSystemDefaultDevice()

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                LanguagePicker()
                Text(lang.text("释放预览", "Reveal preview")).font(.title)
                Picker(lang.text("场景", "Scene"), selection: $id) {
                    ForEach(PhotoScene.all) { Text($0.menuTitle(lang)).tag($0.id) }
                }
                if let scene {
                    SceneCover(scene: scene).frame(height: 145)
                    if scene.prop != nil || scene.usesLeafBed { Toggle(lang.text("场景道具 · ", "Scene prop · ") + scene.propLabel(lang), isOn: $props) }
                    PlacementControl(axis: .height, cm: Binding(get: { height }, set: { height = $0; PlacementAxis.height.save($0, for: id) })) {
                        height = PlacementAxis.height.restore(id)
                    }
                    PlacementControl(axis: .depth, cm: Binding(get: { depth }, set: { depth = $0; PlacementAxis.depth.save($0, for: id) })) {
                        depth = PlacementAxis.depth.restore(id)
                    }
                }
                Button(lang.text("重播释放", "Replay reveal")) { start = ProcessInfo.processInfo.systemUptime }
                    .disabled(world == nil).keyboardShortcut(.space, modifiers: [])
                Button(lang.text("写入头显工程预设…", "Save headset preset…"), action: export)
                if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.secondary) }
                Spacer()
            }.padding(20).frame(width: 270)
            if let device {
                PreviewCanvas(device: device, world: world, start: start, height: height, depth: depth)
            } else { Text(lang.text("需要支持 Metal 的 Mac。", "This preview requires a Metal-capable Mac.")) }
        }
        .frame(minWidth: 760, minHeight: 460)
        .onChange(of: id, initial: true) { _, _ in
            height = PlacementAxis.height.value(for: id)
            depth = PlacementAxis.depth.value(for: id)
        }
        .task(id: id + (props ? "+prop" : "")) {
            world = nil
            guard let device, let scene else { status = lang.text("无法载入场景清单。", "Could not load the scene list."); return }
            status = lang.text("正在读取高斯…", "Loading Gaussians…")
            do {
                let loaded = try await PreviewWorld(scene: scene, props: props, device: device)
                try Task.checkCancellation()
                world = loaded
                start = ProcessInfo.processInfo.systemUptime
                status = ""
            } catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
    }

    private func export() {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/SceneAssets", isDirectory: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = PlacementAxis.file
        if FileManager.default.fileExists(atPath: file.path) { panel.directoryURL = file }
        panel.message = lang.text("保存到工程的 App/SceneAssets/Placement.json，下一次头显构建会使用这些高度和远近。", "Save to App/SceneAssets/Placement.json to apply height and distance in the next headset build.")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let placements = Dictionary(uniqueKeysWithValues: PhotoScene.all.map { scene in
                    (scene.id, [PlacementAxis.height.rawValue: PlacementAxis.height.value(for: scene.id),
                                PlacementAxis.depth.rawValue: PlacementAxis.depth.value(for: scene.id)])
                })
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(placements).write(to: url, options: .atomic)
                status = lang.text("已写入 ", "Saved ") + url.lastPathComponent
            } catch { status = error.localizedDescription }
        }
    }
}

private struct PreviewCanvas: NSViewRepresentable {
    let device: MTLDevice
    let world: PreviewWorld?
    let start: Double
    let height: Double
    let depth: Double

    func makeCoordinator() -> Painter { Painter(device: device) }
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = PreviewWorld.background
        view.preferredFramesPerSecond = 30
        view.delegate = context.coordinator
        return view
    }
    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.world = world
        context.coordinator.start = start
        context.coordinator.height = height
        context.coordinator.depth = depth
    }

    final class Painter: NSObject, MTKViewDelegate {
        let queue: MTLCommandQueue?
        var world: PreviewWorld?
        var start = 0.0
        var height = 0.0
        var depth = 0.0
        private var settledStart = -1.0
        private var settledHeight = Double.nan
        private var settledDepth = Double.nan
        private var settledSize = CGSize.zero
        init(device: MTLDevice) { queue = device.makeCommandQueue() }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let settled = world != nil && elapsed > CFG.revealSeconds + 0.25
            if settled && settledStart == start && settledHeight == height && settledDepth == depth && settledSize == view.drawableSize { return }
            guard let drawable = view.currentDrawable, let depth = view.depthStencilTexture,
                  let command = queue?.makeCommandBuffer() else { return }
            if let world {
                guard (try? world.draw(to: drawable.texture, depth: depth, at: elapsed,
                                       heightCM: height, depthCM: self.depth, command: command)) == true else { return }
            } else if let pass = view.currentRenderPassDescriptor {
                command.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            }
            command.present(drawable)
            command.commit()
            if settled {
                settledStart = start
                settledHeight = height
                settledDepth = self.depth
                settledSize = view.drawableSize
            } else { settledStart = -1 }
        }
    }
}
