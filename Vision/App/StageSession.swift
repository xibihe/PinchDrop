import Foundation
import Synchronization

// A compositor layer can start after the launcher has already rendered another window.
// Route that layer to the exact opening request, then let the window and renderer own it.
final class StageSessions: Sendable {
    private let pending = Mutex<[UUID: StageControl]>([:])

    func register(_ control: StageControl) {
        pending.withLock { $0[control.id] = control }
    }

    @discardableResult
    func take(_ id: UUID?) -> StageControl? {
        guard let id else { return nil }
        return pending.withLock { $0.removeValue(forKey: id) }
    }
}

final class StageControl: Sendable {
    let id = UUID()
    enum Action: Sendable { case capture, preview, calibrate }
    struct State: Sendable {
        var message = AppLanguage.current.text("准备读取内置高斯场景…", "Loading the bundled scene…")
        var hint = AppLanguage.current.text("打开后请看向手机上的封面。", "Look at the matching photo on your phone.")
        var sceneID = "00-autumn"
        var includeProps = true
        var heightCM = 0.0
        var action = Action.capture
        var revision = 0
        var widthMM = CFG.screenWidthMM
        var leafLayout = LeafLayout.accent
        var leafDensity = 1.0
        var leafWidth = 1.0
        var closed = false
        var needsDismissal = false
    }
    let state = Mutex(State())

    func request(_ action: Action) {
        state.withLock { $0.action = action; $0.revision &+= 1 }
    }
}
