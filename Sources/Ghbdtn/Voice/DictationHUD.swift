import AppKit
import SwiftUI

/// Floating dictation overlay: a small always-on-top bubble with a live
/// waveform, an elapsed timer and two symbol-only buttons (cancel / recognize).
///
/// The panel must NEVER take keyboard focus away from the text field the user
/// is dictating into — the caret has to stay in the target app so the
/// recognized text lands there. Three things guarantee that:
///   1. `.nonactivatingPanel` (set at init — changing styleMask later doesn't
///      re-sync the WindowServer's activation tag);
///   2. `canBecomeKey == false` + no focusable controls inside (symbols only);
///   3. it is shown with `orderFrontRegardless()` — never `NSApp.activate`.
final class DictationHUDPanel: NSPanel {
    init(controller: DictationController, capture: AudioCapture) {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow

        let hosting = FirstMouseHostingView(
            rootView: AnyView(DictationHUDView(controller: controller, capture: capture))
        )
        hosting.setFrameSize(hosting.fittingSize)
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }

    // A HUD must never become the key or main window: either would pull the
    // caret out of the field the user is dictating into.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Place the bubble top-center, just below the menu bar — visible but out
    /// of the way of the text being dictated. For a background agent app
    /// NSScreen.main is effectively the primary display, so prefer the screen
    /// the cursor is on: that's where the user is working.
    func positionTopCenter() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = frame.size
        setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                               y: visible.maxY - size.height - 24))
    }
}

/// SwiftUI controls live inside the hosting view itself (they are not nested
/// NSButtons), so accepting "first mouse" here makes every control respond to
/// the initial click even though the panel never becomes key.
private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Content

private struct DictationHUDView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var capture: AudioCapture

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .foregroundColor(.red)
                .font(.system(size: 13, weight: .semibold))

            WaveformView(levels: capture.levelHistory)
                .frame(width: 110, height: 22)

            Text(timeString)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)

            if controller.state == .transcribing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 58)
                    .help("Распознавание…")
            } else {
                HStack(spacing: 6) {
                    HUDButton(symbol: "stop.fill", tint: .red, help: "Остановить (отменить)") {
                        controller.cancel()
                    }
                    HUDButton(symbol: "checkmark.circle.fill", tint: .green, help: "Распознать и вставить") {
                        controller.recognize()
                    }
                }
                .frame(width: 58)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .padding(6) // room for the shadow inside the borderless window
    }

    private var timeString: String {
        let total = Int(controller.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Symbol-only button (no text labels, per spec) with a tooltip.
private struct HUDButton: View {
    let symbol: String
    let tint: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Bar-style live waveform fed by `AudioCapture.levelHistory`.
private struct WaveformView: View {
    let levels: [Float]

    var body: some View {
        Canvas { context, size in
            let count = max(levels.count, 1)
            let step = size.width / CGFloat(count)
            let barWidth = step * 0.62
            for (index, level) in levels.enumerated() {
                let height = max(2.5, CGFloat(level) * size.height)
                let rect = CGRect(x: CGFloat(index) * step + (step - barWidth) / 2,
                                  y: (size.height - height) / 2,
                                  width: barWidth,
                                  height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(.accentColor.opacity(0.9)))
            }
        }
    }
}
