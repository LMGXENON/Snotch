import AppKit
import SwiftUI
import Combine

final class OverlayWindow: NSWindow {

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
        sharingType = .none
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
        guard let screen = NSScreen.main else { return }
        let pillWidth: CGFloat   = 280
        let pillHeight: CGFloat  = 94
        let topEdgeOffset: CGFloat = 2

        var xOrigin: CGFloat
        var yOrigin: CGFloat

        if #available(macOS 12.0, *) {
            let safeInsets = screen.safeAreaInsets
            if safeInsets.top > 0 {
                xOrigin = screen.frame.midX - pillWidth / 2
                yOrigin = screen.frame.maxY - safeInsets.top - topEdgeOffset - pillHeight
            } else {
                xOrigin = screen.frame.midX - pillWidth / 2
                yOrigin = screen.frame.maxY - 28 - topEdgeOffset - pillHeight
            }
        } else {
            xOrigin = screen.frame.midX - pillWidth / 2
            yOrigin = screen.frame.maxY - 28 - topEdgeOffset - pillHeight
        }

        setFrame(CGRect(x: xOrigin, y: yOrigin, width: 280, height: 94), display: true)
    }

    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { false }
}

final class OverlayWindowController: ObservableObject {

    @Published var isVisible: Bool = false

    private var overlayWindow: OverlayWindow?
    private var windowController: NSWindowController?
    private let speechManager: SpeechManager

    init(speechManager: SpeechManager) {
        self.speechManager = speechManager
        buildOverlay()
    }

    private func buildOverlay() {
        let win = OverlayWindow()
        let pillView = OverlayPillView(speechManager: speechManager)
        let hosting = NSHostingView(rootView: pillView)
        hosting.frame = CGRect(x: 0, y: 0, width: 280, height: 94)
        hosting.autoresizingMask = [.width, .height]
        win.contentView?.addSubview(hosting)
        self.overlayWindow = win
        self.windowController = NSWindowController(window: win)
    }

    func show() {
        overlayWindow?.orderFrontRegardless()
        DispatchQueue.main.async { self.isVisible = true }
    }

    func hide() {
        overlayWindow?.orderOut(nil)
        DispatchQueue.main.async { self.isVisible = false }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func repositionIfNeeded() {
        overlayWindow?.positionNearNotch()
    }
}

// MARK: - Advanced Wave Visualizer

struct AudioWaveView: View {
    let audioLevel: Float
    let lightMode: Bool
    @State private var smoothed: Double = 0
    @State private var wavePhase: Double = 0

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let target  = Double(min(audioLevel * 20.0, 1.0))
                let level   = smoothed + (target - smoothed) * (target > smoothed ? 0.28 : 0.05)
                guard level > 0.01 else { return }

                let cx = size.width / 2
                let baseY  = size.height
                
                // Multiple wave layers with different frequencies
                let wave1 = sin(t * 2.4 + wavePhase) * 0.025
                let wave2 = sin(t * 3.7 + wavePhase * 1.3) * 0.018
                let wave3 = sin(t * 5.2 + wavePhase * 0.8) * 0.012
                let combinedWave = (wave1 + wave2 + wave3) * level
                
                let breath = 1.0 + combinedWave
                let radius = size.width * 0.48 * level * breath

                // Main dome with wave distortion
                var wavyDome = Path()
                wavyDome.move(to: CGPoint(x: cx - radius, y: baseY))
                
                let segments = 60
                for i in 0...segments {
                    let angle = Double(i) / Double(segments) * .pi
                    let baseX = cx + cos(angle + .pi) * radius
                    let baseHeight = sin(angle) * radius
                    
                    // Add wave distortion to height
                    let waveInfluence = sin(angle * 3.0 + t * 4.5) * 0.04 * level
                    let height = baseHeight * (1.0 + waveInfluence)
                    
                    let y = baseY - height
                    wavyDome.addLine(to: CGPoint(x: baseX, y: y))
                }
                
                wavyDome.addLine(to: CGPoint(x: cx + radius, y: baseY))
                wavyDome.closeSubpath()

                // Outer glow layers with wave animation
                for layer in 0..<3 {
                    let layerScale = 1.0 + Double(layer) * 0.15
                    let layerOpacity = (1.0 - Double(layer) * 0.3) * level
                    let layerRadius = radius * layerScale
                    
                    var glowDome = Path()
                    glowDome.move(to: CGPoint(x: cx - layerRadius, y: baseY))
                    
                    for i in 0...segments {
                        let angle = Double(i) / Double(segments) * .pi
                        let baseX = cx + cos(angle + .pi) * layerRadius
                        let baseHeight = sin(angle) * layerRadius
                        
                        let waveOffset = sin(angle * 2.0 + t * 3.8 - Double(layer) * 0.5) * 0.03 * level
                        let height = baseHeight * (1.0 + waveOffset)
                        
                        let y = baseY - height
                        glowDome.addLine(to: CGPoint(x: baseX, y: y))
                    }
                    
                    glowDome.addLine(to: CGPoint(x: cx + layerRadius, y: baseY))
                    glowDome.closeSubpath()
                    
                    if lightMode {
                        ctx.fill(glowDome, with: .radialGradient(
                            Gradient(colors: [
                                Color(white: 0.00).opacity(0.08 * layerOpacity),
                                .clear,
                            ]),
                            center: CGPoint(x: cx, y: baseY),
                            startRadius: 0,
                            endRadius: layerRadius
                        ))
                    } else {
                        ctx.fill(glowDome, with: .radialGradient(
                            Gradient(colors: [
                                Color(white: 1.00).opacity(0.12 * layerOpacity),
                                .clear,
                            ]),
                            center: CGPoint(x: cx, y: baseY),
                            startRadius: 0,
                            endRadius: layerRadius
                        ))
                    }
                }

                // Main dome with enhanced gradients
                if lightMode {
                    ctx.fill(wavyDome, with: .radialGradient(
                        Gradient(stops: [
                            .init(color: Color(white: 0.00).opacity(0.32 * level), location: 0.00),
                            .init(color: Color(white: 0.12).opacity(0.22 * level), location: 0.35),
                            .init(color: Color(white: 0.25).opacity(0.10 * level), location: 0.65),
                            .init(color: Color(white: 0.35).opacity(0.04 * level), location: 0.85),
                            .init(color: .clear,                                   location: 1.00),
                        ]),
                        center:      CGPoint(x: cx, y: baseY),
                        startRadius: 0,
                        endRadius:   radius
                    ))
                } else {
                    ctx.fill(wavyDome, with: .radialGradient(
                        Gradient(stops: [
                            .init(color: Color(white: 1.00).opacity(0.65 * level), location: 0.00),
                            .init(color: Color(white: 0.88).opacity(0.45 * level), location: 0.30),
                            .init(color: Color(white: 0.70).opacity(0.22 * level), location: 0.60),
                            .init(color: Color(white: 0.50).opacity(0.08 * level), location: 0.82),
                            .init(color: .clear,                                   location: 1.00),
                        ]),
                        center:      CGPoint(x: cx, y: baseY),
                        startRadius: 0,
                        endRadius:   radius
                    ))
                }

                // Bright core with wave animation
                let coreR = radius * (0.36 + sin(t * 3.2) * 0.04 * level)
                var waveCore = Path()
                waveCore.move(to: CGPoint(x: cx - coreR, y: baseY))
                
                for i in 0...40 {
                    let angle = Double(i) / 40.0 * .pi
                    let baseX = cx + cos(angle + .pi) * coreR
                    let baseHeight = sin(angle) * coreR
                    
                    let microWave = sin(angle * 4.0 + t * 6.0) * 0.06 * level
                    let height = baseHeight * (1.0 + microWave)
                    
                    let y = baseY - height
                    waveCore.addLine(to: CGPoint(x: baseX, y: y))
                }
                
                waveCore.addLine(to: CGPoint(x: cx + coreR, y: baseY))
                waveCore.closeSubpath()
                
                if lightMode {
                    ctx.fill(waveCore, with: .radialGradient(
                        Gradient(colors: [
                            Color(white: 0.00).opacity(0.55 * level),
                            Color(white: 0.08).opacity(0.28 * level),
                            .clear,
                        ]),
                        center: CGPoint(x: cx, y: baseY),
                        startRadius: 0, endRadius: coreR
                    ))
                } else {
                    ctx.fill(waveCore, with: .radialGradient(
                        Gradient(colors: [
                            Color(white: 1.00).opacity(0.95 * level),
                            Color(white: 0.92).opacity(0.65 * level),
                            Color(white: 0.80).opacity(0.25 * level),
                            .clear,
                        ]),
                        center: CGPoint(x: cx, y: baseY),
                        startRadius: 0, endRadius: coreR
                    ))
                }
            }
            .task(id: tl.date) {
                let target = Double(min(audioLevel * 20.0, 1.0))
                smoothed = smoothed + (target - smoothed) * (target > smoothed ? 0.28 : 0.05)
                wavePhase += 0.08
            }
        }
    }
}

struct OverlayPillView: View {

    @ObservedObject var speechManager: SpeechManager
    @AppStorage("snotch.pillLight") private var isLight: Bool = false
    private let rowHeight: CGFloat = 34

    private var progressFraction: Double {
        let total = max(1, speechManager.scriptLines.count - 1)
        return Double(speechManager.currentLineIndex) / Double(total)
    }

    var body: some View {
        ZStack {
            // Background gradient — dark or light
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 24,
                bottomTrailingRadius: 24, topTrailingRadius: 0,
                style: .continuous
            )
            .fill(
                LinearGradient(
                    colors: isLight
                        ? [Color(white: 0.97), Color(white: 0.89)]
                        : [Color(white: 0.00), Color(white: 0.13)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .animation(.easeInOut(duration: 0.3), value: isLight)

            // Reactive voice wave
            AudioWaveView(audioLevel: speechManager.audioLevel, lightMode: isLight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                let offset = geo.size.height / 2.0
                    - CGFloat(speechManager.currentLineIndex) * rowHeight
                    - rowHeight / 2.0
                VStack(alignment: .center, spacing: 0) {
                    ForEach(Array(speechManager.scriptLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(lineFont(index))
                            .foregroundColor(lineColor(index))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity)
                            .frame(height: rowHeight)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .offset(y: offset)
                .animation(
                    .interpolatingSpring(stiffness: 130, damping: 20),
                    value: speechManager.currentLineIndex
                )
            }
            .clipped()

            // Progress bar — fades in when voice activity is detected.
            VStack(spacing: 0) {
                Spacer()
                GeometryReader { bar in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color(white: isLight ? 0 : 1, opacity: 0.10))
                            .frame(height: 3)
                        Rectangle()
                            .fill(Color(white: isLight ? 0 : 1, opacity: 0.60))
                            .frame(width: max(0, CGFloat(progressFraction) * bar.size.width), height: 3)
                            .animation(.linear(duration: 0.4), value: progressFraction)
                    }
                }
                .frame(height: 3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(speechManager.isVoiceActive ? 1 : 0)
            .animation(.easeInOut(duration: 0.3), value: speechManager.isVoiceActive)

            // 3-2-1 countdown overlay
            if speechManager.isCountingDown {
                ZStack {
                    (isLight ? Color(white: 0.94) : Color.black).opacity(0.58)
                    Text("\(speechManager.countdownValue)")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(isLight ? Color(white: 0.10) : .white)
                        .animation(.spring(response: 0.22, dampingFraction: 0.55), value: speechManager.countdownValue)
                }
            }
        }
        .frame(width: 280, height: 94)
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
        .preferredColorScheme(.dark)
        .onHover { speechManager.isPaused = $0 }
    }

    private func lineFont(_ index: Int) -> Font {
        switch abs(index - speechManager.currentLineIndex) {
        case 0:  return .system(size: 14, weight: .semibold, design: .rounded)
        case 1:  return .system(size: 12, weight: .regular,  design: .rounded)
        default: return .system(size: 11, weight: .light,    design: .rounded)
        }
    }

    private func lineColor(_ index: Int) -> Color {
        let dark = abs(index - speechManager.currentLineIndex)
        if isLight {
            switch dark {
            case 0:  return Color(white: 0.05)
            case 1:  return Color(white: 0.05).opacity(0.45)
            default: return Color(white: 0.05).opacity(0.18)
            }
        } else {
            switch dark {
            case 0:  return .white
            case 1:  return .white.opacity(0.45)
            default: return .white.opacity(0.18)
            }
        }
    }
}
