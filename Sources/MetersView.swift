import SwiftUI
import Combine

// MARK: - 仪表数据驱动

final class MeterModel: ObservableObject {
    @Published var frame = MeterFrame()

    private let analyzer: AudioAnalyzer
    private var timer: Timer?

    init(analyzer: AudioAnalyzer) {
        self.analyzer = analyzer
    }

    func start() {
        guard timer == nil else { return }
        let newTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.frame = self.analyzer.computeFrame()
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        frame = MeterFrame()
    }

    deinit {
        timer?.invalidate()
    }
}

// MARK: - 仪表面板

struct MetersView: View {
    @ObservedObject var meter: MeterModel
    @ObservedObject private var theme = Theme.shared
    var onClose: () -> Void

    private let floorDB: Float = -72

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            spectrumBox
            waveformBox
            HStack(alignment: .top, spacing: 12) {
                loudnessBox
                levelBox
            }
            phaseBox
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 330)
        .background(theme.bar)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("仪表")
                .font(.system(size: 12, weight: .semibold))
            Text(meter.frame.active ? "实时" : "静音")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("收起仪表（⌘M）")
        }
    }

    // MARK: 频谱

    private var spectrumBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("频谱")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("24 Hz – 20 kHz · 72 段")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Canvas { context, size in
                let count = meter.frame.spectrum.count
                guard count > 0 else { return }
                drawGrid(context: context, size: size)
                let gap: CGFloat = 1
                let barWidth = max(1, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
                let accent = theme.accent

                for i in 0..<count {
                    let x = CGFloat(i) * (barWidth + gap)
                    let ratio = CGFloat(normalize(meter.frame.spectrum[i]))
                    let height = max(0.5, ratio * size.height)
                    let rect = CGRect(x: x, y: size.height - height, width: barWidth, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: min(2, barWidth / 2)), with: .color(accent.opacity(0.85)))

                    let peakValue = meter.frame.peaks[i]
                    if peakValue > floorDB + 1 {
                        let peakRatio = CGFloat(normalize(peakValue))
                        let peakY = size.height - peakRatio * size.height
                        let cap = CGRect(x: x, y: max(0, peakY - 1.5), width: barWidth, height: 2)
                        context.fill(Path(cap), with: .color(.orange.opacity(0.9)))
                    }
                }
            }
            .frame(height: 118)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.elevated.opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.separator, lineWidth: 0.5)
            )
        }
    }

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        var path = Path()
        for line in 1...3 {
            let y = size.height * CGFloat(line) / 4
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(path, with: .color(Color.primary.opacity(0.06)), lineWidth: 0.5)
    }

    private func normalize(_ db: Float) -> Float {
        max(0, min(1, (db - floorDB) / (0 - floorDB)))
    }

    // MARK: 波形

    private var waveformBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("波形")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Canvas { context, size in
                var path = Path()
                let points = meter.frame.waveform
                guard points.count > 1 else { return }
                let mid = size.height / 2
                let step = size.width / CGFloat(points.count - 1)
                for (index, value) in points.enumerated() {
                    let x = CGFloat(index) * step
                    let y = mid - CGFloat(max(-1, min(1, value))) * (mid - 2)
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                context.stroke(path, with: .color(theme.accent.opacity(0.9)), lineWidth: 1.2)

                var axis = Path()
                axis.move(to: CGPoint(x: 0, y: mid))
                axis.addLine(to: CGPoint(x: size.width, y: mid))
                context.stroke(axis, with: .color(Color.primary.opacity(0.08)), lineWidth: 0.5)
            }
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.elevated.opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.separator, lineWidth: 0.5)
            )
        }
    }

    // MARK: 响度

    private var loudnessBox: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("响度 LUFS")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            loudnessRow("M", value: meter.frame.lufsM, hint: "400ms")
            loudnessRow("S", value: meter.frame.lufsS, hint: "3s")
            loudnessRow("I", value: meter.frame.lufsI, hint: "整首")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loudnessRow(_ label: String, value: Float, hint: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 10, alignment: .leading)

            GeometryReader { geo in
                let width = geo.size.width
                let ratio = CGFloat(max(0, min(1, (value + 40) / 40)))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.07))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.accent.opacity(0.85))
                        .frame(width: max(2, width * ratio))
                }
            }
            .frame(height: 7)

            Text(value > -69 ? String(format: "%.1f", value) : "—")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .help("\(label) 加权响度（\(hint)）")
    }

    // MARK: 电平

    private var levelBox: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("电平 dBFS")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                levelBar(value: meter.frame.levelL, peak: meter.frame.peakL)
                levelBar(value: meter.frame.levelR, peak: meter.frame.peakR)
                VStack(alignment: .leading, spacing: 2) {
                    Text("L")
                    Text("R")
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func levelBar(value: Float, peak: Float) -> some View {
        GeometryReader { geo in
            let height = geo.size.height
            let ratio = CGFloat(max(0, min(1, (value + 60) / 60)))
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary.opacity(0.07))
                RoundedRectangle(cornerRadius: 2)
                    .fill(levelColor(value))
                    .frame(height: max(1, height * ratio))
                if peak > -59 {
                    let peakRatio = CGFloat(max(0, min(1, (peak + 60) / 60)))
                    Rectangle()
                        .fill(Color.orange)
                        .frame(height: 1.5)
                        .offset(y: -max(0, height * peakRatio - 1.5))
                }
            }
        }
        .frame(width: 12, height: 58)
        .overlay(alignment: .bottom) { EmptyView() }
        .help(String(format: "%.1f dBFS", value))
    }

    private func levelColor(_ db: Float) -> Color {
        if db > -3 { return .red }
        if db > -12 { return .orange }
        return theme.accent
    }

    // MARK: 相位

    private var phaseBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("相位 / 立体声")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 - 2

                var ring = Path()
                ring.addEllipse(in: CGRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2
                ))
                context.stroke(ring, with: .color(Color.primary.opacity(0.1)), lineWidth: 0.5)

                var cross = Path()
                cross.move(to: CGPoint(x: center.x, y: center.y - radius))
                cross.addLine(to: CGPoint(x: center.x, y: center.y + radius))
                cross.move(to: CGPoint(x: center.x - radius, y: center.y))
                cross.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                context.stroke(cross, with: .color(Color.primary.opacity(0.08)), lineWidth: 0.5)

                let xs = meter.frame.gonX
                let ys = meter.frame.gonY
                guard xs.count == ys.count, !xs.isEmpty else { return }

                for i in 0..<xs.count {
                    let px = center.x + CGFloat(xs[i]) * radius
                    let py = center.y - CGFloat(ys[i]) * radius
                    guard abs(px - center.x) <= radius, abs(py - center.y) <= radius else { continue }
                    let dot = CGRect(x: px - 0.7, y: py - 0.7, width: 1.4, height: 1.4)
                    context.fill(Path(ellipseIn: dot), with: .color(theme.accent.opacity(0.75)))
                }
            }
            .frame(height: 74)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.elevated.opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.separator, lineWidth: 0.5)
            )
            .help("越靠中间越单声道，越靠左右越宽；上下分离过大可能有相位问题")
        }
    }
}
