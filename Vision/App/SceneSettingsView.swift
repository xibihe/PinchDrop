import SwiftUI

struct SceneCover: View {
    @AppStorage(AppLanguage.key) private var lang = AppLanguage.preferred
    let scene: PhotoScene
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            Color.clear
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            }
        }
        .task(id: scene.id) { image = try? scene.cover(maxSize: 500) }
        .accessibilityLabel(scene.label(lang))
    }
}

struct HeightControl: View {
    @Binding var cm: Double
    @AppStorage(AppLanguage.key) private var lang = AppLanguage.preferred
    let restore: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(lang.text("释放高度", "Reveal height"))
                Spacer()
                Text("\(cm > 0 ? "+" : "")\(Int(cm)) cm").monospacedDigit()
                Button(lang.text("复位", "Reset"), action: restore).controlSize(.small)
            }
            HStack {
                Button { cm = max(SceneHeights.range.lowerBound, cm - 5) } label: {
                    Image(systemName: "minus")
                }.accessibilityLabel(lang.text("降低五厘米", "Lower five centimeters"))
                Slider(value: $cm, in: SceneHeights.range, step: 1)
                    .accessibilityLabel(lang.text("释放高度，厘米", "Reveal height in centimeters"))
                Button { cm = min(SceneHeights.range.upperBound, cm + 5) } label: {
                    Image(systemName: "plus")
                }.accessibilityLabel(lang.text("升高五厘米", "Raise five centimeters"))
            }
        }
    }
}
