import Foundation

/// Persist the expanded order while preserving edits to the visible toolbar.
enum SidebarToolbarItemOrder {
    static func complete(_ identifiers: [String],
                         removedPlacement: (index: Int, hasSpacer: Bool)?) -> [String] {
        guard let placement = removedPlacement,
              !identifiers.contains("SidebarMode") else { return identifiers }
        var complete = identifiers
        let index = min(max(0, placement.index), complete.count)
        complete.insert("SidebarMode", at: index)
        if placement.hasSpacer {
            complete.insert("NSToolbarFlexibleSpaceItem", at: index + 1)
        }
        return complete
    }
}
