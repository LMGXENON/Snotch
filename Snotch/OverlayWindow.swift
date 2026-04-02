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

// MARK: - Low Wide Hemisphere Visualizer

struct AudioWaveView: View {
    let audioLevel: Float
    let lightMode: Bool
    let isPaused: Bool
    @State private var smoothed: Double = 0

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let target  = Double(min(audioLevel * 20.0, 1.0))
                let level   = smoothed + (target - smoothed) * (target > smoothed ? 0.28 : 0.05)
                guard level > 0.01 else { return }

                let cx = size.width / 2
                let baseY  = size.height
                
                // Subtle breathing
                let breath = 1.0 + sin(t * 1.8) * 0.05 * level
                
                // WIDE diameter (40% of width), but VERY LOW height
                let width = size.width * 0.40 * breath
                let height = width * 0.12  // Only 12% height-to-width ratio = very low dome
                
                // Create low wide hemisphere
                var hemisphere = Path()
                hemisphere.move(to: CGPoint(x: cx - width/2, y: baseY))
                
                // Draw smooth arc with very low profile
                let segments = 50
                for i in 0...segments {
                    let t = Double(i) / Double(segments)
                    let angle = t * .pi
                    let x = cx + (cos(angle + .pi) * width / 2)
                    let y = baseY - (sin(angle) * height * level)
                    hemisphere.addLine(to: CGPoint(x: x, y: y))
                }
                
                hemisphere.addLine(to: CGPoint(x: cx + width/2, y: baseY))
                hemisphere.closeSubpath()

                if lightMode {
                    // Light mode: dark gray gradient
                    ctx.fill(hemisphere, with: .radialGradient(
                        Gradient(stops: [
                            .init(color: Color(white: 0.30).opacity(0.50 * level), location: 0.00),
                            .init(color: Color(white: 0.40).opacity(0.30 * level), location: 0.50),
                            .init(color: Color(white: 0.50).opacity(0.10 * level), location: 0.85),
                            .init(color: .clear, location: 1.00),
                        ]),
                        center: CGPoint(x: cx, y: baseY),
                        startRadius: 0,
                        endRadius: width / 2
                    ))
                } else {
                    // Dark mode: gradient gray (darker at edges, lighter at center)
                    // Main hemisphere with soft falloff
                    ctx.fill(hemisphere, with: .radialGradient(
                        Gradient(stops: [
                            .init(color: Color(white: 0.75).opacity(0.70 * level), location: 0.00),
                            .init(color: Color(white: 0.65).opacity(0.50 * level), location: 0.40),
                            .init(color: Color(white: 0.55).opacity(0.28 * level), location: 0.70),
                            .init(color: Color(white: 0.45).opacity(0.08 * level), location: 0.92),
                            .init(color: .clear, location: 1.00),
                        ]),
                        center: CGPoint(x: cx, y: baseY),
                        startRadius: 0,
                        endRadius: width / 2
                    ))
                    
                    // Subtle inner glow at center
                    let glowRadius = width * 0.20
                    var innerGlow = Path()
                    innerGlow.move(to: CGPoint(x: cx - glowRadius/2, y: baseY))
                    for i in 0...30 {
                        let t = Double(i) / 30.0
                        let angle = t * .pi
                        let x = cx + (cos(angle + .pi) * glowRadius / 2)
                        let y = baseY - (sin(angle) * glowRadius / 2 * 0.12 * level)
                        innerGlow.addLine(to: CGPoint(x: x, y: y))
                    }
                    innerGlow.addLine(to: CGPoint(x: cx + glowRadius/2, y: baseY))
                    innerGlow.closeSubpath()
                    
                    ctx.fill(innerGlow, with: .radialGradient(
                        Gradient(stops: [
                            .init(color: Color(white: 0.90).opacity(0.80 * level), location: 0.00),
                            .init(color: Color(white: 0.80).opacity(0.50 * level), location: 0.60),
                            .init(color: .clear, location: 1.00),
                        ]),
                        center: CGPoint(x: cx, y: baseY),
                        startRadius: 0,
                        endRadius: glowRadius / 2
                    ))
                    
                    // Faint outer diffusion halo
                    let haloRadius = width * 0.65
                    var halo = Path()
                    halo.move(to: CGPoint(x: cx - haloRadius/2, y: baseY))
                    for i in 0...50 {
                        let t = Double(i) / 50.0
                        let angle = t * .pi
                        let x = cx + (cos(angle + .pi) * haloRadius / 2)
                        let y = baseY - (sin(angle) * haloRadius / 2 * 0.10 * level)
                        halo.addLine(to: CGPoint(x: x, y: y))
                    }
                    halo.addLine(to: CGPoint(x: cx + haloRadius/2, y: baseY))
                    halo.closeSubpath()
                    
                    ctx.fill(halo, with: .radialGradient(
                        Gradient(colors: [
                            Color(white: 0.60).opacity(0.12 * level),
                            Color(white: 0.50).opacity(0.04 * level),
                            .clear,
                        ]),
                        center: CGPoint(x: cx, y: baseY),
                        startRadius: width / 2,
                        endRadius: haloRadius / 2
                    ))
                }
            }
            .task(id: tl.date) {
                let target = Double(min(audioLevel * 20.0, 1.0))
                smoothed = smoothed + (target - smoothed) * (target > smoothed ? 0.28 : 0.05)
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

            // Reactive voice wave with pause indicator
            AudioWaveView(audioLevel: speechManager.audioLevel, lightMode: isLight, isPaused: speechManager.isPaused)
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

            // Soft red glow when paused (spread to left/right/bottom, not too bright)
            if speechManager.isPaused {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0, bottomLeadingRadius: 24,
                    bottomTrailingRadius: 24, topTrailingRadius: 0,
                    style: .continuous
                )
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .clear,  // No glow at top
                            Color.red.opacity(0.3),  // Soft left side
                            Color.red.opacity(0.5),  // Brighter bottom
                            Color.red.opacity(0.3),  // Soft right side
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 2.0
                )
                .blur(radius: 4)
                .transition(.opacity)
            }

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

            // Progress bar — always visible
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
        .animation(.easeInOut(duration: 0.2), value: speechManager.isPaused)
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
