import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import PDFKit
import Speech
import AVFoundation
import ApplicationServices

struct StickyNoteData: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var text: String = ""
    var pinned: Bool = false
}

struct SnotchScript: Identifiable, Codable, Equatable {
    var id:         UUID   = UUID()
    var title:      String
    var body:       String
    var notes:      String? = nil
    var noteColor:  String? = nil
    var notePinned: Bool? = nil
    var stickyNotes: [StickyNoteData] = []
    var lastEdited: Date   = Date()
    var lastOpened: Date? = nil
    var targetWPMMin: Double = 160
    var targetWPMMax: Double = 210
    var workspace: String = "General"
    var tags: [String] = []

    init(
        id: UUID = UUID(),
        title: String,
        body: String,
        notes: String? = nil,
        noteColor: String? = nil,
        notePinned: Bool? = nil,
        stickyNotes: [StickyNoteData] = [],
        lastEdited: Date = Date(),
        lastOpened: Date? = nil,
        targetWPMMin: Double = 160,
        targetWPMMax: Double = 210,
        workspace: String = "General",
        tags: [String] = []
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.notes = notes
        self.noteColor = noteColor
        self.notePinned = notePinned
        self.stickyNotes = stickyNotes
        self.lastEdited = lastEdited
        self.lastOpened = lastOpened
        self.targetWPMMin = targetWPMMin
        self.targetWPMMax = targetWPMMax
        self.workspace = workspace
        self.tags = tags
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case body
        case notes
        case noteColor
        case notePinned
        case stickyNotes
        case lastEdited
        case lastOpened
        case targetWPMMin
        case targetWPMMax
        case workspace
        case tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled Script"
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        noteColor = try container.decodeIfPresent(String.self, forKey: .noteColor)
        notePinned = try container.decodeIfPresent(Bool.self, forKey: .notePinned)
        stickyNotes = try container.decodeIfPresent([StickyNoteData].self, forKey: .stickyNotes) ?? []
        lastEdited = try container.decodeIfPresent(Date.self, forKey: .lastEdited) ?? Date()
        lastOpened = try container.decodeIfPresent(Date.self, forKey: .lastOpened)
        targetWPMMin = try container.decodeIfPresent(Double.self, forKey: .targetWPMMin) ?? 160
        targetWPMMax = try container.decodeIfPresent(Double.self, forKey: .targetWPMMax) ?? 210
        workspace = try container.decodeIfPresent(String.self, forKey: .workspace) ?? "General"
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []

        // Migrate legacy single-note fields to the new multi-note model.
        if stickyNotes.isEmpty,
           let legacy = notes?.trimmingCharacters(in: .whitespacesAndNewlines),
           !legacy.isEmpty {
            stickyNotes = [StickyNoteData(text: legacy, pinned: notePinned ?? false)]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(noteColor, forKey: .noteColor)
        try container.encodeIfPresent(notePinned, forKey: .notePinned)
        try container.encode(stickyNotes, forKey: .stickyNotes)
        try container.encode(lastEdited, forKey: .lastEdited)
        try container.encodeIfPresent(lastOpened, forKey: .lastOpened)
        try container.encode(targetWPMMin, forKey: .targetWPMMin)
        try container.encode(targetWPMMax, forKey: .targetWPMMax)
        try container.encode(workspace, forKey: .workspace)
        try container.encode(tags, forKey: .tags)
    }
}

final class ScriptStore: ObservableObject {
    @Published var scripts: [SnotchScript] = []
    private let saveKey = "snotch.scripts"

    init() { load() }

    func save() {
        if let data = try? JSONEncoder().encode(scripts) {
            UserDefaults.standard.set(data, forKey: saveKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode([SnotchScript].self, from: data) {
            scripts = decoded
        } else {
            scripts = [SnotchScript(
                title: "Get Started",
                body: "Welcome to Snotch, your personal teleprompter.\n\nStart speaking and watch the text follow your voice.\n\nEdit this script or create a new one from the sidebar.\n\nPress Cmd P to start or stop voice tracking.\n\nUse Shift Up and Shift Down to scroll manually."
            )]
            save()
        }
    }

    func addScript() -> SnotchScript {
        let s = SnotchScript(title: nextUntitledTitle(), body: "")
        scripts.insert(s, at: 0)
        save()
        return s
    }

    private func nextUntitledTitle() -> String {
        let used = Set(scripts.map { $0.title.lowercased() })
        var suffix = 0

        while true {
            let candidate = suffix == 0 ? "Untitled" : "Untitled \(suffix)"
            if !used.contains(candidate.lowercased()) {
                return candidate
            }
            suffix += 1
        }
    }

    func update(_ script: SnotchScript) {
        if let idx = scripts.firstIndex(where: { $0.id == script.id }) {
            scripts[idx] = script
            save()
        }
    }

    func delete(at offsets: IndexSet) {
        scripts.remove(atOffsets: offsets)
        save()
    }
}

// MARK: - Stepper Control

private struct LabeledStepper: View {
    @AppStorage("snotch.pillLight") private var pillLight: Bool = false
    let icon:      String   // SF Symbol name
    let label:     String
    let value:     String
    let canDecrement: Bool
    let canIncrement: Bool
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Icon + label badge
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(white: 0.45))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(white: 0.40))
            }
            .padding(.leading, 9)
            .padding(.trailing, 6)

            Rectangle()
                .fill(Color(white: pillLight ? 0 : 1, opacity: 0.08))
                .frame(width: 0.5, height: 18)

            // Decrement
            Button(action: onDecrement) {
                Image(systemName: "minus")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(canDecrement ? Color(white: 0.60) : Color(white: 0.25))
                    .frame(width: 26, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(!canDecrement)

            // Value
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(white: pillLight ? 0.15 : 0.82))
                .frame(minWidth: 36)
                .multilineTextAlignment(.center)

            // Increment
            Button(action: onIncrement) {
                Image(systemName: "plus")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(canIncrement ? Color(white: 0.60) : Color(white: 0.25))
                    .frame(width: 26, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(!canIncrement)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(white: pillLight ? 0 : 1, opacity: 0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(white: pillLight ? 0 : 1, opacity: 0.09), lineWidth: 0.5)
        )
        .fixedSize()
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private extension View {
    @ViewBuilder
    func snotchTextSelection(enabled: Bool) -> some View {
        if enabled {
            self.textSelection(.enabled)
        } else {
            self.textSelection(.disabled)
        }
    }
}

private struct EditorScrollBarStyler: NSViewRepresentable {
    private let activeLineLayerName = "snotch.active-line-highlight"
    let topInset: CGFloat
    let bottomInset: CGFloat
    let rightInset: CGFloat
    let useDarkKnob: Bool
    let showsVerticalScroller: Bool
    let textTopInset: CGFloat
    let textLeadingInset: CGFloat
    let isEditable: Bool
    let highlightedLineIndex: Int?
    let highlightOpacity: CGFloat
    let onLineTapped: ((Int) -> Void)?

    final class Coordinator: NSObject {
        private var clickRecognizer: NSClickGestureRecognizer?
        private weak var observedTextView: NSTextView?
        private var onLineTapped: ((Int) -> Void)?
        private var lastTappedLine: Int?

        deinit {
            detachClickRecognizer()
        }

        func updateInteraction(for textView: NSTextView, onLineTapped: ((Int) -> Void)?) {
            self.onLineTapped = onLineTapped

            if observedTextView !== textView {
                detachClickRecognizer()
                observedTextView = textView
            }

            guard let onLineTapped else {
                detachClickRecognizer()
                return
            }

            self.onLineTapped = onLineTapped

            if clickRecognizer == nil {
                let recognizer = NSClickGestureRecognizer(target: self, action: #selector(handleTextClick(_:)))
                recognizer.numberOfClicksRequired = 1
                textView.addGestureRecognizer(recognizer)
                clickRecognizer = recognizer
            }
        }

        private func detachClickRecognizer() {
            if let clickRecognizer, let observedTextView {
                observedTextView.removeGestureRecognizer(clickRecognizer)
            }

            clickRecognizer = nil
            lastTappedLine = nil
        }

        @objc private func handleTextClick(_ recognizer: NSClickGestureRecognizer) {
            guard recognizer.state == .ended,
                  let textView = observedTextView,
                  let onLineTapped else {
                return
            }

            let point = recognizer.location(in: textView)
            let line = Self.lineIndex(forPoint: point, in: textView)

            guard line != lastTappedLine else { return }
            lastTappedLine = line
            onLineTapped(line)
        }

        private static func lineIndex(forPoint point: NSPoint, in textView: NSTextView) -> Int {
            let text = textView.string as NSString
            guard text.length > 0 else { return 0 }

            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return 0
            }

            let containerOrigin = textView.textContainerOrigin
            let containerPoint = NSPoint(
                x: point.x - containerOrigin.x,
                y: point.y - containerOrigin.y
            )

            let location = layoutManager.characterIndex(
                for: containerPoint,
                in: textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )

            return lineIndex(forCharacterLocation: location, in: text)
        }

        private static func lineIndex(forCharacterLocation location: Int, in text: NSString) -> Int {
            guard text.length > 0 else { return 0 }

            let clampedLocation = max(0, min(location, text.length - 1))
            var line = 0
            var scanLocation = 0

            while scanLocation < text.length {
                let range = text.lineRange(for: NSRange(location: scanLocation, length: 0))
                if clampedLocation < NSMaxRange(range) {
                    return line
                }
                line += 1
                scanLocation = NSMaxRange(range)
            }

            return max(0, line - 1)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView {
            return scroll
        }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func locateScrollView(near view: NSView) -> NSScrollView? {
        if let enclosing = view.enclosingScrollView {
            return enclosing
        }

        if let found = firstScrollView(in: view) {
            return found
        }

        var current: NSView? = view.superview
        while let node = current {
            if let scroll = node as? NSScrollView {
                return scroll
            }

            current = node.superview
        }

        return nil
    }

    private func applyScrollBarStyle(to scroll: NSScrollView, context: Context) {
        scroll.hasVerticalScroller = showsVerticalScroller
        scroll.hasHorizontalScroller = false
        if showsVerticalScroller {
            // Keep the play-mode scrollbar persistently visible.
            scroll.autohidesScrollers = false
            scroll.scrollerStyle = .legacy
            scroll.verticalScroller?.isEnabled = true
            scroll.verticalScroller?.isHidden = false
            scroll.verticalScroller?.alphaValue = 1.0
            scroll.flashScrollers()
        } else {
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.verticalScroller?.isEnabled = false
            scroll.verticalScroller?.isHidden = true
        }
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(
            top: topInset,
            left: 0,
            bottom: bottomInset,
            right: rightInset
        )
        scroll.verticalScroller?.controlSize = .mini
        scroll.verticalScroller?.knobStyle = useDarkKnob ? .dark : .light

        if let textView = scroll.documentView as? NSTextView {
            // Keep the caret origin aligned with the placeholder even when the
            // document is empty by using container inset for horizontal offset.
            textView.textContainerInset = NSSize(width: textLeadingInset, height: textTopInset)
            textView.textContainer?.lineFragmentPadding = 0
            textView.isEditable = isEditable
            textView.isSelectable = isEditable

            if isEditable {
                textView.insertionPointColor = .controlTextColor
            } else {
                textView.insertionPointColor = .clear
                textView.selectedRanges = [NSValue(range: NSRange(location: 0, length: 0))]
                if let window = textView.window, window.firstResponder === textView {
                    window.makeFirstResponder(nil)
                }
            }

            context.coordinator.updateInteraction(for: textView, onLineTapped: onLineTapped)
            applyLineHighlight(to: textView)
        }
    }

    private func lineRange(for lineIndex: Int, in text: NSString) -> NSRange? {
        guard lineIndex >= 0 else { return nil }
        if text.length == 0 {
            return lineIndex == 0 ? NSRange(location: 0, length: 0) : nil
        }

        var currentLine = 0
        var scanLocation = 0

        while scanLocation < text.length {
            let range = text.lineRange(for: NSRange(location: scanLocation, length: 0))
            if currentLine == lineIndex {
                return range
            }
            currentLine += 1
            scanLocation = NSMaxRange(range)
        }

        return nil
    }

    private func applyLineHighlight(to textView: NSTextView) {
        let content = textView.string as NSString
        if content.length > 0 {
            let fullRange = NSRange(location: 0, length: content.length)
            textView.textStorage?.removeAttribute(.backgroundColor, range: fullRange)
            textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        }

        textView.wantsLayer = true
        textView.layer?.sublayers?
            .filter { $0.name == activeLineLayerName }
            .forEach { $0.removeFromSuperlayer() }

        guard let lineIndex = highlightedLineIndex,
              highlightOpacity > 0,
              let targetRange = lineRange(for: lineIndex, in: content),
              targetRange.length > 0 else {
            return
        }

        let highlightColor = NSColor.systemGreen.withAlphaComponent(0.35)
        textView.textStorage?.addAttribute(.backgroundColor, value: highlightColor, range: targetRange)
        textView.layoutManager?.addTemporaryAttribute(.backgroundColor, value: highlightColor, forCharacterRange: targetRange)

        textView.scrollRangeToVisible(targetRange)
        textView.needsDisplay = true
    }
    
    private func clearLineHighlight(in textView: NSTextView) {
        let content = textView.string as NSString
        if content.length > 0 {
            let fullRange = NSRange(location: 0, length: content.length)
            textView.textStorage?.removeAttribute(.backgroundColor, range: fullRange)
            textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        }

        textView.layer?.sublayers?
            .filter { $0.name == activeLineLayerName }
            .forEach { $0.removeFromSuperlayer() }
    }

    private func applyOrClearHighlight(on textView: NSTextView) {
        if highlightedLineIndex == nil || highlightOpacity <= 0 {
            clearLineHighlight(in: textView)
        } else {
            applyLineHighlight(to: textView)
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        func applyStyle(attempt: Int) {
            guard let scroll = locateScrollView(near: nsView) else {
                if attempt < 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        applyStyle(attempt: attempt + 1)
                    }
                }
                return
            }

            applyScrollBarStyle(to: scroll, context: context)
            if let textView = scroll.documentView as? NSTextView {
                applyOrClearHighlight(on: textView)
            }
        }

        DispatchQueue.main.async {
            applyStyle(attempt: 0)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                applyStyle(attempt: 0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                applyStyle(attempt: 0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                applyStyle(attempt: 0)
            }
        }
    }
}

final class StyleCaptureRecorder: NSObject, ObservableObject {
    @Published var isRecording: Bool = false
    @Published var transcript: String = ""
    @Published var lastNonEmptyTranscript: String = ""
    @Published var secondsRemaining: Int = 30
    @Published var errorMessage: String = ""

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var timer: Timer?

    func startCapture(duration: Int = 30) {
        stopCapture()
        errorMessage = ""
        transcript = ""
        lastNonEmptyTranscript = ""
        secondsRemaining = duration

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] micGranted in
            guard let self else { return }
            guard micGranted else {
                DispatchQueue.main.async { self.errorMessage = "Microphone permission is required for style capture." }
                return
            }

            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    guard status == .authorized else {
                        self.errorMessage = "Speech recognition permission is required for style capture."
                        return
                    }
                    self.beginRecognition(duration: duration)
                }
            }
        }
    }

    private func beginRecognition(duration: Int) {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognizer is unavailable right now."
            return
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else {
            errorMessage = "Unable to create speech request."
            return
        }

        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            errorMessage = "Could not start audio engine: \(error.localizedDescription)"
            return
        }

        isRecording = true
        secondsRemaining = duration

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                DispatchQueue.main.async {
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.transcript = text
                    if !text.isEmpty {
                        self.lastNonEmptyTranscript = text
                    }
                }
            }
            if let error {
                DispatchQueue.main.async {
                    if self.isBenignCancelError(error) {
                        return
                    }
                    self.errorMessage = "Recognition error: \(error.localizedDescription)"
                    self.stopCapture()
                }
            }
        }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { return }
            if self.secondsRemaining > 0 {
                self.secondsRemaining -= 1
            } else {
                t.invalidate()
                self.stopCapture()
            }
        }
    }

    func stopCapture() {
        timer?.invalidate()
        timer = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false
    }

    private func isBenignCancelError(_ error: Error) -> Bool {
        let ns = error as NSError
        let msg = ns.localizedDescription.lowercased()
        if msg.contains("canceled") || msg.contains("cancelled") {
            return true
        }
        if ns.domain.contains("AFAssistant") && ns.code == 216 {
            return true
        }
        return false
    }
}

struct ContentView: View {

    @StateObject private var store = ScriptStore()
    @ObservedObject var speechManager: SpeechManager
    @ObservedObject var overlayController: OverlayWindowController

    @State private var selectedID: UUID? = nil
    @State private var editingScript: SnotchScript? = nil
    @State private var showSidebar: Bool = true
    @State private var fontSize: Double = 18
    @State private var renamingID: UUID? = nil
    @State private var renameText: String = ""
    @State private var searchQuery: String = ""
    @State private var draggedScriptID: UUID? = nil
    @State private var dropInsertionIndex: Int? = nil
    @State private var isImporting: Bool = false
    @State private var showGenerator: Bool = false
    @State private var showSettingsPanel: Bool = false
    @State private var stickyNoteWindowControllers: [UUID: StickyNoteWindowController] = [:]
    @State private var isFileDropTargeted: Bool = false
    @State private var generatorTopic: String = ""
    @State private var generatorAudience: String = ""
    @State private var generatorTone: String = "Conversational"
    @State private var generatorGoal: String = "Educate"
    @State private var generatorSetLength: Bool = false
    @State private var generatorLengthMinutes: Double = 1.0
    @State private var generatorLengthCustom: String = "1.0"
    @State private var generatorUseCues: Bool = true
    @State private var generatorEnableStyleMatch: Bool = false
    @State private var generatorStyleProfileText: String = ""
    @State private var generatorIsLoading: Bool = false
    @State private var generatorErrorMessage: String = ""
    @FocusState private var editorBodyFocused: Bool
    @StateObject private var styleRecorder = StyleCaptureRecorder()
    @AppStorage("snotch.pillLight") private var pillLight: Bool = false
    @AppStorage("snotch.onboardingDone") private var onboardingDone: Bool = true

    var body: some View {
        ZStack {
            VisualEffectBackground()
                .ignoresSafeArea()

            // Smooth gradient veil — tames raw wallpaper colors, keeps glass depth
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
            .animation(.easeInOut(duration: 0.35), value: pillLight)

            HStack(spacing: 0) {
                if showSidebar {
                    sidebarView
                        .frame(width: 218)
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    Rectangle()
                        .fill(Color(white: pillLight ? 0 : 1, opacity: 0.07))
                        .frame(width: 0.5)
                        .transition(.opacity)
                }

                ZStack(alignment: .top) {
                    if editingScript != nil {
                        editorArea
                    } else {
                        emptyState
                    }
                    editorToolbar
                        .padding(.top, 14)
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: showSidebar)

            if isFileDropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(white: pillLight ? 0.12 : 0.90, opacity: 0.75), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                    .padding(16)
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "doc.text.fill")
                                .font(.system(size: 18, weight: .semibold))
                            Text("Drop a .txt script to import")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(Color(white: pillLight ? 0.12 : 0.88))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(white: pillLight ? 1.0 : 0.06, opacity: 0.84))
                        )
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if showSettingsPanel {
                settingsPanelOverlay
            }
        }
        .preferredColorScheme(pillLight ? .light : .dark)
        .onAppear {
            normalizeStoredScriptsOnLaunch()
            UserDefaults.standard.removeObject(forKey: "snotch.recents")
            if editingScript == nil, let first = store.scripts.first { select(first) }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [
                .plainText,
                UTType(filenameExtension: "md") ?? .plainText,
                UTType(filenameExtension: "docx") ?? .data,
                .pdf
            ],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .sheet(isPresented: $showGenerator) {
            ScriptGeneratorSheet(
                topic: $generatorTopic,
                audience: $generatorAudience,
                tone: $generatorTone,
                goal: $generatorGoal,
                setLength: $generatorSetLength,
                lengthMinutes: $generatorLengthMinutes,
                lengthCustom: $generatorLengthCustom,
                useCues: $generatorUseCues,
                enableStyleMatch: $generatorEnableStyleMatch,
                styleProfileText: $generatorStyleProfileText,
                styleRecorder: styleRecorder,
                isGenerating: $generatorIsLoading,
                errorMessage: $generatorErrorMessage,
                onGenerate: { await applyGeneratedScriptWithGPT() },
                onRequestPracticeTopic: { await requestStyleCaptureTopic() }
            )
            .frame(width: 520)
        }
        .background(hotKeyHandler)
        .onDrop(of: [UTType.fileURL], isTargeted: $isFileDropTargeted) { providers in
            handleDroppedFiles(providers)
        }
        .onChange(of: draggedScriptID) { _, dragged in
            if dragged == nil {
                dropInsertionIndex = nil
            }
        }
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Scripts")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(white: pillLight ? 0.38 : 0.42))
                Spacer()
                Menu {
                    Button("New Script") { let s = store.addScript(); select(s) }
                    Button("Import...") { isImporting = true }
                    Divider()
                    Button("Export TXT") { exportCurrentScript(as: .txt) }
                    Button("Export Markdown") { exportCurrentScript(as: .markdown) }
                    Button("Export PDF") { exportCurrentScript(as: .pdf) }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(white: pillLight ? 0.35 : 0.50))
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color(white: pillLight ? 0 : 1, opacity: 0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(Color(white: pillLight ? 0 : 1, opacity: 0.10), lineWidth: 0.5)
                                )
                        )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 8)

            TextField("Search scripts", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(Color(white: pillLight ? 0.18 : 0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(white: pillLight ? 0 : 1, opacity: 0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color(white: pillLight ? 0 : 1, opacity: 0.10), lineWidth: 0.5)
                        )
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    if filteredScripts.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 16, weight: .regular))
                                .foregroundColor(Color(white: pillLight ? 0.36 : 0.62))
                            Text("No scripts found")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(white: pillLight ? 0.34 : 0.60))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 26)
                    } else {
                        ForEach(Array(filteredScripts.enumerated()), id: \.element.id) { index, script in
                            if draggedScriptID != nil && dropInsertionIndex == index {
                                sidebarDropPlaceholder
                                    .transition(.opacity)
                            }

                            SidebarRow(
                                script: script,
                                isSelected: selectedID == script.id,
                                isRenaming: renamingID == script.id,
                                renameText: $renameText,
                                onRenameCommit: {
                                    var updated = script
                                    updated.title = renameText.trimmingCharacters(in: .whitespaces).isEmpty
                                        ? script.title : renameText.trimmingCharacters(in: .whitespaces)
                                    store.update(updated)
                                    if editingScript?.id == script.id { editingScript = updated }
                                    renamingID = nil
                                },
                                onRenameCancel: { renamingID = nil },
                                onRename: { renameText = script.title; renamingID = script.id },
                                onExportTXT: { exportScript(script, as: .txt) },
                                onExportMarkdown: { exportScript(script, as: .markdown) },
                                onExportPDF: { exportScript(script, as: .pdf) },
                                onDelete: {
                                    store.delete(at: IndexSet([store.scripts.firstIndex(where: { $0.id == script.id })!]))
                                    if selectedID == script.id {
                                        if let next = filteredScripts.first { select(next) }
                                        else { selectedID = nil; editingScript = nil }
                                    }
                                }
                            )
                            .onTapGesture { select(script) }
                            .onDrag {
                                draggedScriptID = script.id
                                dropInsertionIndex = index
                                return NSItemProvider(object: script.id.uuidString as NSString)
                            }
                            .onDrop(
                                of: [.text],
                                delegate: ScriptSidebarDropDelegate(
                                    targetIndex: index,
                                    maxIndex: filteredScripts.count,
                                    draggedID: $draggedScriptID,
                                    insertionIndex: $dropInsertionIndex,
                                    onDropAtIndex: moveScript
                                )
                            )
                        }

                        if draggedScriptID != nil && dropInsertionIndex == filteredScripts.count {
                            sidebarDropPlaceholder
                                .transition(.opacity)
                        }

                        Color.clear
                            .frame(height: 18)
                            .contentShape(Rectangle())
                            .onDrop(
                                of: [.text],
                                delegate: ScriptSidebarDropDelegate(
                                    targetIndex: filteredScripts.count,
                                    maxIndex: filteredScripts.count,
                                    draggedID: $draggedScriptID,
                                    insertionIndex: $dropInsertionIndex,
                                    onDropAtIndex: moveScript
                                )
                            )
                    }
                }
                .animation(.easeInOut(duration: 0.12), value: dropInsertionIndex)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            Spacer(minLength: 0)

            // Shortcuts footer
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color(white: pillLight ? 0 : 1, opacity: 0.06))
                    .frame(height: 0.5)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Shortcuts")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(white: pillLight ? 0.38 : 0.40))
                    shortcutRow(keys: ["⌘", "P"],         label: "Play / Stop")
                    shortcutRow(keys: ["⇧", "↑", "/", "↓"], label: "Scroll line")
                    shortcutRow(keys: ["⌘", "["],           label: "Toggle sidebar")
                    shortcutRow(keys: ["Esc"],              label: "Close app")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .background {
                LinearGradient(
                    stops: pillLight ? [
                        .init(color: Color(white: 0, opacity: 0.00), location: 0),
                        .init(color: Color(white: 0, opacity: 0.06), location: 1)
                    ] : [
                        .init(color: Color(white: 0, opacity: 0.08), location: 0),
                        .init(color: Color(white: 0, opacity: 0.28), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    private func shortcutRow(keys: [String], label: String) -> some View {
        HStack(spacing: 7) {
            HStack(spacing: 3) {
                ForEach(Array(keys.enumerated()), id: \.offset) { i, key in
                    if key == "/" {
                        Text("/")
                            .font(.system(size: 9, weight: .light))
                            .foregroundColor(Color(white: 0.28))
                    } else {
                        Text(key)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(white: 0.55))
                            .frame(minWidth: 18, minHeight: 16)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color(white: pillLight ? 0 : 1, opacity: 0.07))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .strokeBorder(Color(white: pillLight ? 0 : 1, opacity: 0.10), lineWidth: 0.5)
                                    )
                            )
                    }
                }
            }
            Text(label)
                .font(.system(size: 10.5))
                .foregroundColor(Color(white: 0.33))
            Spacer()
        }
    }

    private func resetSetup() {
        if speechManager.isListening {
            speechManager.stopListening()
        }

        overlayController.hide()

        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        } else {
            [
                "snotch.scripts",
                "snotch.onboardingDone",
                "snotch.pillLight",
                "snotch.continuousNotchScroll",
                "snotch.reading.scrollSpeed",
                "snotch.reading.scrollSpeed.highlighted",
                "snotch.reading.scrollSpeed.continuous",
                "snotch.audio.noiseGate",
                "snotch.audio.inputGain",
                "snotch.recents"
            ].forEach {
                UserDefaults.standard.removeObject(forKey: $0)
            }
        }

        onboardingDone = false
        UserDefaults.standard.synchronize()
    }

    // MARK: - Editor

    private var editorArea: some View {
        GeometryReader { geo in
            let hPad = max(52.0, (geo.size.width - 680.0) / 2.0 + 52.0)
            let editorColumnWidth = max(340.0, geo.size.width - (hPad * 2.0))
            let editorScrollBottomGap: CGFloat = 56
            let editorTextStartInset: CGFloat = 8
            let editorLineVerticalPadding: CGFloat = 4
            let editorRowSpacing: CGFloat = 10
            let editorLineSpacing: CGFloat = editorRowSpacing + (editorLineVerticalPadding * 2)
            VStack(alignment: .leading, spacing: 0) {
                // Large document title
                TextField("Untitled", text: Binding(
                    get: { editingScript?.title ?? "" },
                    set: { newValue in
                        editingScript?.title = newValue
                        if let s = editingScript { store.update(s) }
                    }
                ))
                .font(.system(size: 44, weight: .light))
                .foregroundColor(Color(white: pillLight ? 0.06 : 0.94))
                .textFieldStyle(.plain)
                .padding(.horizontal, hPad)
                .padding(.top, 90)
                .padding(.bottom, 20)

                if let body = editingScript?.body {
                    directiveChips(from: body)
                        .padding(.horizontal, hPad)
                        .padding(.bottom, 10)
                }

                let isPlaying = speechManager.isListening || speechManager.isCountingDown
                let editorTextBinding = Binding<String>(
                    get: {
                        if isPlaying {
                            return speechManager.scriptLines.joined(separator: "\n")
                        }
                        return scriptBodyBinding.wrappedValue
                    },
                    set: { newValue in
                        guard !isPlaying else { return }
                        scriptBodyBinding.wrappedValue = newValue
                    }
                )
                ZStack(alignment: .topLeading) {
                    TextEditor(text: editorTextBinding)
                        .font(.system(size: fontSize, weight: .light))
                        .lineSpacing(editorLineSpacing)
                        .foregroundColor(Color(white: pillLight ? 0.10 : 0.88))
                        .scrollContentBackground(.hidden)
                        .snotchTextSelection(enabled: !isPlaying)
                        .focused($editorBodyFocused)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(
                            EditorScrollBarStyler(
                                topInset: 6,
                                bottomInset: editorScrollBottomGap,
                                rightInset: 28,
                                useDarkKnob: pillLight,
                                showsVerticalScroller: false,
                                textTopInset: editorLineVerticalPadding,
                                textLeadingInset: editorTextStartInset,
                                isEditable: !isPlaying,
                                highlightedLineIndex: isPlaying
                                    ? min(max(0, speechManager.currentLineIndex), max(0, speechManager.scriptLines.count - 1))
                                    : nil,
                                highlightOpacity: isPlaying ? 0.12 : 0,
                                onLineTapped: isPlaying
                                    ? { tappedLine in
                                        speechManager.jumpToLine(tappedLine)
                                    }
                                    : nil
                            )
                            .id("editor-highlight-\(isPlaying ? 1 : 0)-\(speechManager.currentLineIndex)-\(speechManager.scriptLines.count)")
                        )
                        .onChange(of: isPlaying) { playing in
                            if playing {
                                editorBodyFocused = false
                                DispatchQueue.main.async {
                                    NSApp.keyWindow?.makeFirstResponder(nil)
                                    NSApp.mainWindow?.makeFirstResponder(nil)
                                }
                            }
                        }

                    if !isPlaying,
                       (editingScript?.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Type your script here...")
                            .font(.system(size: fontSize, weight: .light))
                            .foregroundColor(Color(white: pillLight ? 0.35 : 0.46))
                            .padding(.leading, editorTextStartInset)
                            .padding(.top, max(0, editorLineVerticalPadding - 2))
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 6)
                .padding(.bottom, 48)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isPlaying {
                        editorBodyFocused = true
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .frame(width: editorColumnWidth)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, editorScrollBottomGap)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Top and bottom fade-out mask so text drifts in/out of view softly
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 44)
                    Color.black
                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 64)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let body = editingScript?.body,
               !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(scriptDuration)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(white: pillLight ? 0.24 : 0.94))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color(white: pillLight ? 0 : 1, opacity: 0.07))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(Color(white: pillLight ? 0 : 1, opacity: 0.10), lineWidth: 0.5)
                            )
                    )
                    .padding(.trailing, 18)
                    .padding(.bottom, 18)
            }
        }
    }

    private var editorToolbar: some View {
        HStack(spacing: 10) {
            // Font size control
            LabeledStepper(
                icon: "textformat.size",
                label: "Size",
                value: "\(Int(fontSize))pt",
                canDecrement: fontSize > 12,
                canIncrement: fontSize < 32,
                onDecrement: { fontSize = max(12, fontSize - 2) },
                onIncrement: { fontSize = min(32, fontSize + 2) }
            )

            // Divider
            Rectangle()
                .fill(Color(white: pillLight ? 0 : 1, opacity: 0.10))
                .frame(width: 0.5, height: 18)

            // Scroll speed slider
            HStack(spacing: 6) {
                Image(systemName: "tortoise.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color(white: 0.40))
                Slider(value: $speechManager.scrollSpeed, in: 0.5...3.0, step: 0.25)
                    .frame(width: 80)
                    .tint(Color(white: 0.55))
                Image(systemName: "hare.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color(white: 0.40))
                Text(String(format: "%.2g×", speechManager.scrollSpeed))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(white: 0.50))
                    .frame(minWidth: 28)
            }

            Menu {
                Button {
                    createStickyNote()
                } label: {
                    Label("New Note", systemImage: "plus")
                }

                if let script = editingScript, !script.stickyNotes.isEmpty {
                    Divider()
                    ForEach(Array(script.stickyNotes.enumerated()), id: \.element.id) { index, note in
                        Button {
                            openStickyNoteWindow(noteID: note.id)
                        } label: {
                            Label("Note \(index + 1)", systemImage: "note.text")
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "note.text.badge.plus")
                        .font(.system(size: 10.5, weight: .semibold))

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(Color(white: pillLight ? 0.12 : 0.90))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(white: pillLight ? 0 : 1, opacity: 0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color(white: pillLight ? 0 : 1, opacity: 0.16), lineWidth: 0.6)
                        )
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Sticky notes")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSettingsPanel = true
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(Color(white: pillLight ? 0.12 : 0.90))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Open settings")

            // Divider
            Rectangle()
                .fill(Color(white: pillLight ? 0 : 1, opacity: 0.10))
                .frame(width: 0.5, height: 18)

            Button {
                if editingScript == nil {
                    let s = store.addScript()
                    select(s)
                }
                if generatorTopic.isEmpty {
                    generatorTopic = editingScript?.title == "Get Started" ? "Your topic" : (editingScript?.title ?? "Your topic")
                }
                showGenerator = true
            } label: {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(white: pillLight ? 0.20 : 0.78))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)

            // Play / Stop
            Button {
                if let s = editingScript {
                    speechManager.setActiveScript(id: s.id)
                }
                speechManager.loadScript(editingScript?.body ?? "")
                if !overlayController.isVisible { overlayController.show() }
                speechManager.toggleListening()
            } label: {
                ZStack {
                    let idleGreen = pillLight
                        ? Color(red: 0.84, green: 0.93, blue: 0.87).opacity(0.95)
                        : Color(red: 0.05, green: 0.42, blue: 0.21).opacity(0.90)
                    let activeRed = pillLight
                        ? Color(red: 0.95, green: 0.87, blue: 0.89).opacity(0.95)
                        : Color(red: 0.34, green: 0.08, blue: 0.10).opacity(0.78)

                    Circle()
                        .fill(speechManager.isListening
                              ? activeRed
                              : idleGreen)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle()
                                .strokeBorder(Color(white: pillLight ? 0 : 1, opacity: 0.14), lineWidth: 0.5)
                        )
                    Image(systemName: speechManager.isListening ? "stop.fill" : "play.fill")
                        .font(.system(size: speechManager.isListening ? 9 : 10, weight: .bold))
                        .foregroundColor(Color(white: pillLight ? 0.14 : 0.94))
                        .offset(x: speechManager.isListening ? 0 : 1)
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("p", modifiers: .command)
            .animation(.easeInOut(duration: 0.18), value: speechManager.isListening)

            // Overlay toggle
            Button { overlayController.toggle() } label: {
                Image(systemName: overlayController.isVisible ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 11))
                    .foregroundColor(overlayController.isVisible
                        ? Color(white: pillLight ? 0.15 : 0.80)
                        : Color(white: pillLight ? 0.45 : 0.38))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background {
            ZStack {
                // Frosted glass base
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(white: pillLight ? 1 : 0.11,
                                opacity: pillLight ? 0.72 : 0.68))
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                // Subtle border
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color(white: pillLight ? 0 : 1, opacity: 0.12), lineWidth: 0.5)
            }
        }
        .shadow(color: Color.black.opacity(pillLight ? 0.10 : 0.40), radius: 20, x: 0, y: 6)
        .shadow(color: Color.black.opacity(pillLight ? 0.05 : 0.20), radius: 4,  x: 0, y: 1)
    }

    private var darkModeBinding: Binding<Bool> {
        Binding(
            get: { !pillLight },
            set: { isDarkMode in
                pillLight = !isDarkMode
            }
        )
    }

    private var settingsPanelOverlay: some View {
        ZStack {
            Color.black
                .opacity(pillLight ? 0.16 : 0.42)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSettingsPanel = false
                    }
                }

            AppSettingsPanel(
                speechManager: speechManager,
                overlayController: overlayController,
                darkMode: darkModeBinding,
                pillLight: pillLight,
                onResetSetup: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSettingsPanel = false
                    }
                    resetSetup()
                },
                onClose: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSettingsPanel = false
                    }
                }
            )
            .padding(.horizontal, 24)
            .frame(maxWidth: 560)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        .zIndex(20)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundColor(Color(white: 0.22))
            VStack(spacing: 7) {
                Text("No script open")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(white: 0.52))
                Text("Select from the sidebar or create a new script.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.28))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 240)
            }
            Button { let s = store.addScript(); select(s) } label: {
                Text("New Script")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(white: pillLight ? 0.15 : 0.82))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(white: pillLight ? 0 : 1, opacity: 0.09))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color(white: pillLight ? 0 : 1, opacity: 0.13), lineWidth: 0.5)
                            )
                    )
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scriptDuration: String {
        let words = (editingScript?.body ?? "")
            .split(whereSeparator: \.isWhitespace).count
        guard words > 0 else { return "" }
        // Average teleprompter pace ~130 WPM, scaled by scroll speed
        let wpm = 192.0 * Double(speechManager.scrollSpeed)
        let totalSeconds = Int(Double(words) / wpm * 60)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        if m == 0 { return "~\(s)s" }
        if s == 0 { return "~\(m) min" }
        return "~\(m):\(String(format: "%02d", s))"
    }

    private func createStickyNote() {
        guard var script = editingScript else {
            NSSound.beep()
            return
        }

        let newNote = StickyNoteData(text: "", pinned: false)
        script.stickyNotes.append(newNote)
        script.lastEdited = Date()
        store.update(script)
        editingScript = script

        openStickyNoteWindow(noteID: newNote.id)
    }

    private func openStickyNoteWindow(noteID: UUID) {
        guard let script = editingScript,
              let noteIndex = script.stickyNotes.firstIndex(where: { $0.id == noteID }) else {
            NSSound.beep()
            return
        }

        let note = script.stickyNotes[noteIndex]

        if stickyNoteWindowControllers[noteID] == nil {
            stickyNoteWindowControllers[noteID] = StickyNoteWindowController()
        }

        stickyNoteWindowControllers[noteID]?.present(
            scriptTitle: script.title,
            noteNumber: noteIndex + 1,
            initialText: note.text,
            initialPinned: note.pinned,
            onChange: { text, pinned in
                updateStickyNote(noteID: noteID, text: text, pinned: pinned)
            },
            onDelete: {
                deleteStickyNote(noteID: noteID)
            }
        )
    }

    private func updateStickyNote(noteID: UUID, text: String? = nil, pinned: Bool? = nil) {
        guard let scriptID = editingScript?.id,
              let scriptIndex = store.scripts.firstIndex(where: { $0.id == scriptID }),
              let noteIndex = store.scripts[scriptIndex].stickyNotes.firstIndex(where: { $0.id == noteID }) else {
            return
        }

        var script = store.scripts[scriptIndex]
        if let text {
            script.stickyNotes[noteIndex].text = text
        }
        if let pinned {
            script.stickyNotes[noteIndex].pinned = pinned
        }
        script.lastEdited = Date()
        store.update(script)

        if editingScript?.id == scriptID {
            editingScript = script
        }
    }

    private func deleteStickyNote(noteID: UUID) {
        guard let scriptID = editingScript?.id,
              let scriptIndex = store.scripts.firstIndex(where: { $0.id == scriptID }) else {
            return
        }

        var script = store.scripts[scriptIndex]
        let originalCount = script.stickyNotes.count
        script.stickyNotes.removeAll(where: { $0.id == noteID })
        guard script.stickyNotes.count != originalCount else { return }

        script.lastEdited = Date()
        store.update(script)
        if editingScript?.id == scriptID {
            editingScript = script
        }

        stickyNoteWindowControllers[noteID]?.close()
        stickyNoteWindowControllers.removeValue(forKey: noteID)
    }

    private func directiveChips(from body: String) -> some View {
        let base = ["<break>", "<slow>", "<fast>", "<focus>"]
            .filter { body.localizedCaseInsensitiveContains($0) }
        let hasHold = body.range(of: #"<hold\s+\d+(?:\.\d+)?s>"#, options: .regularExpression) != nil
        let tokens = hasHold ? (base + ["<hold Ns>"]) : base

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tokens, id: \.self) { token in
                    Text(token)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(white: pillLight ? 0.28 : 0.66))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(white: pillLight ? 0 : 1, opacity: 0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color(white: pillLight ? 0 : 1, opacity: 0.10), lineWidth: 0.5)
                                )
                        )
                }
            }
        }
        .frame(height: tokens.isEmpty ? 0 : 24)
        .opacity(tokens.isEmpty ? 0 : 1)
    }

    private var filteredScripts: [SnotchScript] {
        store.scripts.filter { script in
            let matchesSearch = searchQuery.isEmpty
                || script.title.localizedCaseInsensitiveContains(searchQuery)
                || script.body.localizedCaseInsensitiveContains(searchQuery)
            return matchesSearch
        }
    }

    private var sidebarDropPlaceholder: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color(white: pillLight ? 0.25 : 0.85, opacity: 0.55))
            .frame(height: 6)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color(white: pillLight ? 0.05 : 1.0, opacity: 0.40), lineWidth: 0.5)
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
    }

    private func moveScript(_ draggedID: UUID, toFilteredInsertionIndex insertionIndex: Int) {
        guard let fromIndex = store.scripts.firstIndex(where: { $0.id == draggedID }),
              let fromVisibleIndex = filteredScripts.firstIndex(where: { $0.id == draggedID }) else {
            return
        }

        var adjustedInsertion = insertionIndex
        if fromVisibleIndex < insertionIndex {
            adjustedInsertion -= 1
        }

        let visibleOrder = filteredScripts
            .map(\.id)
            .filter { $0 != draggedID }
        let clampedIndex = max(0, min(adjustedInsertion, visibleOrder.count))
        let anchorID = clampedIndex < visibleOrder.count ? visibleOrder[clampedIndex] : nil

        withAnimation(.easeInOut(duration: 0.14)) {
            let moved = store.scripts.remove(at: fromIndex)
            if let anchorID,
               let targetIndex = store.scripts.firstIndex(where: { $0.id == anchorID }) {
                store.scripts.insert(moved, at: targetIndex)
            } else {
                store.scripts.append(moved)
            }
        }

        store.save()
    }

    private var scriptBodyBinding: Binding<String> {
        Binding(
            get: { editingScript?.body ?? "" },
            set: { newValue in
                guard var script = editingScript else { return }
                let normalized = normalizeEditorInput(previous: script.body, incoming: newValue)
                guard normalized != script.body else { return }
                script.body = normalized
                script.lastEdited = Date()
                editingScript = script
                store.update(script)
                speechManager.loadScript(normalized)
            }
        )
    }

    private func updateScriptLine(at index: Int, with newValue: String) {
        guard var script = editingScript else { return }
        var lines = speechManager.scriptLines
        guard lines.indices.contains(index) else { return }
        lines[index] = newValue
        let merged = lines.joined(separator: "\n")
        let normalized = normalizeEditorInput(previous: script.body, incoming: merged)
        script.body = normalized
        script.lastEdited = Date()
        editingScript = script
        store.update(script)
        speechManager.loadScript(normalized)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        _ = importScript(from: url)
    }

    private func handleDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let url = decodeDroppedFileURL(from: item) else { return }
            DispatchQueue.main.async {
                _ = importScript(from: url)
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

    @discardableResult
    private func importScript(from url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ["txt", "md", "pdf", "docx"].contains(ext) else {
            NSSound.beep()
            return false
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let content = importedText(from: url) else {
            NSSound.beep()
            return false
        }

        let cleaned = cleanImportedText(content)
        var script = store.addScript()
        script.title = url.deletingPathExtension().lastPathComponent
        script.body = cleaned
        script.lastEdited = Date()
        store.update(script)
        select(script)
        return true
    }

    private func importedText(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "txt" || ext == "md" {
            if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
                return utf8
            }
            if let unicode = try? String(contentsOf: url, encoding: .unicode) {
                return unicode
            }
            return try? String(contentsOf: url, encoding: .ascii)
        }
        if ext == "pdf", let doc = PDFDocument(url: url) {
            var text = ""
            for i in 0..<doc.pageCount {
                text += (doc.page(at: i)?.string ?? "") + "\n"
            }
            return text
        }
        if ext == "docx" {
            return extractDOCXText(url: url)
        }
        return nil
    }

    private func extractDOCXText(url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "word/document.xml"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard var xml = String(data: data, encoding: .utf8) else { return nil }
            xml = xml.replacingOccurrences(of: "</w:p>", with: "\n")
            xml = xml.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            return xml
        } catch {
            return nil
        }
    }

    private func cleanImportedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "[ ]{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum ExportKind { case txt, markdown, pdf }

    private func exportCurrentScript(as kind: ExportKind) {
        guard let script = editingScript else { return }
        exportScript(script, as: kind)
    }

    private func exportScript(_ script: SnotchScript, as kind: ExportKind) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = script.title.replacingOccurrences(of: "/", with: "-")
        switch kind {
        case .txt:
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue += ".txt"
        case .markdown:
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue += ".md"
        case .pdf:
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue += ".pdf"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch kind {
            case .txt:
                let payload = "\(script.title)\n\n\(script.body)"
                try payload.write(to: url, atomically: true, encoding: .utf8)
            case .markdown:
                let payload = "# \(script.title)\n\n\(script.body)"
                try payload.write(to: url, atomically: true, encoding: .utf8)
            case .pdf:
                let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 1024))
                view.string = "\(script.title)\n\n\(script.body)"
                view.font = NSFont.systemFont(ofSize: 15)
                let pdf = view.dataWithPDF(inside: view.bounds)
                try pdf.write(to: url)
            }
        } catch {
            NSSound.beep()
        }
    }

    private func normalizeEditorInput(previous: String, incoming: String) -> String {
        let delta = incoming.count - previous.count
        var out = incoming

        // Preserve explicit Enter key presses as-is so manual line breaks
        // are never swallowed by auto-reflow.
        if delta == 1,
           incoming.hasPrefix(previous),
           incoming.last == "\n" {
            return incoming
        }

        // Large insertions are usually paste/import content.
        if delta > 20 {
            out = out.replacingOccurrences(of: #"^\s*[-*]\s+"#, with: "", options: .regularExpression)
            out = out.replacingOccurrences(of: #"^\s*\d+[.)]\s+"#, with: "", options: .regularExpression)
            out = out.replacingOccurrences(of: #"\*\*(.*?)\*\*"#, with: "$1", options: .regularExpression)
            out = out.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
            out = out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            return formatScriptForNotch(out, maxChars: 48)
        }

        // Keep normal typing stable (including spaces) and avoid reflowing while
        // the caret is moving. Reflow is handled for large paste/import content.

        // Keep explicit newlines tidy if user manually inserts big spacing.
        out = out.replacingOccurrences(of: #"\n{4,}"#, with: "\n\n\n", options: .regularExpression)
        return out
    }

    private func formatScriptForNotch(_ text: String, maxChars: Int) -> String {
        let paragraphs = text
            .components(separatedBy: #"\n\s*\n"#)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !paragraphs.isEmpty else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let wrappedParagraphs = paragraphs.map { wrapParagraphForNotch($0, maxChars: maxChars) }
        return wrappedParagraphs.joined(separator: "\n\n")
    }

    private func wrapParagraphForNotch(_ paragraph: String, maxChars: Int) -> String {
        let compact = paragraph
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return "" }

        let hardMax = max(maxChars + 14, 58)
        var lines: [String] = []
        var rest = compact

        while rest.count > hardMax {
            let splitIndex = bestSplitIndex(in: rest, preferredMax: maxChars, hardMax: hardMax)
            let cut = rest[..<splitIndex].trimmingCharacters(in: .whitespaces)
            if !cut.isEmpty { lines.append(String(cut)) }
            rest = String(rest[splitIndex...]).trimmingCharacters(in: .whitespaces)
        }

        if !rest.isEmpty { lines.append(rest) }

        return lines.joined(separator: "\n")
    }

    private func bestSplitIndex(in text: String, preferredMax: Int, hardMax: Int) -> String.Index {
        let limit = min(hardMax, text.count)
        let windowEnd = text.index(text.startIndex, offsetBy: limit)
        let window = String(text[..<windowEnd])

        // Prefer punctuation boundaries first for more natural speaking rhythm.
        let punctuation = [". ", "! ", "? ", "; ", ": ", ", "]
        for token in punctuation {
            if let range = window.range(of: token, options: .backwards),
               window.distance(from: window.startIndex, to: range.upperBound) >= max(18, preferredMax - 14) {
                return text.index(text.startIndex, offsetBy: window.distance(from: window.startIndex, to: range.upperBound))
            }
        }

        // Fallback to nearest whitespace close to preferred max.
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

    private func applyGeneratedScriptWithGPT() async -> Bool {
        guard var script = editingScript else { return false }

        let targetMinutes: Double?
        if generatorSetLength {
            let parsed = Double(generatorLengthCustom) ?? generatorLengthMinutes
            targetMinutes = min(15.0, max(0.25, parsed))
        } else {
            targetMinutes = nil
        }

        generatorIsLoading = true
        generatorErrorMessage = ""
        defer { generatorIsLoading = false }

        let topic = generatorTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        let audience = generatorAudience.trimmingCharacters(in: .whitespacesAndNewlines)
        let cueRule = generatorUseCues
            ? "Use optional teleprompter cues naturally where useful: <focus>, <break>, <hold 1.2s>."
            : "Do not include any teleprompter cue tags."
        let styleProfile = generatorStyleProfileText.trimmingCharacters(in: .whitespacesAndNewlines)
        let styleRule: String
        if generatorEnableStyleMatch, !styleProfile.isEmpty {
            let fingerprint = makeStyleFingerprint(from: styleProfile)
            styleRule = """
            Match this speaker style profile while keeping content fresh and original.
            Style fingerprint:
            \(fingerprint)

            Source speaking sample:
            \(styleProfile)
            """
        } else {
            styleRule = "No style profile supplied. Use natural spoken delivery."
        }
        let toneRule: String
        switch generatorTone.lowercased() {
        case "professional": toneRule = "Use precise wording, confident delivery, and minimal slang."
        case "friendly": toneRule = "Use warm, approachable wording with simple conversational rhythm."
        case "confident": toneRule = "Use assertive, decisive wording with clear conviction."
        default: toneRule = "Use natural conversational wording like a creator speaking to camera."
        }
        let goalRule: String
        switch generatorGoal.lowercased() {
        case "persuade": goalRule = "Drive persuasive momentum and end with a clear call to action."
        case "inspire": goalRule = "Create emotional lift and end with motivating forward momentum."
        case "explain": goalRule = "Prioritize clarity and simplify complex points with concrete examples."
        default: goalRule = "Educate clearly with practical insights viewers can apply immediately."
        }
        let lengthRule: String
        if let targetMinutes {
            let targetWords = Int(targetMinutes * 147.0)
            let minWords = max(80, Int(Double(targetWords) * 0.9))
            let maxWords = Int(Double(targetWords) * 1.1)
            lengthRule = "Target duration is \(String(format: "%.1f", targetMinutes)) minutes. Keep output between \(minWords) and \(maxWords) words."
        } else {
            lengthRule = "No strict length target. Choose a natural complete script length for a video segment."
        }

        let userPrompt = """
        Use every field below as a hard requirement. Do not ignore any field.

        Topic: \(topic)
        Audience: \(audience.isEmpty ? "General audience" : audience)
        Tone: \(generatorTone)
        Goal: \(generatorGoal)
        Tone guidance: \(toneRule)
        Goal guidance: \(goalRule)
        \(styleRule)
        \(lengthRule)

        Requirements:
        - Return a fully usable spoken script for a video in one go.
        - Make the script directly about the provided topic, with specific details and natural commentary relevant to that topic.
        - Adapt language and examples to the stated audience.
        - Reflect the requested tone consistently from first line to final line.
        - Fulfill the requested goal in structure and ending.
        - If a style profile is provided, mirror its cadence, vocabulary simplicity level, sentence rhythm, and speaking energy.
        - Keep the voice style match strong but keep topic content new and specific to this request.
        - The script must sound natural and human, with concrete wording and natural transitions.
        - Avoid generic coaching filler and avoid meta labels like objective, style note, point one.
        - Avoid buzzwords, robotic phrasing, and repetitive sentence templates.
        - Do not use markdown, bullet lists, numbered lists, or section headings.
        - Do not use em dashes.
        - Format for teleprompter readability: keep lines natural, around 7 to 13 words per line.
        - Insert blank lines between idea blocks so pacing is easy while speaking.
        - Use original wording. Do not copy known scripts, and avoid plagiarism.
        - Write plain spoken language that sounds like a creator talking on camera.
        - \(cueRule)
        - Output only the final script text.
        """

        do {
            let generated = try await generateScriptWithBackend(
                topic: topic,
                audience: audience.isEmpty ? "General audience" : audience,
                tone: generatorTone,
                goal: generatorGoal,
                styleProfile: generatorEnableStyleMatch ? styleProfile : "",
                targetMinutes: targetMinutes,
                useCues: generatorUseCues,
                promptOverride: userPrompt
            )
            await MainActor.run {
                script.title = topic.isEmpty ? script.title : topic
                script.body = formatScriptForNotch(generated, maxChars: 48)
                script.lastEdited = Date()
                editingScript = script
                store.update(script)
                speechManager.loadScript(script.body)
            }
            return true
        } catch {
            generatorErrorMessage = "Generation failed: \(error.localizedDescription)"
            return false
        }
    }

    private var backendBaseURL: String {
        #if DEBUG
        return "http://localhost:8787"
        #else
        return "https://api.snotch.app"
        #endif
    }

    private func generateScriptWithBackend(
        topic: String,
        audience: String,
        tone: String,
        goal: String,
        styleProfile: String,
        targetMinutes: Double?,
        useCues: Bool,
        promptOverride: String
    ) async throws -> String {
        let requestBody = BackendGenerateRequest(
            topic: topic,
            audience: audience,
            tone: tone,
            goal: goal,
            styleProfile: styleProfile,
            targetMinutes: targetMinutes,
            useCues: useCues,
            promptOverride: promptOverride
        )

        var request = URLRequest(url: URL(string: "\(backendBaseURL)/v1/generate/script")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Snotch.Generator", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from backend"])
        }

        if !(200...299).contains(http.statusCode) {
            if let err = try? JSONDecoder().decode(BackendErrorEnvelope.self, from: data) {
                throw NSError(domain: "Snotch.Generator", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: err.message])
            }
            throw NSError(domain: "Snotch.Generator", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Backend request failed with status \(http.statusCode)"])
        }

        let decoded = try JSONDecoder().decode(BackendGenerateResponse.self, from: data)
        guard decoded.ok, let content = decoded.script?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw NSError(domain: "Snotch.Generator", code: -2, userInfo: [NSLocalizedDescriptionKey: decoded.message ?? "Empty script returned by backend"])
        }
        return content
    }

    private func makeStyleFingerprint(from transcript: String) -> String {
        let normalized = transcript
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let sentenceParts = normalized
            .components(separatedBy: #"(?<=[.!?])\s+"#)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let words = normalized
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)

        let avgSentenceWords: Int
        if sentenceParts.isEmpty {
            avgSentenceWords = max(1, words.count)
        } else {
            let counts = sentenceParts.map { sentence in
                sentence.split { !$0.isLetter && !$0.isNumber }.count
            }
            avgSentenceWords = max(1, counts.reduce(0, +) / max(1, counts.count))
        }

        let fillerSet: Set<String> = ["um", "uh", "like", "youknow", "actually", "basically"]
        let fillers = words.filter { fillerSet.contains($0.replacingOccurrences(of: " ", with: "")) }.count

        var freq: [String: Int] = [:]
        for w in words where w.count > 3 {
            freq[w, default: 0] += 1
        }
        let topWords = freq
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .prefix(8)
            .map(\.key)
            .joined(separator: ", ")

        let energyHint: String
        if avgSentenceWords <= 9 {
            energyHint = "fast conversational rhythm with short punchy sentences"
        } else if avgSentenceWords <= 15 {
            energyHint = "balanced conversational rhythm with medium sentence length"
        } else {
            energyHint = "longer explanatory rhythm with detailed sentence structure"
        }

        return """
        - Average sentence length: about \(avgSentenceWords) words.
        - Rhythm: \(energyHint).
        - Filler usage in sample: \(fillers) occurrences.
        - Frequent vocabulary to echo naturally when relevant: \(topWords.isEmpty ? "none" : topWords).
        - Preserve natural pauses and spoken transitions like a real presenter.
        """
    }

    private func requestStyleCaptureTopic() async -> String {
        return "Talk for 30 seconds about your favorite app and why you use it daily."
    }

    private struct BackendGenerateRequest: Encodable {
        let topic: String
        let audience: String
        let tone: String
        let goal: String
        let styleProfile: String
        let targetMinutes: Double?
        let useCues: Bool
        let promptOverride: String
    }

    private struct BackendGenerateResponse: Decodable {
        let ok: Bool
        let script: String?
        let message: String?
    }

    private struct BackendBundlesRequest: Encodable {
        let topic: String
        let audience: String
    }

    private struct BackendBundlesResponse: Decodable {
        let ok: Bool
        let titles: [String]
        let hooks: [String]
        let ctas: [String]
    }

    private struct BackendErrorEnvelope: Decodable {
        let ok: Bool?
        let message: String
    }

    // MARK: - Helpers

    private var hotKeyHandler: some View {
        Color.clear
            .onReceive(NotificationCenter.default.publisher(for: .snotchScrollUp))      { _ in speechManager.scrollUp() }
            .onReceive(NotificationCenter.default.publisher(for: .snotchScrollDown))    { _ in speechManager.scrollDown() }
            .onReceive(NotificationCenter.default.publisher(for: .snotchToggleSidebar)) { _ in
                showSidebar.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .snotchImportScriptURL)) { note in
                guard let url = note.userInfo?["url"] as? URL else { return }
                _ = importScript(from: url)
            }
            .onReceive(NotificationCenter.default.publisher(for: .snotchOverlayEditorSaved)) { note in
                handleOverlayEditorSaved(note)
            }
    }

    private func normalizeStoredScriptsOnLaunch() {
        var changed = false
        for idx in store.scripts.indices {
            let formatted = formatScriptForNotch(store.scripts[idx].body, maxChars: 48)
            if formatted != store.scripts[idx].body {
                store.scripts[idx].body = formatted
                store.scripts[idx].lastEdited = Date()
                changed = true
            }
        }
        if changed {
            store.save()
        }
    }

    private func select(_ script: SnotchScript) {
        var opened = script
        let formatted = formatScriptForNotch(opened.body, maxChars: 48)
        if formatted != opened.body {
            opened.body = formatted
            opened.lastEdited = Date()
        }
        opened.lastOpened = Date()
        store.update(opened)
        selectedID    = script.id
        editingScript = opened
        speechManager.setActiveScript(id: script.id)
        speechManager.loadScript(opened.body)
    }

    private func handleOverlayEditorSaved(_ notification: Notification) {
        guard let id = notification.userInfo?["id"] as? UUID,
              let body = notification.userInfo?["body"] as? String,
              let idx = store.scripts.firstIndex(where: { $0.id == id }) else {
            return
        }

        var updated = store.scripts[idx]
        let normalized = formatScriptForNotch(body, maxChars: 48)
        updated.body = normalized
        updated.lastEdited = Date()
        store.update(updated)

        if editingScript?.id == id {
            editingScript = updated
        }
        if speechManager.activeScriptID == id {
            speechManager.loadScript(normalized)
        }
    }

}

private struct ScriptGeneratorSheet: View {
    @Binding var topic: String
    @Binding var audience: String
    @Binding var tone: String
    @Binding var goal: String
    @Binding var setLength: Bool
    @Binding var lengthMinutes: Double
    @Binding var lengthCustom: String
    @Binding var useCues: Bool
    @Binding var enableStyleMatch: Bool
    @Binding var styleProfileText: String
    @ObservedObject var styleRecorder: StyleCaptureRecorder
    @Binding var isGenerating: Bool
    @Binding var errorMessage: String
    let onGenerate: () async -> Bool
    let onRequestPracticeTopic: () async -> String

    @Environment(\.dismiss) private var dismiss

    private let tones = ["Conversational", "Confident", "Friendly", "Professional"]
    private let goals = ["Educate", "Persuade", "Inspire", "Explain"]
    @State private var practiceTopic: String = ""
    @State private var isPreparingTopic: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Script Generator")
                .font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Topic")
                    .font(.system(size: 11, weight: .medium))
                TextField("What should the script be about?", text: $topic)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Audience")
                        .font(.system(size: 11, weight: .medium))
                    TextField("Optional: who is this for?", text: $audience)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tone")
                        .font(.system(size: 11, weight: .medium))
                    Picker("Tone", selection: $tone) {
                        ForEach(tones, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.menu)
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Goal")
                        .font(.system(size: 11, weight: .medium))
                    Picker("Goal", selection: $goal) {
                        ForEach(goals, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.menu)
                }
            }

            Toggle("Set target length (minutes)", isOn: $setLength)
                .toggleStyle(.switch)

            if setLength {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Length")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(String(format: "%.1f min", lengthMinutes))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    }
                    Slider(value: $lengthMinutes, in: 0.5...10.0, step: 0.5)
                    HStack {
                        Text("Custom")
                            .font(.system(size: 11, weight: .medium))
                        TextField("e.g. 2.5", text: $lengthCustom)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Text("minutes")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Toggle("Auto-insert teleprompter cues (<break>, <hold>, <focus>)", isOn: $useCues)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Match My Speaking Style")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(styleRecorder.isRecording ? "Listening: \(styleRecorder.secondsRemaining)s" : "30s")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Text("Capture a short voice sample so generated scripts mirror your tone, vocabulary, and speaking rhythm.")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Enable style match from voice sample", isOn: $enableStyleMatch)
                    .toggleStyle(.switch)

                if enableStyleMatch {
                    HStack(spacing: 10) {
                        Button(styleRecorder.isRecording ? "Stop Listening" : "Start Listening") {
                            Task {
                                if styleRecorder.isRecording {
                                    let captured = styleRecorder.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !captured.isEmpty {
                                        styleProfileText = captured
                                    } else if !styleRecorder.lastNonEmptyTranscript.isEmpty {
                                        styleProfileText = styleRecorder.lastNonEmptyTranscript
                                    }
                                    styleRecorder.stopCapture()
                                } else {
                                    isPreparingTopic = true
                                    practiceTopic = await onRequestPracticeTopic()
                                    isPreparingTopic = false
                                    styleRecorder.startCapture(duration: 30)
                                }
                            }
                        }
                        .buttonStyle(.bordered)

                        Button("Try Another Prompt") {
                            Task {
                                isPreparingTopic = true
                                practiceTopic = await onRequestPracticeTopic()
                                isPreparingTopic = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(styleRecorder.isRecording || isPreparingTopic)
                    }
                }

                if isPreparingTopic {
                    Text("Preparing topic...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else if enableStyleMatch && !practiceTopic.isEmpty {
                    Text("Talk about: \(practiceTopic)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !styleRecorder.errorMessage.isEmpty {
                    Text(styleRecorder.errorMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextEditor(text: $styleProfileText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 90)
                    .disabled(styleRecorder.isRecording)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.28), lineWidth: 0.5)
                    )
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isGenerating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating script...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Generate") {
                    Task {
                        let ok = await onGenerate()
                        if ok { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isGenerating
                )
            }
        }
        .padding(18)
        .onChange(of: enableStyleMatch) { _, enabled in
            Task {
                if enabled {
                    if practiceTopic.isEmpty {
                        isPreparingTopic = true
                        practiceTopic = await onRequestPracticeTopic()
                        isPreparingTopic = false
                    }
                    if !styleRecorder.isRecording {
                        styleRecorder.startCapture(duration: 30)
                    }
                } else {
                    if styleRecorder.isRecording {
                        styleRecorder.stopCapture()
                    }
                }
            }
        }
        .onReceive(styleRecorder.$transcript.removeDuplicates()) { transcript in
            if enableStyleMatch,
               !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                styleProfileText = transcript
            }
        }
        .onReceive(styleRecorder.$isRecording.removeDuplicates()) { recording in
            if !recording {
                let captured = styleRecorder.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !captured.isEmpty {
                    styleProfileText = captured
                } else if !styleRecorder.lastNonEmptyTranscript.isEmpty {
                    styleProfileText = styleRecorder.lastNonEmptyTranscript
                }
            }
        }
        .onDisappear {
            if styleRecorder.isRecording {
                styleRecorder.stopCapture()
            }
        }
    }
}

private struct AppSettingsPanel: View {
    @ObservedObject var speechManager: SpeechManager
    @ObservedObject var overlayController: OverlayWindowController
    @Binding var darkMode: Bool
    let pillLight: Bool
    let onResetSetup: () -> Void
    let onClose: () -> Void
    @State private var micGranted: Bool = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var speechGranted: Bool = SFSpeechRecognizer.authorizationStatus() == .authorized
    @State private var accessibilityGranted: Bool = AXIsProcessTrusted()
    @State private var permissionPollTimer: Timer? = nil

    private var readingModeBinding: Binding<Int> {
        Binding(
            get: { speechManager.continuousScrollInNotch ? 1 : 0 },
            set: { speechManager.continuousScrollInNotch = ($0 == 1) }
        )
    }

    private var gateBinding: Binding<Double> {
        Binding(
            get: { speechManager.noiseGate },
            set: { speechManager.setNoiseGate($0) }
        )
    }

    private var gainBinding: Binding<Double> {
        Binding(
            get: { speechManager.inputGain },
            set: { speechManager.setInputGain($0) }
        )
    }

    private var meterLevel: CGFloat {
        CGFloat(min(1, max(0, speechManager.audioLevel)))
    }

    private var hideOverlayInCaptureBinding: Binding<Bool> {
        Binding(
            get: { overlayController.hideOverlayInScreenCapture },
            set: { enabled in
                overlayController.setHideOverlayInScreenCapture(enabled)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Theme, reading mode, and audio tuning")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: pillLight ? 0.40 : 0.62))
                }

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(white: pillLight ? 0.20 : 0.85))
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color(white: pillLight ? 0 : 1, opacity: 0.09))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color(white: pillLight ? 1.0 : 0.10, opacity: pillLight ? 0.80 : 0.74))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsSectionCard(title: "Appearance", subtitle: "Window theme", pillLight: pillLight) {
                        HStack(spacing: 10) {
                            Image(systemName: "moon.fill")
                                .font(.system(size: 11))
                                .foregroundColor(Color(white: pillLight ? 0.40 : 0.55))
                                .frame(width: 14)

                            Text("Dark Mode")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color(white: pillLight ? 0.14 : 0.90))

                            Spacer()

                            ZStack(alignment: darkMode ? .trailing : .leading) {
                                Capsule()
                                    .fill(darkMode
                                        ? Color(white: 1, opacity: 0.22)
                                        : Color(white: 1, opacity: 0.10))
                                    .frame(width: 36, height: 20)
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color(white: pillLight ? 0 : 1, opacity: 0.14), lineWidth: 0.5)
                                    )

                                Circle()
                                    .fill(darkMode ? Color(white: 0.90) : Color(white: 0.40))
                                    .frame(width: 14, height: 14)
                                    .padding(.horizontal, 3)
                                    .shadow(color: .black.opacity(0.30), radius: 2, y: 1)
                            }
                            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: darkMode)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            darkMode.toggle()
                        }
                    }

                    SettingsSectionCard(title: "Permissions", subtitle: "System access", pillLight: pillLight) {
                        VStack(alignment: .leading, spacing: 8) {
                            PermissionStatusRow(
                                icon: "mic.fill",
                                label: "Microphone",
                                granted: micGranted,
                                actionLabel: "Allow",
                                pillLight: pillLight,
                                onAction: requestMicrophonePermission
                            )

                            PermissionStatusRow(
                                icon: "waveform",
                                label: "Speech Recognition",
                                granted: speechGranted,
                                actionLabel: "Allow",
                                pillLight: pillLight,
                                onAction: requestSpeechPermission
                            )

                            PermissionStatusRow(
                                icon: "keyboard",
                                label: "Accessibility",
                                granted: accessibilityGranted,
                                actionLabel: "Open Settings",
                                pillLight: pillLight,
                                onAction: openAccessibilitySettings
                            )
                        }
                    }

                    SettingsSectionCard(title: "Reading", subtitle: "Prompt behavior", pillLight: pillLight) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Reading Mode")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color(white: pillLight ? 0.28 : 0.72))

                            Picker("Reading Mode", selection: readingModeBinding) {
                                Text("Highlighted").tag(0)
                                Text("Continuous").tag(1)
                            }
                            .pickerStyle(.segmented)
                            .tint(Color(white: pillLight ? 0.16 : 0.24))
                        }
                    }

                    SettingsSectionCard(title: "Audio", subtitle: "Input tuning", pillLight: pillLight) {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Noise Gate")
                                        .font(.system(size: 11, weight: .medium))
                                    Spacer()
                                    Text("\(Int(speechManager.noiseGate * 100))%")
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Slider(value: gateBinding, in: 0.0...1.0, step: 0.01)
                                HStack {
                                    Text("Low gate (more sensitive)")
                                    Spacer()
                                    Text("High gate (more filtering)")
                                }
                                .font(.system(size: 9.5))
                                .foregroundColor(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Input Gain")
                                        .font(.system(size: 11, weight: .medium))
                                    Spacer()
                                    Text(String(format: "%.2fx", speechManager.inputGain))
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Slider(value: gainBinding, in: 0.5...3.0, step: 0.05)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("VU Meter")
                                        .font(.system(size: 11, weight: .medium))
                                    Spacer()
                                    Text(speechManager.isVoiceActive ? "Voice detected" : (speechManager.isListening ? "Listening..." : "Mic idle"))
                                        .font(.system(size: 9.5, weight: .medium))
                                        .foregroundColor(.secondary)
                                }
                                GeometryReader { geo in
                                    let width = geo.size.width
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(Color(white: pillLight ? 0 : 1, opacity: 0.10))

                                        Capsule()
                                            .fill(
                                                LinearGradient(
                                                    colors: [
                                                        Color.green.opacity(0.85),
                                                        Color.yellow.opacity(0.85),
                                                        Color.red.opacity(0.85)
                                                    ],
                                                    startPoint: .leading,
                                                    endPoint: .trailing
                                                )
                                            )
                                            .frame(width: max(4, meterLevel * width))

                                        Rectangle()
                                            .fill(Color(white: pillLight ? 0.1 : 1.0, opacity: 0.9))
                                            .frame(width: 1.5)
                                            .padding(.vertical, 1)
                                            .offset(x: max(0, min(width - 2, CGFloat(speechManager.noiseGate) * width)))
                                    }
                                }
                                .frame(height: 11)
                            }

                            Text("If scrolling triggers too easily, raise Noise Gate. If it misses your voice, lower Noise Gate or increase Input Gain.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack {
                                Spacer()
                                Button("Reset Audio") {
                                    speechManager.resetAudioTuning()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: 520, maxHeight: 560)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(white: pillLight ? 0.97 : 0.08, opacity: 0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color(white: pillLight ? 0 : 1, opacity: 0.16), lineWidth: 0.6)
                )
        )
        .shadow(color: Color.black.opacity(pillLight ? 0.20 : 0.46), radius: 26, x: 0, y: 8)
        .preferredColorScheme(pillLight ? .light : .dark)
        .onAppear {
            refreshPermissionStates()
            startPermissionPolling()
        }
        .onDisappear {
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
        }
    }

    private func refreshPermissionStates() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        accessibilityGranted = AXIsProcessTrusted()
    }

    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async {
                refreshPermissionStates()
            }
        }
    }

    private func requestSpeechPermission() {
        SFSpeechRecognizer.requestAuthorization { _ in
            DispatchQueue.main.async {
                refreshPermissionStates()
            }
        }
    }

    private func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startPermissionPolling()
    }

    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                refreshPermissionStates()
            }
        }
    }
}

private struct PermissionStatusRow: View {
    let icon: String
    let label: String
    let granted: Bool
    let actionLabel: String
    let pillLight: Bool
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(granted
                    ? Color(red: 0.27, green: 0.68, blue: 0.45)
                    : Color(white: pillLight ? 0.36 : 0.72))
                .frame(width: 16)

            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(white: pillLight ? 0.14 : 0.90))

            Spacer()

            if granted {
                Text("Granted")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(Color(red: 0.27, green: 0.68, blue: 0.45))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color(red: 0.27, green: 0.68, blue: 0.45).opacity(0.14))
                    )
            } else {
                Button(actionLabel) {
                    onAction()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(white: pillLight ? 0 : 1, opacity: 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color(white: pillLight ? 0 : 1, opacity: 0.10), lineWidth: 0.5)
                )
        )
    }
}

private struct SettingsSectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    let pillLight: Bool
    let content: Content

    init(title: String, subtitle: String, pillLight: Bool, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.pillLight = pillLight
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(white: pillLight ? 0.16 : 0.90))
                Spacer()
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(white: pillLight ? 0.40 : 0.62))
            }

            content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: pillLight ? 0 : 1, opacity: pillLight ? 0.05 : 0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(white: pillLight ? 0 : 1, opacity: 0.12), lineWidth: 0.5)
                )
        )
    }
}

final class StickyNoteWindowController: NSWindowController {

    init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 380, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func present(
        scriptTitle: String,
        noteNumber: Int,
        initialText: String,
        initialPinned: Bool,
        onChange: @escaping (String, Bool) -> Void,
        onDelete: @escaping () -> Void
    ) {
        let isLight = UserDefaults.standard.bool(forKey: "snotch.pillLight")
        let view = StickyNoteWindowView(
            scriptTitle: scriptTitle,
            noteNumber: noteNumber,
            initialText: initialText,
            initialPinned: initialPinned,
            onChange: onChange,
            onDelete: onDelete,
            onPinnedChanged: { [weak self] pinned in
                guard let window = self?.window else { return }
                window.level = pinned ? .floating : .normal
                window.collectionBehavior = pinned
                    ? [.canJoinAllSpaces, .fullScreenAuxiliary]
                    : [.fullScreenAuxiliary, .moveToActiveSpace]
            }
        )

        window?.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
        window?.contentViewController = NSHostingController(rootView: view)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct StickyNoteWindowView: View {
    let scriptTitle: String
    let noteNumber: Int
    let onChange: (String, Bool) -> Void
    let onDelete: () -> Void
    let onPinnedChanged: (Bool) -> Void

    @AppStorage("snotch.pillLight") private var pillLight: Bool = false
    @State private var text: String
    @State private var pinned: Bool

    private var secondaryText: Color {
        Color(white: pillLight ? 0.42 : 0.58)
    }

    private var dividerColor: Color {
        Color(white: pillLight ? 0 : 1, opacity: 0.11)
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

    private var deleteForeground: Color {
        Color(white: pillLight ? 0.22 : 0.86)
    }

    private var deleteBackground: Color {
        pillLight
            ? Color(red: 0.95, green: 0.87, blue: 0.89).opacity(0.95)
            : Color(red: 0.34, green: 0.08, blue: 0.10).opacity(0.78)
    }

    private var pinnedForeground: Color {
        pinned ? Color(white: pillLight ? 0.12 : 0.94) : Color(white: pillLight ? 0.22 : 0.82)
    }

    private var pinnedBackground: Color {
        pinned
            ? (pillLight
                ? Color(red: 0.84, green: 0.93, blue: 0.87).opacity(0.95)
                : Color(red: 0.05, green: 0.42, blue: 0.21).opacity(0.90))
            : Color(white: pillLight ? 0 : 1, opacity: 0.09)
    }

    init(
        scriptTitle: String,
        noteNumber: Int,
        initialText: String,
        initialPinned: Bool,
        onChange: @escaping (String, Bool) -> Void,
        onDelete: @escaping () -> Void,
        onPinnedChanged: @escaping (Bool) -> Void
    ) {
        self.scriptTitle = scriptTitle
        self.noteNumber = noteNumber
        self.onChange = onChange
        self.onDelete = onDelete
        self.onPinnedChanged = onPinnedChanged
        _text = State(initialValue: initialText)
        _pinned = State(initialValue: initialPinned)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if !scriptTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("\(scriptTitle)  •  Note \(noteNumber)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(secondaryText)
                        .lineLimit(1)
                }
                Spacer()

                Button {
                    pinned.toggle()
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(pinnedForeground)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(pinnedBackground)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(deleteForeground)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(deleteBackground)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Rectangle()
                .fill(dividerColor)
                .frame(height: 0.5)

            TextEditor(text: $text)
                .font(.system(size: 15, weight: .regular, design: .monospaced))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(editorBackground)
                .foregroundColor(editorText)
        }
        .background(panelBackground)
        .frame(minWidth: 340, minHeight: 280)
        .preferredColorScheme(pillLight ? .light : .dark)
        .onAppear {
            onPinnedChanged(pinned)
            onChange(text, pinned)
        }
        .onChange(of: text) { _, value in
            onChange(value, pinned)
        }
        .onChange(of: pinned) { _, value in
            onPinnedChanged(value)
            onChange(text, value)
        }
    }
}

// MARK: - Sidebar Row

struct SidebarRow: View {
    let script: SnotchScript
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    let onRenameCommit: () -> Void
    let onRenameCancel: () -> Void
    let onRename: () -> Void
    let onExportTXT: () -> Void
    let onExportMarkdown: () -> Void
    let onExportPDF: () -> Void
    let onDelete: () -> Void

    @AppStorage("snotch.pillLight") private var pillLight: Bool = false
    @State private var isHovered = false
    @FocusState private var fieldFocused: Bool

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            // Selection accent bar
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isSelected ? Color(white: 0.55) : Color.clear)
                .frame(width: 2, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                if isRenaming {
                    HStack(spacing: 6) {
                        TextField("Script name", text: $renameText)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(Color(white: pillLight ? 0.10 : 0.92))
                            .textFieldStyle(.plain)
                            .focused($fieldFocused)
                            .onSubmit { onRenameCommit() }
                            .onExitCommand { onRenameCancel() }

                        // Confirm button
                        Button(action: onRenameCommit) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color(white: pillLight ? 0.25 : 0.75))
                                .frame(width: 20, height: 20)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color(white: pillLight ? 0 : 1, opacity: 0.12))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(white: pillLight ? 0 : 1, opacity: 0.07))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color(white: pillLight ? 0 : 1, opacity: 0.18), lineWidth: 0.5)
                            )
                    )
                    .onAppear {
                        // Slight delay so the view is in the hierarchy before focusing
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            fieldFocused = true
                        }
                    }
                } else {
                    Text(script.title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected
                            ? Color(white: pillLight ? 0.10 : 0.92)
                            : Color(white: pillLight ? 0.35 : 0.60))
                        .lineLimit(1)
                }
                if !isRenaming {
                    Text(Self.dateFormatter.string(from: script.lastEdited))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(Color(white: pillLight ? 0.50 : 0.26))
                }
            }

            Spacer()

            if (isHovered || isSelected) && !isRenaming {
                Menu {
                    Button("Rename") { onRename() }
                    Menu("Export") {
                        Button("TXT") { onExportTXT() }
                        Button("Markdown") { onExportMarkdown() }
                        Button("PDF") { onExportPDF() }
                    }
                    Divider()
                    Button(role: .destructive) { onDelete() } label: {
                        Text("Delete")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(white: pillLight ? 0.35 : 0.72))
                        .frame(width: 22, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color(white: pillLight ? 0 : 1, opacity: 0.12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(Color(white: pillLight ? 0 : 1, opacity: 0.14), lineWidth: 0.5)
                                )
                        )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .transition(.opacity)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? Color(white: pillLight ? 0 : 1, opacity: 0.09)
                        : (isHovered ? Color(white: pillLight ? 0 : 1, opacity: 0.04) : Color.clear)
                )
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .animation(.easeInOut(duration: 0.14), value: isRenaming)
    }
}

private struct ScriptSidebarDropDelegate: DropDelegate {
    let targetIndex: Int
    let maxIndex: Int
    @Binding var draggedID: UUID?
    @Binding var insertionIndex: Int?
    let onDropAtIndex: (UUID, Int) -> Void

    private var clampedIndex: Int {
        max(0, min(targetIndex, maxIndex))
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggedID != nil
    }

    func dropEntered(info: DropInfo) {
        insertionIndex = clampedIndex
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        insertionIndex = clampedIndex
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedScriptID = draggedID else {
            insertionIndex = nil
            return false
        }
        onDropAtIndex(draggedScriptID, clampedIndex)
        draggedID = nil
        insertionIndex = nil
        return true
    }

    func dropExited(info: DropInfo) {
        // Keep current order; item remains draggable until dropped.
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let snotchScrollUp      = Notification.Name("snotch.scrollUp")
    static let snotchScrollDown    = Notification.Name("snotch.scrollDown")
    static let snotchToggleSidebar = Notification.Name("snotch.toggleSidebar")
    static let snotchImportScriptURL = Notification.Name("snotch.importScriptURL")
    static let snotchOverlayEditorSaved = Notification.Name("snotch.overlayEditorSaved")
}
