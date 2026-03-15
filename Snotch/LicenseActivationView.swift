import SwiftUI

struct LicenseActivationView: View {
    @ObservedObject var licenseManager: LicenseManager
    @State private var licenseKey: String = ""

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

            VStack(alignment: .leading, spacing: 16) {
                Text("Snotch Activation")
                    .font(.custom("Didot", size: 44))
                    .foregroundColor(.white)

                Text("Enter your license key to activate this copy.")
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.68))

                TextField("XXXX-XXXX-XXXX-XXXX", text: $licenseKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.92))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                            )
                    )

                HStack {
                    Button("Activate") {
                        Task {
                            _ = await licenseManager.activate(licenseKey: licenseKey)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(licenseManager.isChecking || licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Paste") {
                        if let fromBoard = NSPasteboard.general.string(forType: .string) {
                            licenseKey = fromBoard
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(licenseManager.isChecking)

                    Spacer()
                }

                if !licenseManager.statusMessage.isEmpty {
                    Text(licenseManager.statusMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(licenseManager.isLicensed ? Color.green.opacity(0.85) : Color.red.opacity(0.85))
                }

                Text("Need a key? Purchase once and activate on your device.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.white.opacity(0.55))
            }
            .padding(28)
            .frame(width: 560)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6)
                    )
            )
        }
        .onAppear {
            if let existing = licenseManager.loadLicenseKey() {
                licenseKey = existing
            }
        }
        .preferredColorScheme(.dark)
    }
}
