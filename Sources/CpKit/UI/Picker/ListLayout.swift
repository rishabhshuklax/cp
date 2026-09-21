import CoreGraphics

/// Which edge a row should be brought to when it is out of view.
public enum ScrollAnchor: Equatable, Sendable {
    case top
    case bottom
}

/// Where each row sits in the list, and whether the list has to move at all.
///
/// This is the piece that made the old picker feel broken. It re-centred the
/// selection on every arrow key, so the list slid a row under the pointer and
/// the next click pasted something the user had never looked at. Here the list
/// moves only when the selection has actually left the viewport, and then by
/// the smallest amount that brings it back.
public struct ListLayout: Equatable, Sendable {

    private let heights: [CGFloat]
    private let offsets: [CGFloat]
    public let contentHeight: CGFloat

    public init(itemHeights: [CGFloat], topPadding: CGFloat = 0, bottomPadding: CGFloat = 0) {
        var offsets: [CGFloat] = []
        offsets.reserveCapacity(itemHeights.count)
        var y = topPadding
        for height in itemHeights {
            offsets.append(y)
            y += height
        }
        self.heights = itemHeights
        self.offsets = offsets
        self.contentHeight = y + bottomPadding
    }

    public var count: Int { heights.count }

    public func offset(of index: Int) -> CGFloat {
        guard heights.indices.contains(index) else { return 0 }
        return offsets[index]
    }

    /// `nil` when the row is already fully visible — which is the common case,
    /// and the one where scrolling would be wrong.
    public func anchor(for index: Int, viewportTop: CGFloat, viewportHeight: CGFloat) -> ScrollAnchor? {
        guard heights.indices.contains(index), viewportHeight > 0 else { return nil }
        let top = offsets[index]
        let bottom = top + heights[index]
        // A row taller than the viewport can only be shown from its top.
        if top < viewportTop { return .top }
        if bottom > viewportTop + viewportHeight { return .bottom }
        return nil
    }
}
