import CoreGraphics
import ImageIO

struct PhotoColors: Sendable {
    private static let side = 128
    private let pixels: [UInt32]
    let aspect: Float

    init?(image: CGImage) {
        let size = Self.side
        let count = size * size
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let canvas = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                     bytesPerRow: size * 4, space: space, bitmapInfo: info),
              let data = canvas.data else { return nil }
        canvas.interpolationQuality = .medium
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        pixels = (0..<count).map { i in
            let j = i * 4
            return UInt32(bytes[j]) | UInt32(bytes[j + 1]) << 8 | UInt32(bytes[j + 2]) << 16
        }
        aspect = Float(image.width) / Float(image.height)
    }

    func sample(_ u: Float, _ v: Float) -> UInt32 {
        let x = min(Self.side - 1, max(0, Int(u * Float(Self.side))))
        let y = min(Self.side - 1, max(0, Int(v * Float(Self.side))))
        return pixels[y * Self.side + x]
    }
}
