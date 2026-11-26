import AppKit
import Combine
import SwiftUI

private indirect enum BrowserSplit: Sendable {
    case pane(UUID)
    case split(Axis, BrowserSplit, BrowserSplit)

    func axes(for id: UUID) -> Set<Axis>? {
        switch self {
        case .pane(let pane):
            return pane == id ? [] : nil
        case .split(let axis, let first, let second):
            return (first.axes(for: id) ?? second.axes(for: id))?.union([axis])
        }
    }

    func inserting(_ id: UUID, nextTo active: UUID, on axis: Axis) -> Self {
        switch self {
        case .pane(let pane):
            return pane == active ? .split(axis, self, .pane(id)) : self
        case .split(let currentAxis, let first, let second):
            return .split(currentAxis, first.inserting(id, nextTo: active, on: axis),
                          second.inserting(id, nextTo: active, on: axis))
        }
    }

    func removing(_ id: UUID) -> Self? {
        switch self {
        case .pane(let pane):
            return pane == id ? nil : self
        case .split(let axis, let first, let second):
            let left = first.removing(id)
            let right = second.removing(id)
            if let left, let right { return .split(axis, left, right) }
            return left ?? right
        }
    }

    func place(in rect: CGRect, frames: inout [UUID: CGRect]) {
        switch self {
        case .pane(let id):
            frames[id] = rect
        case .split(let axis, let first, let second):
            let span = axis == .horizontal ? rect.width : rect.height
            let half = floor(max(0, span - 1) / 2)
            let edge: CGRectEdge = axis == .horizontal ? .minXEdge : .minYEdge
            let (leading, remainder) = rect.divided(atDistance: half, from: edge)
            let (_, trailing) = remainder.divided(atDistance: min(1, span), from: edge)
            first.place(in: leading, frames: &frames)
            second.place(in: trailing, frames: &frames)
        }
    }
}

@MainActor
final class BrowserPanes: ObservableObject {
    struct Pane: Identifiable {
        let id = UUID()
        let model: Workspace
        let inspector: PaneInspectorState
    }

    @Published private(set) var panes: [Pane]
    @Published private(set) var active: Pane
    fileprivate var arrangement: BrowserSplit
    private var activeUpdates: AnyCancellable?

    init(model: Workspace) {
        let first = Pane(model: model, inspector: PaneInspectorState(isVisible: true))
        active = first
        panes = [first]
        arrangement = .pane(first.id)
        observeActive()
    }

    var isSplit: Bool { panes.count > 1 }

    func activate(_ pane: Pane) {
        guard active.id != pane.id, panes.contains(where: { $0.id == pane.id }) else { return }
        active = pane
        observeActive()
    }

    func canSplit(_ axis: Axis) -> Bool {
        arrangement.axes(for: active.id)?.contains(axis) == false
    }

    @discardableResult
    func split(_ axis: Axis) -> Bool {
        guard canSplit(axis), let index = panes.firstIndex(where: { $0.id == active.id }) else { return false }
        let pane = Pane(model: active.model.duplicateBrowser(), inspector: PaneInspectorState(isVisible: false))
        arrangement = arrangement.inserting(pane.id, nextTo: active.id, on: axis)
        panes.insert(pane, at: index + 1)
        activate(pane)
        return true
    }

    func close(_ pane: Pane) {
        guard isSplit, let index = panes.firstIndex(where: { $0.id == pane.id }),
              let remaining = arrangement.removing(pane.id) else { return }
        arrangement = remaining
        panes.remove(at: index)
        if active.id == pane.id { activate(panes[min(index, panes.count - 1)]) }
        pane.model.closeBrowser()
    }

    private func observeActive() {
        guard active.model !== active.model.transferQueue else {
            activeUpdates = nil
            return
        }
        activeUpdates = active.model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

struct BrowserPaneGrid<Content: View>: View {
    let layout: BrowserPanes
    @ViewBuilder let content: (BrowserPanes.Pane) -> Content

    var body: some View {
        SplitLayout(arrangement: layout.arrangement, ids: layout.panes.map(\.id)) {
            ForEach(layout.panes, content: content)
        }.background(Color(nsColor: .separatorColor))
    }
}

private struct SplitLayout: Layout {
    let arrangement: BrowserSplit
    let ids: [UUID]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 670, height: 540))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var frames: [UUID: CGRect] = [:]
        arrangement.place(in: bounds, frames: &frames)
        for (id, subview) in zip(ids, subviews) {
            guard let frame = frames[id] else { continue }
            subview.place(at: frame.origin, anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
