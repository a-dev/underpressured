import Dispatch
import Foundation

/// Independent reference downscaler: separable Lanczos-`taps` in linear light,
/// float32 storage, float64 accumulation, no vImage. Output is sRGB 8-bit.
private struct Weights {
    var start: [Int32] = []
    var count: [Int32] = []
    var offset: [Int] = []
    var w: [Float] = []
}

private func lanczos(_ x: Double, _ a: Double) -> Double {
    if x == 0 { return 1 }
    if abs(x) >= a { return 0 }
    let px = Double.pi * x
    return a * sin(px) * sin(px / a) / (px * px)
}

private func makeWeights(src: Int, dst: Int, taps: Double) -> Weights {
    let scale = Double(src) / Double(dst)
    let support = taps * scale
    var out = Weights()
    for i in 0..<dst {
        let c = (Double(i) + 0.5) * scale - 0.5
        let lo = max(0, Int((c - support).rounded(.up)))
        let hi = min(src - 1, Int((c + support).rounded(.down)))
        var ws: [Double] = []
        var sum = 0.0
        for j in lo...hi {
            let v = lanczos((Double(j) - c) / scale, taps)
            ws.append(v)
            sum += v
        }
        out.start.append(Int32(lo))
        out.count.append(Int32(ws.count))
        out.offset.append(out.w.count)
        for v in ws { out.w.append(Float(v / sum)) }
    }
    return out
}

private func srgbToLinear(_ v: Double) -> Double {
    v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
}

private func linearToSRGB(_ v: Double) -> Double {
    v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
}

func referenceDownscale(_ src: Pixels, width dw: Int, height dh: Int, taps: Int) -> Pixels {
    let sw = src.width
    let sh = src.height
    let a = Double(taps)
    let lut = (0..<256).map { Float(srgbToLinear(Double($0) / 255)) }
    let hw = makeWeights(src: sw, dst: dw, taps: a)
    let vw = makeWeights(src: sh, dst: dh, taps: a)

    // Horizontal pass: sh rows x dw columns x 3 channels, linear light.
    let mid = UnsafeMutablePointer<Float>.allocate(capacity: sh * dw * 3)
    defer { mid.deallocate() }
    let midP = SendPtr(p: mid)
    let sBytes = src.data.assumingMemoryBound(to: UInt8.self)
    let sP = SendPtr(p: UnsafeMutablePointer(mutating: sBytes))
    let rowBytes = src.rowBytes
    DispatchQueue.concurrentPerform(iterations: sh) { y in
        let row = sP.p + y * rowBytes
        let o = midP.p + y * dw * 3
        for x in 0..<dw {
            let s = Int(hw.start[x])
            let n = Int(hw.count[x])
            let off = hw.offset[x]
            var r = 0.0, g = 0.0, b = 0.0
            for k in 0..<n {
                let w = Double(hw.w[off + k])
                let px = row + (s + k) * 4
                r += w * Double(lut[Int(px[0])])
                g += w * Double(lut[Int(px[1])])
                b += w * Double(lut[Int(px[2])])
            }
            o[x * 3] = Float(r)
            o[x * 3 + 1] = Float(g)
            o[x * 3 + 2] = Float(b)
        }
    }

    // Vertical pass + sRGB encode.
    let dst = Pixels(width: dw, height: dh)
    let dBytes = dst.data.assumingMemoryBound(to: UInt8.self)
    let dP = SendPtr(p: dBytes)
    DispatchQueue.concurrentPerform(iterations: dh) { y in
        let s = Int(vw.start[y])
        let n = Int(vw.count[y])
        let off = vw.offset[y]
        var acc = [Double](repeating: 0, count: dw * 3)
        for k in 0..<n {
            let w = Double(vw.w[off + k])
            let row = midP.p + (s + k) * dw * 3
            for i in 0..<(dw * 3) { acc[i] += w * Double(row[i]) }
        }
        let o = dP.p + y * dst.rowBytes
        for x in 0..<dw {
            for c in 0..<3 {
                let v = min(1, max(0, acc[x * 3 + c]))
                o[x * 4 + c] = UInt8((linearToSRGB(v) * 255).rounded())
            }
            o[x * 4 + 3] = 255
        }
    }
    return dst
}
