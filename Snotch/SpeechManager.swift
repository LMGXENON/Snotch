import Foundation
import AVFoundation
import Combine

final class SpeechManager: NSObject, ObservableObject {

    @Published var isListening:      Bool   = false
    @Published var currentLineIndex: Int    = 0
    @Published var currentWordIndexInLine: Int = 0
    @Published var scriptLines:      [String] = []
    @Published var micAuthStatus:    AVAuthorizationStatus = .notDetermined
    @Published var lastSpokenText:   String = ""
    @Published var isCalibrating:    Bool   = false
    @Published var calibrationDone:  Bool   = false
    @Published var wordsPerMinute:   Double = 192
    @Published var scrollSpeed:      Double = 1.6 {
        didSet {
            persistPreferredScrollSpeed()
        }
    }
    @Published var continuousScrollInNotch: Bool = false {
        didSet {
            UserDefaults.standard.set(continuousScrollInNotch, forKey: continuousScrollPrefKey)
            applyPreferredScrollSpeedForCurrentMode()
            if continuousScrollInNotch {
                holdUntil = nil
                speedMultiplier = 1.0
                cadenceTarget = 1.0
                cadenceValue = 1.0
                voicePaceTarget = 1.0
                voicePaceValue = 1.0
            }
            if isListening {
                if continuousScrollInNotch {
                    applyDirectives(for: currentLineIndex)
                    if voiceActive && scrollTimer == nil && !scriptLines.isEmpty {
                        startScrollTimer()
                    }
                } else {
                    silenceTimer?.invalidate(); silenceTimer = nil
                    voiceActive = false
                    isVoiceActive = false
                    scrollTimer?.invalidate(); scrollTimer = nil
                    lineAccum = 0
                    currentWordIndexInLine = 0
                    continuousLineProgress = Double(currentLineIndex)
                }
            } else if !continuousScrollInNotch {
                currentWordIndexInLine = 0
                continuousLineProgress = Double(currentLineIndex)
            }
        }
    }
    @Published var continuousLineProgress: Double = 0
    @Published var isPaused:         Bool   = false
    @Published var audioLevel:       Float  = 0
    @Published var isVoiceActive:    Bool   = false
    @Published var countdownValue:   Int    = 0
    @Published var isCountingDown:   Bool   = false
    @Published var fillerFlash:      Bool   = false
    @Published var pauseForCue:      Bool   = false
    @Published var focusGlow:        Bool   = false
    @Published var fillerCountSession: Int  = 0
    @Published var fillerHeatmap:    [String: Int] = ["Intro": 0, "Body": 0, "Outro": 0]
    @Published var scriptTrend:      [Double] = []
    @Published private(set) var noiseGate: Double = 0.45
    @Published private(set) var inputGain: Double = 1.0

    private var audioEngine:    AVAudioEngine = AVAudioEngine()
    private var scrollTimer:    Timer?
    private var silenceTimer:   Timer?
    private var countdownTimer: Timer?
    private var fillerTimer:    Timer?
    private var lineAccum:      Double = 0
    private var voiceActive:    Bool   = false
    private var avgWordsPerLine: Double = 8.0
    private var speedMultiplier: Double = 1.0
    private var holdUntil:      Date?
    private var linesAdvancedSession: Int = 0
    private var sessionStart:   Date?
    @Published private(set) var activeScriptID: UUID?
    private var cueBreaks:       Set<Int> = []
    private var consumedBreaks:  Set<Int> = []
    private var slowLines:       Set<Int> = []
    private var fastLines:       Set<Int> = []
    private var focusLines:      Set<Int> = []
    private var holdLines:       [Int: TimeInterval] = [:]
    private var fillerTriggeredOnLine: Set<Int> = []
    private var pendingStartAfterPermission: Bool = false
    private var noiseFloorRMS:  Float = 0.0008
    private var warmupUntil: Date?
    private var cadenceTarget: Double = 1.0
    private var cadenceValue: Double = 1.0
    private var cadenceRefreshAt: Date = .distantPast
    private var voicePaceTarget: Double = 1.0
    private var voicePaceValue: Double = 1.0
    private var voiceActivateHitStreak: Int = 0
    private var voiceQuietHitStreak: Int = 0
    private var lineWordTimingCache: [Int: [Double]] = [:]
    private var scriptEnded: Bool = false
    private let continuousScrollPrefKey = "snotch.continuousNotchScroll"
    private let scrollSpeedPrefKey = "snotch.reading.scrollSpeed"
    private let highlightedSpeedPrefKey = "snotch.reading.scrollSpeed.highlighted"
    private let continuousSpeedPrefKey = "snotch.reading.scrollSpeed.continuous"
    private let noiseGatePrefKey = "snotch.audio.noiseGate"
    private let inputGainPrefKey = "snotch.audio.inputGain"

    // Baseline silence timeout, adjusted dynamically with RMS for breath-aware pausing
    private let silenceTimeout: TimeInterval = 0.4

    private var calibrationStart: Date?

    override init() {
        super.init()
        continuousScrollInNotch = UserDefaults.standard.bool(forKey: continuousScrollPrefKey)
        scrollSpeed = preferredScrollSpeedForCurrentMode()
        noiseGate = clampNoiseGate(UserDefaults.standard.object(forKey: noiseGatePrefKey) as? Double ?? 0.45)
        inputGain = clampInputGain(UserDefaults.standard.object(forKey: inputGainPrefKey) as? Double ?? 1.0)
        continuousLineProgress = Double(currentLineIndex)
        checkPermissions()
    }

    func setNoiseGate(_ value: Double) {
        let clamped = clampNoiseGate(value)
        noiseGate = clamped
        UserDefaults.standard.set(clamped, forKey: noiseGatePrefKey)
    }

    func setInputGain(_ value: Double) {
        let clamped = clampInputGain(value)
        inputGain = clamped
        UserDefaults.standard.set(clamped, forKey: inputGainPrefKey)
    }

    func resetAudioTuning() {
        setNoiseGate(0.45)
        setInputGain(1.0)
    }

    private func persistPreferredScrollSpeed() {
        let clamped = min(3.0, max(0.5, scrollSpeed))
        if clamped != scrollSpeed {
            scrollSpeed = clamped
            return
        }

        UserDefaults.standard.set(clamped, forKey: scrollSpeedPrefKey)
        let modeKey = continuousScrollInNotch ? continuousSpeedPrefKey : highlightedSpeedPrefKey
        UserDefaults.standard.set(clamped, forKey: modeKey)
    }

    private func defaultScrollSpeedForCurrentMode() -> Double {
        continuousScrollInNotch ? 1.6 : 1.1
    }

    private func preferredScrollSpeedForCurrentMode() -> Double {
        let modeKey = continuousScrollInNotch ? continuousSpeedPrefKey : highlightedSpeedPrefKey
        if let modeStored = UserDefaults.standard.object(forKey: modeKey) as? Double {
            return min(3.0, max(0.5, modeStored))
        }

        // Legacy fallback for continuous mode only; highlighted defaults to 1.1x.
        if continuousScrollInNotch,
           let legacy = UserDefaults.standard.object(forKey: scrollSpeedPrefKey) as? Double {
            return min(3.0, max(0.5, legacy))
        }

        return defaultScrollSpeedForCurrentMode()
    }

    private func applyPreferredScrollSpeedForCurrentMode() {
        let preferred = preferredScrollSpeedForCurrentMode()
        guard abs(scrollSpeed - preferred) > 0.0001 else { return }
        DispatchQueue.main.async {
            if abs(self.scrollSpeed - preferred) > 0.0001 {
                self.scrollSpeed = preferred
            }
        }
    }

    private func clampNoiseGate(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }

    private func clampInputGain(_ value: Double) -> Double {
        min(3.0, max(0.5, value))
    }

    private func currentGateThreshold() -> Float {
        let minThreshold: Float = 0.00003
        let maxThreshold: Float = 0.00110
        return minThreshold + Float(noiseGate) * (maxThreshold - minThreshold)
    }

    func loadScript(_ text: String) {
        var lines: [String] = []
        var breaks: Set<Int> = []
        var slows: Set<Int> = []
        var fasts: Set<Int> = []
        var focuses: Set<Int> = []
        var holds: [Int: TimeInterval] = [:]

        let rawLines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        for raw in rawLines where !raw.isEmpty {
            let lower = raw.lowercased()
            let hasBreak = lower.contains("<break>")
            let hasSlow = lower.contains("<slow>")
            let hasFast = lower.contains("<fast>")
            let hasFocus = lower.contains("<focus>")
            let hold = holdSeconds(from: lower)

            var cleaned = raw
            ["<break>", "<slow>", "<fast>", "<focus>"]
                .forEach { cleaned = cleaned.replacingOccurrences(of: $0, with: "", options: .caseInsensitive) }
            cleaned = cleaned.replacingOccurrences(of: #"<hold\s+\d+(?:\.\d+)?s>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)

            if !cleaned.isEmpty {
                // Wrap long paragraphs into notch-friendly chunks so lines don't truncate.
                let wrapped = wrapForNotch(cleaned, maxChars: 48)
                let startIndex = lines.count
                lines.append(contentsOf: wrapped)

                // Apply directives to the first visual chunk of this logical line.
                let idx = startIndex
                if hasBreak { breaks.insert(idx) }
                if hasSlow { slows.insert(idx) }
                if hasFast { fasts.insert(idx) }
                if hasFocus { focuses.insert(idx) }
                if let hold { holds[idx] = hold }
            } else if let idx = lines.indices.last {
                if hasBreak { breaks.insert(idx) }
                if hasSlow { slows.insert(idx) }
                if hasFast { fasts.insert(idx) }
                if hasFocus { focuses.insert(idx) }
                if let hold { holds[idx] = hold }
            }
        }

        scriptLines = lines
        cueBreaks = breaks
        slowLines = slows
        fastLines = fasts
        focusLines = focuses
        holdLines = holds
        consumedBreaks = []
        fillerTriggeredOnLine = []
        pauseForCue = false
        focusGlow = false
        lineWordTimingCache = [:]
        speedMultiplier = 1.0
        holdUntil = nil
        cadenceTarget = 1.0
        cadenceValue = 1.0
        voicePaceTarget = 1.0
        voicePaceValue = 1.0
        voiceActivateHitStreak = 0
        voiceQuietHitStreak = 0
        cadenceRefreshAt = Date()
        scriptEnded = false
        // Compute average words per line so the scroll rate matches actual speech pace
        let totalWords = lines.reduce(0) { $0 + $1.split(separator: " ").count }
        if !lines.isEmpty { avgWordsPerLine = max(1.0, Double(totalWords) / Double(lines.count)) }
        lineAccum = 0
        DispatchQueue.main.async {
            self.currentLineIndex = 0
            self.currentWordIndexInLine = 0
            self.continuousLineProgress = 0
            self.isVoiceActive = false
        }
    }

    private func wrapForNotch(_ text: String, maxChars: Int) -> [String] {
        let compact = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return [] }

        let hardMax = max(maxChars + 14, 58)
        var chunks: [String] = []
        var rest = compact

        while rest.count > hardMax {
            let splitIndex = bestSplitIndex(in: rest, preferredMax: maxChars, hardMax: hardMax)
            let cut = rest[..<splitIndex].trimmingCharacters(in: .whitespaces)
            if !cut.isEmpty { chunks.append(String(cut)) }
            rest = String(rest[splitIndex...]).trimmingCharacters(in: .whitespaces)
        }

        if !rest.isEmpty { chunks.append(rest) }
        return chunks
    }

    private func wordsInLine(at index: Int) -> Int {
        guard scriptLines.indices.contains(index) else { return 1 }
        let tokens = scriptLines[index].split(whereSeparator: \.isWhitespace)
        return max(1, tokens.count)
    }

    private func wordTimingProfile(for index: Int) -> [Double] {
        let expectedWordCount = wordsInLine(at: index)
        if let cached = lineWordTimingCache[index], cached.count == expectedWordCount {
            return cached
        }

        let profile = buildWordTimingProfile(for: index)
        lineWordTimingCache[index] = profile
        return profile
    }

    private func buildWordTimingProfile(for index: Int) -> [Double] {
        guard scriptLines.indices.contains(index) else { return [1] }

        let words = scriptLines[index].split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 1 else { return [1] }

        var weights = Array(repeating: 1.0, count: words.count)

        // Base human variation per word.
        for i in weights.indices {
            weights[i] *= Double.random(in: 0.84...1.18)
        }

        // Punctuation naturally creates tiny pauses.
        for (i, token) in words.enumerated() {
            if token.hasSuffix("...") {
                weights[i] *= Double.random(in: 1.42...1.70)
            } else if token.hasSuffix(".") || token.hasSuffix("!") || token.hasSuffix("?") {
                weights[i] *= Double.random(in: 1.28...1.52)
            } else if token.hasSuffix(",") || token.hasSuffix(";") || token.hasSuffix(":") {
                weights[i] *= Double.random(in: 1.10...1.28)
            }
        }

        // Occasionally consume two adjacent words faster, as in natural speech runs.
        let pairSlots = max(0, words.count - 1)
        if pairSlots > 0 {
            let maxPairs = max(1, words.count / 5)
            let pairCount = Int.random(in: 0...maxPairs)
            var usedStarts: Set<Int> = []

            for _ in 0..<pairCount {
                let candidates = (0..<pairSlots).filter {
                    !usedStarts.contains($0) && !usedStarts.contains($0 - 1) && !usedStarts.contains($0 + 1)
                }
                guard let start = candidates.randomElement() else { break }

                usedStarts.insert(start)
                weights[start] *= Double.random(in: 0.58...0.76)
                weights[start + 1] *= Double.random(in: 0.62...0.82)

                if start > 0 {
                    weights[start - 1] *= Double.random(in: 1.05...1.20)
                }
            }
        }

        // Small random breath-like hold point inside longer lines.
        if words.count >= 4 && Bool.random() {
            let breathIndex = Int.random(in: 1..<(words.count - 1))
            weights[breathIndex] *= Double.random(in: 1.18...1.36)
        }

        weights = weights.map { min(2.2, max(0.42, $0)) }

        let total = weights.reduce(0, +)
        guard total > 0 else {
            return Array(repeating: 1.0 / Double(words.count), count: words.count)
        }

        return weights.map { $0 / total }
    }

    private func updateCurrentWordIndexInLine() {
        let words = wordsInLine(at: currentLineIndex)
        if words <= 1 {
            currentWordIndexInLine = 0
            return
        }

        let profile = wordTimingProfile(for: currentLineIndex)
        let progress = min(max(lineAccum, 0), 0.999)

        var cumulative = 0.0
        for (index, weight) in profile.enumerated() {
            cumulative += weight
            if progress < cumulative {
                currentWordIndexInLine = index
                return
            }
        }

        currentWordIndexInLine = words - 1
    }

    private func bestSplitIndex(in text: String, preferredMax: Int, hardMax: Int) -> String.Index {
        let limit = min(hardMax, text.count)
        let windowEnd = text.index(text.startIndex, offsetBy: limit)
        let window = String(text[..<windowEnd])

        let punctuation = [". ", "! ", "? ", "; ", ": ", ", "]
        for token in punctuation {
            if let range = window.range(of: token, options: .backwards),
               window.distance(from: window.startIndex, to: range.upperBound) >= max(18, preferredMax - 14) {
                return text.index(text.startIndex, offsetBy: window.distance(from: window.startIndex, to: range.upperBound))
            }
        }

        let preferred = min(preferredMax, window.count)
        let preferredEnd = window.index(window.startIndex, offsetBy: preferred)
        let preferredSlice = String(window[..<preferredEnd])
        if let split = preferredSlice.lastIndex(of: " "),
           preferredSlice.distance(from: preferredSlice.startIndex, to: split) > 12 {
            return text.index(text.startIndex, offsetBy: preferredSlice.distance(from: preferredSlice.startIndex, to: split))
        }

        if let split = window.lastIndex(of: " "),
           window.distance(from: window.startIndex, to: split) > 12 {
            return text.index(text.startIndex, offsetBy: window.distance(from: window.startIndex, to: split))
        }

        return windowEnd
    }

    // MARK: - Start / Stop

    func startListening() {
        guard !isListening else { return }
        micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micAuthStatus == .authorized else {
            pendingStartAfterPermission = true
            requestPermissions()
            return
        }
        pendingStartAfterPermission = false

        sessionStart = Date()
        linesAdvancedSession = 0
        fillerCountSession = 0
        fillerHeatmap = ["Intro": 0, "Body": 0, "Outro": 0]
        noiseFloorRMS = 0.0008
        warmupUntil = Date().addingTimeInterval(0.7)
        voiceActive = false
        isVoiceActive = false
        voiceActivateHitStreak = 0
        voiceQuietHitStreak = 0

        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        // Prime the meter so UI reacts immediately when listening starts.
        DispatchQueue.main.async {
            self.audioLevel = 0
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            DispatchQueue.main.async {
                self.isListening = true
            }
        } catch {
            print("SpeechManager: engine failed to start — \(error)")
        }
    }

    func stopListening() {
        pendingStartAfterPermission = false
        scrollTimer?.invalidate();  scrollTimer  = nil
        silenceTimer?.invalidate(); silenceTimer = nil
        voiceActive = false
        isVoiceActive = false
        voiceActivateHitStreak = 0
        voiceQuietHitStreak = 0
        // lineAccum intentionally preserved — resume will continue mid-line
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        persistTrendPoint()
        DispatchQueue.main.async { self.isListening = false; self.audioLevel = 0 }
    }

    func toggleListening() {
        if isListening || isCountingDown {
            countdownTimer?.invalidate(); countdownTimer = nil
            isCountingDown = false
            countdownValue = 0
            stopListening()
        } else {
            beginCountdown()
        }
    }

    private func beginCountdown() {
        guard micAuthStatus == .authorized else {
            pendingStartAfterPermission = true
            requestPermissions()
            return
        }
        countdownValue = 3
        isCountingDown = true
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { return }
            DispatchQueue.main.async {
                if self.countdownValue > 1 {
                    self.countdownValue -= 1
                } else {
                    t.invalidate()
                    self.countdownTimer = nil
                    self.countdownValue = 0
                    self.isCountingDown = false
                    self.startListening()
                }
            }
        }
    }

    func scrollUp() {
        DispatchQueue.main.async {
            guard !self.scriptLines.isEmpty else { return }
            let nextIndex = max(0, self.currentLineIndex - 1)
            let changed = nextIndex != self.currentLineIndex
            self.currentLineIndex = nextIndex
            self.lineAccum = 0
            self.currentWordIndexInLine = 0
            self.continuousLineProgress = Double(self.currentLineIndex)
            if changed {
                self.scriptEnded = false
            }
        }
    }

    func scrollDown() {
        DispatchQueue.main.async {
            guard !self.scriptLines.isEmpty else { return }
            let nextIndex = min(self.scriptLines.count - 1, self.currentLineIndex + 1)
            let changed = nextIndex != self.currentLineIndex
            self.currentLineIndex = nextIndex
            self.lineAccum = 0
            self.currentWordIndexInLine = 0
            self.continuousLineProgress = Double(self.currentLineIndex)
            if changed {
                self.scriptEnded = false
            }
        }
    }

    func jumpToLine(_ index: Int) {
        DispatchQueue.main.async {
            guard !self.scriptLines.isEmpty else { return }

            let target = min(max(0, index), self.scriptLines.count - 1)
            self.currentLineIndex = target
            self.lineAccum = 0
            self.currentWordIndexInLine = 0
            self.continuousLineProgress = Double(target)
            self.scriptEnded = false
            self.pauseForCue = false
            self.applyDirectives(for: target)
        }
    }

    func setActiveScript(id: UUID?) {
        activeScriptID = id
        loadTrend()
    }

    // MARK: - Calibration (onboarding compatibility)

    func startCalibration() {
        isCalibrating    = true
        calibrationDone  = false
        calibrationStart = Date()
        startListening()
    }

    func stopCalibration() {
        stopListening()
        isCalibrating   = false
        calibrationDone = true
    }

    // MARK: - Audio / VAD

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        let (rms, _) = meterValues(from: buffer, frameCount: count)
        let gainedRMS = rms * Float(inputGain)
        let boosted = min(gainedRMS * 24.0, 1.0)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Exponential smoothing — decays naturally to 0 when silent
            self.audioLevel = 0.45 * boosted + 0.55 * self.audioLevel

            let now = Date()

            if !self.voiceActive,
               let warmupUntil = self.warmupUntil {
                if now > warmupUntil {
                    self.noiseFloorRMS = 0.988 * self.noiseFloorRMS + 0.012 * gainedRMS
                } else {
                    // Ignore early activation during warmup to avoid immediate false starts.
                    return
                }
            }

            let gate = self.currentGateThreshold()
            let adaptive = max(gate, min(0.0035, self.noiseFloorRMS * 1.15 + gate * 0.22))

            // Entry requires stronger confidence than sustain. This prevents
            // steady room noise from latching speech active.
            let activateThreshold = max(adaptive * 1.03, self.noiseFloorRMS * 1.65 + gate * 0.08)
            let sustainThreshold = max(adaptive * 0.78, self.noiseFloorRMS * 1.28)

            let strongSpeech = gainedRMS >= activateThreshold
            let sustainSpeech = gainedRMS >= sustainThreshold

            if strongSpeech {
                self.voiceActivateHitStreak = min(8, self.voiceActivateHitStreak + 1)
                self.voiceQuietHitStreak = 0
            } else if self.voiceActive && sustainSpeech {
                self.voiceActivateHitStreak = min(8, self.voiceActivateHitStreak + 1)
                self.voiceQuietHitStreak = 0
            } else {
                self.voiceQuietHitStreak = min(12, self.voiceQuietHitStreak + 1)
                self.voiceActivateHitStreak = max(0, self.voiceActivateHitStreak - 1)
            }

            if !self.voiceActive {
                if self.voiceActivateHitStreak >= 2 {
                    self.handleVoiceBurst(rms: max(gainedRMS, activateThreshold))
                }
            } else {
                if sustainSpeech {
                    self.handleVoiceBurst(rms: max(gainedRMS, sustainThreshold))
                } else if self.voiceQuietHitStreak >= 4 {
                    // Hard stop when voice confidence drops for several frames.
                    self.voiceActive = false
                    self.isVoiceActive = false
                    self.silenceTimer?.invalidate()
                    self.silenceTimer = nil
                    self.scrollTimer?.invalidate()
                    self.scrollTimer = nil
                }
            }
        }
    }

    private func meterValues(from buffer: AVAudioPCMBuffer, frameCount: Int) -> (Float, Float) {
        if let channels = buffer.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            var sum: Float = 0
            var peak: Float = 0
            var samples = 0
            for ch in 0..<max(1, channelCount) {
                let data = channels[ch]
                for i in 0..<frameCount {
                    let v = data[i]
                    sum += v * v
                    let av = abs(v)
                    if av > peak { peak = av }
                    samples += 1
                }
            }
            let rms = samples > 0 ? sqrtf(sum / Float(samples)) : 0
            return (rms, peak)
        }

        if let channels = buffer.int16ChannelData {
            let channelCount = Int(buffer.format.channelCount)
            var sum: Float = 0
            var peak: Float = 0
            var samples = 0
            let scale: Float = 1.0 / Float(Int16.max)
            for ch in 0..<max(1, channelCount) {
                let data = channels[ch]
                for i in 0..<frameCount {
                    let v = Float(data[i]) * scale
                    sum += v * v
                    let av = abs(v)
                    if av > peak { peak = av }
                    samples += 1
                }
            }
            let rms = samples > 0 ? sqrtf(sum / Float(samples)) : 0
            return (rms, peak)
        }

        if let channels = buffer.int32ChannelData {
            let channelCount = Int(buffer.format.channelCount)
            var sum: Float = 0
            var peak: Float = 0
            var samples = 0
            let scale: Float = 1.0 / Float(Int32.max)
            for ch in 0..<max(1, channelCount) {
                let data = channels[ch]
                for i in 0..<frameCount {
                    let v = Float(data[i]) * scale
                    sum += v * v
                    let av = abs(v)
                    if av > peak { peak = av }
                    samples += 1
                }
            }
            let rms = samples > 0 ? sqrtf(sum / Float(samples)) : 0
            return (rms, peak)
        }

        let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var sum: Float = 0
        var peak: Float = 0
        var samples = 0

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            for audioBuffer in abl {
                guard let mData = audioBuffer.mData else { continue }
                let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                let ptr = mData.assumingMemoryBound(to: Float.self)
                for i in 0..<sampleCount {
                    let v = ptr[i]
                    sum += v * v
                    let av = abs(v)
                    if av > peak { peak = av }
                    samples += 1
                }
            }
        case .pcmFormatInt16:
            let scale: Float = 1.0 / Float(Int16.max)
            for audioBuffer in abl {
                guard let mData = audioBuffer.mData else { continue }
                let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                let ptr = mData.assumingMemoryBound(to: Int16.self)
                for i in 0..<sampleCount {
                    let v = Float(ptr[i]) * scale
                    sum += v * v
                    let av = abs(v)
                    if av > peak { peak = av }
                    samples += 1
                }
            }
        case .pcmFormatInt32:
            let scale: Float = 1.0 / Float(Int32.max)
            for audioBuffer in abl {
                guard let mData = audioBuffer.mData else { continue }
                let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
                let ptr = mData.assumingMemoryBound(to: Int32.self)
                for i in 0..<sampleCount {
                    let v = Float(ptr[i]) * scale
                    sum += v * v
                    let av = abs(v)
                    if av > peak { peak = av }
                    samples += 1
                }
            }
        default:
            break
        }

        let rms = samples > 0 ? sqrtf(sum / Float(samples)) : 0
        return (rms, peak)
    }

    private func handleVoiceBurst(rms: Float) {
        guard !scriptLines.isEmpty, !scriptEnded else {
            scrollTimer?.invalidate()
            scrollTimer = nil
            voiceActive = false
            DispatchQueue.main.async { self.isVoiceActive = false }
            return
        }

        // Push the silence deadline forward on every voice burst
        silenceTimer?.invalidate()
        let dynamicSilence = dynamicSilenceTimeout(rms: rms)

        if continuousScrollInNotch {
            voicePaceTarget = 1.0
            voicePaceValue = 1.0
        } else {
            let gate = currentGateThreshold()
            let gateRatio = Double(max(0.0, min(2.8, rms / max(gate, 0.00001))))
            voicePaceTarget = min(1.22, max(0.92, 0.90 + gateRatio * 0.14))
        }

        silenceTimer = Timer.scheduledTimer(withTimeInterval: dynamicSilence, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.voiceActive = false
            self.voiceActivateHitStreak = 0
            self.voiceQuietHitStreak = 0
            DispatchQueue.main.async { self.isVoiceActive = false }
            self.scrollTimer?.invalidate()
            self.scrollTimer = nil
        }

        if voiceActive {
            if scrollTimer == nil && !isPaused && !scriptLines.isEmpty {
                startScrollTimer()
            }
            return
        }

        voiceActive = true
        DispatchQueue.main.async { self.isVoiceActive = true }
        if pauseForCue {
            pauseForCue = false
            consumedBreaks.insert(currentLineIndex)
        }
        applyDirectives(for: currentLineIndex)
        if currentLineHasFiller() && !fillerTriggeredOnLine.contains(currentLineIndex) {
            fillerTriggeredOnLine.insert(currentLineIndex)
            fillerCountSession += 1
            incrementHeatmapSection(for: currentLineIndex)
            triggerFillerFlash()
        }
        // Do NOT reset lineAccum — preserves partial progress through the current line
        // so resuming mid-sentence doesn't require re-reading from the line start.

        startScrollTimer()
    }

    private func startScrollTimer() {
        if scrollTimer != nil { return }

        // Tick slightly faster for smoother interpolation.
        let tickInterval: TimeInterval = 0.04
        scrollTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            guard let self, !self.isPaused, !self.scriptLines.isEmpty else { return }

            guard self.voiceActive else {
                self.scrollTimer?.invalidate()
                self.scrollTimer = nil
                return
            }

            if self.scriptEnded {
                self.scrollTimer?.invalidate()
                self.scrollTimer = nil
                return
            }

            let now = Date()
            if let holdUntil, Date() < holdUntil {
                return
            } else {
                self.holdUntil = nil
            }

            let isContinuousMode = self.continuousScrollInNotch

            if isContinuousMode {
                self.cadenceTarget = 1.0
                self.cadenceValue = 1.0
                self.voicePaceValue = 1.0
            } else if now >= self.cadenceRefreshAt {
                self.cadenceTarget = Double.random(in: 0.95...1.07)
                self.cadenceRefreshAt = now.addingTimeInterval(Double.random(in: 0.25...0.75))
            }

            if !isContinuousMode {
                self.cadenceValue += (self.cadenceTarget - self.cadenceValue) * 0.14
                self.voicePaceValue += (self.voicePaceTarget - self.voicePaceValue) * 0.18
            }

            let currentWords = Double(self.wordsInLine(at: self.currentLineIndex))
            let effectiveWords = max(currentWords, self.avgWordsPerLine)
            let linesPerSec = (self.wordsPerMinute / 60.0) / max(1.0, effectiveWords)
            let smoothDamping = 0.82
            let directiveSpeed = isContinuousMode ? 1.0 : self.speedMultiplier
            let cadenceFactor = isContinuousMode ? 1.0 : self.cadenceValue
            let voicePaceFactor = isContinuousMode ? 1.0 : self.voicePaceValue
            self.lineAccum += linesPerSec
                * self.scrollSpeed
                * directiveSpeed
                * smoothDamping
                * cadenceFactor
                * voicePaceFactor
                * tickInterval

            while self.lineAccum >= 1.0 {
                let previousIndex = self.currentLineIndex
                if previousIndex >= self.scriptLines.count - 1 {
                    self.finishScriptProgression()
                    return
                }

                self.lineAccum -= 1.0
                self.currentLineIndex = min(self.currentLineIndex + 1, self.scriptLines.count - 1)
                self.linesAdvancedSession += 1
                if !isContinuousMode {
                    self.applyTransitionPause(afterLine: previousIndex)
                }
                self.applyDirectives(for: self.currentLineIndex)
            }

            self.updateCurrentWordIndexInLine()

            let maxProgress = Double(max(0, self.scriptLines.count - 1))
            let smoothProgress = min(maxProgress, Double(self.currentLineIndex) + min(self.lineAccum, 0.999))
            // Keep progress continuous in both modes so Highlighted mode can
            // scroll smoothly while still using current-word emphasis.
            self.continuousLineProgress = smoothProgress
        }
    }

    private func applyDirectives(for index: Int) {
        if continuousScrollInNotch {
            speedMultiplier = 1.0
            return
        }

        speedMultiplier = slowLines.contains(index) ? 0.75 : (fastLines.contains(index) ? 1.35 : 1.0)
        focusGlow = focusLines.contains(index)
        if let hold = holdLines[index] {
            extendHold(by: hold)
        }
    }

    private func finishScriptProgression() {
        let lastIndex = max(0, scriptLines.count - 1)
        currentLineIndex = lastIndex
        currentWordIndexInLine = max(0, wordsInLine(at: lastIndex) - 1)
        continuousLineProgress = Double(lastIndex)
        lineAccum = 0
        scriptEnded = true
        pauseForCue = false
        holdUntil = nil
        scrollTimer?.invalidate()
        scrollTimer = nil
        voiceActive = false
        DispatchQueue.main.async { self.isVoiceActive = false }
    }

    private func applyTransitionPause(afterLine index: Int) {
        guard scriptLines.indices.contains(index) else { return }
        let line = scriptLines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        let pause: TimeInterval
        if line.hasSuffix("...") {
            pause = Double.random(in: 0.24...0.38)
        } else if line.hasSuffix(".") || line.hasSuffix("!") || line.hasSuffix("?") {
            pause = Double.random(in: 0.16...0.30)
        } else if line.hasSuffix(";") || line.hasSuffix(":") {
            pause = Double.random(in: 0.11...0.22)
        } else if line.hasSuffix(",") {
            pause = Double.random(in: 0.06...0.15)
        } else {
            pause = 0
        }

        if pause > 0 {
            extendHold(by: pause)
        }
    }

    private func extendHold(by duration: TimeInterval) {
        let until = Date().addingTimeInterval(duration)
        if let holdUntil, holdUntil > until {
            return
        }
        holdUntil = until
    }

    private func holdSeconds(from line: String) -> TimeInterval? {
        let pattern = #"<hold\s+(\d+(?:\.\d+)?)s>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        let value = ns.substring(with: match.range(at: 1))
        return Double(value)
    }

    private func shouldPauseForCue() -> Bool {
        cueBreaks.contains(currentLineIndex) && !consumedBreaks.contains(currentLineIndex)
    }

    private func currentLineHasFiller() -> Bool {
        guard scriptLines.indices.contains(currentLineIndex) else { return false }
        let tokens = scriptLines[currentLineIndex]
            .lowercased()
            .split { !$0.isLetter }
        return tokens.contains(where: { $0 == "um" || $0 == "uh" || $0 == "like" })
    }

    private func dynamicSilenceTimeout(rms: Float) -> TimeInterval {
        let threshold = currentGateThreshold()
        let clamped = max(threshold, min(0.045, rms))
        let norm = Double((clamped - threshold) / max(0.00001, 0.045 - threshold))
        // Fast enough to stop drift, long enough to survive short syllable gaps.
        return max(0.28, min(0.60, silenceTimeout * 0.72 + norm * 0.22))
    }

    private func incrementHeatmapSection(for index: Int) {
        let total = max(1, scriptLines.count)
        let section: String
        if index < total / 3 {
            section = "Intro"
        } else if index < (2 * total) / 3 {
            section = "Body"
        } else {
            section = "Outro"
        }
        fillerHeatmap[section, default: 0] += 1
    }

    private func trendKey() -> String? {
        guard let id = activeScriptID else { return nil }
        return "snotch.trend.\(id.uuidString)"
    }

    private func loadTrend() {
        guard let key = trendKey() else {
            scriptTrend = []
            return
        }
        scriptTrend = UserDefaults.standard.array(forKey: key) as? [Double] ?? []
    }

    private func persistTrendPoint() {
        guard let key = trendKey(), isListening || sessionStart != nil else { return }
        let minutes = max(1.0 / 60.0, (Date().timeIntervalSince(sessionStart ?? Date())) / 60.0)
        let fillersPerMin = Double(fillerCountSession) / minutes
        // Higher is better: start at 100, penalize filler density.
        var score = 100.0 - fillersPerMin * 18.0
        score = max(0, min(100, score))
        var trend = UserDefaults.standard.array(forKey: key) as? [Double] ?? []
        trend.append(score)
        if trend.count > 20 { trend.removeFirst(trend.count - 20) }
        UserDefaults.standard.set(trend, forKey: key)
        scriptTrend = trend
    }

    private func triggerFillerFlash() {
        fillerTimer?.invalidate()
        fillerFlash = true
        fillerTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.fillerFlash = false }
        }
    }

    // MARK: - Permissions

    func checkPermissions() {
        micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestPermissions() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .notDetermined else {
            DispatchQueue.main.async {
                self.micAuthStatus = status
                if status == .authorized, self.pendingStartAfterPermission {
                    self.pendingStartAfterPermission = false
                    self.beginCountdown()
                } else if status == .denied || status == .restricted {
                    self.pendingStartAfterPermission = false
                }
            }
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.micAuthStatus = granted ? .authorized : .denied
                if granted, self.pendingStartAfterPermission {
                    self.pendingStartAfterPermission = false
                    self.beginCountdown()
                }
            }
        }
    }
}
