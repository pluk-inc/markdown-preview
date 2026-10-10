import Foundation

/// Persist the expanded order while preserving edits to the visible toolbar.
enum SidebarToolbarItemOrder {
    struct Placement {
        let index: Int
        let hasSpacer: Bool
        private let preceding: [String]
        private let following: [String]

        init(index: Int, hasSpacer: Bool, identifiers: [String] = []) {
            self.index = index
            self.hasSpacer = hasSpacer
            preceding = Array(identifiers.prefix(index).reversed())
            following = Array(identifiers.dropFirst(index + (hasSpacer ? 2 : 1)))
        }

        /// Repeated space identifiers are not reliable anchors. Prefer the
        /// next surviving control, then the previous control, then the index.
        func insertionIndex(in identifiers: [String]) -> Int {
            if preceding.count == index, identifiers.starts(with: preceding.reversed()) {
                return index
            }
            let spaces = ["NSToolbarFlexibleSpaceItem", "NSToolbarSpaceItem"]
            for anchor in following where !spaces.contains(anchor) {
                if let index = identifiers.firstIndex(of: anchor) { return index }
            }
            for anchor in preceding where !spaces.contains(anchor) {
                if let index = identifiers.lastIndex(of: anchor) { return index + 1 }
            }
            return min(max(0, index), identifiers.count)
        }
    }

    static func complete(_ identifiers: [String],
                         removedPlacement: Placement?) -> [String] {
        guard let placement = removedPlacement,
              !identifiers.contains("SidebarMode") else { return identifiers }
        var complete = identifiers
        let index = placement.insertionIndex(in: complete)
        complete.insert("SidebarMode", at: index)
        if placement.hasSpacer {
            complete.insert("NSToolbarFlexibleSpaceItem", at: index + 1)
        }
        return complete
    }
}
