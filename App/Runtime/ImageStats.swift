import AppKit

/// Cheap pixel statistics on downsampled snapshots, used by smoke tests.
nonisolated struct PixelSample: Sendable {
    static let side = 192
    let rgba: [UInt8]

    init?(_ image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = Self.side
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return nil }
        rgba = buffer
    }

    /// Share of pixels that fall in the most common coarse color bucket (1.0 = a single flat color).
    var dominantColorShare: Double {
        var counts = [Int](repeating: 0, count: 512)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let bucket = Int(rgba[i] >> 5) << 6 | Int(rgba[i + 1] >> 5) << 3 | Int(rgba[i + 2] >> 5)
            counts[bucket] += 1
        }
        return Double(counts.max() ?? 0) / Double(rgba.count / 4)
    }

    /// Share of pixels whose color changed noticeably between two samples.
    func changedShare(comparedTo other: PixelSample) -> Double {
        var changed = 0
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let d = abs(Int(rgba[i]) - Int(other.rgba[i])) + abs(Int(rgba[i + 1]) - Int(other.rgba[i + 1]))
                + abs(Int(rgba[i + 2]) - Int(other.rgba[i + 2]))
            if d > 24 { changed += 1 }
        }
        return Double(changed) / Double(rgba.count / 4)
    }
}

extension NSImage {
    /// PNG data scaled so the longest side is at most `maxPixels`.
    func pngData(maxPixels: CGFloat) -> (Data, Int, Int)? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxPixels / CGFloat(max(cg.width, cg.height)))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaled)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return (data, w, h)
    }
}
