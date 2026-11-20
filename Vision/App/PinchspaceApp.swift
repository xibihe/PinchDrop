import CompositorServices
import SwiftUI
import UIKit

@main
struct PinchspaceApp: App {
    @State private var sessions = StageSessions()
    @State private var immersion: ImmersionStyle = .mixed

    var body: some Scene {
        WindowGroup {
            Controls(sessions: sessions)
        }
        .defaultSize(width: 475, height: 700)

        ImmersiveSpace(id: "pinchspace", for: UUID.self) { sessionID in
            CompositorLayer(configuration: StageConfiguration()) { [sessions] layer in
                guard let control = sessions.take(sessionID.wrappedValue) else { return }
                StageRenderer.start(layer, control: control)
            }
        }
        .immersionStyle(selection: $immersion, in: .mixed)
        .upperLimbVisibility(.visible)
    }
}

private struct Controls: View {
    let sessions: StageSessions
    @State private var control = StageControl()
    @AppStorage(AppLanguage.key) private var lang = AppLanguage.preferred
    @State private var isOpen = false
    @State private var isBusy = false
    @AppStorage("selectedPhotoScene") private var sceneID = "00-autumn"
    @AppStorage("includeTripoProps") private var includeProps = true
    @State private var heightCM = 0.0
    private var scene: PhotoScene? { PhotoScene.all.first { $0.id == sceneID } ?? PhotoScene.all.first }
    @AppStorage("photoWidthMM") private var widthMM = CFG.screenWidthMM
    @AppStorage("galleryLeafLayout") private var leafLayout = LeafLayout.accent
    @AppStorage("leafDensity") private var leafDensity = 1.0
    @AppStorage("leafWidth") private var leafWidth = 1.0
    @State private var info = StageControl.State()
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("PinchDrop").font(.system(size: 40, weight: .light))
                if !isOpen { LanguagePicker() }
                if let scene {
                    if !isOpen {
                        Picker(lang.text("场景", "Scene"), selection: $sceneID) {
                            ForEach(PhotoScene.all) { Text($0.menuTitle(lang)).tag($0.id) }
                        }.pickerStyle(.menu).accessibilityIdentifier("scene-picker").disabled(isBusy)
                    }
                    SceneCover(scene: scene).frame(height: isOpen ? 95 : 160)
                    if !isOpen {
                        ShareLink(item: scene.photoURL) {
                            Label(lang.text("分享配对照片到 iPhone", "Share matching photo to iPhone"), systemImage: "square.and.arrow.up")
                        }
                    }
                    HeightControl(cm: Binding(get: { heightCM }, set: { changeHeight($0, scene: scene) })) {
                        heightCM = SceneHeights.restore(scene.id)
                        control.state.withLock { $0.heightCM = heightCM }
                    }
                    if !isOpen && (scene.prop != nil || scene.usesLeafBed) { Toggle(lang.text("场景道具 · ", "Scene prop · ") + scene.propLabel(lang), isOn: $includeProps) }
                }
                if isOpen {
                    Text(info.message).font(.callout)
                    Text(info.hint).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button(lang.text("预览释放", "Preview reveal")) { control.request(.preview) }
                        Button(lang.text("回到捏取", "Back to pickup")) { control.request(.capture) }
                        Button(lang.text("退出", "Exit")) { Task { await exitSpace() } }
                    }
                    Button(lang.text("手动定位手机", "Locate phone manually")) { control.request(.calibrate) }
                } else {
                    if info.closed { Text(info.message).font(.caption).foregroundStyle(.secondary) }
                    Stepper(lang.text("照片实际显示宽度：\(widthMM) mm", "Displayed photo width: \(widthMM) mm"), value: $widthMM, in: 30...190)
                    Text(lang.text("按手机上照片左右边缘之间的距离填写。完整显示照片，避免放大裁切。", "Measure between the visible left and right edges. Keep the entire photo in view."))
                        .font(.caption).foregroundStyle(.secondary)
                    if scene?.usesLeafBed == true && includeProps {
                        Picker(lang.text("银杏落叶", "Ginkgo leaves"), selection: $leafLayout) {
                            ForEach(LeafLayout.allCases, id: \.self) { Text($0.label(lang)).tag($0) }
                        }
                        if leafLayout != .none && leafLayout != .accent {
                            Slider(value: $leafDensity, in: 0.25...1.65, step: 0.05) {
                                Text(lang.text("密度 \(leafDensity.formatted(.percent.precision(.fractionLength(0))))", "Density \(leafDensity.formatted(.percent.precision(.fractionLength(0))))"))
                            }
                            Slider(value: $leafWidth, in: 0.65...1.35, step: 0.05) {
                                Text(lang.text("叶片大小 \(leafWidth.formatted(.percent.precision(.fractionLength(0))))", "Leaf size \(leafWidth.formatted(.percent.precision(.fractionLength(0))))"))
                            }
                        }
                    }
                    HStack {
                        Button(lang.text("预览释放", "Preview reveal")) { Task { await enter(preview: true) } }
                        Button(lang.text("从手机捏取", "Pick up from phone")) { Task { await enter(preview: false) } }.buttonStyle(.borderedProminent)
                    }.disabled(isBusy || scene == nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .onChange(of: sceneID, initial: true) { _, _ in
            if let scene {
                if scene.id != sceneID { sceneID = scene.id }
                heightCM = SceneHeights.value(for: scene.id)
            }
        }
        .task(id: isOpen ? control.id : nil) {
            guard isOpen else { return }
            let opened = control
            while !Task.isCancelled && control === opened {
                info = opened.state.withLock { $0 }
                if info.closed {
                    if info.needsDismissal { await exitSpace() }
                    else { isOpen = false }
                    return
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    @MainActor private func exitSpace() async {
        guard isOpen, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        sessions.take(control.id)
        await dismissSpace()
        isOpen = false
    }

    private func changeHeight(_ cm: Double, scene: PhotoScene) {
        heightCM = cm
        SceneHeights.save(cm, for: scene.id)
        control.state.withLock { $0.heightCM = cm }
    }

    @MainActor private func enter(preview: Bool) async {
        guard !isBusy, let scene else { return }
        isBusy = true
        defer { isBusy = false }
        let next = StageControl()
        next.state.withLock {
            $0.sceneID = scene.id
            $0.includeProps = includeProps
            $0.heightCM = heightCM
            $0.widthMM = widthMM
            $0.leafLayout = leafLayout
            $0.leafDensity = leafDensity
            $0.leafWidth = leafWidth
        }
        next.request(preview ? .preview : .capture)
        info = StageControl.State()
        control = next
        sessions.register(next)
        let result = await openSpace(id: "pinchspace", value: next.id)
        isOpen = result == .opened
        if !isOpen {
            sessions.take(next.id)
            if result == .error {
                info.message = lang.text("无法打开沉浸空间，请重试。", "Could not open the immersive space. Try again.")
                info.closed = true
            }
        }
    }
}
