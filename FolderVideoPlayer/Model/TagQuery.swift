import Foundation

/// Several library names combined into one playlist — ⌘-clicked in the library
/// panel: videos carrying ANY of them, or ALL of them.
///
/// A name is anything a sidebar row plays: a tag, a star rating (stars are
/// tags), a named person (people are tags) or a reading off the file. The query
/// only holds the names and how they combine; which videos carry a name is the
/// library's answer (`Library.paths(matching:)`), so a query never goes stale
/// the way a stored list of videos would.
///
/// Distinct from the playlist's own tag filter: that narrows the list already
/// open, this builds the list from the whole profile.
struct TagQuery: Equatable {
    enum Match: String, CaseIterable, Identifiable {
        /// At least one of the names — the default, because "these and these"
        /// in ordinary speech usually means more videos, not fewer.
        case any
        /// Every one of the names.
        case all

        var id: String { rawValue }
        var title: String { self == .any ? "Any" : "All" }
    }

    private(set) var names: [String] = []
    var match: Match = .any

    init(names: [String] = [], match: Match = .any) {
        self.match = match
        for name in names { add(name) }
    }

    var isEmpty: Bool { names.isEmpty }

    /// Case-insensitive, the way the library compares tag names.
    func contains(_ name: String) -> Bool {
        names.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    mutating func add(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !contains(clean) else { return }
        names.append(clean)
    }

    mutating func remove(_ name: String) {
        names.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// In if it was out, out if it was in.
    mutating func toggle(_ name: String) {
        if contains(name) { remove(name) } else { add(name) }
    }

    /// Drop names nothing carries any more — a tag deleted, or renamed away —
    /// so a query never holds a constraint the user cannot see the reason for.
    /// Under All, one vanished name would otherwise empty the list silently.
    mutating func prune(keeping exists: (String) -> Bool) {
        names.removeAll { !exists($0) }
    }

    /// How the playlist is titled: "Iceland or Singapore", "Iceland and 2016".
    var label: String {
        switch names.count {
        case 0: return "No tags"
        case 1: return names[0]
        default:
            let joiner = match == .any ? " or " : " and "
            return names.dropLast().joined(separator: ", ") + joiner + names.last!
        }
    }

    /// The members of every name, combined. Pure, so the rule is testable
    /// without a library: union for Any, intersection for All, and nothing at
    /// all for a query with no names.
    static func combine(_ members: [Set<String>], _ match: Match) -> Set<String> {
        guard var result = members.first else { return [] }
        for set in members.dropFirst() {
            switch match {
            case .any: result.formUnion(set)
            case .all: result.formIntersection(set)
            }
        }
        return result
    }
}
