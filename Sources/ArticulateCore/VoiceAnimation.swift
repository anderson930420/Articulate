import SwiftUI

/// Looks for the recording animation (設定 › 一般 › 錄音動畫).
enum WaveStyle: String, CaseIterable, Identifiable {
    /// White bars, taller in the middle (dictation apps such as Wispr Flow).
    case bars
    /// Layered sine lines that taper at both ends (classic Siri).
    case line
    /// Rings spreading out from a dot.
    case ripple
    /// Four coloured dots that stretch with the voice (Google Assistant).
    case dots
    /// A soft colour orb that changes shape with the voice (Siri, Gemini, ChatGPT voice).
    case orb

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bars: "音量條"
        case .line: "波形線"
        case .ripple: "波紋"
        case .dots: "跳動圓點"
        case .orb: "光球"
        }
    }

    var size: CGSize {
        switch self {
        case .bars: CGSize(width: 87, height: 24)
        case .line: CGSize(width: 96, height: 24)
        case .ripple: CGSize(width: 30, height: 24)
        case .dots: CGSize(width: 44, height: 24)
        case .orb: CGSize(width: 28, height: 24)
        }
    }

    static var current: WaveStyle { WaveStyle(rawValue: UserDefaults.standard.string(forKey: "waveStyle") ?? "") ?? .bars }
}

/// The recording animation. While listening it follows the microphone level; while Articulate works it
/// switches to a calmer motion, so the two states never look alike. Drawn once per display frame
/// into a Canvas, so it stays smooth and never re-lays out the floating bar.
struct Waveform: View {
    enum Source {
        case meter(LevelMeter)
        /// A made-up voice, for the preview in Settings.
        case demo
    }

    let source: Source
    var working = false
    var style: WaveStyle = .bars
    /// Measured with `--check-bar`: 120 Hz (every ProMotion refresh) about 10% CPU, 60 Hz 7%, 30 Hz 4%.
    /// 60 looks as smooth as 120 for a level meter. ARTICULATE_WAVE_FPS overrides it for measurements.
    static let frameInterval: Double = 1.0 / (Double(ProcessInfo.processInfo.environment["ARTICULATE_WAVE_FPS"] ?? "") ?? 60)

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.frameInterval)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let level = working ? 0 : levelValue(at: time)
            Canvas { context, size in
                switch style {
                case .bars: Self.drawBars(&context, size, time, level, working)
                case .line: Self.drawLine(&context, size, time, level, working)
                case .ripple: Self.drawRipple(&context, size, time, level, working)
                case .dots: Self.drawDots(&context, size, time, level, working)
                case .orb: Self.drawOrb(&context, size, time, level, working)
                }
            }
        }
        .frame(width: style.size.width, height: style.size.height)
    }

    private func levelValue(at time: Double) -> Double {
        switch source {
        case .meter(let meter):
            return Double(meter.value(at: time))
        case .demo:
            // Syllables inside phrases, with short pauses between phrases.
            let phrase = max(0, sin(time * 0.9))
            let syllables = 0.55 + 0.45 * sin(time * 7.3) * sin(time * 3.1)
            return min(1, phrase * syllables * 1.1)
        }
    }

    /// 1 in the middle, falling towards both ends.
    private static func bell(_ x: Double, sharpness: Double = 1.8) -> Double { exp(-sharpness * x * x) }

    // MARK: Bars

    private static func drawBars(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double, _ level: Double, _ working: Bool) {
        let count = 15
        let width: CGFloat = 3
        let step = (size.width - width) / CGFloat(count - 1)
        for i in 0..<count {
            let envelope = bell((Double(i) - Double(count - 1) / 2) / (Double(count - 1) / 2))
            let height: CGFloat
            if working {
                let wave = 0.5 + 0.5 * sin(t * 4.5 - Double(i) * 0.7)
                height = 4 + 14 * wave * (0.35 + 0.65 * envelope)
            } else {
                let flutter = 0.7 + 0.3 * sin(t * 11 + Double(i) * 1.7)
                let breathe = 0.5 + 0.5 * sin(t * 2.2 + Double(i) * 0.45)
                height = 4 + 2 * breathe + (size.height - 6) * min(1, level * 1.15) * envelope * flutter
            }
            let rect = CGRect(x: CGFloat(i) * step, y: (size.height - height) / 2, width: width, height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(.white.opacity(0.5 + 0.5 * envelope)))
        }
    }

    // MARK: Line

    private static func drawLine(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double, _ level: Double, _ working: Bool) {
        let mid = size.height / 2
        let loudness = working ? 0.3 : 0.08 + 0.92 * min(1, level * 1.2)
        let speed = working ? 2.0 : 6.0
        // Back to front: faint, wide curves behind a bright main line.
        let curves: [(cycles: Double, phase: Double, opacity: Double, width: CGFloat, scale: Double)] = [
            (2.6, 1.3, 0.25, 1, 0.55),
            (1.9, 2.1, 0.45, 1.2, 0.75),
            (1.4, 0.0, 1.0, 1.8, 1.0),
        ]
        for curve in curves {
            var path = Path()
            let steps = 60
            for s in 0...steps {
                let x = Double(s) / Double(steps)
                let taper = pow(sin(.pi * x), 2)
                let y = sin(2 * .pi * curve.cycles * x - t * speed + curve.phase) * taper * loudness * curve.scale
                let point = CGPoint(x: x * size.width, y: mid - y * (mid - 1.5))
                if s == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(.white.opacity(curve.opacity)),
                           style: StrokeStyle(lineWidth: curve.width, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: Ripple

    private static func drawRipple(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double, _ level: Double, _ working: Bool) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = min(size.width, size.height) / 2 - 0.5
        let rings = 3
        let speed = working ? 0.45 : 0.55 + 1.1 * level
        for i in 0..<rings {
            // Each ring travels outward and fades; louder speech sends them faster and brighter.
            let progress = (t * speed + Double(i) / Double(rings)).truncatingRemainder(dividingBy: 1)
            let radius = 4 + progress * (maxRadius - 4)
            let strength = working ? 0.55 : 0.3 + 0.7 * min(1, level * 1.3)
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity((1 - progress) * strength)), lineWidth: 1.4)
        }
        let dot = working ? 3.2 + 0.6 * sin(t * 3) : 3 + 2.2 * min(1, level * 1.2)
        context.fill(Path(ellipseIn: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2)), with: .color(.white))
    }

    // MARK: Dots

    private static let dotColors: [Color] = [
        Color(red: 0.26, green: 0.52, blue: 0.96),
        Color(red: 0.92, green: 0.26, blue: 0.21),
        Color(red: 0.98, green: 0.74, blue: 0.02),
        Color(red: 0.20, green: 0.66, blue: 0.33),
    ]

    private static func drawDots(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double, _ level: Double, _ working: Bool) {
        let diameter: CGFloat = 6.5
        let gap = (size.width - diameter * 4) / 3
        for (i, color) in dotColors.enumerated() {
            let x = CGFloat(i) * (diameter + gap)
            var height = diameter
            var lift: CGFloat = 0
            if working {
                // One after another, like a loading indicator.
                lift = CGFloat(5 * max(0, sin(t * 6 - Double(i) * 0.9)))
            } else {
                // Speech stretches the dots into bars; the middle two stretch most.
                let weight = i == 1 || i == 2 ? 1.0 : 0.7
                let flutter = 0.65 + 0.35 * sin(t * 10 + Double(i) * 2.1)
                height += CGFloat(min(1, level * 1.2) * weight * flutter) * (size.height - diameter)
            }
            let rect = CGRect(x: x, y: (size.height - height) / 2 - lift, width: diameter, height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: diameter / 2), with: .color(color))
        }
    }

    // MARK: Orb

    private static func drawOrb(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double, _ level: Double, _ working: Bool) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let loud = min(1, level * 1.2)
        let base = working ? 8.5 + 0.8 * sin(t * 2.4) : 7.5 + 3 * loud
        let wobble = working ? 0.04 : 0.05 + 0.13 * loud
        var blob = Path()
        let steps = 72
        for s in 0...steps {
            let angle = Double(s) / Double(steps) * 2 * .pi
            let r = base * (1 + wobble * sin(3 * angle + t * 3.1) + wobble * 0.6 * sin(5 * angle - t * 2.3))
            let point = CGPoint(x: center.x + CGFloat(cos(angle) * r), y: center.y + CGFloat(sin(angle) * r))
            if s == 0 { blob.move(to: point) } else { blob.addLine(to: point) }
        }
        blob.closeSubpath()
        let spin = Angle(radians: t * (working ? 1.2 : 2.0))
        let colors: [Color] = [.cyan, .blue, .purple, .pink, .orange, .cyan]
        // A soft glow behind the orb grows with the voice.
        var glow = context
        glow.addFilter(.blur(radius: 3))
        glow.opacity = working ? 0.5 : 0.35 + 0.5 * loud
        glow.fill(blob, with: .conicGradient(Gradient(colors: colors), center: center, angle: spin))
        context.fill(blob, with: .conicGradient(Gradient(colors: colors), center: center, angle: spin))
        // A bright core keeps it reading as light rather than a flat disc.
        let core = base * 0.45
        context.fill(Path(ellipseIn: CGRect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2)),
                     with: .radialGradient(Gradient(colors: [.white.opacity(0.85), .white.opacity(0)]),
                                           center: center, startRadius: 0, endRadius: core))
    }
}
