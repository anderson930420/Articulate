import AppKit

/// The Articulate marks. `LogoStyle.handwritten` is a hand-drawn V with a small heart, traced from the drawing in
/// design/logo-source.png (Tools/trace_logo.swift) into smooth curves and filled. `LogoStyle.wave` is the
/// original mark: a voice wave that settles into a line of text, stroked. The app icon, the sidebar logo and the
/// menu-bar icon all come from here; `Prefs.logoStyle` picks the mark.
enum LogoMark {
    // MARK: Hand-drawn V

    /// The outline, y down, in the drawing's pixels.
    static let path: CGPath = parse(LogoPath.data)

    /// Reads the absolute M/C/Z path data the tracer writes.
    private static func parse(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var numbers: [CGFloat] = []
        var command: Character = " "
        func flush() {
            switch command {
            case "M" where numbers.count >= 2:
                path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
            case "C" where numbers.count >= 6:
                path.addCurve(to: CGPoint(x: numbers[4], y: numbers[5]),
                              control1: CGPoint(x: numbers[0], y: numbers[1]), control2: CGPoint(x: numbers[2], y: numbers[3]))
            case "Z":
                path.closeSubpath()
            default:
                break
            }
            numbers.removeAll()
        }
        for token in data.split(whereSeparator: { $0 == " " || $0.isNewline }) {
            if let first = token.first, first.isLetter {
                flush()
                command = first
                if let value = Double(token.dropFirst()) { numbers.append(CGFloat(value)) }
            } else if let value = Double(token) {
                numbers.append(CGFloat(value))
            }
        }
        flush()
        return path
    }

    /// Fills the V `height` tall, centred in `rect`. `context` is a normal y-up Core Graphics context.
    static func draw(in context: CGContext, rect: CGRect, height: CGFloat, color: CGColor) {
        let bounds = path.boundingBoxOfPath
        let scale = height / bounds.height
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -bounds.midX, y: -bounds.midY)
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath()
        context.restoreGState()
    }

    // MARK: Voice wave

    /// Drawn in a 104 × 104 design space.
    enum Wave {
        static let designStroke: CGFloat = 5.5
        typealias Dashes = [(start: CGFloat, end: CGFloat)]
        static let iconDashes: Dashes = [(64, 70), (77, 85), (92, 93)]
        /// At menu-bar size the icon's gaps close up, so the dashes spread out a little.
        static let menuBarDashes: Dashes = [(66, 71), (80, 86), (95, 95)]
        /// The 16 and 32 px icons can't resolve three gaps; one dash and a dot keep the idea.
        static let tinyDashes: Dashes = [(70, 77), (90, 90)]

        /// `amplitude: 0` gives the flat "turning into text" version used while processing.
        static func path(amplitude: CGFloat = 24, dashes: Dashes = iconDashes) -> CGPath {
            let path = CGMutablePath()
            let x0: CGFloat = 10, xFlat: CGFloat = 52, xEnd: CGFloat = 57, y0: CGFloat = 52
            path.move(to: CGPoint(x: x0, y: y0))
            for x in stride(from: x0 + 0.4, through: xEnd, by: 0.4) {
                let t = (x - x0) / (xFlat - x0)
                let envelope = pow(max(0, 1 - t), 1.2)
                path.addLine(to: CGPoint(x: x, y: y0 - amplitude * envelope * sin(t * 4 * .pi)))
            }
            for (start, end) in dashes {
                path.move(to: CGPoint(x: start, y: y0))
                path.addLine(to: CGPoint(x: end, y: y0))
            }
            return path
        }

        /// Strokes the wave so its outline (round caps included) is `width` wide and centred in `rect` —
        /// vertically on its outline, or on the baseline so that every menu-bar state sits at the same height.
        static func draw(in context: CGContext, rect: CGRect, width: CGFloat, amplitude: CGFloat = 24,
                         dashes: Dashes = iconDashes, strokeScale: CGFloat = 1, onBaseline: Bool = false, color: CGColor) {
            let mark = path(amplitude: amplitude, dashes: dashes)
            let bounds = mark.boundingBoxOfPath.insetBy(dx: -designStroke / 2, dy: -designStroke / 2)
            let scale = width / bounds.width
            context.saveGState()
            context.translateBy(x: rect.midX, y: rect.midY)
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: -bounds.midX, y: onBaseline ? -52 : -bounds.midY)
            context.addPath(mark)
            context.setLineWidth(designStroke * strokeScale)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setStrokeColor(color)
            context.strokePath()
            context.restoreGState()
        }
    }

    // MARK: App icon

    /// The app icon on the macOS icon grid: a white mark on black (dark), or a black mark on white (light).
    static func appIconRep(pixels: Int, dark: Bool, style: LogoStyle = Prefs.logoStyle) -> NSBitmapImageRep {
        let size = CGFloat(pixels)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        let graphics = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext

        // macOS icon grid: 824/1024 rounded square, centred, with a soft shadow so the light one keeps its edge.
        let inset = size * 100 / 1024
        let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.03,
                          color: CGColor(gray: 0, alpha: dark ? 0.35 : 0.28))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil))
        context.setFillColor(dark ? .black : .white)
        context.fillPath()
        context.restoreGState()
        let color: CGColor = dark ? .white : .black
        switch style {
        case .handwritten:
            // The small heart needs a little more room to stay visible in the smallest sizes.
            draw(in: context, rect: rect, height: rect.height * (pixels <= 32 ? 0.72 : 0.62), color: color)
        case .wave:
            // Thin strokes vanish in the smallest sizes, so those get a heavier line and fewer dashes.
            let strokeScale: CGFloat = pixels <= 32 ? 1.5 : pixels <= 64 ? 1.3 : 1
            let dashes = pixels <= 32 ? Wave.tinyDashes : pixels <= 64 ? Wave.menuBarDashes : Wave.iconDashes
            Wave.draw(in: context, rect: rect, width: rect.width * 0.72, dashes: dashes, strokeScale: strokeScale, color: color)
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Writes every size an .iconset needs, with the default mark. The bundle icon is the dark one; while Articulate
    /// runs, `appIcon(for:)` swaps the Dock icon to match the appearance and the chosen mark.
    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for (scale, suffix) in [(1, ""), (2, "@2x")] {
                let png = appIconRep(pixels: base * scale, dark: true, style: .handwritten).representation(using: .png, properties: [:])!
                try png.write(to: directory.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
            }
        }
    }

    @MainActor private static var icons: [String: NSImage] = [:]

    /// The app icon for the chosen mark, built once per mark and appearance.
    @MainActor static func icon(dark: Bool, style: LogoStyle = Prefs.logoStyle) -> NSImage {
        let key = "\(style.rawValue)-\(dark)"
        if let icon = icons[key] { return icon }
        let image = NSImage(size: NSSize(width: 512, height: 512))
        for pixels in [1024, 512, 256, 128, 64, 32] {
            image.addRepresentation(appIconRep(pixels: pixels, dark: dark, style: style))
        }
        icons[key] = image
        return image
    }

    @MainActor static func appIcon(for appearance: NSAppearance) -> NSImage {
        icon(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    // MARK: Menu bar

    enum MenuBarStyle { case idle, recording, processing }

    /// Template image for the status item: the mark; the mark cut out of a filled rounded shape while recording;
    /// while processing, the V faded or the wave flattened.
    static func menuBarImage(_ state: MenuBarStyle, style: LogoStyle = Prefs.logoStyle) -> NSImage {
        let size = style == .handwritten ? NSSize(width: 18, height: 18) : NSSize(width: 26, height: 16)
        let image = NSImage(size: size, flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            switch (style, state) {
            case (.handwritten, .idle):
                draw(in: context, rect: bounds, height: 16, color: .black)
            case (.handwritten, .processing):
                draw(in: context, rect: bounds, height: 16, color: CGColor(gray: 0, alpha: 0.45))
            case (.handwritten, .recording):
                context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4.5, cornerHeight: 4.5, transform: nil))
                context.setFillColor(.black)
                context.fillPath()
                context.setBlendMode(.clear)
                draw(in: context, rect: bounds, height: 13, color: .black)
            case (.wave, .idle):
                Wave.draw(in: context, rect: bounds, width: 24, dashes: Wave.menuBarDashes, onBaseline: true, color: .black)
            case (.wave, .processing):
                Wave.draw(in: context, rect: bounds, width: 24, amplitude: 0, dashes: Wave.menuBarDashes, onBaseline: true, color: .black)
            case (.wave, .recording):
                context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 0, dy: 0.5), cornerWidth: 5, cornerHeight: 5, transform: nil))
                context.setFillColor(.black)
                context.fillPath()
                context.setBlendMode(.clear)
                Wave.draw(in: context, rect: bounds, width: 20, dashes: Wave.menuBarDashes, strokeScale: 0.9, onBaseline: true, color: .black)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Articulate"
        return image
    }
}
