import Foundation
import simd

enum CFG {
    static let screenWidthMM = 69 // 照片画面实际宽度，毫米；手机竖屏全宽。
    static let pickupEdge: Float = 0.030 // 指尖可在照片边缘外 3 cm 起捏。
    static let pickupFront: Float = 0.060 // 照片朝观众一侧 6 cm 内。
    static let pickupBehind: Float = 0.018 // 为深度误差留 1.8 cm 背面容差。
    static let pinchIn: Float = 0.030 // 拇指食指小于 3 cm，开始捏住。
    static let pinchOut: Float = 0.050 // 指尖张开超过 5 cm，释放。
    static let handGrace = 0.16 // 秒；遮挡太久取消，不能把丢手当松手。
    static let imageGrace = 0.26 // 秒；短暂遮挡保留手机最后位姿。
    static let photoRows = 96 // 照片纵向采样密度，横向按宽高比。
    static let photoLock = 0.24 // 秒；整张照片的点阵先贴在屏幕上。
    static let photoPeel = 0.57 // 秒；从靠手的一侧逐步松开。
    static let photoTransit = 1.83 // 秒；点阵从屏幕到掌心的基础时长。
    static let maxParticles = 20_000 // 允许横向照片保持相近的采样密度。
    static let receiptPause = 0.14 // 秒；末尾落在掌心后短停一拍。
    static let minimumHold = 0.24 // 秒；短促轻点不触发展开。
    static let revealSeconds = 1.95 // 秒；指尖光团长成空间的总时长。
    static let finalDistance: Float = 0.36 // 米；场景原机位放在释放瞬间的视线前方。
    static let finalScale: Float = 0.86 // 内置模型的最终缩放。
    static let worldPointBudget = 650_000 // 照片高斯预算，另外加上叶片。
    static let renderQuality: Float = 0.66 // Vision Pro 注视点渲染质量。
    static let seedParticles = 440 // 掌心最多留下的颗粒数。
    static let collectEvery = 22 // 到达的照片点里留一部分给掌心释放。
    static let seedScatterSeconds = 0.74 // 张手后，指尖微粒散入高斯的时长。
    static let sourceLift: Float = 0.0012 // 米；点阵贴在图像平面前 1.2 mm。
}

struct PhonePose: Sendable {
    let center: SIMD3<Float>
    let right: SIMD3<Float>
    let up: SIMD3<Float>
    let normal: SIMD3<Float>
    let width: Float
    let anchorID: UUID?

    init(matrix: simd_float4x4, head: SIMD3<Float>, width: Float, isManual: Bool = false, anchorID: UUID? = nil) {
        center = matrix.columns.3.xyz
        right = simd_normalize(matrix.columns.0.xyz)
        up = simd_normalize(isManual ? matrix.columns.1.xyz : -matrix.columns.2.xyz)
        let outward = simd_normalize(simd_cross(right, up))
        normal = simd_dot(outward, head - center) >= 0 ? outward : -outward
        self.width = width
        self.anchorID = anchorID
    }

    func acceptsPinch(at point: SIMD3<Float>, aspect: Float) -> Bool {
        let offset = point - center
        let depth = simd_dot(offset, normal)
        return abs(simd_dot(offset, right)) <= width / 2 + CFG.pickupEdge
            && abs(simd_dot(offset, up)) <= width / (2 * aspect) + CFG.pickupEdge
            && (-CFG.pickupBehind...CFG.pickupFront).contains(depth)
    }
}

struct PalmPose {
    let center: SIMD3<Float>
    let normal: SIMD3<Float>
}

struct PinchSample {
    let center: SIMD3<Float>
    let tip: SIMD3<Float>
    let gap: Float? // 指尖短暂遮挡时为 nil，掌心仍可继续接收。
    var palm: PalmPose? = nil
}

struct Glow {
    var center: SIMD4<Float> // 世界坐标 xyz，w 为不透明度。
    var radius: Float // 米。
    var color: UInt32 = 0xD9EBF3 // 低位起依次为 sRGB 红、绿、蓝。
    var softness: Float = 0.36 // 核心外围的扩散量。
    var lift: Float = 0 // 屏幕近处的柔光提亮。
}

// 与 Metal 的照片平面参数共用布局。两个方向向量是实拍照片的半宽和半高。
struct PhotoSurface {
    let center: SIMD4<Float>
    let halfRight: SIMD4<Float>
    let halfUp: SIMD4<Float>
    let peel: SIMD4<Float> // 剥离进度、从右出发、起手显影、整体可见度。
}

struct Reveal: Sendable {
    let seed: SIMD3<Float>
    let finalModel: simd_float4x4
    let localSeed: SIMD3<Float>
    let radius: Float
    let time: Double

    init(seed: SIMD3<Float>, head: simd_float4x4, points: [SIMD3<Float>], now: Double) {
        self.seed = seed
        time = now
        var forward = SIMD3<Float>(-head.columns.2.x, 0, -head.columns.2.z)
        forward = simd_length_squared(forward) > 0.0001 ? simd_normalize(forward) : [0, 0, -1]
        let yaw = simd_quatf(angle: atan2(-forward.x, -forward.z), axis: [0, 1, 0])
        // IMG_0394 的实测投影为 +X 向右、+Y 向下、+Z 向前。
        let flipRDF = simd_quatf(angle: .pi, axis: [1, 0, 0])
        var model = simd_float4x4(yaw * flipRDF)
        model.columns.0 *= CFG.finalScale
        model.columns.1 *= CFG.finalScale
        model.columns.2 *= CFG.finalScale
        model.columns.3 = SIMD4(head.columns.3.xyz + forward * CFG.finalDistance, 1)
        finalModel = model
        localSeed = (model.inverse * SIMD4(seed, 1)).xyz
        let origin = localSeed
        let radii = points.map { simd_distance($0, origin) }.sorted()
        radius = radii.isEmpty ? 8 : max(0.35, radii[Int(Float(radii.count - 1) * 0.985)])
    }

    func progress(_ now: Double) -> Float {
        Float(max(0, min(1, (now - time) / CFG.revealSeconds)))
    }

    func model(_ now: Double, height: Float = 0) -> simd_float4x4 {
        let t = progress(now)
        // 临界阻尼的闭式曲线，归一到结束位置。世界坐标从指尖统一放大。
        let grown = (1 - (1 + 5 * t) * exp(-5 * t)) / (1 - 6 * exp(Float(-5)))
        let scale = 0.027 + 0.973 * grown
        var model = finalModel
        model.columns.0 *= scale
        model.columns.1 *= scale
        model.columns.2 *= scale
        let destination = model.columns.3.xyz + SIMD3(0, height, 0)
        model.columns.3 = SIMD4(seed + (destination - seed) * scale, 1)
        return model
    }
}

struct Choreography {
    private struct PhotoDot {
        let uv: SIMD2<Float>
        let color: UInt32
        let grain: Float
        let brightness: Float
        let landing: SIMD3<Float>
        let staysInHand: Bool
    }

    private struct Flying {
        let dot: PhotoDot
        let phone: PhonePose
        let born: Double
        let lifespan: Double

        var arrival: Double { born + lifespan }
    }

    let colors: PhotoColors
    private typealias Scheduled = (dot: PhotoDot, delay: Double)
    private let leftFirst: [Scheduled]
    private let rightFirst: [Scheduled]
    private var waiting: [Scheduled] = []
    private var nextDot = 0
    private var peelFromRight = false
    private var flying: [Flying] = []
    private var caught: [Flying] = []
    private var isArmed = false
    private var start: Double?
    private var lastTracked: Double = -.infinity
    private var palm: PalmPose?
    private var palmOffset: SIMD3<Float> = .zero
    private var source: PhonePose?
    private var lastPhotoSeen: Double = -.infinity
    private var receivedAt: Double?
    private(set) var reveal: Reveal?

    var isTransferring: Bool { start != nil && receivedAt == nil && reveal == nil }
    var hasReceived: Bool { receivedAt != nil && reveal == nil }

    init(colors: PhotoColors) {
        self.colors = colors
        let columns = min(CFG.maxParticles / CFG.photoRows,
                          max(1, Int((Float(CFG.photoRows) * colors.aspect).rounded())))
        let dimensions = SIMD2(Float(columns), Float(CFG.photoRows))
        let photo = (0..<(columns * CFG.photoRows)).map { index in
            let cell = SIMD2(Float(index % columns), Float(index / columns))
            let jitter = SIMD2(Self.noise(index, 1) - 0.5, Self.noise(index, 2) - 0.5) * 0.32
            let uv = (cell + 0.5 + jitter) / dimensions
            let color = colors.sample(uv.x, uv.y)
            let grain = Self.noise(index, 6)
            return PhotoDot(uv: uv, color: color, grain: grain,
                            brightness: (0.25 + 0.63 * sqrt(Self.luma(color))) * (0.63 + 0.37 * grain),
                            landing: Self.grainDirection(index)
                                * (0.002 + 0.021 * sqrt(Self.noise(index, 10))),
                            staysInHand: Self.noise(index, 15) < 1 / Float(CFG.collectEvery))
        }
        leftFirst = Self.peelOrder(photo, fromRight: false)
        rightFirst = Self.peelOrder(photo, fromRight: true)
    }

    private static func peelOrder(_ photo: [PhotoDot], fromRight: Bool) -> [Scheduled] {
        photo.map { dot in
            let u = fromRight ? 1 - dot.uv.x : dot.uv.x
            let wave = 0.89 * u + 0.11 * dot.uv.y + (dot.grain - 0.5) * 0.072
            return (dot, CFG.photoLock + CFG.photoPeel * Double(min(1, max(0, wave))))
        }.sorted { $0.delay < $1.delay }
    }

    mutating func reset() {
        cancel()
        reveal = nil
        isArmed = false
        lastTracked = -.infinity
        palmOffset = .zero
    }

    mutating func step(hand: PinchSample?, phone: PhonePose?, head: simd_float4x4,
                       samples: [SIMD3<Float>], now: Double) -> [Glow] {
        if let reveal, let palm { return glows(at: now, palm: palm, openedAt: reveal.time) }
        if now - lastTracked > CFG.handGrace, start != nil {
            cancel()
            isArmed = false
        }
        collectArrivals(at: now)
        if let hand {
            lastTracked = now
            if let measured = hand.palm {
                if hand.gap != nil { palmOffset = measured.center - hand.center }
                palm = measured
            } else {
                // 短暂挡住指根时，用最后测到的掌心与捏合点的相对位置。
                palm = PalmPose(center: hand.center + palmOffset, normal: palm?.normal ?? [0, 1, 0])
            }

            if let gap = hand.gap {
                if let began = start {
                    if gap >= CFG.pinchOut, now - began < CFG.minimumHold {
                        cancel()
                        isArmed = true
                    }
                } else if gap >= CFG.pinchOut {
                    isArmed = true
                } else if gap <= CFG.pinchIn, isArmed {
                    isArmed = false
                    if let phone, phone.acceptsPinch(at: hand.center, aspect: colors.aspect) {
                        start = now
                        lastPhotoSeen = now
                        source = phone
                        peelFromRight = simd_dot(hand.center - phone.center, phone.right) >= 0
                        waiting = peelFromRight ? rightFirst : leftFirst
                        nextDot = 0
                    }
                }
            }
        }

        guard let began = start, let palm else { return [] }
        let age = now - began
        if nextDot < waiting.count {
            if let phone {
                if let source, source.anchorID != phone.anchorID
                    || simd_distance(source.center, phone.center) > 0.08
                    || simd_dot(source.right, phone.right) < 0.77
                    || simd_dot(source.up, phone.up) < 0.77 {
                    reset()
                    return []
                }
                source = phone
                lastPhotoSeen = now
            } else if now - lastPhotoSeen > CFG.imageGrace {
                reset()
                return []
            }
        }

        // 发射结束且最后一批落到掌心才算收齐。提前张手会继续传到掌心。
        if nextDot == waiting.count, flying.isEmpty, receivedAt == nil {
            receivedAt = now
        }
        if let receivedAt, now - receivedAt >= CFG.receiptPause,
           let gap = hand?.gap, gap >= CFG.pinchOut {
            reveal = Reveal(seed: palm.center, head: head, points: samples, now: now)
            return glows(at: now, palm: palm, openedAt: now)
        }

        if let source {
            while nextDot < waiting.count, age >= waiting[nextDot].delay {
                let cell = waiting[nextDot]
                let transit = CFG.photoTransit
                    + 0.155 * Double(cell.dot.grain) + 0.045 * Double(cell.dot.uv.y)
                flying.append(Flying(dot: cell.dot, phone: source,
                                     born: began + cell.delay, lifespan: transit))
                nextDot += 1
            }
        }

        var result = glows(at: now, palm: palm)
        if let source, nextDot < waiting.count {
            result.reserveCapacity(result.count + waiting.count - nextDot)
            let opacity = Self.smooth(0.025, Float(CFG.photoLock) - 0.015, Float(age)) * 0.95
            if opacity > 0 {
                for cell in waiting[nextDot...] {
                    let pickup = 1 - Self.smooth(0, 0.19, Float(cell.delay - age))
                    result.append(Glow(center: SIMD4(sourcePoint(source, uv: cell.dot.uv), opacity),
                                       radius: photoDotRadius(source), color: Self.withPhotoTone(cell.dot.color, weight: 1),
                                       lift: pickup * cell.dot.brightness))
                }
            }
        }
        return result
    }

    private func sourcePoint(_ phone: PhonePose, uv: SIMD2<Float>) -> SIMD3<Float> {
        phone.center + phone.right * ((uv.x - 0.5) * phone.width)
            + phone.up * ((0.5 - uv.y) * phone.width / colors.aspect) + phone.normal * CFG.sourceLift
    }

    func photoSurface(on phone: PhonePose?, at now: Double) -> PhotoSurface? {
        guard let phone, let start else { return nil }
        let age = Float(now - start)
        let settle = Self.smooth(0.025, Float(CFG.photoLock), age)
        let visibility = reveal.map { 1 - Self.smooth(0, 0.48, Float(now - $0.time)) } ?? 1
        guard settle * visibility > 0.001 else { return nil }
        let phase = (age - Float(CFG.photoLock)) / Float(CFG.photoPeel)
        return PhotoSurface(center: SIMD4(phone.center, 1),
                            halfRight: SIMD4(phone.right * (phone.width * 0.5), 0),
                            halfUp: SIMD4(phone.up * (phone.width * 0.5 / colors.aspect), 0),
                            peel: [phase, peelFromRight ? 1 : 0, settle, visibility])
    }

    private mutating func collectArrivals(at now: Double) {
        // 先确认飞行结束，再把原来的光粒留在手里。
        for fly in flying where fly.arrival <= now && fly.dot.staysInHand && caught.count < CFG.seedParticles {
            caught.append(fly)
        }
        flying.removeAll { $0.arrival <= now }
    }

    private mutating func cancel() {
        start = nil
        palm = nil
        source = nil
        receivedAt = nil
        flying.removeAll(keepingCapacity: true)
        caught.removeAll(keepingCapacity: true)
        waiting.removeAll(keepingCapacity: false)
        nextDot = 0
    }

    private func streamGlow(_ fly: Flying, palm: PalmPose, now: Double, photoPhase: Float) -> Glow {
        let p = Float(min(1, max(0, (now - fly.born) / fly.lifespan)))
        // 屏幕上逐列揭起，空中大部分点逐渐同速，避免树干被横向拉成长条。
        let dot = fly.dot
        let coherence = 0.96 - 0.62 * Self.smooth(0.83, 1, dot.grain)
        let sync = Self.smooth(0.005, 0.32, p) * (1 - Self.smooth(0.63, 1, p)) * coherence
        let phase = p + (photoPhase - p) * sync
        let t = phase * phase * (3 - 2 * phase)
        let v = 1 - t
        let origin = fly.phone.center + fly.phone.normal * CFG.sourceLift
        let landing = palm.center + Self.palmOffset(dot.landing, normal: palm.normal)
        let toward = palm.center - origin
        let second = origin + toward * 0.19 + fly.phone.normal * 0.008
        let third = landing - toward * 0.21 + palm.normal * 0.032
        let center = origin * (v * v * v) + second * (3 * v * v * t)
            + third * (3 * v * t * t) + landing * (t * t * t)

        // 起始 UV 完全贴着原像素，带着原照片的轮廓离屏后才在掌心折叠。
        let carry = 1 - Self.smooth(0.46, 0.95, t)
        let free = Self.smooth(0.12, 0.54, t)
        let scale = carry * (1 + 0.55 * free)
        let fold = sin(.pi * (1.2 * dot.uv.x - 1.1 * dot.uv.y - t))
        let local = sourcePoint(fly.phone, uv: dot.uv) - origin
        let ripple = sin(5.4 * dot.uv.y - 4.6 * t + 1.5 * dot.uv.x)
        let point = center + local * scale + fly.phone.right * (0.005 * ripple * free * carry)
            + fly.phone.normal * ((0.009 * fold + 0.005 * (dot.grain - 0.5)) * free * carry)
        let photoTone = 1 - Self.smooth(0.68, 0.97, t)
        let landFade = 1 - Self.smooth(0.80, 1, p)
        let handFade = dot.staysInHand ? 0.70 + 0.30 * landFade : landFade
        let opacity = (0.95 * photoTone + dot.brightness * 0.72 * (1 - photoTone)) * handFade
        let cellRadius = photoDotRadius(fly.phone)
        let radius = cellRadius * (1.0 + 0.44 * free) * photoTone
            + pickupRadius(dot) * (1 - photoTone)
        let screenLight = dot.brightness * (1 - Self.smooth(0, 0.15, p))
        return Glow(center: SIMD4(point, opacity), radius: radius,
                    color: Self.withPhotoTone(dot.color, weight: photoTone),
                    softness: 0.38, lift: screenLight + 0.20 * (1 - photoTone))
    }

    private func photoDotRadius(_ phone: PhonePose) -> Float {
        phone.width / (Float(CFG.photoRows) * colors.aspect) * 0.84
    }

    private func pickupRadius(_ dot: PhotoDot) -> Float {
        0.00018 + (0.00087 - 0.00018) * pow(dot.grain, 3.25)
    }

    private static func withPhotoTone(_ color: UInt32, weight: Float) -> UInt32 {
        color | (UInt32(weight * 255) << 24)
    }

    private func glows(at now: Double, palm: PalmPose, openedAt: Double? = nil) -> [Glow] {
        if let openedAt, now - openedAt >= CFG.seedScatterSeconds { return [] }
        var result = [Glow]()
        result.reserveCapacity(flying.count + caught.count)
        let age = now - (start ?? now)
        let photoPhase = Float(min(1, max(0, (age - CFG.photoLock - CFG.photoPeel * 0.5)
                                         / (CFG.photoTransit + 0.10))))
        for fly in flying {
            result.append(streamGlow(fly, palm: palm, now: now, photoPhase: photoPhase))
        }
        let contact = receivedAt.map { Self.smooth(0, Float(CFG.receiptPause), Float(now - $0)) } ?? 0
        for fly in caught {
            let releaseAge = openedAt.map { now - max($0, fly.arrival) } ?? 0
            let progress = Float(releaseAge / CFG.seedScatterSeconds)
            guard progress < 1 else { continue }

            let held = Float(max(0, min(now, openedAt ?? now) - fly.arrival))
            let settle = 0.56 + 0.44 * exp(-7 * held)
            let offset = Self.palmOffset(fly.dot.landing, normal: palm.normal)
                * settle * (1 - 0.28 * contact)
            let spread = Self.smooth(0, 0.82, progress)
            let direction = simd_normalize(offset)
            let release = direction * spread * (0.029 + 0.065 * fly.dot.grain)
            let fade = (1 - progress) * (1 - progress)
            let brightness = fly.dot.brightness * (0.51 + 0.14 * (1 - exp(-4 * held))) * fade
            result.append(Glow(center: SIMD4(palm.center + offset + release, brightness),
                               radius: pickupRadius(fly.dot) * (1 + spread * 0.43), color: fly.dot.color,
                               softness: 0.44, lift: 0.29 + spread * 0.22))
        }
        return result
    }

    private static func palmOffset(_ offset: SIMD3<Float>, normal: SIMD3<Float>) -> SIMD3<Float> {
        offset - normal * (0.68 * simd_dot(offset, normal))
    }

    private static func smooth(_ a: Float, _ b: Float, _ value: Float) -> Float {
        let t = min(1, max(0, (value - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    private static func luma(_ color: UInt32) -> Float {
        let rgb = SIMD3(Float(color & 255), Float((color >> 8) & 255), Float((color >> 16) & 255))
        return simd_dot(rgb, [0.2126, 0.7152, 0.0722]) / 255
    }

    private static func grainDirection(_ i: Int) -> SIMD3<Float> {
        let angle = Float(i) * 2.39996323
        let z = 2 * (Float(i) * 0.61803399).truncatingRemainder(dividingBy: 1) - 1
        let r = sqrt(max(0, 1 - z * z))
        return [r * cos(angle), z, r * sin(angle)]
    }

    private static func noise(_ index: Int, _ salt: UInt32) -> Float {
        var a = UInt32(truncatingIfNeeded: index) &* 2_654_435_761 &+ salt &* 2_246_822_519
        a = (a ^ (a >> 16)) &* 2_246_822_519
        return Float((a ^ (a >> 13)) & 0xffff) / 65535
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { [x, y, z] }
}
