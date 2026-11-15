import AppKit
import SwiftUI

/// Side of the bubble where its anchor (a Dock icon, a ⌘Tab icon) sits; the tip points that way.
nonisolated enum BubbleEdge { case bottom, left, right }

/// A bubble with a tip pointing at an app icon, showing that app's window thumbnails.
/// Shared by Glance (Dock) and Switch (system ⌘Tab).
final class WindowBubble {
    let model = BubbleModel()
    private(set) lazy var panel: CursorPanel = {
        let panel = CursorPanel(contentView: BubbleHostingView(rootView: BubbleView(model: model)))
        panel.hasShadow = false // the bubble draws its own
        return panel
    }()
    /// Bumped on every show/hide so stale async loads stop.
    private var generation = 0
    private var anchor = CGRect.zero
    /// Thumbnails survive between shows of the same window (no flicker while cycling ⌘Tab).
    private var cache: [CGWindowID: CGImage] = [:]

    private static let gap: CGFloat = 6

    var isVisible: Bool { panel.isVisible }

    /// Loads `app`'s windows and shows them next to `anchor` (AppKit coordinates).
    /// Windows that can't be captured (other Spaces, invisible helpers) are left out.
    /// `takesKeyboard`: make the bubble key once visible (Glance's type-to-filter).
    func show(_ app: NSRunningApplication, anchor: CGRect, edge: BubbleEdge, takesKeyboard: Bool = false) async {
        generation += 1
        let token = generation
        self.anchor = anchor
        guard let windows = try? await WindowCatalog.windows(of: [app.processIdentifier]), token == generation else { return }
        let shown = windows.filter(\.isShowable)
            .map { window -> CatalogWindow in
                var window = window
                window.image = cache[window.id]
                return window
            }
        guard !shown.isEmpty else { return hide() }
        model.load(appName: app.localizedName ?? "", windows: shown, edge: edge)
        place()
        if takesKeyboard { panel.makeKey() }
        for window in shown where window.image == nil {
            let image = await WindowCatalog.thumbnail(window.scWindow, maxWidth: 320)
            guard token == generation else { return }
            if let image {
                cache[window.id] = image
                model.setImage(image, for: window.id)
            } else {
                remove(window.id)
            }
        }
    }

    func remove(_ id: CGWindowID) {
        model.remove(id)
        if model.windows.isEmpty { hide() } else { place() }
    }

    func hide() {
        generation += 1
        panel.orderOut(nil)
        model.filter = ""
    }

    /// Clears cached thumbnails (call when a session ends, so the next one is fresh).
    func flush() { cache.removeAll() }

    /// Next to the anchor, on the far side from it, never over it; the tip aims at the anchor's center
    /// even when the panel is clamped to the screen.
    func place() {
        let size = panel.contentView?.fittingSize ?? .zero
        let g = Self.gap
        let center: CGPoint = switch model.edge {
        case .bottom: CGPoint(x: anchor.midX, y: anchor.maxY + g + size.height / 2)
        case .left: CGPoint(x: anchor.maxX + g + size.width / 2, y: anchor.midY)
        case .right: CGPoint(x: anchor.minX - g - size.width / 2, y: anchor.midY)
        }
        panel.show(centeredAt: center)
        model.tipOffset = model.edge == .bottom
            ? anchor.midX - panel.frame.minX
            : panel.frame.maxY - anchor.midY // SwiftUI is top-left origin
    }
}

// MARK: - Model & view

@Observable
final class BubbleModel {
    private(set) var appName = ""
    private(set) var windows: [CatalogWindow] = []
    private(set) var edge = BubbleEdge.bottom
    /// Tip position along the edge facing the anchor (points from the panel's left, or from its top).
    var tipOffset: CGFloat = 0
    var filter = ""
    var onRaise: ((CatalogWindow) -> Void)?
    var onClose: ((CatalogWindow) -> Void)?

    var visible: [CatalogWindow] {
        filter.isEmpty ? windows : windows.filter { $0.title.localizedCaseInsensitiveContains(filter) }
    }

    func load(appName: String, windows: [CatalogWindow], edge: BubbleEdge) {
        self.appName = appName
        self.windows = windows
        self.edge = edge
    }

    func setImage(_ image: CGImage, for id: CGWindowID) {
        if let i = windows.firstIndex(where: { $0.id == id }) { windows[i].image = image }
    }

    func remove(_ id: CGWindowID) { windows.removeAll { $0.id == id } }
}

private final class BubbleHostingView: NSHostingView<BubbleView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Rounded rectangle with a triangular tip on the side facing the anchor.
nonisolated private struct BubbleShape: Shape {
    let edge: BubbleEdge
    let tip: CGFloat
    static let tipSize: CGFloat = 9
    static let radius: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        let t = Self.tipSize
        var body = rect
        switch edge {
        case .bottom: body.size.height -= t
        case .left: body.origin.x += t; body.size.width -= t
        case .right: body.size.width -= t
        }
        var path = Path(roundedRect: body, cornerRadius: Self.radius)
        let lo = Self.radius + t
        switch edge {
        case .bottom:
            let x = min(max(tip, lo), rect.width - lo)
            path.move(to: CGPoint(x: x - t, y: body.maxY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + t, y: body.maxY))
        case .left:
            let y = min(max(tip, lo), rect.height - lo)
            path.move(to: CGPoint(x: body.minX, y: y - t))
            path.addLine(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: body.minX, y: y + t))
        case .right:
            let y = min(max(tip, lo), rect.height - lo)
            path.move(to: CGPoint(x: body.maxX, y: y - t))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            path.addLine(to: CGPoint(x: body.maxX, y: y + t))
        }
        path.closeSubpath()
        return path
    }
}

private struct BubbleView: View {
    let model: BubbleModel
    private static let thumb = CGSize(width: 180, height: 112)
    private static let maxVisible = 4
    private static let shadowRoom: CGFloat = 10

    var body: some View {
        let t = BubbleShape.tipSize
        let shape = BubbleShape(edge: model.edge, tip: model.tipOffset - Self.shadowRoom)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.appName).font(.headline)
                if !model.filter.isEmpty {
                    Label(model.filter, systemImage: "magnifyingglass").font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.visible) { thumbnail($0) }
                }
            }
            .frame(width: CGFloat(min(max(model.windows.count, 1), Self.maxVisible)) * (Self.thumb.width + 10) - 10)
        }
        .padding(12)
        // Room for the tip on the anchor side.
        .padding(.bottom, model.edge == .bottom ? t : 0)
        .padding(.leading, model.edge == .left ? t : 0)
        .padding(.trailing, model.edge == .right ? t : 0)
        .background(.regularMaterial, in: shape)
        .overlay(shape.stroke(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .padding(Self.shadowRoom)
    }

    private func thumbnail(_ window: CatalogWindow) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = window.image {
                        Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    }
                }
                .frame(width: Self.thumb.width, height: Self.thumb.height)
                .opacity(window.minimized ? 0.55 : 1)
                if window.minimized {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.yellow).padding(4)
                }
            }
            Text(window.title).font(.caption).lineLimit(1).frame(width: Self.thumb.width)
        }
        .overlay(ClickCatcher(onLeft: { model.onRaise?(window) }, onMiddle: { model.onClose?(window) }))
    }
}

/// SwiftUI has no middle-click gesture: a transparent NSView catches left and middle clicks.
private struct ClickCatcher: NSViewRepresentable {
    let onLeft: () -> Void
    let onMiddle: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) {
        view.onLeft = onLeft
        view.onMiddle = onMiddle
    }

    final class CatcherView: NSView {
        var onLeft: (() -> Void)?
        var onMiddle: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onLeft?() }
        override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { onMiddle?() } }
        override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) } // let the strip scroll
    }
}
