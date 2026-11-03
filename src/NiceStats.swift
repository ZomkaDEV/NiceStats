import SwiftUI
import AppKit

@main struct NiceStats: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    var body: some Scene { Settings { EmptyView() } }
}

final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let sampler = Sampler()
    private var item: NSStatusItem!
    private let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private var host: NSHostingView<PanelRoot>!
    private var outside: Any?
    private var page: Page?
    private let state = PanelState()
    private var navigating = false
    private var scrollMonitor: Any?
    private var swipe = 0.0
    private var dragging = false
    private var anim: Timer?
    private var iconKey = ""

    func applicationDidFinishLaunching(_: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(click)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let blur = NSVisualEffectView()
        blur.material = .menu; blur.blendingMode = .behindWindow; blur.state = .active
        blur.maskImage = Self.roundedMask(radius: 20)
        panel.contentView = blur
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .statusBar; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        item.button?.imagePosition = .imageOnly
        sampler.onTick = { [weak self] in self?.refreshIcon() }
        state.onEditing = { [weak self] in self?.sampler.paused = $0 }
        refreshIcon()
    }

    /// macbook trackpad supremacy
    private func scroll(_ e: NSEvent) {
        if e.phase == .began { swipe = 0; dragging = false }
        if !dragging {
            guard page != nil, !navigating, e.phase == .changed || e.phase == .began, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return }
            dragging = true
        }
        if e.phase == .changed || e.phase == .began {
            swipe = max(0, swipe + (e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX))
            let w = host.frame.width
            host.frame.origin.x = swipe
            host.alphaValue = max(0, 1 - swipe / (w * 0.8))
        } else if e.phase == .ended || e.phase == .cancelled {
            dragging = false
            let from = swipe, w = host.frame.width, fromAlpha = host.alphaValue
            if from > 70 {
                navigating = true
                animate(0.15, { [self] t, _ in host.frame.origin.x = from + (w - from) * CGFloat(t); host.alphaValue = fromAlpha * (1 - t) },
                        done: { [self] in navigating = false; navigate(nil, fadeIn: 0.07) })
            } else {
                navigating = true
                animate(0.2, { [self] t, _ in host.frame.origin.x = from * (1 - CGFloat(t)); host.alphaValue = fromAlpha + (1 - fromAlpha) * t },
                        done: { [self] in navigating = false; contentResized(host.fittingSize) })
            }
            swipe = 0
        }
    }

    private func fit() {
        let s = host.fittingSize
        host.frame = NSRect(x: 0, y: panel.contentView!.bounds.height - s.height, width: s.width, height: s.height)
    }

    private func root() -> PanelRoot { PanelRoot(sampler: sampler, state: state, page: page, onSelect: { [weak self] in self?.navigate($0) }, onSize: { [weak self] in self?.contentResized($0) }) }

    private static func roundedMask(radius r: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill(); NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill(); return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r); img.resizingMode = .stretch
        return img
    }

    private func refreshIcon() {
        let b = sampler.s.battery, low = ProcessInfo.processInfo.isLowPowerModeEnabled
        let key = "\(b.percent) \(b.charging) \(b.onAC) \(low) \(item.button?.effectiveAppearance.name.rawValue ?? "")"
        guard key != iconKey else { return }
        iconKey = key
        item.button?.image = batteryIcon(percent: b.percent, charging: b.charging, plugged: b.onAC)
    }

    @objc private func click() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let m = NSMenu()
            m.addItem(withTitle: String(localized: "Edit layout"), action: #selector(startEditing), keyEquivalent: "").target = self
            m.addItem(withTitle: String(localized: "Reset layout"), action: #selector(resetLayout), keyEquivalent: "").target = self
            let pin = NSMenuItem(title: String(localized: "Pin panel"), action: #selector(togglePin), keyEquivalent: "")
            pin.target = self; pin.state = state.pinned ? .on : .off
            m.addItem(pin)
            m.addItem(.separator())
            m.addItem(withTitle: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = m; item.button?.performClick(nil); item.menu = nil
        } else if panel.isVisible { hide() } else { show() }
    }

    @objc private func resetLayout() {
        let a = NSAlert()
        a.messageText = String(localized: "Reset layout?")
        a.informativeText = String(localized: "This puts every stat back to its default style and position.")
        a.addButton(withTitle: String(localized: "Reset"))
        a.addButton(withTitle: String(localized: "Cancel"))
        a.buttons[0].hasDestructiveAction = true
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn { UserDefaults.standard.removeObject(forKey: StatLayout.key) }
    }

    @objc private func togglePin() { state.pinned.toggle() }

    @objc private func startEditing() {
        if panel.isVisible { navigate(nil) } else { show() }
        state.editing = true
    }

    private func frame(for size: CGSize) -> NSRect {
        guard let w = item.button?.window else { return .zero }
        let r = w.frame, screen = w.screen?.visibleFrame ?? .zero
        let x = min(max(r.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        return NSRect(x: x, y: r.minY - 6 - size.height, width: size.width, height: size.height)
    }

    private func show() {
        cancelAnimation()
        sampler.visible = true; sampler.refreshPanel()
        page = nil
        host = NSHostingView(rootView: root())
        host.autoresizingMask = [.minYMargin]
        panel.contentView?.addSubview(host)
        panel.setFrame(frame(for: host.fittingSize), display: false)
        fit()
        host.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in self?.scroll(e); return e }
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.state.pinned == true || self?.state.editing == true { return }
            if let w = self?.item.button?.window, w.frame.contains(NSEvent.mouseLocation) { return }
            self?.hide()
        }
    }

    private func hide() {
        state.editing = false
        if let o = outside { NSEvent.removeMonitor(o); outside = nil }
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        cancelAnimation()
        sampler.visible = false
        panel.orderOut(nil)
        host?.removeFromSuperview(); host = nil
    }

    private func cancelAnimation() {
        anim?.invalidate(); anim = nil
        navigating = false; dragging = false; swipe = 0
    }

    private func animate(_ duration: Double, _ step: @escaping (_ eased: Double, _ raw: Double) -> Void, done: @escaping () -> Void) {
        let start = CACurrentMediaTime()
        anim = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { t in
            let x = min(1, (CACurrentMediaTime() - start) / duration)
            step(x * x * (3 - 2 * x), x)
            if x >= 1 { t.invalidate(); done() }
        }
    }

    private func contentResized(_ size: CGSize) {
        DispatchQueue.main.async { [self] in
            guard panel.isVisible, !navigating, !dragging, abs(size.height - panel.frame.height) > 1 else { return }
            panel.setFrame(frame(for: size), display: true); fit()
        }
    }

    private func navigate(_ p: Page?, fadeIn: Double = 0.15) {
        guard !navigating, !dragging else { return }
        navigating = true
        page = p
        let startAlpha = host.alphaValue
        let next = root(), from = panel.frame, to = frame(for: NSHostingView(rootView: next).fittingSize)
        func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
        animate(0.25, { [self] t, raw in
            host.alphaValue = min(startAlpha, max(0, 1 - raw / 0.4))
            panel.setFrame(NSRect(x: lerp(from.minX, to.minX, t), y: lerp(from.minY, to.minY, t), width: lerp(from.width, to.width, t), height: lerp(from.height, to.height, t)), display: true)
        }, done: { [self] in
            host.rootView = next
            panel.setFrame(frame(for: host.fittingSize), display: true); fit()
            animate(fadeIn, { [self] t, _ in host.alphaValue = t }, done: { [self] in navigating = false; contentResized(host.fittingSize) })
        })
    }
}
