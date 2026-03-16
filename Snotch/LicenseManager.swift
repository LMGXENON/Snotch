import Foundation
import Combine

final class LicenseManager: ObservableObject {
    @Published var isLicensed: Bool = false
    @Published var isChecking: Bool = false
    @Published var statusMessage: String = ""

    private let service = "LMGXENON.Snotch"
    private let keyAccount = "license.key"
    private let activationAccount = "license.activation"
    #if DEBUG
    private let apiBaseURL = "http://127.0.0.1:8787"
    #else
    private let apiBaseURL = "https://api.snotch.app"
    #endif

    private var activateURL: URL { URL(string: "\(apiBaseURL)/v1/license/activate")! }
    private var validateURL: URL { URL(string: "\(apiBaseURL)/v1/license/validate")! }
    private let maxOfflineGraceDays: Double = 7
    private let revalidateIntervalHours: Double = 24

    struct Activation: Codable {
        let token: String
        var expiresAt: Date
        let devicesAllowed: Int
        var lastValidatedAt: Date
    }

    struct ActivateResponse: Decodable {
        let ok: Bool
        let token: String
        let expiresAt: String
        let devicesAllowed: Int
        let message: String?
    }

    struct ActivateRequest: Encodable {
        let licenseKey: String
        let deviceId: String
        let appVersion: String
        let platform: String
    }

    struct ValidateRequest: Encodable {
        let token: String
        let licenseKey: String
        let deviceId: String
        let appVersion: String
        let platform: String
    }

    struct ValidateResponse: Decodable {
        let ok: Bool
        let expiresAt: String
        let message: String?
    }

    init() {
        if let activation = loadActivation(), activation.expiresAt > Date() {
            isLicensed = true
            statusMessage = "License active"
        }
    }

    func startupValidate() async {
        guard let key = loadLicenseKey(), !key.isEmpty else {
            await MainActor.run {
                self.isLicensed = false
                self.statusMessage = "Enter your license key to activate."
            }
            return
        }

        guard let activation = loadActivation() else {
            _ = await activate(licenseKey: key)
            return
        }

        let now = Date()
        let graceWindow = activation.lastValidatedAt.addingTimeInterval(maxOfflineGraceDays * 24 * 3600)

        if activation.expiresAt > now {
            await MainActor.run {
                self.isLicensed = true
                self.statusMessage = "License active"
            }

            // Revalidate in the background if stale.
            if activation.lastValidatedAt.addingTimeInterval(revalidateIntervalHours * 3600) < now {
                _ = await validateCurrentLicense(force: false)
            }
            return
        }

        // Token expired. Allow temporary grace if recently validated.
        if now < graceWindow {
            await MainActor.run {
                self.isLicensed = true
                self.statusMessage = "License in offline grace period"
            }
            _ = await validateCurrentLicense(force: true)
            return
        }

        await MainActor.run {
            self.isLicensed = false
            self.statusMessage = "License expired. Please reconnect and re-validate."
        }
    }

    func activate(licenseKey: String) async -> Bool {
        let trimmed = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await MainActor.run {
                self.isLicensed = false
                self.statusMessage = "License key cannot be empty."
            }
            return false
        }

        await MainActor.run {
            self.isChecking = true
            self.statusMessage = "Checking license..."
        }
        defer { Task { @MainActor in self.isChecking = false } }

        let requestPayload = ActivateRequest(
            licenseKey: trimmed,
            deviceId: deviceId(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            platform: "macOS"
        )

        var req = URLRequest(url: activateURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            req.httpBody = try JSONEncoder().encode(requestPayload)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw NSError(domain: "License", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
            }
            guard (200...299).contains(http.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? "Activation failed"
                throw NSError(domain: "License", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            }

            let decoded = try JSONDecoder().decode(ActivateResponse.self, from: data)
            guard decoded.ok else {
                await MainActor.run {
                    self.isLicensed = false
                    self.statusMessage = decoded.message ?? "License rejected"
                }
                return false
            }

            let dateFormatter = ISO8601DateFormatter()
            let expiry = dateFormatter.date(from: decoded.expiresAt) ?? Date().addingTimeInterval(60 * 60 * 24 * 7)
            let activation = Activation(
                token: decoded.token,
                expiresAt: expiry,
                devicesAllowed: decoded.devicesAllowed,
                lastValidatedAt: Date()
            )

            saveLicenseKey(trimmed)
            saveActivation(activation)

            await MainActor.run {
                self.isLicensed = true
                self.statusMessage = "License activated"
            }
            return true
        } catch {
            await MainActor.run {
                self.isLicensed = false
                self.statusMessage = "Activation failed: \(error.localizedDescription)"
            }
            return false
        }
    }

    func validateCurrentLicense(force: Bool = false) async -> Bool {
        guard let key = loadLicenseKey(), !key.isEmpty,
              var activation = loadActivation() else {
            await MainActor.run {
                self.isLicensed = false
                self.statusMessage = "License not configured"
            }
            return false
        }

        if !force,
           activation.lastValidatedAt.addingTimeInterval(revalidateIntervalHours * 3600) > Date(),
           activation.expiresAt > Date() {
            await MainActor.run {
                self.isLicensed = true
                self.statusMessage = "License active"
            }
            return true
        }

        await MainActor.run {
            self.isChecking = true
            self.statusMessage = "Validating license..."
        }
        defer { Task { @MainActor in self.isChecking = false } }

        let payload = ValidateRequest(
            token: activation.token,
            licenseKey: key,
            deviceId: deviceId(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            platform: "macOS"
        )

        do {
            var req = URLRequest(url: validateURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw NSError(domain: "License", code: -2, userInfo: [NSLocalizedDescriptionKey: "Validation endpoint rejected request"])
            }

            let decoded = try JSONDecoder().decode(ValidateResponse.self, from: data)
            guard decoded.ok else {
                await MainActor.run {
                    self.isLicensed = false
                    self.statusMessage = decoded.message ?? "License invalid"
                }
                return false
            }

            let iso = ISO8601DateFormatter()
            activation.expiresAt = iso.date(from: decoded.expiresAt) ?? activation.expiresAt
            activation.lastValidatedAt = Date()
            saveActivation(activation)

            await MainActor.run {
                self.isLicensed = true
                self.statusMessage = "License validated"
            }
            return true
        } catch {
            // Network down: allow temporary grace if previously validated.
            let graceWindow = activation.lastValidatedAt.addingTimeInterval(maxOfflineGraceDays * 24 * 3600)
            if Date() < graceWindow {
                await MainActor.run {
                    self.isLicensed = true
                    self.statusMessage = "Offline grace active"
                }
                return true
            }

            await MainActor.run {
                self.isLicensed = false
                self.statusMessage = "License validation failed: \(error.localizedDescription)"
            }
            return false
        }
    }

    func deactivate() {
        SnotchKeychain.delete(service: service, account: keyAccount)
        SnotchKeychain.delete(service: service, account: activationAccount)
        Task { @MainActor in
            self.isLicensed = false
            self.statusMessage = "License removed"
        }
    }

    func loadLicenseKey() -> String? {
        SnotchKeychain.load(service: service, account: keyAccount)
    }

    func activationSummary() -> Activation? {
        loadActivation()
    }

    func maskedLicenseKey() -> String {
        guard let key = loadLicenseKey(), key.count > 8 else { return "Not set" }
        let prefix = key.prefix(4)
        let suffix = key.suffix(4)
        return "\(prefix)••••••••\(suffix)"
    }

    private func saveLicenseKey(_ key: String) {
        SnotchKeychain.save(service: service, account: keyAccount, value: key)
    }

    private func saveActivation(_ activation: Activation) {
        guard let data = try? JSONEncoder().encode(activation),
              let json = String(data: data, encoding: .utf8) else { return }
        SnotchKeychain.save(service: service, account: activationAccount, value: json)
    }

    private func loadActivation() -> Activation? {
        guard let raw = SnotchKeychain.load(service: service, account: activationAccount),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Activation.self, from: data) else {
            return nil
        }
        return decoded
    }

    private func deviceId() -> String {
        let defaultsKey = "snotch.installationID"
        if let existing = UserDefaults.standard.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: defaultsKey)
        return generated
    }
}
