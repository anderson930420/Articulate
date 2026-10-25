import AppKit
import CoreImage
import Vision

// Traces the dark shapes of a scanned drawing into smooth closed curves; writes mark.svg and mark.path
// (the path data that Sources/Articulate/LogoPath.swift holds).
//   swiftc -O -o /tmp/trace_logo Tools/trace_logo.swift && /tmp/trace_logo design/logo-source.png <out-dir>
// Steps: upscale 8× and threshold → Vision contours → even resampling → Gaussian smoothing along the outline
// (removes the marker's ragged edge, keeps the shape) → Douglas–Peucker → cubic curves.
let args = CommandLine.arguments
let input = URL(fileURLWithPath: args[1]), outDir = URL(fileURLWithPath: args[2])
let blurSigma = Double(args.count > 3 ? args[3] : "0.8")!     // image blur before thresholding, source pixels
let epsilon = Double(args.count > 4 ? args[4] : "0.08")!      // simplification tolerance, source pixels
let cornerDegrees = Double(args.count > 5 ? args[5] : "179")! // turns sharper than this stay corners
let smoothSigma = Double(args.count > 6 ? args[6] : "5")!     // outline smoothing, source pixels

let source = CIImage(contentsOf: input)!
let scale = 8.0
let gray = source.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
let big = gray.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
let blurred = big.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurSigma * scale]).cropped(to: big.extent)
// Hard threshold at the middle grey.
let thresholded = blurred.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.5])
let ctx = CIContext()
let cg = ctx.createCGImage(thresholded, from: thresholded.extent)!
let W = Double(cg.width), H = Double(cg.height)

let request = VNDetectContoursRequest()
request.detectsDarkOnLight = true
request.contrastAdjustment = 1
request.maximumImageDimension = max(cg.width, cg.height)
try VNImageRequestHandler(cgImage: cg).perform([request])
let observation = request.results!.first!

// Shoelace area in pixels.
func area(_ p: [CGPoint]) -> Double {
    var a = 0.0
    for i in p.indices { let j = (i + 1) % p.count; a += Double(p[i].x * p[j].y - p[j].x * p[i].y) }
    return abs(a) / 2
}

// Douglas–Peucker on a closed ring.
func simplify(_ pts: [CGPoint], _ eps: Double) -> [CGPoint] {
    func dp(_ p: ArraySlice<CGPoint>) -> [CGPoint] {
        guard p.count > 2, let a = p.first, let b = p.last else { return Array(p) }
        let dx = b.x - a.x, dy = b.y - a.y, len = max(1e-9, hypot(dx, dy))
        var best = 0.0, idx = p.startIndex
        for i in p.indices.dropFirst().dropLast() {
            let d = abs(Double(dy * p[i].x - dx * p[i].y + b.x * a.y - b.y * a.x)) / Double(len)
            if d > best { best = d; idx = i }
        }
        if best <= eps { return [a, b] }
        return dp(p[p.startIndex...idx]).dropLast() + dp(p[idx...p.endIndex - 1])
    }
    // Split the ring at the point farthest from the first one.
    let far = pts.indices.max { hypot(pts[$0].x - pts[0].x, pts[$0].y - pts[0].y) < hypot(pts[$1].x - pts[0].x, pts[$1].y - pts[0].y) }!
    let first = dp(pts[0...far]), second = dp((Array(pts[far...]) + [pts[0]])[...])
    return Array(first.dropLast() + second.dropLast())
}

// Evenly spaced points along the closed outline.
func resample(_ pts: [CGPoint], _ step: Double) -> [CGPoint] {
    var out: [CGPoint] = []
    var carry = 0.0
    for i in pts.indices {
        let a = pts[i], b = pts[(i + 1) % pts.count]
        let len = hypot(Double(b.x - a.x), Double(b.y - a.y))
        var t = carry
        while t < len {
            let f = CGFloat(t / len)
            out.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            t += step
        }
        carry = t - len
    }
    return out
}

// Gaussian smoothing along the outline (sigma in source pixels; the points are 0.4 px apart).
func smooth(_ pts: [CGPoint], _ sigma: Double) -> [CGPoint] {
    let s = sigma / 0.4, r = Int(ceil(s * 3)), n = pts.count
    let weights = (-r...r).map { exp(-Double($0 * $0) / (2 * s * s)) }
    let total = weights.reduce(0, +)
    return (0..<n).map { i in
        var x = 0.0, y = 0.0
        for (k, w) in zip(-r...r, weights) {
            let p = pts[((i + k) % n + n) % n]
            x += Double(p.x) * w; y += Double(p.y) * w
        }
        return CGPoint(x: x / total, y: y / total)
    }
}

var shapes: [[CGPoint]] = []
func collect(_ c: VNContour) {
    // Vision points are normalised with a bottom-left origin; convert to source pixels, y down.
    let pts = c.normalizedPoints.map { CGPoint(x: Double($0.x) * W / scale, y: (1 - Double($0.y)) * H / scale) }
    if area(pts) > 30 { shapes.append(simplify(smooth(resample(pts, 0.4), smoothSigma), epsilon)) }
    for child in c.childContours { collect(child) }
}
for c in observation.topLevelContours { collect(c) }

// Corner-aware Catmull–Rom: sharp turns stay sharp (straight in and out), the rest becomes cubic curves.
func svgPath(_ shape: [CGPoint]) -> String {
    let n = shape.count
    func angle(_ i: Int) -> Double {
        let a = shape[(i - 1 + n) % n], b = shape[i], c = shape[(i + 1) % n]
        let v1 = (b.x - a.x, b.y - a.y), v2 = (c.x - b.x, c.y - b.y)
        let dot = Double(v1.0 * v2.0 + v1.1 * v2.1), cross = Double(v1.0 * v2.1 - v1.1 * v2.0)
        return abs(atan2(cross, dot)) * 180 / .pi
    }
    let corner = (0..<n).map { angle($0) > cornerDegrees }
    // Unit tangent through each point; handles are a third of each segment's own length, so uneven spacing
    // can't make a curve overshoot into a kink.
    func direction(_ i: Int) -> CGPoint {
        if corner[i] { return .zero }
        let a = shape[(i - 1 + n) % n], c = shape[(i + 1) % n]
        let len = max(1e-9, hypot(c.x - a.x, c.y - a.y))
        return CGPoint(x: (c.x - a.x) / len, y: (c.y - a.y) / len)
    }
    func f(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }
    var d = "M\(f(shape[0].x)) \(f(shape[0].y))"
    for i in 0..<n {
        let p0 = shape[i], p1 = shape[(i + 1) % n], d0 = direction(i), d1 = direction((i + 1) % n)
        let h = hypot(p1.x - p0.x, p1.y - p0.y) / 3
        d += " C\(f(p0.x + d0.x * h)) \(f(p0.y + d0.y * h)) \(f(p1.x - d1.x * h)) \(f(p1.y - d1.y * h)) \(f(p1.x)) \(f(p1.y))"
    }
    return d + " Z"
}

let paths = shapes.map(svgPath)
var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
for s in shapes { for p in s { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) } }
print("shapes:", shapes.map(\.count), "bounds:", minX, minY, maxX, maxY)
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="\(minX) \(minY) \(maxX - minX) \(maxY - minY)">
<path fill="#000" fill-rule="evenodd" d="\(paths.joined(separator: " "))"/>
</svg>
"""
try svg.write(to: outDir.appendingPathComponent("mark.svg"), atomically: true, encoding: .utf8)
try paths.joined(separator: "\n").write(to: outDir.appendingPathComponent("mark.path"), atomically: true, encoding: .utf8)
