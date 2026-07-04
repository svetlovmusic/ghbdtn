import AppKit
import SwiftUI

/// Small floating overlay for the on-demand correction: a spinner while the
/// model works, and a readable message if it fails (no key, quota/out of money,
/// network, API error). Mirrors DictationHUDPanel — it must NEVER take key
/// focus, or it would pull the caret out of the field being corrected.
@MainActor
final class RecoveryHUD {
    static let shared = RecoveryHUD()

    enum State: Equatable {
        case working
        case error(String)
    }

    final class Model: ObservableObject {
        @Published var state: State = .working
    }

    private let model = Model()
    private var panel: RecoveryHUDPanel?
    private var hideWork: DispatchWorkItem?

    private init() {}

    /// Show the "working…" spinner.
    func working() {
        hideWork?.cancel(); hideWork = nil
        model.state = .working
        present()
    }

    /// Show an error message; auto-dismiss after a few seconds.
    func fail(_ message: String) {
        hideWork?.cancel()
        model.state = .error(message)
        present()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    /// Dismiss immediately (success / nothing to do).
    func hide() {
        hideWork?.cancel(); hideWork = nil
        panel?.orderOut(nil)
    }

    private func present() {
        let p: RecoveryHUDPanel
        if let existing = panel {
            p = existing
        } else {
            p = RecoveryHUDPanel(model: model)
            panel = p
        }
        p.fitToContent()
        p.positionNearMouse()
        p.orderFrontRegardless()
    }
}

final class RecoveryHUDPanel: NSPanel {
    private let hosting: NSHostingView<RecoveryHUDView>

    init(model: RecoveryHUD.Model) {
        hosting = NSHostingView(rootView: RecoveryHUDView(model: model))
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
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        hosting.setFrameSize(hosting.fittingSize)
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }

    // Never key/main: either would steal the caret from the field being fixed.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Re-measure after the state (and thus the message width) changes.
    func fitToContent() {
        hosting.layoutSubtreeIfNeeded()
        setContentSize(hosting.fittingSize)
    }

    /// Place the bubble next to the mouse cursor, clamped on-screen.
    func positionNearMouse() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let size = frame.size
        let gap: CGFloat = 18
        var origin = NSPoint(x: mouse.x + gap, y: mouse.y - size.height / 2)
        if origin.x + size.width > visible.maxX - 8 {
            origin.x = mouse.x - gap - size.width
        }
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
        origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - size.height - 8))
        setFrameOrigin(origin)
    }
}

struct RecoveryHUDView: View {
    @ObservedObject var model: RecoveryHUD.Model

    var body: some View {
        HStack(spacing: 10) {
            switch model.state {
            case .working:
                ProgressView().controlSize(.small)
                Text("Исправляю…")
                    .font(.system(size: 13, weight: .medium))
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280, alignment: .leading)
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
}
