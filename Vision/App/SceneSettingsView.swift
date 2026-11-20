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
        .task(id: scene.id) {
            let thumbnail = await Task.detached { try? scene.cover(maxSize: 500) }.value
            if !Task.isCancelled { image = thumbnail }
        }
        .accessibilityLabel(scene.label(lang))
    }
}

struct PlacementControl: View {
    let axis: PlacementAxis
    @Binding var cm: Double
    @AppStorage(AppLanguage.key) private var lang = AppLanguage.preferred
    let restore: () -> Void
    private var step: Double { axis == .height ? 5 : 10 }
    private var title: String {
        axis == .height ? lang.text("释放高度", "Reveal height") : lang.text("释放远近", "Reveal distance")
    }
    private var readout: String {
        if axis == .depth, cm != 0 {
            let direction = cm < 0 ? lang.text("拉近", "Closer") : lang.text("推远", "Farther")
            return "\(direction) \(Int(abs(cm))) cm"
        }
        return "\(cm > 0 ? "+" : "")\(Int(cm)) cm"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(readout).monospacedDigit()
                    .accessibilityIdentifier(axis == .height ? "height-readout" : "depth-readout")
                Button(lang.text("复位", "Reset"), action: restore).controlSize(.small)
            }
            HStack {
                Button { cm = max(PlacementAxis.range.lowerBound, cm - step) } label: {
                    if axis == .height { Image(systemName: "minus") }
                    else { Text(lang.text("拉近", "Closer")) }
                }.accessibilityLabel(axis == .height ? lang.text("降低五厘米", "Lower five centimeters") : lang.text("拉近十厘米", "Move ten centimeters closer"))
                Slider(value: $cm, in: PlacementAxis.range, step: 1)
                    .accessibilityLabel(title)
                Button { cm = min(PlacementAxis.range.upperBound, cm + step) } label: {
                    if axis == .height { Image(systemName: "plus") }
                    else { Text(lang.text("推远", "Farther")) }
                }.accessibilityLabel(axis == .height ? lang.text("升高五厘米", "Raise five centimeters") : lang.text("推远十厘米", "Move ten centimeters farther"))
            }
        }
    }
}
