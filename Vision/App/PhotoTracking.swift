import Foundation
import simd

/// ARKit 的锚点状态在渲染帧上读取。同一观测可连续出现多帧，只对真实的新观测滤波。
struct PhotoTracking {
    static let confirmationTime = 0.12
    private(set) var anchorID: UUID?
    private var acquiredAt = 0.0
    private var timestamp = -Double.infinity
    private var center = SIMD3<Float>.zero
    private var rotation = simd_quatf(angle: 0, axis: [0, 1, 0])
    private var width: Float = 0

    mutating func clear() { anchorID = nil }

    mutating func observe(id: UUID, transform: simd_float4x4, width measuredWidth: Float,
                          timestamp sampleTime: Double, now: Double) {
        let position = transform.columns.3.xyz
        guard measuredWidth.isFinite, measuredWidth > 0, sampleTime.isFinite,
              simd_length_squared(position).isFinite else { clear(); return }
        if id == anchorID && sampleTime <= timestamp { return }
        let axes = simd_float3x3(columns: (simd_normalize(transform.columns.0.xyz),
                                            simd_normalize(transform.columns.1.xyz),
                                            simd_normalize(transform.columns.2.xyz)))
        guard simd_determinant(axes) > 0.95 else { clear(); return }
        let orientation = simd_normalize(simd_quatf(axes))
        let dt = Float(max(0, sampleTime - timestamp))
        let displacement = simd_distance(center, position)
        let alignment = abs(simd_dot(rotation.vector, orientation.vector))
        // 少量抖动做平滑；普通持机移动直接跟随，明显重定位让观众先看清边界。
        if id != anchorID || displacement > 0.08 || alignment < 0.94 {
            center = position
            rotation = orientation
            width = measuredWidth
            acquiredAt = now
        } else {
            let alpha: Float = displacement > 0.012 ? 1 : 1 - exp(-dt / 0.035)
            center += (position - center) * alpha
            rotation = simd_slerp(rotation, orientation, alpha)
            width += (measuredWidth - width) * (1 - exp(-dt / 0.10))
        }
        anchorID = id
        timestamp = sampleTime
    }

    func pose(at now: Double, head: SIMD3<Float>) -> PhonePose? {
        guard let anchorID, now - acquiredAt >= Self.confirmationTime else { return nil }
        var matrix = simd_float4x4(rotation)
        matrix.columns.3 = SIMD4(center, 1)
        return PhonePose(matrix: matrix, head: head, width: width, anchorID: anchorID)
    }
}
