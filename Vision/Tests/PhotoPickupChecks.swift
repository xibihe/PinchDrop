import Foundation
import ImageIO
import simd

@main
struct PhotoPickupChecks {
    static func main() {
        let id = UUID(), head = SIMD3<Float>(0, 1, 0)
        let identity = matrix_identity_float4x4
        let width: Float = 0.069
        var tracking = PhotoTracking()
        tracking.observe(id: id, transform: identity, width: width, timestamp: 1, now: 1)
        precondition(tracking.pose(at: 1.05, head: head) == nil)
        let phone = tracking.pose(at: 1.13, head: head)!
        precondition(tracking.pose(at: 4, head: head)?.anchorID == id)
        var moved = identity
        moved.columns.3.x = 0.14
        tracking.observe(id: id, transform: moved, width: width, timestamp: 4, now: 4)
        precondition(tracking.pose(at: 4.03, head: head) == nil)
        precondition(tracking.pose(at: 4.15, head: head)?.center.x == 0.14)
        tracking.clear()
        precondition(tracking.pose(at: 5, head: head) == nil)

        // 边缘可以起捏；照片后方、超出图面和旧版 20 cm 捕获范围内的远处均应被拒绝。
        precondition(phone.acceptsPinch(at: [0.035, 0.012, 0], aspect: 1.5))
        precondition(!phone.acceptsPinch(at: [0, -0.03, 0], aspect: 1.5))
        precondition(!phone.acceptsPinch(at: [0, 0.15, 0], aspect: 1.5))
        precondition(!phone.acceptsPinch(at: [0, 0.01, 0.065], aspect: 1.5))
        precondition(phone.acceptsPinch(at: [0, 0.01, 0.065], aspect: 0.7))

        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
        var dance = Choreography(colors: PhotoColors(image: image)!)
        func step(_ t: Double, _ gap: Float, _ target: PhonePose?) {
            let hand = PinchSample(center: .zero, tip: .zero, gap: gap)
            _ = dance.step(hand: hand, phone: target, head: identity, samples: [], now: t)
        }
        let open: Float = 0.065, pinch: Float = 0.01
        step(0, open, phone)
        step(0.02, pinch, nil)
        precondition(!dance.isTransferring)
        step(0.04, open, phone)
        step(0.06, pinch, phone)
        precondition(dance.isTransferring)
        for i in 1...8 { step(0.06 + Double(i) * 0.04, pinch, nil) }
        precondition(!dance.isTransferring && dance.reveal == nil)
        step(0.42, pinch, phone)
        precondition(!dance.isTransferring)
        step(0.46, open, phone)
        step(0.50, pinch, phone)
        step(0.54, pinch, nil)
        step(0.58, pinch, phone)
        precondition(dance.isTransferring)
        let quarterTurn = simd_float4x4(simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
        let rotated = PhonePose(matrix: quarterTurn, head: head, width: width, anchorID: id)
        step(0.62, pinch, rotated)
        precondition(!dance.isTransferring)
        step(0.66, open, phone)
        step(0.70, pinch, phone)
        step(0.74, open, phone)
        precondition(!dance.isTransferring && dance.reveal == nil)

        step(0.78, pinch, phone)
        for i in 1...100 {
            let elapsed = Double(i) * 0.04
            step(0.78 + elapsed, elapsed > 0.5 ? open : pinch, elapsed > 1 ? nil : phone)
            if elapsed < 2 { precondition(dance.reveal == nil) }
        }
        let first = dance.reveal!.time
        step(4.82, open, nil)
        precondition(dance.reveal?.time == first)
        print("照片确认、平面边界、短暂遮挡、失跟重捏、方向突变及离屏后释放通过")
    }
}
