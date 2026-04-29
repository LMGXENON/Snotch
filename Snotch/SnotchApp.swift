import SwiftUI
import AppKit

@main
struct SnotchApp: App {

    @AppStorage("snotch.onboardingDone") private var onboardingDone: Bool = false
    @StateObject private var speechManager: SpeechManager
    @StateObject private var overlayController: OverlayWindowController
    @State private var globalMonitor: Any? = nil
    @State private var localMonitor: Any? = nil

    init() {
        let sm = SpeechManager()
        _speechManager     = StateObject(wrappedValue: sm)
        _overlayController = StateObject(wrappedValue: OverlayWindowController(speechManager: sm))
    }

    var body: some Scene {
        WindowGroup("Snotch Editor") {
            Group {
                if onboardingDone {
                    ContentView(
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
                if onboardingDone {
                    installGlobalHotkeys()
                    overlayController.show()
                }
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil,
                    queue: .main
                ) { _ in overlayController.repositionIfNeeded() }
            }
            .onChange(of: onboardingDone) { _, done in
                if done {
                    installGlobalHotkeys()
                    overlayController.show()
                }
            }
            .onDisappear { removeGlobalHotkeys() }
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
                Button("Select All") {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("a", modifiers: .command)

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
        }
    }

    private func installGlobalHotkeys() {
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.isEmpty && event.keyCode == 53 {
                    DispatchQueue.main.async {
                        NSApp.terminate(nil)
                    }
                    return nil
                }
                if flags == .command,
                   event.charactersIgnoringModifiers?.lowercased() == "a" {
                    DispatchQueue.main.async {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    }
                    return nil
                }
                return event
            }
        }

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
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
}
