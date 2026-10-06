import Foundation

/// A `List` or `Grid`'s `pagination` prop: whether more exists, and the handler that loads it.
struct ExtensionPagination: Equatable, Sendable {
    /// The API types `pageSize` as required; this stands in only when a bundle omits it anyway.
    static let defaultPageSize = 20

    let hasMore: Bool
    let pageSize: Int
    let handler: String?

    init(hasMore: Bool, pageSize: Int, handler: String?) {
        self.hasMore = hasMore
        self.pageSize = max(1, pageSize)
        self.handler = handler
    }

    init?(_ prop: [String: RenderValue]?) {
        guard let prop else { return nil }
        self.init(
            hasMore: prop["hasMore"]?.boolValue ?? false,
            pageSize: prop["pageSize"]?.doubleValue.map { Int($0) } ?? Self.defaultPageSize,
            handler: prop["onLoadMore"]?.handlerID)
    }

    /// Half a page before the end, so the next one is usually there before it is scrolled to.
    func triggerIndex(itemCount: Int) -> Int {
        max(0, itemCount - max(1, pageSize / 2))
    }

    /// How far the user has reached, and which item count already asked for the next page.
    struct Latch: Equatable, Sendable {
        private var handler: String?
        private var reach = -1
        private var requestedCount: Int?
        private var lastCount = 0

        /// `index` is a row just reached, or nil to re-ask after a load settles with rows in view.
        mutating func shouldLoad(
            _ pagination: ExtensionPagination, reaching index: Int?, itemCount: Int, isLoading: Bool
        ) -> Bool {
            // A new list, or one that shrank for a new search, starts over from its top.
            if pagination.handler != handler || itemCount < lastCount {
                self = Latch()
                handler = pagination.handler
            }
            lastCount = itemCount
            if let index { reach = max(reach, min(index, itemCount - 1)) }
            guard pagination.hasMore, pagination.handler != nil, !isLoading, itemCount > 0,
                requestedCount != itemCount,
                reach >= pagination.triggerIndex(itemCount: itemCount)
            else { return false }
            requestedCount = itemCount
            return true
        }
    }
}
