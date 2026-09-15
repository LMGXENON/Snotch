import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

final class OverlayWindow: NSWindow {

    static let compactSize = CGSize(width: 280, height: 94)
    static let expandedSize = CGSize(width: 760, height: 360)

    var onScrollUp: (() -> Void)?
    var onScrollDown: (() -> Void)?
    var shouldInterceptScrollWheel: (() -> Bool)?
    private var wheelAccumulator: CGFloat = 0
    private var overlaySize: CGSize = compactSize

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configure()
    }

    private func configure() {
        // Default to shareable; controller applies user-selected capture privacy mode.
        sharingType = .readOnly
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isMovableByWindowBackground = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView?.wantsLayer = true
        // Mask the AppKit layer with bottom-only rounded corners (radius 24),
        // matching the SwiftUI UnevenRoundedRectangle clipShape precisely.
        applyBottomRoundedMask(radius: 24)
        positionNearNotch()
    }

    private func applyBottomRoundedMask(radius: CGFloat) {
        guard let layer = contentView?.layer else { return }
        layer.cornerRadius = 0
        layer.masksToBounds = true
        // Use cornerRadius only on the bottom two corners via CALayer's maskedCorners
        layer.cornerRadius = radius
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    }

    func positionNearNotch() {
        guard let frame = targetFrame(for: overlaySize) else { return }
        setFrame(frame, display: true)
    }

    func setOverlaySize(_ size: CGSize, animated: Bool) {
        overlaySize = size
        guard let frame = targetFrame(for: size) else { return }
        setFrame(frame, display: true, animate: animated)
    }

    private func targetFrame(for size: CGSize) -> CGRect? {
        guard let screen = NSScreen.main else { return nil }
        let topEdgeOffset: CGFloat = 2

        var xOrigin: CGFloat
        var yOrigin: CGFloat

        if #available(macOS 12.0, *) {
            let safeInsets = screen.safeAreaInsets
            if safeInsets.top > 0 {
                xOrigin = screen.frame.midX - size.width / 2
                yOrigin = screen.frame.maxY - safeInsets.top - topEdgeOffset - size.height
            } else {
                xOrigin = screen.frame.midX - size.width / 2
                yOrigin = screen.frame.maxY - 28 - topEdgeOffset - size.height
            }
        } else {
            xOrigin = screen.frame.midX - size.width / 2
            yOrigin = screen.frame.maxY - 28 - topEdgeOffset - size.height
        }

        return CGRect(x: xOrigin, y: yOrigin, width: size.width, height: size.height)
    }

    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, handleScrollWheel(event) {
            return
        }
        super.sendEvent(event)
    }

    private func handleScrollWheel(_ event: NSEvent) -> Bool {
        if let shouldInterceptScrollWheel, shouldInterceptScrollWheel() == false {
            return false
        }

        let deltaY = event.scrollingDeltaY
        guard deltaY != 0 else { return false }

        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 6.0 : 1.0
        wheelAccumulator += deltaY
        var consumed = false

        while wheelAccumulator >= threshold {
            onScrollUp?()
            wheelAccumulator -= threshold
            consumed = true
        }

        while wheelAccumulator <= -threshold {
            onScrollDown?()
            wheelAccumulator += threshold
            consumed = true
        }

        return consumed
    }
}

struct OverlayInlineEditorScript {
    let id: UUID
    let title: String
    let body: String
}

final class OverlayWindowController: ObservableObject {

    @Published var isVisible: Bool = false
    @Published private(set) var hideOverlayInScreenCapture: Bool
    @Published private(set) var isInlineEditing: Bool = false

    private static let hideOverlayInCapturePrefKey = "snotch.dev.hideOverlayInCapture"

    private var overlayWindow: OverlayWindow?
    private var windowController: NSWindowController?
    private let speechManager: SpeechManager

    init(speechManager: SpeechManager) {
        self.speechManager = speechManager
        if let saved = UserDefaults.standard.object(forKey: Self.hideOverlayInCapturePrefKey) as? Bool {
            self.hideOverlayInScreenCapture = saved
        } else {
            self.hideOverlayInScreenCapture = true
        }
        buildOverlay()
    }

    private func buildOverlay() {
        let win = OverlayWindow()
        win.onScrollUp = { [weak self] in
            self?.speechManager.scrollUp()
        }
        win.onScrollDown = { [weak self] in
            self?.speechManager.scrollDown()
        }
        win.shouldInterceptScrollWheel = { [weak self] in
            !(self?.isInlineEditing ?? false)
        }
        let pillView = OverlayPillView(
            speechManager: speechManager,
            onRequestInlineScript: { [weak self] in
                self?.activeScriptForInlineEditor()
            },
            onCommitInlineEdit: { [weak self] scriptID, newBody in
                self?.saveQuickEditorChanges(scriptID: scriptID, newBody: newBody)
            },
            onEditingModeChanged: { [weak self] editing in
                self?.setInlineEditing(editing)
            }
        )
        let hosting = NSHostingView(rootView: pillView)
        hosting.frame = CGRect(origin: .zero, size: OverlayWindow.compactSize)
        hosting.autoresizingMask = [.width, .height]
        win.contentView?.addSubview(hosting)
        self.overlayWindow = win
        self.windowController = NSWindowController(window: win)
        applyCapturePrivacyMode()
    }

    private func setInlineEditing(_ editing: Bool) {
        guard isInlineEditing != editing else { return }
        isInlineEditing = editing
        let targetSize = editing ? OverlayWindow.expandedSize : OverlayWindow.compactSize
        overlayWindow?.setOverlaySize(targetSize, animated: true)
    }

    func setHideOverlayInScreenCapture(_ enabled: Bool) {
        guard hideOverlayInScreenCapture != enabled else { return }
        hideOverlayInScreenCapture = enabled
        UserDefaults.standard.set(enabled, forKey: Self.hideOverlayInCapturePrefKey)
        applyCapturePrivacyMode()
    }

    private func applyCapturePrivacyMode() {
        overlayWindow?.sharingType = hideOverlayInScreenCapture ? .none : .readOnly
    }

    func show() {
        overlayWindow?.orderFrontRegardless()
        DispatchQueue.main.async { self.isVisible = true }
    }

    func hide() {
        setInlineEditing(false)
        overlayWindow?.orderOut(nil)
        DispatchQueue.main.async { self.isVisible = false }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func repositionIfNeeded() {
        overlayWindow?.positionNearNotch()
    }

    private func activeScriptForInlineEditor() -> OverlayInlineEditorScript? {
        guard let activeID = speechManager.activeScriptID else {
            return nil
        }
        let scripts = loadStoredScripts()
        guard let script = scripts.first(where: { $0.id == activeID }) else {
            return nil
        }

        return OverlayInlineEditorScript(id: activeID, title: script.title, body: script.body)
    }

    private func loadStoredScripts() -> [SnotchScript] {
        guard let data = UserDefaults.standard.data(forKey: "snotch.scripts"),
              let decoded = try? JSONDecoder().decode([SnotchScript].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persistStoredScripts(_ scripts: [SnotchScript]) {
        guard let data = try? JSONEncoder().encode(scripts) else { return }
        UserDefaults.standard.set(data, forKey: "snotch.scripts")
    }

    private func saveQuickEditorChanges(scriptID: UUID, newBody: String) {
        var scripts = loadStoredScripts()
        guard let idx = scripts.firstIndex(where: { $0.id == scriptID }) else { return }

        scripts[idx].body = newBody
        scripts[idx].lastEdited = Date()
        persistStoredScripts(scripts)

        if speechManager.activeScriptID == scriptID {
            speechManager.loadScript(newBody)
        }

        NotificationCenter.default.post(
            name: .snotchOverlayEditorSaved,
            object: nil,
            userInfo: ["id": scriptID, "body": newBody]
        )
    }
}

final class OverlayQuickEditorWindowController: NSWindowController {

    init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func present(script: SnotchScript, onSave: @escaping (String) -> Void) {
        let isLight = UserDefaults.standard.bool(forKey: "snotch.pillLight")
        let root = OverlayQuickEditorView(
            title: script.title,
            initialText: script.body,
            onSave: { [weak self] text in
                onSave(text)
                self?.window?.close()
            },
            onCancel: { [weak self] in
                self?.window?.close()
            }
        )
        let host = NSHostingController(rootView: root)
        window?.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
        window?.contentViewController = host
        showWindow(nil)
        if let window {
            centerWindowOnActiveScreen(window)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        // Re-apply on next runloop in case AppKit repositions after activation.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            self.centerWindowOnActiveScreen(window)
        }
    }

    private func centerWindowOnActiveScreen(_ window: NSWindow) {
        guard let screen = NSApp.keyWindow?.screen
                ?? NSApp.mainWindow?.screen
                ?? NSScreen.main
                ?? window.screen else {
            window.center()
            return
        }

        let visible = screen.visibleFrame
        let size = window.frame.size
        let origin = CGPoint(
            x: visible.origin.x + (visible.size.width - size.width) / 2,
            y: visible.origin.y + (visible.size.height - size.height) / 2
        )
        window.setFrameOrigin(origin)
    }
}

private struct OverlayQuickEditorView: View {
    let title: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @AppStorage("snotch.pillLight") private var pillLight: Bool = false
    @State private var draft: String

    private var primaryText: Color {
        Color(white: pillLight ? 0.12 : 0.82)
    }

    private var secondaryText: Color {
        Color(white: pillLight ? 0.40 : 0.55)
    }

    private var dividerColor: Color {
        Color(white: pillLight ? 0 : 1, opacity: 0.10)
    }

    private var panelBackground: Color {
        Color(white: pillLight ? 0.94 : 0.10)
    }

    private var editorBackground: Color {
        Color(white: pillLight ? 1.0 : 0.07)
    }

    private var editorText: Color {
        Color(white: pillLight ? 0.10 : 0.93)
    }

    private var cancelForeground: Color {
        Color(white: pillLight ? 0.22 : 0.86)
    }

    private var saveForeground: Color {
        Color(white: pillLight ? 0.12 : 0.96)
    }

    private var cancelBackground: Color {
        pillLight
            ? Color(red: 0.95, green: 0.87, blue: 0.89).opacity(0.95)
            : Color(red: 0.34, green: 0.08, blue: 0.10).opacity(0.78)
    }

    private var saveBackground: Color {
        pillLight
            ? Color(red: 0.84, green: 0.93, blue: 0.87).opacity(0.95)
            : Color(red: 0.05, green: 0.42, blue: 0.21).opacity(0.90)
    }

    init(title: String, initialText: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: initialText)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quick Edit")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(primaryText)
                    Text(title)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(cancelForeground)
                        .frame(width: 28, height: 28)
                        .background(cancelBackground, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button(action: { onSave(draft) }) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(saveForeground)
                        .frame(width: 28, height: 28)
                        .background(saveBackground, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Rectangle()
                .fill(dividerColor)
                .frame(height: 0.5)

            TextEditor(text: $draft)
                .font(.system(size: 15, weight: .regular, design: .monospaced))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(editorBackground)
                .foregroundColor(editorText)
        }
        .background(panelBackground)
        .frame(minWidth: 700, minHeight: 440)
        .preferredColorScheme(pillLight ? .light : .dark)
        .onExitCommand(perform: onCancel)
    }
}

// MARK: - Speaking glow layer

private struct CurvedGlowTopMask: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let sideY = rect.height * 0.74
        let apexY = rect.height * 0.26

        path.move(to: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: sideY))
        path.addCurve(
            to: CGPoint(x: rect.width, y: sideY),
            control1: CGPoint(x: rect.width * 0.26, y: apexY),
            control2: CGPoint(x: rect.width * 0.74, y: apexY)
        )
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.closeSubpath()
        return path
    }
}

private struct SpeakingGradientGlowView: View {
    let audioLevel: Float
    let lightMode: Bool
    let isVoiceActive: Bool
    @State private var smoothed: Double = 0

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let breathing = 0.92 + 0.08 * sin(t * 3.2)
            let strength = max(0, min(1, smoothed * breathing))

            ZStack {
                LinearGradient(
                    colors: lightMode
                        ? [
                            Color(red: 0.38, green: 0.63, blue: 0.98).opacity(0.32),
                            Color(red: 0.15, green: 0.42, blue: 0.90).opacity(0.14),
                            .clear,
                        ]
                        : [
                            Color(red: 0.20, green: 0.46, blue: 1.00).opacity(0.48),
                            Color(red: 0.08, green: 0.24, blue: 0.78).opacity(0.24),
                            .clear,
                        ],
                    startPoint: .bottom,
                    endPoint: .top
                )

                RadialGradient(
                    stops: [
                        .init(color: Color(red: 0.34, green: 0.62, blue: 1.00).opacity(lightMode ? 0.56 : 0.74), location: 0.00),
                        .init(color: Color(red: 0.10, green: 0.34, blue: 0.95).opacity(lightMode ? 0.36 : 0.52), location: 0.52),
                        .init(color: .clear, location: 1.00),
                    ],
                    center: .bottom,
                    startRadius: 0,
                    endRadius: 154
                )

                RadialGradient(
                    stops: [
                        .init(color: Color(red: 0.54, green: 0.76, blue: 1.00).opacity(lightMode ? 0.28 : 0.42), location: 0.00),
                        .init(color: .clear, location: 1.00),
                    ],
                    center: UnitPoint(x: 0.5, y: 0.90),
                    startRadius: 0,
                    endRadius: 96
                )
            }
            .mask(
                CurvedGlowTopMask()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.00),
                                .init(color: .white.opacity(0.12), location: 0.40),
                                .init(color: .white.opacity(0.48), location: 0.62),
                                .init(color: .white.opacity(0.84), location: 0.80),
                                .init(color: .white, location: 1.00),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .opacity(strength)
            .scaleEffect(x: 1.0 + 0.015 * strength, y: 1.0 + 0.05 * strength, anchor: .bottom)
            .blur(radius: lightMode ? 6 : 8)
            .animation(.easeInOut(duration: 0.20), value: smoothed)
            .task(id: tl.date) {
                let normalized = Double(min(max(audioLevel * 18.0, 0), 1.0))
                let target = isVoiceActive ? max(0.20, normalized) : 0
                let response = target > smoothed ? 0.17 : 0.07
                smoothed += (target - smoothed) * response
            }
        }
        .allowsHitTesting(false)
    }
}

private struct DotMatrixTextureView: View {
    let lightMode: Bool

    var body: some View {
        Canvas { ctx, size in
            let spacing: CGFloat = 10
            let dotSize: CGFloat = 2.2
            let rows = Int(ceil(size.height / spacing)) + 1
            let cols = Int(ceil(size.width / spacing)) + 1
            let tint = lightMode
                ? Color(white: 0.10).opacity(0.14)
                : Color.white.opacity(0.19)

            for row in 0...rows {
                for col in 0...cols {
                    let x = CGFloat(col) * spacing + spacing * 0.5
                    let y = CGFloat(row) * spacing + spacing * 0.5
                    let dotRect = CGRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize)
                    ctx.fill(Path(ellipseIn: dotRect), with: .color(tint))
                }
            }
        }
    }
}

private struct NotchBackdropView: View {
    let lightMode: Bool
    let showPauseAccent: Bool

    var body: some View {
        GeometryReader { geo in
            let glowOpacity = lightMode ? 0.20 : 0.52
            let glowRadius = max(geo.size.width * 0.80, geo.size.height * 2.25)

            let accentCenterColor = Color(red: 0.60, green: 0.05, blue: 0.08)
            let accentEdgeColor = Color(red: 0.34, green: 0.04, blue: 0.07)

            ZStack {
                LinearGradient(
                    colors: lightMode
                        ? [Color(white: 0.96), Color(white: 0.88)]
                        : [Color(white: 0.01), Color(white: 0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                if showPauseAccent {
                    RadialGradient(
                        stops: [
                            .init(color: accentCenterColor.opacity(glowOpacity), location: 0.00),
                            .init(color: accentEdgeColor.opacity(glowOpacity * 0.80), location: 0.50),
                            .init(color: .clear, location: 1.00),
                        ],
                        center: .bottom,
                        startRadius: 0,
                        endRadius: glowRadius
                    )
                    .blendMode(lightMode ? .multiply : .screen)
                }

                DotMatrixTextureView(lightMode: lightMode)
                    .opacity(lightMode ? 0.55 : 0.78)
                    .blendMode(lightMode ? .multiply : .screen)
            }
        }
    }
}

struct OverlayPillView: View {

    @ObservedObject var speechManager: SpeechManager
    let onRequestInlineScript: () -> OverlayInlineEditorScript?
    let onCommitInlineEdit: (UUID, String) -> Void
    let onEditingModeChanged: (Bool) -> Void
    @AppStorage("snotch.pillLight") private var isLight: Bool = false
    @State private var isHovering: Bool = false
    @State private var isEditingInline: Bool = false
    @State private var inlineEditorScriptID: UUID?
    @State private var inlineEditorTitle: String = ""
    @State private var inlineEditorDraft: String = ""
    @FocusState private var inlineEditorFocused: Bool

    private var activeRowHeight: CGFloat {
        38
    }

    private var progressFraction: Double {
        guard speechManager.isListening || speechManager.isCountingDown else { return 0 }
        let total = max(1, speechManager.scriptLines.count - 1)
        let rawProgress = speechManager.continuousLineProgress
        return min(1, max(0, rawProgress / Double(total)))
    }

    // In highlighted mode, keep the active line anchored for most of the line
    // and only start lifting near the end to make word-by-word reading easier.
    private var notchDisplayProgress: Double {
        let raw = speechManager.continuousLineProgress
        guard !speechManager.continuousScrollInNotch else { return raw }

        let baseLine = floor(raw)
        let fraction = raw - baseLine
        let liftStart = 0.86

        guard fraction > liftStart else { return baseLine }

        let normalized = (fraction - liftStart) / (1.0 - liftStart)
        return baseLine + min(1.0, max(0.0, normalized))
    }

    private var highlightedVerticalBias: CGFloat {
        speechManager.continuousScrollInNotch ? 0 : 6
    }

    private var overlaySize: CGSize {
        isEditingInline ? OverlayWindow.expandedSize : OverlayWindow.compactSize
    }

    private func beginInlineEdit() {
        guard !isEditingInline else { return }
        guard let script = onRequestInlineScript() else {
            NSSound.beep()
            return
        }

        inlineEditorScriptID = script.id
        inlineEditorTitle = script.title
        inlineEditorDraft = script.body

        withAnimation(.easeInOut(duration: 0.2)) {
            isEditingInline = true
        }
        onEditingModeChanged(true)

        DispatchQueue.main.async {
            inlineEditorFocused = true
        }
    }

    private func cancelInlineEdit() {
        guard isEditingInline else { return }
        inlineEditorFocused = false
        withAnimation(.easeInOut(duration: 0.2)) {
            isEditingInline = false
        }
        onEditingModeChanged(false)
    }

    private func approveInlineEdit() {
        guard let scriptID = inlineEditorScriptID else {
            cancelInlineEdit()
            return
        }

        onCommitInlineEdit(scriptID, inlineEditorDraft)
        cancelInlineEdit()
    }

    private var inlineEditorOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notch Edit")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(white: isLight ? 0.12 : 0.82))
                    Text(inlineEditorTitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Color(white: isLight ? 0.40 : 0.55))
                        .lineLimit(1)
                }

                Spacer()

                Button(action: cancelInlineEdit) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(white: isLight ? 0.22 : 0.86))
                        .frame(width: 28, height: 28)
                        .background(
                            (isLight
                                ? Color(red: 0.95, green: 0.87, blue: 0.89).opacity(0.95)
                                : Color(red: 0.34, green: 0.08, blue: 0.10).opacity(0.78)),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)

                Button(action: approveInlineEdit) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(white: isLight ? 0.12 : 0.96))
                        .frame(width: 28, height: 28)
                        .background(
                            (isLight
                                ? Color(red: 0.84, green: 0.93, blue: 0.87).opacity(0.95)
                                : Color(red: 0.05, green: 0.42, blue: 0.21).opacity(0.90)),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Rectangle()
                .fill(Color(white: isLight ? 0 : 1, opacity: 0.10))
                .frame(height: 0.5)

            TextEditor(text: $inlineEditorDraft)
                .font(.system(size: 15, weight: .regular, design: .monospaced))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(Color(white: isLight ? 1.0 : 0.07))
                .foregroundColor(Color(white: isLight ? 0.10 : 0.93))
                .focused($inlineEditorFocused)
        }
        .background(Color(white: isLight ? 0.94 : 0.10).opacity(0.98))
    }

    var body: some View {
        ZStack {
            NotchBackdropView(
                lightMode: isLight,
                showPauseAccent: speechManager.isPaused
            )
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0, bottomLeadingRadius: 24,
                        bottomTrailingRadius: 24, topTrailingRadius: 0,
                        style: .continuous
                    )
                )
                .animation(.easeInOut(duration: 0.3), value: isLight)

            // Speaking glow: smooth gradient fade in/out while voice is active.
            SpeakingGradientGlowView(
                audioLevel: speechManager.audioLevel,
                lightMode: isLight,
                isVoiceActive: speechManager.isVoiceActive && !speechManager.isPaused
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blendMode(isLight ? .multiply : .screen)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0, bottomLeadingRadius: 24,
                        bottomTrailingRadius: 24, topTrailingRadius: 0,
                        style: .continuous
                    )
                )

            // Border
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 24,
                bottomTrailingRadius: 24, topTrailingRadius: 0,
                style: .continuous
            )
            .strokeBorder(
                LinearGradient(
                    colors: isLight
                        ? [.clear, .black.opacity(0.12)]
                        : [.clear, .white.opacity(0.12)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.75
            )
            .animation(.easeInOut(duration: 0.3), value: isLight)

            // Filler word flash — subtle glow pulse
            if speechManager.fillerFlash {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0, bottomLeadingRadius: 24,
                    bottomTrailingRadius: 24, topTrailingRadius: 0,
                    style: .continuous
                )
                .strokeBorder(
                    Color(white: isLight ? 0.0 : 1.0, opacity: 0.22),
                    lineWidth: 1.0
                )
                .blur(radius: 2)
                .transition(.opacity)
            }

            if speechManager.focusGlow {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0, bottomLeadingRadius: 24,
                    bottomTrailingRadius: 24, topTrailingRadius: 0,
                    style: .continuous
                )
                .fill(Color(white: isLight ? 0 : 1, opacity: isLight ? 0.05 : 0.07))
                .blur(radius: 12)
                .transition(.opacity)
            }

            // Script lines
            GeometryReader { geo in
                let displayProgress = notchDisplayProgress
                let offset = geo.size.height / 2.0
                    - CGFloat(displayProgress) * activeRowHeight
                    - activeRowHeight / 2.0
                    + highlightedVerticalBias
                VStack(alignment: .center, spacing: 0) {
                    ForEach(Array(speechManager.scriptLines.enumerated()), id: \.offset) { index, line in
                        Group {
                            if shouldUseWordHighlight(for: index) {
                                highlightedLineText(line)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .minimumScaleFactor(1.0)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text(line)
                                    .font(lineFont(index))
                                    .foregroundColor(lineColor(index))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .minimumScaleFactor(1.0)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .frame(height: activeRowHeight)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .offset(y: offset)
                .animation(
                    .linear(duration: 0.08),
                    value: notchDisplayProgress
                )
            }
            .clipped()

            // Progress bar — pinned to very bottom edge.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color(white: isLight ? 0 : 1, opacity: 0.10))
                        .frame(height: 3)
                    GeometryReader { bar in
                        Rectangle()
                            .fill(Color(white: isLight ? 0 : 1, opacity: 0.60))
                            .frame(
                                width: min(bar.size.width, max(0, CGFloat(progressFraction) * bar.size.width)),
                                height: 3
                            )
                            .animation(.linear(duration: 0.4), value: progressFraction)
                    }
                }
                .frame(height: 3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)

            // 3-2-1 countdown overlay
            if speechManager.isCountingDown {
                ZStack {
                    (isLight ? Color(white: 0.94) : Color.black).opacity(0.58)
                    Text("\(speechManager.countdownValue)")
                        .font(.system(size: 48, weight: .light))
                        .foregroundColor(isLight ? Color(white: 0.10) : .white)
                        .animation(.spring(response: 0.22, dampingFraction: 0.55), value: speechManager.countdownValue)
                }
            }

            if isEditingInline {
                inlineEditorOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(20)
            }
        }
        .frame(width: overlaySize.width, height: overlaySize.height)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 24,
                bottomTrailingRadius: 24, topTrailingRadius: 0,
                style: .continuous
            )
        )
        .shadow(
            color: isLight ? .black.opacity(0.18) : .black.opacity(0.4),
            radius: 14, x: 0, y: 6
        )
        .animation(.easeOut(duration: 0.2), value: speechManager.fillerFlash)
        .animation(.easeInOut(duration: 0.25), value: speechManager.focusGlow)
        .animation(.easeInOut(duration: 0.2), value: speechManager.isPaused)
        .preferredColorScheme(.dark)
        .onTapGesture(count: 2) {
            if !isEditingInline {
                beginInlineEdit()
            }
        }
        .onHover { hovering in
            isHovering = hovering
            if isEditingInline {
                speechManager.isPaused = false
            } else {
                speechManager.isPaused = hovering && speechManager.isListening
            }
        }
        .onChange(of: speechManager.isListening) { _, listening in
            if !listening {
                speechManager.isPaused = false
            } else if isHovering && !isEditingInline {
                speechManager.isPaused = true
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            isEditingInline ? false : handleFileDrop(providers)
        }
        .onDisappear {
            if isEditingInline {
                cancelInlineEdit()
            }
        }
    }

    private func shouldUseWordHighlight(for index: Int) -> Bool {
        !speechManager.continuousScrollInNotch && index == speechManager.currentLineIndex
    }

    private func highlightedLineText(_ line: String) -> Text {
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else {
            return Text(line)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isLight ? Color(white: 0.05) : .white)
        }

        let activeIndex = min(max(0, speechManager.currentWordIndexInLine), words.count - 1)
        var attributed = AttributedString()

        for (index, word) in words.enumerated() {
            let isActive = index == activeIndex

            var piece = AttributedString(word)
            piece.font = .system(size: 13, weight: isActive ? .semibold : .regular)
            piece.foregroundColor = isLight
                ? Color(white: 0.05).opacity(isActive ? 1.0 : 0.82)
                : Color.white.opacity(isActive ? 1.0 : 0.88)

            attributed.append(piece)
            if index < words.count - 1 {
                attributed.append(AttributedString(" "))
            }
        }

        return Text(attributed)
    }

    private func lineFont(_ index: Int) -> Font {
        _ = index
        return .system(size: 13, weight: .regular)
    }

    private func lineColor(_ index: Int) -> Color {
        _ = index
        return isLight
            ? Color(white: 0.05).opacity(0.82)
            : .white.opacity(0.88)
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let url = decodeDroppedFileURL(from: item) else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .snotchImportScriptURL,
                    object: nil,
                    userInfo: ["url": url]
                )
            }
        }

        return true
    }

    private func decodeDroppedFileURL(from item: NSSecureCoding?) -> URL? {
        func decodeTextURL(_ text: String) -> URL? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), url.isFileURL {
                return url
            }
            if trimmed.hasPrefix("/") {
                return URL(fileURLWithPath: trimmed)
            }
            if let decoded = trimmed.removingPercentEncoding, decoded.hasPrefix("/") {
                return URL(fileURLWithPath: decoded)
            }
            if let url = URL(string: trimmed), url.isFileURL {
                return url
            }
            return nil
        }

        if let url = item as? URL {
            return url
        }
        if let data = item as? Data {
            if let nsURL = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL? {
                return nsURL
            }
            if let text = String(data: data, encoding: .utf8) {
                return decodeTextURL(text)
            }
        }
        if let text = item as? String {
            return decodeTextURL(text)
        }
        return nil
    }
}
