import SwiftUI
import AppKit

@main
struct SnotchApp: App {

    @AppStorage("snotch.onboardingDone") private var onboardingDone: Bool = false
    @StateObject private var speechManager: SpeechManager
    @StateObject private var overlayController: OverlayWindowController
    @StateObject private var licenseManager = LicenseManager()
    @State private var globalMonitor: Any? = nil
    @State private var showManageLicense: Bool = false

    init() {
        let sm = SpeechManager()
        _speechManager     = StateObject(wrappedValue: sm)
        _overlayController = StateObject(wrappedValue: OverlayWindowController(speechManager: sm))
    }

    var body: some Scene {
        WindowGroup("Snotch Editor") {
            Group {
                if !licenseManager.isLicensed {
                    LicenseActivationView(licenseManager: licenseManager)
                } else if onboardingDone {
                    ContentView(
                        licenseManager: licenseManager,
                        speechManager:     speechManager,
                        overlayController: overlayController
                    )
                } else {
                    OnboardingView(speechManager: speechManager) {
                        onboardingDone = true
                    }
                }
            }
            .onAppear {
                Task { await licenseManager.startupValidate() }
                if licenseManager.isLicensed && onboardingDone {
                    installGlobalHotkeys()
                    overlayController.show()
                }
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil,
                    queue: .main
                ) { _ in overlayController.repositionIfNeeded() }
            }
            .onChange(of: licenseManager.isLicensed) { licensed in
                if licensed && onboardingDone {
                    installGlobalHotkeys()
                    overlayController.show()
                } else {
                    removeGlobalHotkeys()
                    overlayController.hide()
                }
            }
            .onChange(of: onboardingDone) { done in
                if done && licenseManager.isLicensed {
                    installGlobalHotkeys()
                    overlayController.show()
                }
            }
            .onDisappear { removeGlobalHotkeys() }
            .sheet(isPresented: $showManageLicense) {
                ManageLicenseView(licenseManager: licenseManager)
            }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 900, height: 620)
        .commands {
            CommandGroup(replacing: .printItem) {
                Button("Play / Stop") { speechManager.toggleListening() }
                    .keyboardShortcut("p", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Scroll Up") {
                    NotificationCenter.default.post(name: .snotchScrollUp, object: nil)
                }
                .keyboardShortcut(.upArrow, modifiers: .shift)
                Button("Scroll Down") {
                    NotificationCenter.default.post(name: .snotchScrollDown, object: nil)
                }
                .keyboardShortcut(.downArrow, modifiers: .shift)
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .snotchToggleSidebar, object: nil)
                }
                .keyboardShortcut("[", modifiers: .command)
            }
            // Provide a Format menu so TextEditor's auto-registered submenus
            // (Font, Spelling, Substitutions, etc.) have a valid parent and
            // stop logging "Internal inconsistency in menus" warnings.
            CommandMenu("Format") {
                EmptyView()
            }
            CommandMenu("License") {
                Button("Manage License") {
                    showManageLicense = true
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("Revalidate License") {
                    Task { _ = await licenseManager.validateCurrentLicense(force: true) }
                }

                Button("Deactivate License") {
                    licenseManager.deactivate()
                }
            }
        }
    }

    private func installGlobalHotkeys() {
        guard globalMonitor == nil else { return }
        guard AXIsProcessTrusted() else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command && event.charactersIgnoringModifiers == "p" {
                DispatchQueue.main.async { speechManager.toggleListening() }
            }
            if flags == .shift && event.specialKey == .upArrow {
                DispatchQueue.main.async { speechManager.scrollUp() }
            }
            if flags == .shift && event.specialKey == .downArrow {
                DispatchQueue.main.async { speechManager.scrollDown() }
            }
            if flags == .command && event.charactersIgnoringModifiers == "[" {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .snotchToggleSidebar, object: nil)
                }
            }
        }
    }

    private func removeGlobalHotkeys() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }
}
