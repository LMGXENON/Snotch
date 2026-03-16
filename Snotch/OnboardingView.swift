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
        OnboardingStep(icon: "waveform.badge.mic",  title: "Welcome to Snotch",     subtitle: "Your teleprompter that lives in the notch and follows your voice — invisibly.", actionLabel: nil),
        OnboardingStep(icon: "lock.shield",          title: "Privacy First",          subtitle: "All speech recognition runs 100% on your Mac. Nothing leaves your device.", actionLabel: nil),
        OnboardingStep(icon: "mic.fill",             title: "Microphone Access",      subtitle: "Snotch needs your microphone to hear your voice and sync in real time.", actionLabel: "Allow Microphone"),
        OnboardingStep(icon: "waveform",             title: "Speech Recognition",     subtitle: "On-device speech recognition powers the voice-to-scroll engine.", actionLabel: "Allow Speech Recognition"),
        OnboardingStep(icon: "keyboard",             title: "Accessibility",          subtitle: "Optional: Enable Accessibility for global hotkeys to work when other apps are in focus.", actionLabel: "Open Settings"),
        OnboardingStep(icon: "gauge.with.dots.needle.67percent", title: "Calibrate Your Voice", subtitle: "Read aloud for 10 seconds so Snotch can learn your speaking speed.", actionLabel: "Start Speaking"),
        OnboardingStep(icon: "checkmark.seal.fill",  title: "You're All Set!",        subtitle: "Open your first script, press play, and let Snotch follow your words.", actionLabel: "Start Using Snotch"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            leftPane.frame(maxWidth: .infinity)
            rightPane.frame(maxWidth: .infinity)
        }
        .frame(width: 820, height: 540)
        .onAppear { checkCurrentPermissions() }
    }

    private var leftPane: some View {
        ZStack {
            RadialGradient(
                colors: [
                    Color(red: 0.25, green: 0.45, blue: 0.98),
                    Color(red: 0.55, green: 0.20, blue: 0.90),
                    Color(red: 0.10, green: 0.05, blue: 0.35)
                ],
                center: .topLeading, startRadius: 30, endRadius: 520
            )
            VStack(spacing: 20) {
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.white.opacity(0.15))
                        .frame(width: 80, height: 80)
                    Image(systemName: steps[currentStep].icon)
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundColor(.white)
                }
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: currentStep)
                Text("Snotch")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Voice-Synced Teleprompter")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                stepDots.padding(.bottom, 32)
            }
            .padding(32)
        }
    }

    private var rightPane: some View {
        ZStack {
            Color(red: 0.10, green: 0.10, blue: 0.12)
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                VStack(alignment: .leading, spacing: 16) {
                    Text(steps[currentStep].title)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .id("title-\(currentStep)")
                    Text(steps[currentStep].subtitle)
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .id("sub-\(currentStep)")
                    stepSpecificContent.padding(.top, 8)
                }
                .padding(.horizontal, 48)
                .animation(.easeInOut(duration: 0.35), value: currentStep)
                Spacer()
                HStack {
                    if currentStep > 0 {
                        Button("Back") { withAnimation { currentStep -= 1 } }
                            .buttonStyle(GhostButtonStyle())
                    }
                    Spacer()
                    stepDots
                    Spacer()
                    // Skip for accessibility and calibration steps
                    if currentStep == 4 || currentStep == 5 {
                        Button("Skip") {
                            withAnimation { currentStep += 1 }
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                    Button(speechManager.isCalibrating ? "Done (\(calibrationSeconds)s)" :
                           steps[currentStep].actionLabel ?? (currentStep == steps.count - 1 ? "Get Started" : "Continue")) {
                        handleAction()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(speechManager.isCalibrating && calibrationSeconds > 0)
                }
                .padding(.horizontal, 48)
                .padding(.bottom, 36)
            }
        }
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
                            .fill(Color.red.opacity(0.2))
                            .frame(width: 40, height: 40)
                        Image(systemName: "mic.fill")
                            .foregroundColor(.red)
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
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))

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
                            .fill(Color.green.opacity(0.2))
                            .frame(width: 40, height: 40)
                        Image(systemName: "checkmark")
                            .foregroundColor(.green)
                    }
                    Text("Voice speed calibrated!")
                        .foregroundColor(.white)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.green.opacity(0.08)))
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
                    .fill(granted ? Color.green.opacity(0.2) : Color.white.opacity(0.08))
                    .frame(width: 40, height: 40)
                Image(systemName: icon).foregroundColor(granted ? .green : .white.opacity(0.6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundColor(.white).font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(granted ? "Granted ✓" : "Not yet granted")
                    .foregroundColor(granted ? .green : .white.opacity(0.4))
                    .font(.system(size: 12, design: .rounded))
            }
            Spacer()
            ZStack {
                Capsule().fill(granted ? Color.green : Color.white.opacity(0.15)).frame(width: 44, height: 26)
                Circle().fill(.white).frame(width: 20, height: 20)
                    .offset(x: granted ? 9 : -9)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: granted)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.3, green: 0.5, blue: 1.0), Color(red: 0.6, green: 0.2, blue: 0.9)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.6))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.white.opacity(configuration.isPressed ? 0.1 : 0.05))
            .clipShape(Capsule())
    }
}
