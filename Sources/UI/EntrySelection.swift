import Foundation

/// The entry list's selection: one focused entry (the card, the keyboard cursor) plus, with ⌘/⇧-clicks,
/// more entries for bulk actions. A selection never spans databases.
struct EntrySelection: Equatable {
    /// Every selected entry, the focused one included.
    private(set) var ids: Set<UUID> = []
    /// The entry the card shows and arrow keys move from.
    private(set) var focus: UUID?
    /// Where ⇧-click and ⇧-arrow ranges start.
    private(set) var anchor: UUID?

    init(focus: UUID? = nil) {
        select(focus)
    }

    var isMultiple: Bool {
        ids.count > 1
    }

    func contains(_ id: UUID) -> Bool {
        ids.contains(id)
    }

    /// The selected entries in list order.
    func ordered(in order: [UUID]) -> [UUID] {
        order.filter(ids.contains)
    }

    /// A plain click: just this entry.
    mutating func select(_ id: UUID?) {
        ids = id.map { [$0] } ?? []
        focus = id
        anchor = id
    }

    /// ⌘-click: adds or removes the entry. An entry of another database starts a new selection.
    mutating func toggle(_ id: UUID, database: (UUID) -> String?) {
        guard let focus, database(id) == database(focus) else {
            select(id)
            return
        }
        if ids.contains(id) {
            guard ids.count > 1 else {
                return
            }
            ids.remove(id)
            if focus == id {
                self.focus = ids.first
            }
            if anchor == id {
                anchor = self.focus
            }
        } else {
            ids.insert(id)
            self.focus = id
            anchor = id
        }
    }

    /// ⇧-click and ⇧-arrow: everything between the anchor and the entry, in list order,
    /// skipping entries of other databases. The anchor stays.
    mutating func extend(to id: UUID, in order: [UUID], database: (UUID) -> String?) {
        guard let anchor, database(id) == database(anchor),
              let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
            select(id)
            return
        }
        let key = database(anchor)
        ids = Set(order[min(from, to)...max(from, to)].filter { database($0) == key })
        focus = id
    }

    /// ⌘A: every entry in the list of the focused entry's database.
    mutating func selectAll(in order: [UUID], database: (UUID) -> String?) {
        guard let first = focus ?? order.first else {
            return
        }
        let key = database(first)
        ids = Set(order.filter { database($0) == key })
        focus = first
        anchor = anchor ?? first
    }

    /// Esc: back to the focused entry alone.
    mutating func collapse() {
        select(focus)
    }

    /// Drops entries no longer in the list (search, sidebar, merges). Returns false when the focus went too,
    /// so the caller can pick a new one.
    @discardableResult
    mutating func trim(to visible: [UUID]) -> Bool {
        let visibleSet = Set(visible)
        ids.formIntersection(visibleSet)
        if let anchor, !visibleSet.contains(anchor) {
            self.anchor = nil
        }
        guard let focus, visibleSet.contains(focus) else {
            focus = visible.first(where: ids.contains)
            anchor = anchor ?? focus
            return focus != nil
        }
        return true
    }
}
