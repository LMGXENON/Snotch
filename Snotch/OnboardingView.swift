import SwiftUI
import AppKit
import Speech
import AVFoundation
import ApplicationServices

struct OnboardingStep {
    let icon: String
    let title: String
    let subtitle: String
    let actionLabel: String?
}

struct OnboardingView: View {

    @ObservedObject var speechManager: SpeechManager
    @State private var currentStep: Int = 0
    @State private var micGranted: Bool = false
    @State private var speechGranted: Bool = false
    @State private var accessibilityOK: Bool = false
    @State private var permissionAdvanceWorkItem: DispatchWorkItem? = nil
    @State private var accessibilityPollTimer: Timer? = nil

    @State private var calibrationSeconds: Int = 10
    @State private var calibrationTimer: Timer? = nil
    @State private var calibrationEngine = AVAudioEngine()
    @State private var calibrationRequest: SFSpeechAudioBufferRecognitionRequest? = nil
    @State private var calibrationTask: SFSpeechRecognitionTask? = nil
    @State private var calibrationStartDate: Date? = nil
    @State private var calibrationTranscript: String = ""
    @State private var calibrationProgress: Double = 0
    @State private var calibrationMicLevel: Double = 0
    @State private var calibrationEstimatedWPM: Int = 0
    @State private var calibrationCompleted: Bool = false
    @State private var calibrationEndedByTimer: Bool = false
    @State private var calibrationConfirmationText: String = "Voice calibrated."
    @State private var calibrationError: String = ""

    @AppStorage("snotch.onboardingDone") private var onboardingDone: Bool = false
    @AppStorage("snotch.pillLight") private var pillLight: Bool = false

    let onComplete: () -> Void

    private let calibrationSentence = "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs."
    private let calibrationCompletionThreshold: Double = 0.80

    private let steps: [OnboardingStep] = [
        OnboardingStep(icon: "waveform.badge.mic", title: "Welcome to Snotch", subtitle: "Your voice-synced teleprompter that lives near the notch and stays out of your way.", actionLabel: nil),
        OnboardingStep(icon: "lock.shield", title: "Privacy First", subtitle: "Speech processing stays on your Mac. Your script and voice data are not uploaded by default.", actionLabel: nil),
        OnboardingStep(icon: "mic.fill", title: "Microphone Access", subtitle: "Allow microphone so Snotch can detect your voice and move the script naturally.", actionLabel: "Allow Microphone"),
        OnboardingStep(icon: "waveform", title: "Speech Recognition", subtitle: "Allow speech recognition for style capture and smoother speaking-aware controls.", actionLabel: "Allow Speech Recognition"),
        OnboardingStep(icon: "keyboard", title: "Accessibility", subtitle: "Optional: enable accessibility so global shortcuts work while other apps are focused.", actionLabel: "Open Settings"),
        OnboardingStep(icon: "gauge.with.dots.needle.67percent", title: "Calibrate Voice Pace", subtitle: "Read the sentence below. Snotch will calibrate pacing from your actual speaking speed.", actionLabel: "Start Speaking"),
        OnboardingStep(icon: "checkmark.seal.fill", title: "Ready", subtitle: "Open a script, hit play, and let Snotch follow your voice flow.", actionLabel: "Start Using Snotch")
    ]

    var body: some View {
        ZStack {
            OnboardingVisualEffectBackground()
                .ignoresSafeArea()

            LinearGradient(
                stops: pillLight ? [
                    .init(color: Color(white: 1.0, opacity: 0.72), location: 0.0),
                    .init(color: Color(white: 0.94, opacity: 0.60), location: 0.45),
                    .init(color: Color(white: 0.88, opacity: 0.68), location: 1.0)
                ] : [
                    .init(color: Color(white: 0.06, opacity: 0.82), location: 0.0),
                    .init(color: Color(white: 0.09, opacity: 0.68), location: 0.45),
                    .init(color: Color(white: 0.12, opacity: 0.78), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(white: pillLight ? 1 : 0.10, opacity: pillLight ? 0.72 : 0.68))
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color(white: pillLight ? 0 : 1, opacity: 0.12), lineWidth: 0.6)
                )
                .padding(14)

            HStack(spacing: 0) {
                leftPane
                    .frame(width: 250)
                Rectangle()
                    .fill(Color(white: pillLight ? 0 : 1, opacity: 0.08))
                    .frame(width: 0.5)
                rightPane
                    .frame(maxWidth: .infinity)
            }
            .padding(14)
        }
        .frame(width: 900, height: 620)
        .onAppear {
            checkCurrentPermissions()
        }
        .onDisappear {
            cleanupTimersAndTasks()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if currentStep == 4 {
                refreshAccessibilityState()
                if accessibilityOK {
                    schedulePermissionAutoAdvance(from: 4)
                }
            }
        }
        .onChange(of: currentStep) { _, newValue in
            if newValue != 4 {
                stopAccessibilityPolling()
            }
            if newValue != 5, speechManager.isCalibrating {
                stopCalibrationSession(markCompleted: calibrationCompleted)
            }
        }
        .preferredColorScheme(pillLight ? .light : .dark)
    }

    private var grantedCount: Int {
        [micGranted, speechGranted, accessibilityOK].filter { $0 }.count
    }

    private var primaryButtonLabel: String {
        if currentStep == 2, micGranted {
            return "Access Granted"
        }
        if currentStep == 3, speechGranted {
            return "Access Granted"
        }
        if currentStep == 4, accessibilityOK {
            return "Access Granted"
        }
        if currentStep == 5 {
            if speechManager.isCalibrating {
                return "Listening (\(calibrationSeconds)s)"
            }
            if calibrationCompleted {
                return "Next"
            }
            return "Start Speaking"
        }
        return steps[currentStep].actionLabel ?? (currentStep == steps.count - 1 ? "Get Started" : "Continue")
    }

    private var shouldAccentPrimaryButton: Bool {
        switch currentStep {
        case 2:
            return micGranted
        case 3:
            return speechGranted
        case 4:
            return accessibilityOK
        default:
            return false
        }
    }

    private var primaryTextColor: Color {
        Color(white: pillLight ? 0.10 : 0.92)
    }

    private var secondaryTextColor: Color {
        Color(white: pillLight ? 0.36 : 0.68)
    }

    private var cardFillColor: Color {
        Color(white: pillLight ? 0 : 1, opacity: pillLight ? 0.06 : 0.05)
    }

    private var cardBorderColor: Color {
        Color(white: pillLight ? 0 : 1, opacity: 0.10)
    }

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Snotch")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(primaryTextColor)
                Text("Voice-synced teleprompter")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(secondaryTextColor)
            }

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardFillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(cardBorderColor, lineWidth: 0.5)
                )
                .frame(height: 150)
                .overlay(
                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color(white: pillLight ? 0 : 1, opacity: 0.10))
                                .frame(width: 62, height: 62)
                            Image(systemName: steps[currentStep].icon)
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundColor(primaryTextColor)
                        }
                        Text("Step \(currentStep + 1) of \(steps.count)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                    }
                )

            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<steps.count, id: \.self) { idx in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(idx <= currentStep
                                ? Color(red: 0.36, green: 0.82, blue: 0.55).opacity(0.85)
                                : Color(white: pillLight ? 0 : 1, opacity: 0.20))
                            .frame(width: 6, height: 6)
                        Text(steps[idx].title)
                            .font(.system(size: 11, weight: idx == currentStep ? .semibold : .regular))
                            .foregroundColor(idx == currentStep ? primaryTextColor : secondaryTextColor)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
        }
        .padding(24)
    }

    private var rightPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            onboardingTopBar
                .padding(.horizontal, 52)
                .padding(.top, 16)

            VStack(alignment: .leading, spacing: 14) {
                Text(steps[currentStep].title)
                    .font(.system(size: 38, weight: .light))
                    .foregroundColor(primaryTextColor)
                    .id("title-\(currentStep)")

                Text(steps[currentStep].subtitle)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(secondaryTextColor)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .id("sub-\(currentStep)")

                stepSpecificContent
                    .padding(.top, 10)
            }
            .padding(.horizontal, 52)
            .padding(.top, 84)
            .animation(.easeInOut(duration: 0.25), value: currentStep)

            Spacer()

            VStack(spacing: 16) {
                progressTrack

                HStack {
                    if currentStep > 0 {
                        Button("Back") {
                            withAnimation {
                                currentStep -= 1
                            }
                        }
                        .buttonStyle(OnboardingGhostButtonStyle(pillLight: pillLight))
                    }

                    Spacer()

                    if currentStep == 4 || currentStep == 5 {
                        Button("Skip") {
                            if currentStep == 5, speechManager.isCalibrating {
                                stopCalibrationSession(markCompleted: calibrationCompleted)
                            }
                            withAnimation {
                                currentStep += 1
                            }
                        }
                        .buttonStyle(OnboardingGhostButtonStyle(pillLight: pillLight))
                    }

                    Button(primaryButtonLabel) {
                        handleAction()
                    }
                    .buttonStyle(OnboardingPrimaryButtonStyle(
                        pillLight: pillLight,
                        isSuccess: shouldAccentPrimaryButton
                    ))
                    .disabled(currentStep == 5 && speechManager.isCalibrating)
                }
            }
            .padding(.horizontal, 52)
            .padding(.bottom, 24)
        }
    }

    private var onboardingTopBar: some View {
        HStack(spacing: 12) {
            Text("Setup")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(secondaryTextColor)

            Rectangle()
                .fill(cardBorderColor)
                .frame(width: 0.5, height: 14)

            HStack(spacing: 6) {
                statusChip(label: "Mic", ok: micGranted)
                statusChip(label: "Speech", ok: speechGranted)
                statusChip(label: "Access", ok: accessibilityOK)
            }

            Spacer()

            Text("\(grantedCount)/3 ready")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(secondaryTextColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardFillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(cardBorderColor, lineWidth: 0.5)
                )
        )
    }

    private func statusChip(label: String, ok: Bool) -> some View {
        let grantedColor = Color(red: 0.36, green: 0.82, blue: 0.55)
        return Text(label)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(ok ? grantedColor : secondaryTextColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(ok ? grantedColor.opacity(0.20) : Color(white: pillLight ? 0 : 1, opacity: 0.08))
            )
    }

    private var progressTrack: some View {
        GeometryReader { geo in
            let fraction = Double(currentStep + 1) / Double(steps.count)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(white: pillLight ? 0 : 1, opacity: 0.12))
                    .frame(height: 5)
                Capsule()
                    .fill(Color(red: 0.36, green: 0.82, blue: 0.55).opacity(0.85))
                    .frame(width: max(0, geo.size.width * fraction), height: 5)
                    .animation(.easeInOut(duration: 0.25), value: currentStep)
            }
        }
        .frame(height: 5)
    }

    @ViewBuilder
    private var stepSpecificContent: some View {
        switch currentStep {
        case 2:
            PermissionToggleRow(label: "Microphone", icon: "mic.fill", granted: micGranted, pillLight: pillLight)
        case 3:
            PermissionToggleRow(label: "Speech Recognition", icon: "waveform", granted: speechGranted, pillLight: pillLight)
        case 4:
            PermissionToggleRow(label: "Accessibility", icon: "keyboard", granted: accessibilityOK, pillLight: pillLight)
        case 5:
            calibrationView
        default:
            EmptyView()
        }
    }

    private var calibrationView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if speechManager.isCalibrating {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.22 + min(0.5, calibrationMicLevel * 0.5)))
                            .frame(width: 40, height: 40)
                        Image(systemName: "mic.fill")
                            .foregroundColor(.white.opacity(0.95))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Listening...")
                            .foregroundColor(primaryTextColor)
                            .font(.system(size: 14, weight: .semibold))
                        Text("Read the sentence naturally")
                            .foregroundColor(secondaryTextColor)
                            .font(.system(size: 12))
                    }
                    Spacer()
                    Text("\(calibrationSeconds)s")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(primaryTextColor)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(cardFillColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(cardBorderColor, lineWidth: 0.5)
                        )
                )

                VStack(alignment: .leading, spacing: 7) {
                    Text("Mic Input")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(secondaryTextColor)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.12))
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.green.opacity(0.90), Color.yellow.opacity(0.90)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(4, geo.size.width * calibrationMicLevel))
                        }
                    }
                    .frame(height: 10)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Read this sentence:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(secondaryTextColor)

                    Text("\"\(calibrationSentence)\"")
                        .font(.system(size: 13))
                        .foregroundColor(primaryTextColor.opacity(0.82))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Progress: \(Int((calibrationProgress * 100).rounded()))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.70))

                    Text(calibrationTranscript.isEmpty
                        ? "Heard: Listening..."
                        : "Heard: \(calibrationTranscript)")
                        .font(.system(size: 11))
                        .foregroundColor(secondaryTextColor)
                        .lineLimit(2)

                    if calibrationEstimatedWPM > 0 {
                        Text("Estimated pace: \(calibrationEstimatedWPM) WPM")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.green.opacity(0.90))
                    }
                }
            } else if calibrationCompleted {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.green.opacity(0.25))
                                .frame(width: 40, height: 40)
                            Image(systemName: "checkmark")
                                .foregroundColor(.green.opacity(0.95))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Voice calibrated")
                                .foregroundColor(.green.opacity(0.95))
                                .font(.system(size: 14, weight: .semibold))
                            Text("Speaking pace set to \(calibrationEstimatedWPM) WPM")
                                .foregroundColor(secondaryTextColor)
                                .font(.system(size: 12))
                        }
                    }

                    Text("Voice calibrated")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.green.opacity(0.90))

                    Text(calibrationConfirmationText)
                        .font(.system(size: 11))
                        .foregroundColor(secondaryTextColor)
                        .lineLimit(2)

                    if !calibrationTranscript.isEmpty {
                        Text("Heard: \(calibrationTranscript)")
                            .font(.system(size: 11))
                            .foregroundColor(secondaryTextColor)
                            .lineLimit(2)
                    }

                    Button("Re-calibrate") {
                        startCalibrationSession()
                    }
                    .buttonStyle(OnboardingPrimaryButtonStyle(pillLight: pillLight, isSuccess: true))
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.green.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.green.opacity(0.45), lineWidth: 0.6)
                        )
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Tap \"Start Speaking\" and read the sentence. Snotch calibrates speed from your live speaking pace and turns green when the sentence is completed.")
                    .font(.system(size: 13))
                    .foregroundColor(secondaryTextColor)
                    .lineSpacing(3)

                if !calibrationError.isEmpty {
                    Text(calibrationError)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red.opacity(0.88))
                }
            }
        }
    }

    private func handleAction() {
        switch currentStep {
        case 2:
            requestMicrophonePermission()
        case 3:
            requestSpeechPermission()
        case 4:
            requestAccessibilityPermission()
        case 5:
            if calibrationCompleted {
                withAnimation {
                    currentStep += 1
                }
            } else if !speechManager.isCalibrating {
                startCalibrationSession()
            }
        case 6:
            onboardingDone = true
            onComplete()
        default:
            withAnimation {
                currentStep = min(currentStep + 1, steps.count - 1)
            }
        }
    }

    private func requestMicrophonePermission() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            micGranted = true
            schedulePermissionAutoAdvance(from: 2)
            return
        }

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                micGranted = granted
                if granted {
                    schedulePermissionAutoAdvance(from: 2)
                }
            }
        }
    }

    private func requestSpeechPermission() {
        if SFSpeechRecognizer.authorizationStatus() == .authorized {
            speechGranted = true
            schedulePermissionAutoAdvance(from: 3)
            return
        }

        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                speechGranted = (status == .authorized)
                if speechGranted {
                    schedulePermissionAutoAdvance(from: 3)
                }
            }
        }
    }

    private func requestAccessibilityPermission() {
        refreshAccessibilityState()
        if accessibilityOK {
            schedulePermissionAutoAdvance(from: 4)
            return
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startAccessibilityPolling()
    }

    private func schedulePermissionAutoAdvance(from step: Int) {
        permissionAdvanceWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            guard currentStep == step else { return }
            withAnimation {
                currentStep = min(currentStep + 1, steps.count - 1)
            }
        }
        permissionAdvanceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: workItem)
    }

    private func startAccessibilityPolling() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { timer in
            DispatchQueue.main.async {
                refreshAccessibilityState()
                if accessibilityOK {
                    timer.invalidate()
                    accessibilityPollTimer = nil
                    schedulePermissionAutoAdvance(from: 4)
                }
            }
        }
    }

    private func stopAccessibilityPolling() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
    }

    private func refreshAccessibilityState() {
        accessibilityOK = AXIsProcessTrusted()
    }

    private func startCalibrationSession() {
        guard !speechManager.isCalibrating else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            calibrationError = "Microphone permission is required before calibration."
            return
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            calibrationError = "Speech recognition permission is required before calibration."
            return
        }

        calibrationError = ""
        calibrationTranscript = ""
        calibrationProgress = 0
        calibrationMicLevel = 0
        calibrationSeconds = 10
        calibrationCompleted = false
        calibrationEndedByTimer = false
        calibrationConfirmationText = "Calibrating voice pace..."
        calibrationEstimatedWPM = 0
        calibrationStartDate = Date()

        speechManager.isCalibrating = true
        speechManager.calibrationDone = false

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            calibrationError = "Speech recognizer is unavailable right now."
            stopCalibrationSession(markCompleted: false)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        calibrationRequest = request

        calibrationTask = recognizer.recognitionTask(with: request) { result, error in
            DispatchQueue.main.async {
                guard speechManager.isCalibrating else { return }

                if let result {
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    calibrationTranscript = text
                    calibrationProgress = sentenceProgress(for: text)
                    updateEstimatedWPM(from: text)

                    if calibrationProgress >= calibrationCompletionThreshold {
                        finishCalibration(success: true, endedByTimer: false)
                        return
                    }
                }

                if let error {
                    if !isBenignRecognitionError(error) {
                        calibrationError = error.localizedDescription
                    }
                    finishCalibration(success: calibrationProgress >= calibrationCompletionThreshold, endedByTimer: false)
                }
            }
        }

        let input = calibrationEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            calibrationRequest?.append(buffer)
            updateCalibrationMicLevel(from: buffer)
        }

        do {
            calibrationEngine.prepare()
            try calibrationEngine.start()
        } catch {
            calibrationError = "Could not start microphone input: \(error.localizedDescription)"
            stopCalibrationSession(markCompleted: false)
            return
        }

        calibrationTimer?.invalidate()
        calibrationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            DispatchQueue.main.async {
                guard speechManager.isCalibrating else {
                    timer.invalidate()
                    return
                }

                if calibrationSeconds > 0 {
                    calibrationSeconds -= 1
                } else {
                    timer.invalidate()
                    finishCalibration(success: true, endedByTimer: true)
                }
            }
        }
    }

    private func finishCalibration(success: Bool, endedByTimer: Bool) {
        guard speechManager.isCalibrating else { return }

        calibrationTimer?.invalidate()
        calibrationTimer = nil
        calibrationRequest?.endAudio()
        calibrationTask?.cancel()
        calibrationTask = nil
        calibrationRequest = nil

        if calibrationEngine.isRunning {
            calibrationEngine.stop()
        }
        calibrationEngine.inputNode.removeTap(onBus: 0)

        speechManager.isCalibrating = false
        calibrationCompleted = success
        speechManager.calibrationDone = success
        calibrationEndedByTimer = endedByTimer

        if success {
            calibrationProgress = 1.0
            let fallbackWPM = max(110, min(240, Int(speechManager.wordsPerMinute.rounded())))
            let resolved = resolveFinalCalibrationWPM(fallbackWPM: fallbackWPM)
            calibrationEstimatedWPM = resolved
            speechManager.wordsPerMinute = Double(resolved)
            calibrationConfirmationText = endedByTimer
                ? "Timer finished. Voice calibration confirmed at \(resolved) WPM."
                : "Voice calibration confirmed at \(resolved) WPM."
        } else {
            calibrationConfirmationText = endedByTimer
                ? "Timer finished. Calibration needs another try."
                : "Calibration needs another try."
        }
    }

    private func stopCalibrationSession(markCompleted: Bool) {
        calibrationTimer?.invalidate()
        calibrationTimer = nil

        calibrationRequest?.endAudio()
        calibrationTask?.cancel()
        calibrationTask = nil
        calibrationRequest = nil

        if calibrationEngine.isRunning {
            calibrationEngine.stop()
        }
        calibrationEngine.inputNode.removeTap(onBus: 0)

        speechManager.isCalibrating = false
        calibrationCompleted = markCompleted
        if !markCompleted {
            speechManager.calibrationDone = false
        }
    }

    private func updateCalibrationMicLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?.pointee else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var sum: Float = 0
        for i in 0..<frameCount {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))
        let normalized = min(1.0, max(0.0, Double(rms * 30.0)))

        DispatchQueue.main.async {
            calibrationMicLevel = (calibrationMicLevel * 0.65) + (normalized * 0.35)
        }
    }

    private func sentenceProgress(for transcript: String) -> Double {
        let targetWords = tokenizedWords(in: calibrationSentence)
        guard !targetWords.isEmpty else { return 0 }
        let matchedCount = matchedWordCount(for: transcript)

        return min(1.0, Double(matchedCount) / Double(targetWords.count))
    }

    private func matchedWordCount(for transcript: String) -> Int {
        let targetWords = tokenizedWords(in: calibrationSentence)
        let spokenWords = tokenizedWords(in: transcript)
        guard !targetWords.isEmpty, !spokenWords.isEmpty else { return 0 }

        var matchedCount = 0
        for word in spokenWords {
            if matchedCount >= targetWords.count { break }
            if word == targetWords[matchedCount] {
                matchedCount += 1
            }
        }

        return matchedCount
    }

    private func tokenizedWords(in text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func updateEstimatedWPM(from transcript: String) {
        guard let start = calibrationStartDate else { return }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0.8 else { return }

        let matchedWords = matchedWordCount(for: transcript)
        guard matchedWords >= 3 else { return }

        let raw = (Double(matchedWords) / elapsed) * 60.0
        let clamped = min(240, max(100, Int(raw.rounded())))

        if calibrationEstimatedWPM == 0 {
            calibrationEstimatedWPM = clamped
        } else {
            let blended = (Double(calibrationEstimatedWPM) * 0.35) + (Double(clamped) * 0.65)
            calibrationEstimatedWPM = Int(blended.rounded())
        }
    }

    private func resolveFinalCalibrationWPM(fallbackWPM: Int) -> Int {
        guard let start = calibrationStartDate else { return fallbackWPM }

        let elapsed = max(1.0, Date().timeIntervalSince(start))
        let matchedWords = matchedWordCount(for: calibrationTranscript)
        var samples: [Double] = []

        if matchedWords >= 3 {
            samples.append((Double(matchedWords) / elapsed) * 60.0)
        }
        if calibrationEstimatedWPM > 0 {
            samples.append(Double(calibrationEstimatedWPM))
        }

        let resolved = samples.isEmpty
            ? Double(fallbackWPM)
            : samples.reduce(0, +) / Double(samples.count)

        return min(240, max(100, Int(resolved.rounded())))
    }

    private func isBenignRecognitionError(_ error: Error) -> Bool {
        let ns = error as NSError
        let msg = ns.localizedDescription.lowercased()
        return msg.contains("canceled") || msg.contains("cancelled")
    }

    private func checkCurrentPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        accessibilityOK = AXIsProcessTrusted()
    }

    private func cleanupTimersAndTasks() {
        permissionAdvanceWorkItem?.cancel()
        permissionAdvanceWorkItem = nil
        stopAccessibilityPolling()
        if speechManager.isCalibrating {
            stopCalibrationSession(markCompleted: calibrationCompleted)
        } else {
            calibrationTimer?.invalidate()
            calibrationTimer = nil
        }
    }
}

private struct OnboardingVisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct PermissionToggleRow: View {
    let label: String
    let icon: String
    let granted: Bool
    let pillLight: Bool

    var body: some View {
        let grantedColor = Color(red: 0.36, green: 0.82, blue: 0.55)

        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(granted ? grantedColor.opacity(0.22) : Color(white: pillLight ? 0 : 1, opacity: 0.08))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .foregroundColor(granted ? grantedColor : Color(white: pillLight ? 0.30 : 0.70))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .foregroundColor(Color(white: pillLight ? 0.10 : 0.92))
                    .font(.system(size: 14, weight: .semibold))
                Text(granted ? "Access Granted" : "Access Needed")
                    .foregroundColor(granted ? grantedColor : Color(white: pillLight ? 0.42 : 0.55))
                    .font(.system(size: 12, weight: .medium))
            }

            Spacer()

            ZStack {
                Capsule()
                    .fill(granted ? grantedColor.opacity(0.80) : Color(white: pillLight ? 0 : 1, opacity: 0.15))
                    .frame(width: 44, height: 26)
                Circle()
                    .fill(Color(white: pillLight ? 0.96 : 0.98))
                    .frame(width: 20, height: 20)
                    .offset(x: granted ? 9 : -9)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: granted)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(white: pillLight ? 0 : 1, opacity: pillLight ? 0.06 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(white: pillLight ? 0 : 1, opacity: 0.10), lineWidth: 0.5)
                )
        )
    }
}

struct OnboardingPrimaryButtonStyle: ButtonStyle {
    let pillLight: Bool
    let isSuccess: Bool

    func makeBody(configuration: Configuration) -> some View {
        let neutralFill = Color(white: pillLight ? 0 : 1, opacity: configuration.isPressed
            ? (pillLight ? 0.12 : 0.16)
            : (pillLight ? 0.08 : 0.12))
        let successFill = pillLight
            ? Color(red: 0.84, green: 0.93, blue: 0.87).opacity(configuration.isPressed ? 0.84 : 0.95)
            : Color(red: 0.05, green: 0.42, blue: 0.21).opacity(configuration.isPressed ? 0.75 : 0.90)

        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(isSuccess
                ? Color(white: pillLight ? 0.14 : 0.95)
                : Color(white: pillLight ? 0.28 : 0.82))
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(isSuccess ? successFill : neutralFill)
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color(white: pillLight ? 0 : 1, opacity: 0.18), lineWidth: 0.6)
            )
    }
}

struct OnboardingGhostButtonStyle: ButtonStyle {
    let pillLight: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(Color(white: pillLight ? 0.28 : 0.78))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(white: pillLight ? 0 : 1, opacity: configuration.isPressed ? 0.14 : 0.07))
            .overlay(
                Capsule()
                    .strokeBorder(Color(white: pillLight ? 0 : 1, opacity: 0.12), lineWidth: 0.5)
            )
            .clipShape(Capsule())
    }
}