//
//  OpenTargetCatalog.swift
//  md-preview
//
//  Which apps a document can be handed off to, and which one is the default.
//
//  Lifted out of DocumentWindowController so the Settings window and the
//  document toolbar resolve the same default from the same allowlists. The
//  handoff itself (deep links, AppleScript, clipboard) stays in the window
//  controller — this file only answers "which apps, and which one is default".
//

import AppKit
import UniformTypeIdentifiers

struct EditorCandidate {
    let url: URL
    let bundleID: String?
}

enum LLMHandoff {
    case codexDesktop
    case claudeCodeDesktop
    case chatGPTDocumentOpen
    case copyAndOpen
}

struct LLMTarget {
    let id: String
    let title: String
    let bundleIDs: [String]
    let handoff: LLMHandoff
}

struct LLMCandidate {
    let target: LLMTarget
    let appURL: URL
}

enum OpenActionKind: String {
    case editor
    case llm
}

enum OpenActionSelection {
    case editor(EditorCandidate)
    case llm(LLMCandidate)
}

enum OpenTargetCatalog {

    // MARK: - Persisted defaults

    static let defaultOpenActionKindKey = "MarkdownPreview.defaultOpenActionKind"
    static let defaultEditorBundleIDKey = "MarkdownPreview.defaultEditorBundleID"
    static let defaultEditorURLKey = "MarkdownPreview.defaultEditorURL"
    static let defaultLLMTargetIDKey = "MarkdownPreview.defaultLLMTargetID"

    /// Records an editor as the default hand-off target.
    ///
    /// The bundle id is the durable half — it survives the app moving on disk
    /// or being updated — while the path is a fallback for apps that don't
    /// report one. Writing both keys keeps `resolveDefaultEditor` able to match
    /// either way.
    static func setDefaultEditor(_ candidate: EditorCandidate) {
        if let bundleID = candidate.bundleID {
            UserDefaults.standard.set(bundleID, forKey: defaultEditorBundleIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultEditorBundleIDKey)
        }
        UserDefaults.standard.set(candidate.url.path, forKey: defaultEditorURLKey)
        UserDefaults.standard.set(OpenActionKind.editor.rawValue,
                                  forKey: defaultOpenActionKindKey)
    }

    static func setDefaultLLM(_ candidate: LLMCandidate) {
        UserDefaults.standard.set(candidate.target.id, forKey: defaultLLMTargetIDKey)
        UserDefaults.standard.set(OpenActionKind.llm.rawValue,
                                  forKey: defaultOpenActionKindKey)
    }

    // MARK: - LLM apps

    static let llmTargets: [LLMTarget] = [
        LLMTarget(
            id: "codex",
            title: "Codex",
            bundleIDs: ["com.openai.codex"],
            handoff: .codexDesktop
        ),
        LLMTarget(
            id: "claude",
            title: "Claude",
            bundleIDs: ["com.anthropic.claudefordesktop"],
            handoff: .claudeCodeDesktop
        ),
        LLMTarget(
            id: "chatgpt",
            title: "ChatGPT",
            bundleIDs: ["com.openai.chat"],
            handoff: .chatGPTDocumentOpen
        )
    ]

    static func llmCandidates() -> [LLMCandidate] {
        llmTargets.compactMap { target in
            let appURL = target.bundleIDs.compactMap {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            }.first
            guard let appURL else { return nil }
            return LLMCandidate(target: target, appURL: appURL)
        }
    }

    static func resolveDefaultLLM(among candidates: [LLMCandidate]) -> LLMCandidate? {
        if let persistedID = UserDefaults.standard.string(forKey: defaultLLMTargetIDKey),
           let match = candidates.first(where: { $0.target.id == persistedID }) {
            return match
        }
        return candidates.first
    }

    // MARK: - Editors

    private static let markdownDocTypeExtensions: Set<String> = ["md", "markdown", "mdown"]
    private static let strongMarkdownUTIs: Set<String> = ["net.daringfireball.markdown"]
    private static let plainTextUTIs: Set<String> = [
        "public.plain-text", "public.text",
        "public.utf8-plain-text", "public.utf16-plain-text"
    ]
    private static let textyUTIs: Set<String> = plainTextUTIs.union(strongMarkdownUTIs)

    private static let editorBundleIDPriority = [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.barebones.bbedit",
        "com.panic.Nova",
        "com.coteditor.CotEditor",
        "com.apple.TextEdit",
        "com.apple.dt.Xcode",
        "com.macromates.TextMate",
        "org.vim.MacVim"
    ]
    /// Editors we trust to open Markdown even when their Info.plist doesn't pass
    /// `canEditMarkdown`. Markdown-first apps like iA Writer declare a custom
    /// imported UTI (which only *conforms to* `net.daringfireball.markdown`) and
    /// omit `CFBundleTypeExtensions`, so the heuristic can't see them. See #114.
    private static let editorBundleIDAllowlist: Set<String> = [
        "pro.writer.mac",           // iA Writer (Mac App Store / direct)
        "pro.writer.mac-setapp",    // iA Writer (Setapp)
        "abnerworks.Typora",        // Typora
        "com.uranusjr.macdown",     // MacDown
        "md.obsidian"
    ]
    /// Apps that claim a Markdown/plain-text document type but aren't useful as a
    /// text editor — they pass `canEditMarkdown` only as noise. See #114.
    private static let editorBundleIDDenylist: Set<String> = [
        "com.microsoft.Word",
        "com.ideasoncanvas.mindnode.macos",
        "com.somac.subtitleburner"
    ]

    /// Editors that can open a specific document.
    static func editorCandidates(for fileURL: URL) -> [EditorCandidate] {
        filterEditors(NSWorkspace.shared.urlsForApplications(toOpen: fileURL))
    }

    /// Editors that can open Markdown in general, with no document in hand.
    ///
    /// Settings has to offer the choice before any document is open, so it asks
    /// Launch Services by content type rather than by URL. Both plain text and
    /// Markdown are queried because plain-text editors — the majority of what
    /// people pick here — register for `public.plain-text` only.
    static func markdownEditorCandidates() -> [EditorCandidate] {
        let types: [UTType] = [
            UTType("net.daringfireball.markdown"),
            .plainText
        ].compactMap { $0 }

        var seen: Set<URL> = []
        var urls: [URL] = []
        for type in types {
            for url in NSWorkspace.shared.urlsForApplications(toOpen: type)
            where seen.insert(canonicalAppURL(url)).inserted {
                urls.append(url)
            }
        }
        return filterEditors(urls)
    }

    private static func filterEditors(_ appURLs: [URL]) -> [EditorCandidate] {
        let myBundleID = Bundle.main.bundleIdentifier
        // Every URL Launch Services has registered for our bundle id — covers stale DerivedData /
        // archive copies the sandbox can't introspect by reading their Info.plist.
        var selfURLs: Set<URL> = [canonicalAppURL(Bundle.main.bundleURL)]
        if let myBundleID {
            for url in NSWorkspace.shared.urlsForApplications(withBundleIdentifier: myBundleID) {
                selfURLs.insert(canonicalAppURL(url))
            }
        }

        var seenBundleIDs: Set<String> = []
        var seenUnidentifiedURLs: Set<URL> = []

        return appURLs.compactMap { appURL in
            if selfURLs.contains(canonicalAppURL(appURL)) { return nil }
            let plist = infoPlist(at: appURL)
            let bundleID = (plist?["CFBundleIdentifier"] as? String)
                ?? Bundle(url: appURL)?.bundleIdentifier
            if let bundleID, editorBundleIDDenylist.contains(bundleID) { return nil }
            let isAllowlisted = bundleID.map(editorBundleIDAllowlist.contains) ?? false
            guard isAllowlisted || canEditMarkdown(plist: plist) else { return nil }

            // Launch Services can return several installed copies of the same
            // app. The preference is bundle-ID based, so presenting duplicate
            // indistinguishable rows would imply a path choice we cannot keep.
            if let bundleID {
                guard seenBundleIDs.insert(bundleID).inserted else { return nil }
            } else {
                guard seenUnidentifiedURLs.insert(canonicalAppURL(appURL)).inserted else {
                    return nil
                }
            }
            return EditorCandidate(url: appURL, bundleID: bundleID)
        }
    }

    static func resolveDefaultEditor(among candidates: [EditorCandidate]) -> EditorCandidate? {
        let myBundleID = Bundle.main.bundleIdentifier
        if let persistedID = UserDefaults.standard.string(forKey: defaultEditorBundleIDKey),
           persistedID != myBundleID {
            if let match = candidates.first(where: { $0.bundleID == persistedID }) {
                return match
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: persistedID) {
                return EditorCandidate(url: url, bundleID: persistedID)
            }
        }

        if let persistedPath = UserDefaults.standard.string(forKey: defaultEditorURLKey) {
            let persistedURL = canonicalAppURL(URL(fileURLWithPath: persistedPath))
            if let match = candidates.first(where: { sameApplication($0.url, persistedURL) }) {
                return match
            }
        }

        for preferred in editorBundleIDPriority {
            if let match = candidates.first(where: { $0.bundleID == preferred }) {
                return match
            }
        }
        return candidates.first
    }

    // MARK: - Combined default

    static func resolveDefaultOpenAction(editors: [EditorCandidate],
                                         defaultEditor: EditorCandidate?,
                                         llmApps: [LLMCandidate],
                                         defaultLLM: LLMCandidate?) -> OpenActionSelection? {
        let persistedKind = UserDefaults.standard.string(forKey: defaultOpenActionKindKey)
            .flatMap(OpenActionKind.init(rawValue:))

        switch persistedKind {
        case .llm:
            if let defaultLLM { return .llm(defaultLLM) }
            if let defaultEditor { return .editor(defaultEditor) }
        case .editor:
            if let defaultEditor { return .editor(defaultEditor) }
            if let defaultLLM { return .llm(defaultLLM) }
        case nil:
            if let defaultLLM { return .llm(defaultLLM) }
            if let defaultEditor { return .editor(defaultEditor) }
        }
        return nil
    }

    // MARK: - Identity helpers

    static func sameEditor(_ lhs: EditorCandidate, _ rhs: EditorCandidate) -> Bool {
        if let leftID = lhs.bundleID, let rightID = rhs.bundleID {
            return leftID == rightID
        }
        return sameApplication(lhs.url, rhs.url)
    }

    static func sameApplication(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalAppURL(lhs) == canonicalAppURL(rhs)
    }

    static func canonicalAppURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    static func displayName(for appURL: URL) -> String {
        FileManager.default.displayName(atPath: appURL.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    static func icon(for appURL: URL, size: CGFloat) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: size, height: size)
        return icon
    }

    // MARK: - Info.plist inspection

    private static func infoPlist(at appURL: URL) -> [String: Any]? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                     options: [],
                                                                     format: nil) as? [String: Any] else {
            return Bundle(url: appURL)?.infoDictionary
        }
        return plist
    }

    private static func canEditMarkdown(plist: [String: Any]?) -> Bool {
        guard let docTypes = plist?["CFBundleDocumentTypes"] as? [[String: Any]] else {
            return true
        }

        var matchedAsEditor = false
        var matchedAsViewer = false

        for docType in docTypes {
            let utis = Set((docType["LSItemContentTypes"] as? [String]) ?? [])
            let extensions = Set(((docType["CFBundleTypeExtensions"] as? [String]) ?? [])
                .map { $0.lowercased() })
            let rank = (docType["LSHandlerRank"] as? String) ?? "Default"

            let hasMarkdownUTI = !strongMarkdownUTIs.isDisjoint(with: utis)
            let hasMarkdownExtension = !markdownDocTypeExtensions.isDisjoint(with: extensions)
            // A generic plain-text claim only counts as "real text editor" when the entry's UTI
            // list is purely text-flavored and isn't ranked Alternate. That filters Postico
            // (Alternate) and Numbers (bundles public.plain-text with CSV/TSV import UTIs).
            let isPureTextEntry = !utis.isEmpty && utis.isSubset(of: textyUTIs)
            let isPlainTextEditor = isPureTextEntry && rank != "Alternate"

            guard hasMarkdownUTI || hasMarkdownExtension || isPlainTextEditor else { continue }

            let role = (docType["CFBundleTypeRole"] as? String) ?? "Editor"
            switch role {
            case "Viewer", "QLGenerator": matchedAsViewer = true
            default: matchedAsEditor = true
            }
        }

        if matchedAsEditor { return true }
        if matchedAsViewer { return false }
        return false
    }
}
