//
//  ReleaseNotesFormatter.swift
//  md-preview
//
//  Turns the GitHub releases into one Markdown document, newest first:
//  years and months as headings, then for each release its title, date,
//  version, intro and a list of items. A release body is a CHANGELOG.md
//  entry — an intro, then `### Added`, `### Changed` and `### Fixed` lists
//  of `**Title.** Text ([#1](…)).` bullets and a `### Contributors` list —
//  and its items are merged into one list, each with its title, text, who
//  shipped it (the authors of its pull requests) and its links. The document
//  is Markdown with a few classed inline elements; the marker at the top
//  lets the app's stylesheet lay it out as a changelog page.
//

import Foundation

nonisolated enum ReleaseNotesFormatter {

    struct Release: Equatable, Sendable {
        let version: String
        /// The GitHub release name: a release title when the CHANGELOG.md
        /// heading has one, otherwise "Markdown Preview <version>".
        let name: String?
        let date: Date
        let body: String
    }

    struct Item: Equatable {
        let title: String?
        let text: String
        /// Pull request and issue links, as Markdown.
        let links: [String]
    }

    /// Who opened a pull request.
    struct Author: Equatable, Codable, Sendable {
        /// The first name from the GitHub profile, or the login.
        let name: String
        let avatarURL: String
    }

    struct Entry: Equatable {
        let intro: String
        let items: [Item]
        /// Contributor links, as Markdown.
        let contributors: [String]
    }

    /// Lets the stylesheet find the page; an empty element shows nothing in
    /// other Markdown viewers.
    static let marker = MarkdownHTML.releaseNotesMarker

    /// Lines that belong together (year, month, date, title, version) have
    /// no blank line between them: the page keeps a spacer element for each
    /// blank line, and the stylesheet expects them only between blocks.
    static func document(_ releases: [Release],
                         authors: [Int: Author] = [:],
                         footer: String? = nil,
                         calendar: Calendar = Calendar(identifier: .gregorian),
                         locale: Locale = Locale(identifier: "en_US")) -> String {
        var calendar = calendar
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let monthFormat = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .month(.wide)
        let dayFormat = Date.FormatStyle(date: .long, time: .omitted, locale: locale,
                                         calendar: calendar, timeZone: calendar.timeZone)

        // The HTML block ends at the blank line.
        var lines = [marker, ""]
        var year: Int?
        var month: Int?
        for release in releases.sorted(by: { $0.date > $1.date }) {
            let parts = calendar.dateComponents([.year, .month], from: release.date)
            if parts.year != year {
                year = parts.year
                month = nil
                lines.append("# \(parts.year ?? 0)")
            }
            if parts.month != month {
                month = parts.month
                lines.append("## \(release.date.formatted(monthFormat))")
            }
            let entry = parse(release.body)
            lines += [
                release.date.formatted(dayFormat),
                "### \(title(for: release, entry: entry))",
                "`v\(release.version)`",
                "",
            ]
            if !entry.intro.isEmpty { lines += [entry.intro, ""] }
            for item in entry.items {
                // A loose list: title, text and links are paragraphs.
                var paragraphs: [String] = []
                if let title = item.title { paragraphs.append("**\(title)**") }
                if !item.text.isEmpty { paragraphs.append(item.text) }
                if let shipped = shippedBy(item, authors: authors) { paragraphs.append(shipped) }
                if !item.links.isEmpty { paragraphs.append(linkPills(item.links, version: release.version)) }
                guard let first = paragraphs.first else { continue }
                lines += ["- \(first)", ""]
                for paragraph in paragraphs.dropFirst() { lines += ["  \(paragraph)", ""] }
            }
            if !entry.contributors.isEmpty {
                lines += ["Thanks to \(list(entry.contributors)).", ""]
            }
        }
        if let footer { lines += [footer, ""] }
        return lines.joined(separator: "\n")
    }

    /// The releases a reader who updated from `previousVersion` to
    /// `currentVersion` has not seen: newer than the first, up to and
    /// including the second. An empty `previousVersion` (unknown) gives the
    /// current version alone.
    static func releases(_ releases: [Release], after previousVersion: String,
                         through currentVersion: String) -> [Release] {
        releases.filter { release in
            guard !previousVersion.isEmpty else { return release.version == currentVersion }
            return release.version.compare(previousVersion, options: .numeric) == .orderedDescending
                && release.version.compare(currentVersion, options: .numeric) != .orderedDescending
        }
    }

    /// The release title, or one made from the first item titles for the
    /// releases that predate titles.
    static func title(for release: Release, entry: Entry) -> String {
        if let name = release.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
           name != "Markdown Preview \(release.version)" {
            return name
        }
        let titles = entry.items.compactMap(\.title)
        guard let first = titles.first else { return "Markdown Preview \(release.version)" }
        if titles.count > 1, first.count + titles[1].count <= 48 {
            return "\(first), \(titles[1])"
        }
        return first
    }

    static func parse(_ body: String) -> Entry {
        var intro: [String] = []
        var items: [Item] = []
        var contributors: [String] = []
        var section: String?
        var bullet: String?

        func finishBullet() {
            guard let text = bullet else { return }
            bullet = nil
            if section == "contributors" {
                contributors += text.matches(of: contributorLink).map { String($0.output) }
            } else {
                items.append(item(from: text))
            }
        }

        for line in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                finishBullet()
                section = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased()
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                finishBullet()
                bullet = String(trimmed.dropFirst(2))
            } else if trimmed.isEmpty {
                finishBullet()
            } else if bullet != nil {
                bullet! += " " + trimmed
            } else if section == nil {
                intro.append(trimmed)
            }
            // Other prose under a heading ("Thank you to …") is dropped.
        }
        finishBullet()
        return Entry(intro: intro.joined(separator: " "), items: items, contributors: contributors)
    }

    /// How many link pills an item shows before a "+N" pill that opens
    /// the release on GitHub, where every link is listed.
    static let visibleLinkCount = 4

    // MARK: - Private

    private static func shippedBy(_ item: Item, authors: [Int: Author]) -> String? {
        var shippers: [Author] = []
        for link in item.links {
            guard let number = link.firstMatch(of: pullRequestLink).flatMap({ Int($0.output.1) }),
                  let author = authors[number],
                  !shippers.contains(where: { $0.name == author.name }) else { continue }
            shippers.append(author)
        }
        guard !shippers.isEmpty else { return nil }
        let avatars = shippers.prefix(3).map {
            #"<img src="\#(MarkdownHTML.htmlEscape($0.avatarURL))" alt="">"#
        }.joined()
        let names = list(shippers.map { MarkdownHTML.htmlEscape($0.name) })
        return #"<span class="mdp-rn-shipped">\#(avatars)Shipped by <span class="mdp-rn-name">\#(names)</span></span>"#
    }

    private static func linkPills(_ links: [String], version: String) -> String {
        var pills = Array(links.prefix(visibleLinkCount))
        if links.count > visibleLinkCount {
            let release = "https://github.com/pluk-inc/markdown-preview/releases/tag/v\(version)"
            pills.append("[+\(links.count - visibleLinkCount)](\(release))")
        }
        return #"<span class="mdp-rn-links">\#(pills.joined(separator: " "))</span>"#
    }

    private static func item(from bullet: String) -> Item {
        var text = bullet
        var title: String?
        if let match = text.prefixMatch(of: boldTitle) {
            title = String(match.output.1).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            text = String(text[match.range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        var links: [String] = []
        if let match = text.firstMatch(of: trailingLinks) {
            links = match.output.matches(of: issueLink).map { String($0.output) }
            text = String(text[..<match.range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, !text.hasSuffix(".") { text += "." }
        }
        return Item(title: title, text: text, links: links)
    }

    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    /// `**Title.**` or `**Title**` at the start of a bullet.
    nonisolated(unsafe) private static let boldTitle = #/\*\*(.+?)\*\*/#
    /// ` ([#1](…), [#2](…)).` at the end of a bullet.
    nonisolated(unsafe) private static let trailingLinks =
        #/\s*\((?:\[#\d+\]\([^)\s]+\)(?:,\s*)?)+\)\.?\s*$/#
    nonisolated(unsafe) private static let issueLink = #/\[#\d+\]\([^)\s]+\)/#
    nonisolated(unsafe) private static let pullRequestLink = #/\[#\d+\]\([^)\s]*/pull/(\d+)\)/#
    nonisolated(unsafe) private static let contributorLink = #/\[@[^\]]+\]\([^)\s]+\)/#
}
