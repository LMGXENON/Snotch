import SwiftUI
import Speech
import AVFoundation

struct OnboardingStep {
    let icon: String
    let title: String
    let subtitle: String
    let actionLabel: String?
}

struct OnboardingView: View {

    @ObservedObject var speechManager: SpeechManager
    @State private var currentStep:   Int  = 0
    @State private var micGranted:    Bool = false
    @State private var speechGranted: Bool = false
    @State private var accessibilityOK: Bool = false
    @State private var calibrationSeconds: Int = 10
    @State private var calibrationTimer: Timer? = nil
    @AppStorage("snotch.onboardingDone") private var onboardingDone: Bool = false

    let onComplete: () -> Void

    private let steps: [OnboardingStep] = [
        OnboardingStep(icon: "waveform.badge.mic",  title: "Welcome to Snotch", subtitle: "Your voice-synced teleprompter that lives near the notch and stays out of your way.", actionLabel: nil),
        OnboardingStep(icon: "lock.shield", title: "Privacy First", subtitle: "Speech processing stays on your Mac. Your script and voice data are not uploaded by default.", actionLabel: nil),
        OnboardingStep(icon: "mic.fill", title: "Microphone Access", subtitle: "Allow microphone so Snotch can detect your voice and move the script naturally.", actionLabel: "Allow Microphone"),
        OnboardingStep(icon: "waveform", title: "Speech Recognition", subtitle: "Allow speech recognition for style capture and smoother speaking-aware controls.", actionLabel: "Allow Speech Recognition"),
        OnboardingStep(icon: "keyboard", title: "Accessibility", subtitle: "Optional: enable accessibility so global shortcuts work while other apps are focused.", actionLabel: "Open Settings"),
        OnboardingStep(icon: "gauge.with.dots.needle.67percent", title: "Calibrate Voice Pace", subtitle: "Read aloud for 10 seconds so Snotch can estimate your natural speaking speed.", actionLabel: "Start Speaking"),
        OnboardingStep(icon: "checkmark.seal.fill", title: "Ready", subtitle: "Open a script, hit play, and let Snotch follow your voice flow.", actionLabel: "Start Using Snotch"),
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color(white: 0.06), location: 0),
                    .init(color: Color(white: 0.09), location: 0.45),
                    .init(color: Color(white: 0.12), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6)
                )
                .padding(14)

            HStack(spacing: 0) {
                leftPane
                    .frame(width: 250)
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 0.5)
                rightPane
                    .frame(maxWidth: .infinity)
            }
            .padding(14)
        }
        .frame(width: 900, height: 620)
        .onAppear { checkCurrentPermissions() }
        .preferredColorScheme(.dark)
    }

    private var grantedCount: Int {
        [micGranted, speechGranted, accessibilityOK].filter { $0 }.count
    }

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Snotch")
                    .font(.custom("Didot", size: 42))
                    .kerning(1.2)
                    .foregroundColor(.white)
                Text("Voice-synced teleprompter")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
            }

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
                .frame(height: 150)
                .overlay(
                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.10))
                                .frame(width: 62, height: 62)
                            Image(systemName: steps[currentStep].icon)
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundColor(Color.white.opacity(0.88))
                        }
                        Text("Step \(currentStep + 1) of \(steps.count)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.58))
                    }
                )

            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<steps.count, id: \.self) { idx in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(idx <= currentStep ? Color.white.opacity(0.75) : Color.white.opacity(0.18))
                            .frame(width: 6, height: 6)
                        Text(steps[idx].title)
                            .font(.system(size: 11, weight: idx == currentStep ? .semibold : .regular))
                            .foregroundColor(Color.white.opacity(idx == currentStep ? 0.86 : 0.48))
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
                    .font(.custom("Didot", size: 44))
                    .kerning(1.0)
                    .foregroundColor(.white)
                    .id("title-\(currentStep)")

                Text(steps[currentStep].subtitle)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.70))
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
                        Button("Back") { withAnimation { currentStep -= 1 } }
                            .buttonStyle(OnboardingGhostButtonStyle())
                    }

                    Spacer()

                    if currentStep == 4 || currentStep == 5 {
                        Button("Skip") {
                            withAnimation { currentStep += 1 }
                        }
                        .buttonStyle(OnboardingGhostButtonStyle())
                    }

                    Button(
                        speechManager.isCalibrating
                        ? "Done (\(calibrationSeconds)s)"
                        : steps[currentStep].actionLabel ?? (currentStep == steps.count - 1 ? "Get Started" : "Continue")
                    ) {
                        handleAction()
                    }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .disabled(speechManager.isCalibrating && calibrationSeconds > 0)
                }
            }
            .padding(.horizontal, 52)
            .padding(.bottom, 24)
        }
    }

    private var onboardingTopBar: some View {
        HStack(spacing: 12) {
            Text("Setup")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.56))

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 0.5, height: 14)

            HStack(spacing: 6) {
                statusChip(label: "Mic", ok: micGranted)
                statusChip(label: "Speech", ok: speechGranted)
                statusChip(label: "Access", ok: accessibilityOK)
            }

            Spacer()

            Text("\(grantedCount)/3 ready")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.60))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        )
    }

    private func statusChip(label: String, ok: Bool) -> some View {
        Text(label)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(ok ? 0.90 : 0.52))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.white.opacity(ok ? 0.18 : 0.08))
            )
    }

    private var progressTrack: some View {
        GeometryReader { geo in
            let fraction = Double(currentStep + 1) / Double(steps.count)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 5)
                Capsule()
                    .fill(Color.white.opacity(0.75))
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
            PermissionToggleRow(label: "Microphone", icon: "mic.fill", granted: micGranted)
        case 3:
            PermissionToggleRow(label: "Speech Recognition", icon: "waveform", granted: speechGranted)
        case 4:
            PermissionToggleRow(label: "Accessibility", icon: "keyboard", granted: accessibilityOK)
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
                    // Animated mic indicator
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.14))
                            .frame(width: 40, height: 40)
                        Image(systemName: "mic.fill")
                            .foregroundColor(.white.opacity(0.9))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Listening...")
                            .foregroundColor(.white)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                        Text("Read anything aloud naturally")
                            .foregroundColor(.white.opacity(0.5))
                            .font(.system(size: 12, design: .rounded))
                    }
                    Spacer()
                    Text("\(calibrationSeconds)s")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                        )
                )

                // Sample text to read
                Text("\"The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.\"")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .italic()
                    .padding(.top, 4)

            } else if speechManager.calibrationDone {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "checkmark")
                            .foregroundColor(.white.opacity(0.9))
                    }
                    Text("Voice speed calibrated!")
                        .foregroundColor(.white)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                        )
                )
            } else {
                Text("Tap \"Start Speaking\" and read anything aloud for 10 seconds. Snotch will learn your natural speaking pace.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .lineSpacing(3)
            }
        }
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<steps.count, id: \.self) { i in
                Capsule()
                    .fill(i == currentStep ? Color.accentColor : Color.white.opacity(0.25))
                    .frame(width: i == currentStep ? 20 : 7, height: 7)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: currentStep)
            }
        }
    }

    private func handleAction() {
        switch currentStep {
        case 2:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    micGranted = granted
                    if granted { withAnimation { currentStep += 1 } }
                }
            }
        case 3:
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    speechGranted = status == .authorized
                    if speechGranted { withAnimation { currentStep += 1 } }
                }
            }
        case 4:
            if AXIsProcessTrusted() {
                withAnimation { currentStep += 1 }
            } else {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                NSWorkspace.shared.open(url)
                Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                    if AXIsProcessTrusted() {
                        DispatchQueue.main.async {
                            accessibilityOK = true
                            timer.invalidate()
                            withAnimation { currentStep += 1 }
                        }
                    }
                }
            }
        case 5:
            if speechManager.calibrationDone {
                withAnimation { currentStep += 1 }
            } else if !speechManager.isCalibrating {
                speechManager.startCalibration()
                calibrationSeconds = 10
                calibrationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                    DispatchQueue.main.async {
                        if calibrationSeconds > 0 {
                            calibrationSeconds -= 1
                        } else {
                            timer.invalidate()
                            speechManager.stopCalibration()
                        }
                    }
                }
            }
        case 6:
            onboardingDone = true
            onComplete()
        default:
            withAnimation { currentStep = min(currentStep + 1, steps.count - 1) }
        }
    }

    private func checkCurrentPermissions() {
        micGranted      = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted   = SFSpeechRecognizer.authorizationStatus() == .authorized
        accessibilityOK = AXIsProcessTrusted()
    }
}

struct PermissionToggleRow: View {
    let label: String
    let icon: String
    let granted: Bool
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(granted ? Color.white.opacity(0.12) : Color.white.opacity(0.08))
                    .frame(width: 40, height: 40)
                Image(systemName: icon).foregroundColor(granted ? .white : .white.opacity(0.6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundColor(.white).font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(granted ? "Granted ✓" : "Not yet granted")
                    .foregroundColor(granted ? .white.opacity(0.75) : .white.opacity(0.4))
                    .font(.system(size: 12, design: .rounded))
            }
            Spacer()
            ZStack {
                Capsule().fill(granted ? Color.white.opacity(0.7) : Color.white.opacity(0.15)).frame(width: 44, height: 26)
                Circle().fill(.white).frame(width: 20, height: 20)
                    .offset(x: granted ? 9 : -9)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: granted)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        )
    }
}

struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundColor(.black)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.75 : 0.92))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.6)
            )
    }
}

struct OnboardingGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.75))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.07))
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .clipShape(Capsule())
    }
}
