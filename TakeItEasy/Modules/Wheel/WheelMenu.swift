import AppKit
import SwiftUI

struct WheelItem {
    let title: String
    let symbol: String
    var children: [WheelItem] = []
    /// Disabled items keep their slot (stable positions = muscle memory) but are dimmed and can't be chosen.
    var isEnabled = true
    var action: (() -> Void)?
}

/// Radial menu centered on the cursor. Selection is by direction: only the angle matters,
/// so a small mouse movement is enough. Center = cancel. Hovering an item with children opens a sub-ring.
///
/// Two ways to use it: hold the trigger, move, release (hold mode); or click the trigger, move, click.
final class WheelMenu {
    private let model: WheelModel
    private let panel: CursorPanel
    private var timer: Timer?
    private var globalMonitor: Any?
    private var holdMode: Bool
    /// Cursor left the dead zone at least once: releasing in the center then means "cancel", not "stay open".
    private var movedOut = false
    private var hoverStart = Date()
    private var screenCenter = CGPoint.zero
    var onClose: (() -> Void)?

    init(items: [WheelItem], holdMode: Bool) {
        self.holdMode = holdMode
        model = WheelModel(items: items)
        let view = WheelHostingView(rootView: WheelView(model: model))
        panel = CursorPanel(contentView: view)
        panel.hasShadow = false // the wheel draws its own
        view.onClick = { [weak self] in self?.commit() }
        view.onEscape = { [weak self] in self?.close() }
    }

    func show() {
        panel.showAtCursor()
        screenCenter = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.makeKey()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        // A click on another display or outside the wheel closes it.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    /// The physical trigger (e.g. middle button) was released.
    func triggerReleased() {
        guard holdMode else { return }
        holdMode = false
        if movedOut { commit() } // otherwise it was a quick click: stay open in click mode
    }

    /// Click (or release) on the current highlight.
    func commit() {
        if let parent = model.expanded, let child = model.highlightedChild {
            return finish(model.items[parent].children[child].action)
        }
        guard let index = model.highlighted else { return close() }
        let item = model.items[index]
        if item.children.isEmpty {
            finish(item.action)
        } else {
            model.expanded = index // releasing on a parent opens its sub-ring and keeps the wheel open
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        panel.orderOut(nil)
        let onClose = onClose
        self.onClose = nil
        onClose?()
    }

    private func finish(_ action: (() -> Void)?) {
        close()
        action?()
    }

    // ponytail: polling at 60 Hz instead of mouse-moved events; works the same whether the trigger
    // is held (drag events go elsewhere) or not, and only runs while the wheel is open.
    private func track() {
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - screenCenter.x, dy = mouse.y - screenCenter.y
        let distance = hypot(dx, dy)
        guard distance >= WheelGeometry.deadZone else {
            model.highlighted = nil
            model.highlightedChild = nil
            return
        }
        movedOut = true
        let angle = WheelGeometry.angle(dx: dx, dy: dy)

        if let parent = model.expanded, distance > WheelGeometry.ringOuter {
            let parentAngle = WheelGeometry.sliceAngle(parent, count: model.items.count)
            let children = model.items[parent].children
            let child = WheelGeometry.child(at: angle, count: children.count, parent: parentAngle)
            model.highlighted = parent
            model.highlightedChild = children[child].isEnabled ? child : nil
            return
        }

        model.highlightedChild = nil
        let index = WheelGeometry.slice(at: angle, count: model.items.count)
        guard model.items[index].isEnabled else {
            // Like the center: nothing highlighted, so release/click cancels.
            model.highlighted = nil
            model.expanded = nil
            return
        }
        if index != model.highlighted {
            model.highlighted = index
            hoverStart = Date()
            if model.expanded != index { model.expanded = nil }
        }
        let hasChildren = !model.items[index].children.isEmpty
        if hasChildren, model.expanded != index,
           distance > WheelGeometry.ringOuter || Date().timeIntervalSince(hoverStart) > 0.35 {
            model.expanded = index
        }
    }
}

@Observable
private final class WheelModel {
    let items: [WheelItem]
    var highlighted: Int?
    var highlightedChild: Int?
    var expanded: Int?

    init(items: [WheelItem]) { self.items = items }
}

/// Hosting view that turns any mouse button into a commit and Esc into cancel.
private final class WheelHostingView: NSHostingView<WheelView> {
    var onClick: (() -> Void)?
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
    override func otherMouseDown(with event: NSEvent) { onClick?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) } // 53 = Esc
    }
}

private struct WheelView: View {
    let model: WheelModel
    private static let size = (WheelGeometry.subOuter + 8) * 2

    var body: some View {
        let c = CGPoint(x: Self.size / 2, y: Self.size / 2)
        let count = model.items.count
        let step = 360 / Double(count)
        ZStack {
            ForEach(model.items.indices, id: \.self) { i in
                let mid = WheelGeometry.sliceAngle(i, count: count)
                sector(c, mid - step / 2, mid + step / 2, WheelGeometry.deadZone + 2, WheelGeometry.ringOuter,
                       highlighted: model.highlighted == i && model.highlightedChild == nil,
                       enabled: model.items[i].isEnabled)
                label(model.items[i], at: point(c, mid, (WheelGeometry.deadZone + WheelGeometry.ringOuter) / 2),
                      highlighted: model.highlighted == i && model.highlightedChild == nil,
                      hasChildren: !model.items[i].children.isEmpty)
            }
            if let parent = model.expanded {
                let children = model.items[parent].children
                let parentAngle = WheelGeometry.sliceAngle(parent, count: count)
                let half = WheelGeometry.childStep / 2
                ForEach(children.indices, id: \.self) { j in
                    let mid = WheelGeometry.childAngle(j, count: children.count, parent: parentAngle)
                    sector(c, mid - half, mid + half, WheelGeometry.subInner, WheelGeometry.subOuter,
                           highlighted: model.highlightedChild == j, enabled: children[j].isEnabled)
                    label(children[j], at: point(c, mid, (WheelGeometry.subInner + WheelGeometry.subOuter) / 2),
                          highlighted: model.highlightedChild == j, hasChildren: false)
                }
            }
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.highlighted == nil ? .primary : .secondary)
                .frame(width: WheelGeometry.deadZone * 2 - 4, height: WheelGeometry.deadZone * 2 - 4)
                .background(.regularMaterial, in: Circle())
                .position(c)
        }
        .frame(width: Self.size, height: Self.size)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .animation(.easeOut(duration: 0.12), value: model.expanded)
    }

    private func sector(_ c: CGPoint, _ a0: Double, _ a1: Double, _ inner: Double, _ outer: Double,
                        highlighted: Bool, enabled: Bool) -> some View {
        let path = Path { p in
            let gap = 0.8 // degrees between slices
            let steps = 24
            let from = a0 + gap, to = a1 - gap
            for k in 0...steps { // outer arc
                let pt = point(c, from + (to - from) * Double(k) / Double(steps), outer)
                k == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            for k in (0...steps).reversed() { // inner arc back
                p.addLine(to: point(c, from + (to - from) * Double(k) / Double(steps), inner))
            }
            p.closeSubpath()
        }
        return ZStack {
            path.fill(.regularMaterial).opacity(enabled ? 1 : 0.55)
            if highlighted { path.fill(Color.accentColor) }
        }
    }

    private func label(_ item: WheelItem, at p: CGPoint, highlighted: Bool, hasChildren: Bool) -> some View {
        VStack(spacing: 2) {
            Image(systemName: item.symbol).font(.system(size: 16, weight: .medium))
            Text(item.title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
            if hasChildren { Image(systemName: "ellipsis").font(.system(size: 8)).opacity(0.6) }
        }
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .opacity(item.isEnabled ? 1 : 0.3)
        .frame(width: 64)
        .position(p)
    }

    /// SwiftUI is y-down, so the clockwise-from-top angle maps to (sin, -cos).
    private func point(_ c: CGPoint, _ angle: Double, _ r: Double) -> CGPoint {
        let rad = angle * .pi / 180
        return CGPoint(x: c.x + r * sin(rad), y: c.y - r * cos(rad))
    }
}
