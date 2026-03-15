import SwiftUI

struct ManageLicenseView: View {
    @ObservedObject var licenseManager: LicenseManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Manage License")
                .font(.custom("Didot", size: 34))
                .foregroundColor(.white)

            Text("Status: \(licenseManager.statusMessage.isEmpty ? "Unknown" : licenseManager.statusMessage)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.72))

            HStack {
                Text("License")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.72))
                Spacer()
                Text(licenseManager.maskedLicenseKey())
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.90))
            }

            if let activation = licenseManager.activationSummary() {
                HStack {
                    Text("Expires")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.72))
                    Spacer()
                    Text(activation.expiresAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.90))
                }

                HStack {
                    Text("Last validated")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.72))
                    Spacer()
                    Text(activation.lastValidatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.90))
                }
            }

            HStack(spacing: 10) {
                Button("Revalidate") {
                    Task { _ = await licenseManager.validateCurrentLicense(force: true) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(licenseManager.isChecking)

                Button("Deactivate") {
                    licenseManager.deactivate()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .disabled(licenseManager.isChecking)

                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        )
        .preferredColorScheme(.dark)
    }
}
