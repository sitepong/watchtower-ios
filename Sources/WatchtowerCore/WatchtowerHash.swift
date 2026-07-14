import Foundation

/// dHash perceptual hash — Swift port that MUST stay byte-identical to the
/// reference TypeScript implementation in `@sitepong/capture-core`.
///
/// Algorithm (spec §2):
///   1. Input is RGBA (redaction already applied, §5).
///   2. Grayscale: gray = round(0.299 R + 0.587 G + 0.114 B).
///   3. Bilinear resize to width=9, height=8 (8 rows x 9 cols of gray),
///      half-pixel-center / align-corners=false.
///   4. For each row, cols c in 0..7: bit = (gray[r][c] < gray[r][c+1]) ? 1 : 0.
///   5. Row-major, row 0 first; within a row, c=0 is the MSB of that byte.
///      => 64 bits => 8 bytes => 16 lowercase hex chars (MSB first).
public enum WatchtowerHash {

    public static let dHashWidth = 9
    public static let dHashHeight = 8

    /// ITU-R BT.601 luma weights, matched exactly across TS and Swift.
    @inline(__always)
    static func toGray(_ r: Double, _ g: Double, _ b: Double) -> Double {
        // Swift's rounded() uses .toNearestOrAwayFromZero, matching JS Math.round
        // for the non-negative values produced here.
        return (0.299 * r + 0.587 * g + 0.114 * b).rounded()
    }

    /// Convert an RGBA byte buffer to a full-resolution grayscale plane.
    static func rgbaToGray(_ rgba: [UInt8], width: Int, height: Int) -> [Double] {
        var out = [Double](repeating: 0, count: width * height)
        let count = width * height
        for i in 0..<count {
            let o = i * 4
            out[i] = toGray(Double(rgba[o]), Double(rgba[o + 1]), Double(rgba[o + 2]))
        }
        return out
    }

    /// Bilinear resize of a single-channel grayscale plane to dstW x dstH using
    /// the align-corners=false half-pixel center mapping:
    ///   srcX = (dstX + 0.5) * (srcW / dstW) - 0.5  (clamped)
    static func bilinearResizeGray(
        _ src: [Double], srcW: Int, srcH: Int, dstW: Int, dstH: Int
    ) -> [Double] {
        var dst = [Double](repeating: 0, count: dstW * dstH)
        let scaleX = Double(srcW) / Double(dstW)
        let scaleY = Double(srcH) / Double(dstH)

        for dy in 0..<dstH {
            var sy = (Double(dy) + 0.5) * scaleY - 0.5
            if sy < 0 { sy = 0 }
            if sy > Double(srcH - 1) { sy = Double(srcH - 1) }
            let y0 = Int(sy.rounded(.down))
            let y1 = min(y0 + 1, srcH - 1)
            let wy = sy - Double(y0)

            for dx in 0..<dstW {
                var sx = (Double(dx) + 0.5) * scaleX - 0.5
                if sx < 0 { sx = 0 }
                if sx > Double(srcW - 1) { sx = Double(srcW - 1) }
                let x0 = Int(sx.rounded(.down))
                let x1 = min(x0 + 1, srcW - 1)
                let wx = sx - Double(x0)

                let p00 = src[y0 * srcW + x0]
                let p01 = src[y0 * srcW + x1]
                let p10 = src[y1 * srcW + x0]
                let p11 = src[y1 * srcW + x1]

                let top = p00 + (p01 - p00) * wx
                let bottom = p10 + (p11 - p10) * wx
                dst[dy * dstW + dx] = top + (bottom - top) * wy
            }
        }
        return dst
    }

    /// Compute the dHash of an RGBA image. Returns 16-char lowercase hex.
    public static func dHash(rgba: [UInt8], width: Int, height: Int) -> String {
        precondition(width > 0 && height > 0, "dHash: invalid dimensions")
        precondition(rgba.count >= width * height * 4, "dHash: rgba buffer too short")

        let gray = rgbaToGray(rgba, width: width, height: height)
        let small = bilinearResizeGray(gray, srcW: width, srcH: height,
                                       dstW: dHashWidth, dstH: dHashHeight)

        var bytes = [UInt8](repeating: 0, count: 8)
        for row in 0..<dHashHeight {
            var byte = 0
            for c in 0..<8 {
                let left = small[row * dHashWidth + c]
                let right = small[row * dHashWidth + c + 1]
                let bit = left < right ? 1 : 0
                byte |= bit << (7 - c)
            }
            bytes[row] = UInt8(byte)
        }

        var hex = ""
        hex.reserveCapacity(16)
        for i in 0..<8 {
            hex += String(format: "%02x", bytes[i])
        }
        return hex
    }

    /// Hamming distance between two dHash hex strings (popcount of XOR).
    public static func hamming(_ a: String, _ b: String) -> Int {
        let ac = Array(a), bc = Array(b)
        guard ac.count == bc.count, ac.count % 2 == 0 else { return Int.max }
        var dist = 0
        var i = 0
        while i < ac.count {
            let byteA = UInt8(String(ac[i...(i + 1)]), radix: 16) ?? 0
            let byteB = UInt8(String(bc[i...(i + 1)]), radix: 16) ?? 0
            dist += (byteA ^ byteB).nonzeroBitCount
            i += 2
        }
        return dist
    }
}
