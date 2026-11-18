import Foundation
import AVFoundation
import Accelerate

// MARK: - 一帧仪表数据

struct MeterFrame {
    var spectrum = [Float](repeating: -78, count: 72)
    var peaks = [Float](repeating: -78, count: 72)
    var waveform = [Float](repeating: 0, count: 256)
    var gonX = [Float](repeating: 0, count: 128)
    var gonY = [Float](repeating: 0, count: 128)
    var levelL: Float = -78
    var levelR: Float = -78
    var peakL: Float = -78
    var peakR: Float = -78
    var lufsM: Float = -70
    var lufsS: Float = -70
    var lufsI: Float = -70
    var active = false
}

// MARK: - 二阶滤波器（BS.1770 K 加权）

struct Biquad {
    var b0: Double = 1
    var b1: Double = 0
    var b2: Double = 0
    var a1: Double = 0
    var a2: Double = 0
    var x1: Double = 0
    var x2: Double = 0
    var y1: Double = 0
    var y2: Double = 0

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }

    mutating func reset() {
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
    }

    /// K 加权第一级：高频搁架（48kHz 标准系数）
    static func kWeightShelf() -> Biquad {
        Biquad(
            b0: 1.53512485958697,
            b1: -2.69169618940638,
            b2: 1.19839281085285,
            a1: -1.69065929318241,
            a2: 0.73248077421585
        )
    }

    /// K 加权第二级：RLB 高通
    static func kWeightHighPass() -> Biquad {
        Biquad(
            b0: 1.0,
            b1: -2.0,
            b2: 1.0,
            a1: -1.99004745483398,
            a2: 0.99007225036621
        )
    }
}

// MARK: - 分析器

final class AudioAnalyzer {

    private let fftSize = 2048
    private let bandCount = 72
    private let capacity = 8192
    private let fMin: Float = 24
    private let fMax: Float = 20000

    private var setup: FFTSetup!
    private var window: [Float] = []
    private var bandBins: [(Int, Int)] = []

    // 环形缓冲（音频线程写，主线程读）
    private var ringL = [Float](repeating: 0, count: 8192)
    private var ringR = [Float](repeating: 0, count: 8192)
    private var writeIndex = 0
    private var filled = 0
    private let lock = NSLock()

    // 采样率与响度分块
    private var sampleRate: Double = 0
    private var chunkSize = 4800
    private var chunkFrames = 0
    private var chunkSum = 0.0
    private var chunkHistory: [Float] = []
    private var cachedIntegrated: Float = -70
    private var cachedIntegratedCount = -1
    private var lastFeed = Date.distantPast

    // K 加权滤波器（左右各两级）
    private var shelfL = Biquad.kWeightShelf()
    private var rlbL = Biquad.kWeightHighPass()
    private var shelfR = Biquad.kWeightShelf()
    private var rlbR = Biquad.kWeightHighPass()

    // 绘制平滑状态
    private var smooth = [Float](repeating: -78, count: 72)
    private var peakHold = [Float](repeating: -78, count: 72)
    private var levelHoldL: Float = -78
    private var levelHoldR: Float = -78
    private var peakHoldL: Float = -78
    private var peakHoldR: Float = -78

    // 复用缓冲，避免每帧分配
    private var scratchL = [Float](repeating: 0, count: 2048)
    private var scratchR = [Float](repeating: 0, count: 2048)
    private var scratchMono = [Float](repeating: 0, count: 2048)
    private var scratchWindowed = [Float](repeating: 0, count: 2048)
    private var realPart = [Float](repeating: 0, count: 1024)
    private var imagPart = [Float](repeating: 0, count: 1024)
    private var magnitudes = [Float](repeating: 0, count: 1024)

    init() {
        let log2n = vDSP_Length(log2(Double(fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    func reset() {
        lock.lock()
        writeIndex = 0
        filled = 0
        chunkFrames = 0
        chunkSum = 0
        chunkHistory.removeAll(keepingCapacity: true)
        cachedIntegratedCount = -1
        cachedIntegrated = -70
        shelfL.reset(); rlbL.reset(); shelfR.reset(); rlbR.reset()
        lock.unlock()

        smooth = [Float](repeating: -78, count: bandCount)
        peakHold = [Float](repeating: -78, count: bandCount)
        levelHoldL = -78; levelHoldR = -78
        peakHoldL = -78; peakHoldR = -78
        lastFeed = .distantPast
    }

    // MARK: - 音频线程入口

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        let channelCount = Int(buffer.format.channelCount)
        let left = channels[0]
        let right = channelCount > 1 ? channels[1] : channels[0]

        lock.lock()

        if sampleRate == 0 {
            sampleRate = buffer.format.sampleRate
            chunkSize = max(256, Int(sampleRate * 0.1))
            buildBandBins()
        }

        for i in 0..<frames {
            let l = left[i]
            let r = right[i]

            ringL[writeIndex] = l
            ringR[writeIndex] = r
            writeIndex = (writeIndex + 1) % capacity
            if filled < capacity { filled += 1 }

            // K 加权后累积能量（BS.1770：各声道均方和）
            let kl = rlbL.process(shelfL.process(Double(l)))
            let kr = rlbR.process(shelfR.process(Double(r)))
            chunkSum += kl * kl + kr * kr
            chunkFrames += 1

            if chunkFrames >= chunkSize {
                let meanSquare = Float(chunkSum / Double(chunkFrames))
                chunkHistory.append(meanSquare)
                if chunkHistory.count > 24000 { chunkHistory.removeFirst(chunkHistory.count - 24000) }
                chunkSum = 0
                chunkFrames = 0
            }
        }

        lastFeed = Date()
        lock.unlock()
    }

    // MARK: - 主线程取一帧

    func computeFrame() -> MeterFrame {
        var frame = MeterFrame()

        lock.lock()
        let rate = sampleRate
        let count = min(filled, fftSize)
        let stereoCount = min(filled, 512)

        if count > 0 {
            let start = (writeIndex - count + capacity) % capacity
            for i in 0..<count {
                let idx = (start + i) % capacity
                scratchL[i] = ringL[idx]
                scratchR[i] = ringR[idx]
            }
        }
        let gonStart = (writeIndex - stereoCount + capacity) % capacity
        var gonL = [Float](repeating: 0, count: 128)
        var gonR = [Float](repeating: 0, count: 128)
        if stereoCount >= 256 {
            for i in 0..<128 {
                let idx = (gonStart + i * 2) % capacity
                gonL[i] = ringL[idx]
                gonR[i] = ringR[idx]
            }
        }
        lock.unlock()

        let silent = count == 0 || Date().timeIntervalSince(lastFeed) > 0.25

        if !silent, rate > 0 {
            frame.active = true

            // 波形
            let waveCount = 256
            let step = max(1, count / waveCount)
            for i in 0..<waveCount {
                let start = i * step
                let end = min(count, start + step)
                var peak: Float = 0
                if start < end {
                    for j in start..<end where abs(scratchL[j]) > abs(peak) {
                        peak = scratchL[j]
                    }
                }
                frame.waveform[i] = peak
            }

            // 相位图
            for i in 0..<128 {
                frame.gonX[i] = (gonL[i] - gonR[i]) * 0.7071
                frame.gonY[i] = (gonL[i] + gonR[i]) * 0.7071
            }

            // 电平
            var peakL: Float = 0
            var peakR: Float = 0
            for i in 0..<count {
                peakL = max(peakL, abs(scratchL[i]))
                peakR = max(peakR, abs(scratchR[i]))
            }
            let dbL = peakL > 0 ? 20 * log10(peakL) : -78
            let dbR = peakR > 0 ? 20 * log10(peakR) : -78

            levelHoldL = max(dbL, levelHoldL - 1.6)
            levelHoldR = max(dbR, levelHoldR - 1.6)
            peakHoldL = max(dbL, peakHoldL - 0.35)
            peakHoldR = max(dbR, peakHoldR - 0.35)
            frame.levelL = levelHoldL
            frame.levelR = levelHoldR
            frame.peakL = peakHoldL
            frame.peakR = peakHoldR

            // 频谱
            for i in 0..<count {
                scratchMono[i] = (scratchL[i] + scratchR[i]) * 0.5
            }
            if count < fftSize {
                for i in count..<fftSize { scratchMono[i] = 0 }
            }
            vDSP.multiply(scratchMono, window, result: &scratchWindowed)

            realPart.withUnsafeMutableBufferPointer { rp in
                imagPart.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    scratchWindowed.withUnsafeBytes { raw in
                        let complex = raw.bindMemory(to: DSPComplex.self)
                        vDSP_ctoz(complex.baseAddress!, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                    let log2n = vDSP_Length(log2(Double(fftSize)))
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
                }
            }

            let scale = 2.0 / Float(fftSize)
            for band in 0..<bandCount {
                let range = bandBins[band]
                var maxValue: Float = 0
                for bin in range.0...range.1 {
                    maxValue = max(maxValue, magnitudes[bin] * scale)
                }
                let db = maxValue > 0 ? 20 * log10(maxValue) : -78
                let clamped = max(-78, min(0, db))

                let prev = smooth[band]
                smooth[band] = clamped > prev
                    ? prev + (clamped - prev) * 0.6
                    : prev + (clamped - prev) * 0.14

                if clamped >= peakHold[band] {
                    peakHold[band] = clamped
                } else {
                    peakHold[band] = max(smooth[band], peakHold[band] - 0.5)
                }
                frame.spectrum[band] = smooth[band]
                frame.peaks[band] = peakHold[band]
            }

            // 响度
            lock.lock()
            let history = chunkHistory
            lock.unlock()
            frame.lufsM = averageLoudness(history, last: 4)
            frame.lufsS = averageLoudness(history, last: 30)
            frame.lufsI = integratedLoudness(history)
        } else {
            for band in 0..<bandCount {
                smooth[band] = max(-78, smooth[band] - 2.2)
                peakHold[band] = max(-78, peakHold[band] - 3.0)
                frame.spectrum[band] = smooth[band]
                frame.peaks[band] = peakHold[band]
            }
            levelHoldL = max(-78, levelHoldL - 2.5)
            levelHoldR = max(-78, levelHoldR - 2.5)
            peakHoldL = max(-78, peakHoldL - 1.5)
            peakHoldR = max(-78, peakHoldR - 1.5)
            frame.levelL = levelHoldL
            frame.levelR = levelHoldR
            frame.peakL = peakHoldL
            frame.peakR = peakHoldR
            frame.active = levelHoldL > -70
        }

        return frame
    }

    // MARK: - 内部

    private func buildBandBins() {
        guard sampleRate > 0 else { return }
        let nyquist = Float(sampleRate / 2)
        let binCount = fftSize / 2
        var bins: [(Int, Int)] = []
        for band in 0..<bandCount {
            let t0 = Float(band) / Float(bandCount)
            let t1 = Float(band + 1) / Float(bandCount)
            let f0 = fMin * powf(fMax / fMin, t0)
            let f1 = fMin * powf(fMax / fMin, t1)
            var b0 = Int(f0 / nyquist * Float(binCount))
            var b1 = Int(f1 / nyquist * Float(binCount))
            b0 = max(1, min(binCount - 1, b0))
            b1 = max(b0 + 1, min(binCount - 1, b1))
            bins.append((b0, b1))
        }
        bandBins = bins
    }

    private func loudness(_ meanSquare: Float) -> Float {
        guard meanSquare > 0 else { return -70 }
        return -0.691 + 10 * log10(meanSquare)
    }

    private func averageLoudness(_ history: [Float], last: Int) -> Float {
        guard !history.isEmpty else { return -70 }
        let slice = history.suffix(last)
        let mean = slice.reduce(0, +) / Float(slice.count)
        return max(-70, loudness(mean))
    }

    private func integratedLoudness(_ history: [Float]) -> Float {
        guard !history.isEmpty else { return -70 }
        if history.count == cachedIntegratedCount { return cachedIntegrated }

        let aboveAbsolute = history.filter { loudness($0) > -70 }
        guard !aboveAbsolute.isEmpty else {
            cachedIntegratedCount = history.count
            cachedIntegrated = -70
            return -70
        }
        let firstMean = aboveAbsolute.reduce(0, +) / Float(aboveAbsolute.count)
        let relativeGate = loudness(firstMean) - 10
        let gated = aboveAbsolute.filter { loudness($0) > relativeGate }
        let finalMean = gated.isEmpty
            ? firstMean
            : gated.reduce(0, +) / Float(gated.count)

        let value = max(-70, loudness(finalMean))
        cachedIntegratedCount = history.count
        cachedIntegrated = value
        return value
    }
}
