import Foundation
import AVFoundation
import Combine

final class SpeechManager: NSObject, ObservableObject {

    @Published var isListening:      Bool   = false
    @Published var currentLineIndex: Int    = 0
    @Published var scriptLines:      [String] = []
    @Published var micAuthStatus:    AVAuthorizationStatus = .notDetermined
    @Published var lastSpokenText:   String = ""
    @Published var isCalibrating:    Bool   = false
    @Published var calibrationDone:  Bool   = false
    @Published var wordsPerMinute:   Double = 192
    @Published var scrollSpeed:      Double = 1.0
    @Published var isPaused:         Bool   = false
    @Published var audioLevel:       Float  = 0
    @Published var countdownValue:   Int    = 0
    @Published var isCountingDown:   Bool   = false
    @Published var fillerFlash:      Bool   = false
    @Published var pauseForCue:      Bool   = false
    @Published var focusGlow:        Bool   = false
    @Published var fillerCountSession: Int  = 0
    @Published var fillerHeatmap:    [String: Int] = ["Intro": 0, "Body": 0, "Outro": 0]
    @Published var scriptTrend:      [Double] = []

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
    private var wordsAdvancedSession: Double = 0
    private var sessionStart:   Date?
    private var activeScriptID: UUID?
    private var cueBreaks:       Set<Int> = []
    private var consumedBreaks:  Set<Int> = []
    private var slowLines:       Set<Int> = []
    private var fastLines:       Set<Int> = []
    private var focusLines:      Set<Int> = []
    private var holdLines:       [Int: TimeInterval] = [:]
    private var fillerTriggeredOnLine: Set<Int> = []

    // How loud the mic needs to be to count as voice (0.0–1.0 RMS)
    private let rmsThreshold:   Float        = 0.01
    // Baseline silence timeout, adjusted dynamically with RMS for breath-aware pausing
    private let silenceTimeout: TimeInterval = 0.4

    private var calibrationStart: Date?

    override init() {
        super.init()
        checkPermissions()
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
        speedMultiplier = 1.0
        holdUntil = nil
        // Compute average words per line so the scroll rate matches actual speech pace
        let totalWords = lines.reduce(0) { $0 + $1.split(separator: " ").count }
        if !lines.isEmpty { avgWordsPerLine = max(1.0, Double(totalWords) / Double(lines.count)) }
        lineAccum = 0
        DispatchQueue.main.async { self.currentLineIndex = 0 }
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
        let rawTokens = scriptLines[index].split(whereSeparator: \.isWhitespace)
        guard !rawTokens.isEmpty else { return 1 }

        var units = 0
        for raw in rawTokens {
            let token = raw.filter { $0.isLetter || $0.isNumber }
            guard !token.isEmpty else { continue }

            let hasLetter = token.contains { $0.isLetter }
            let hasDigit = token.contains { $0.isNumber }
            if hasLetter && hasDigit {
                // Treat mixed tokens like W223 as spoken character-by-character (W 2 2 3).
                units += token.count
            } else {
                units += 1
            }
        }
        return max(1, units)
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
        guard micAuthStatus == .authorized else { requestPermissions(); return }

        sessionStart = Date()
        wordsAdvancedSession = 0
        fillerCountSession = 0
        fillerHeatmap = ["Intro": 0, "Body": 0, "Outro": 0]

        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let format    = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            DispatchQueue.main.async { self.isListening = true }
        } catch {
            print("SpeechManager: engine failed to start — \(error)")
        }
    }

    func stopListening() {
        scrollTimer?.invalidate();  scrollTimer  = nil
        silenceTimer?.invalidate(); silenceTimer = nil
        voiceActive = false
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
        guard micAuthStatus == .authorized else { requestPermissions(); return }
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
            self.currentLineIndex = max(0, self.currentLineIndex - 1)
        }
    }

    func scrollDown() {
        DispatchQueue.main.async {
            self.currentLineIndex = min(self.scriptLines.count - 1, self.currentLineIndex + 1)
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
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        let rms = sqrtf(sum / Float(count))

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Exponential smoothing — decays naturally to 0 when silent
            self.audioLevel = 0.35 * rms + 0.65 * self.audioLevel
            if rms > self.rmsThreshold { self.handleVoiceBurst(rms: rms) }
        }
    }

    private func handleVoiceBurst(rms: Float) {
        // Push the silence deadline forward on every voice burst
        silenceTimer?.invalidate()
        let dynamicSilence = dynamicSilenceTimeout(rms: rms)
        silenceTimer = Timer.scheduledTimer(withTimeInterval: dynamicSilence, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.voiceActive = false
            self.scrollTimer?.invalidate()
            self.scrollTimer = nil
        }

        guard !voiceActive else { return }   // already scrolling
        voiceActive = true
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

        // Tick at 20 Hz using per-line word counts to keep pace stable across varying line lengths.
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, !self.isPaused, !self.scriptLines.isEmpty else { return }
            if let holdUntil, Date() < holdUntil {
                return
            } else {
                self.holdUntil = nil
            }
            let currentWords = Double(self.wordsInLine(at: self.currentLineIndex))
            let linesPerSec = (self.wordsPerMinute / 60.0) / max(1.0, currentWords)
            self.lineAccum += linesPerSec * self.scrollSpeed * self.speedMultiplier * 0.05
            if self.lineAccum >= 1.0 {
                if self.shouldPauseForCue() {
                    self.lineAccum = 0
                    self.pauseForCue = true
                    self.voiceActive = false
                    self.scrollTimer?.invalidate()
                    self.scrollTimer = nil
                    return
                }
                self.lineAccum -= 1.0
                self.wordsAdvancedSession += currentWords
                self.currentLineIndex = min(self.currentLineIndex + 1, self.scriptLines.count - 1)
                self.applyDirectives(for: self.currentLineIndex)
            }
        }
    }

    private func applyDirectives(for index: Int) {
        speedMultiplier = slowLines.contains(index) ? 0.75 : (fastLines.contains(index) ? 1.35 : 1.0)
        focusGlow = focusLines.contains(index)
        if let hold = holdLines[index] {
            holdUntil = Date().addingTimeInterval(hold)
        }
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
        let clamped = max(rmsThreshold, min(0.045, rms))
        let norm = Double((clamped - rmsThreshold) / (0.045 - rmsThreshold))
        // Stronger voice -> slightly longer timeout to tolerate breathing between phrases.
        return max(0.28, min(0.70, silenceTimeout + norm * 0.24))
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
            DispatchQueue.main.async { self.micAuthStatus = status }
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.micAuthStatus = granted ? .authorized : .denied
            }
        }
    }
}
