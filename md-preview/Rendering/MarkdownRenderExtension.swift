//
//  MarkdownRenderExtension.swift
//  md-preview
//
//  App-bundled Markdown rendering extensions.
//

import Foundation

/// Stores opt-outs only: every extension newly compiled into registry starts
/// enabled without a migration. Values live in app-group defaults so both
/// render hosts apply same configuration.
nonisolated enum RenderExtensionPreferences {
  static let defaultsKeyPrefix = "MarkdownPreview.renderExtension.enabled."

  static var currentConfiguration: MarkdownHTML.RenderExtensionConfiguration {
    configuration(from: sharedDefaults())
  }

  static func sharedDefaults(bundle: Bundle = .main) -> UserDefaults? {
    guard let identifier = bundle.object(
      forInfoDictionaryKey: AppearanceMode.appGroupInfoKey
    ) as? String,
      !identifier.isEmpty
    else { return nil }
    return UserDefaults(suiteName: identifier)
  }

  static func configuration(
    from defaults: UserDefaults?,
    registryIDs: [String] = MarkdownHTML.renderExtensions.map(\.id)
  ) -> MarkdownHTML.RenderExtensionConfiguration {
    MarkdownHTML.RenderExtensionConfiguration(
      enabledIDs: enabledIDs(from: defaults, registryIDs: registryIDs)
    )
  }

  static func enabledIDs(
    from defaults: UserDefaults?,
    registryIDs: [String] = MarkdownHTML.renderExtensions.map(\.id)
  ) -> Set<String> {
    Set(registryIDs.filter { isEnabled($0, in: defaults) })
  }

  static func isEnabled(_ id: String, in defaults: UserDefaults?) -> Bool {
    guard let stored = defaults?.object(forKey: defaultsKey(for: id)) as? NSNumber else {
      return true
    }
    return stored.boolValue
  }

  static func setEnabled(_ enabled: Bool, for id: String, in defaults: UserDefaults?) {
    let key = defaultsKey(for: id)
    if enabled {
      defaults?.removeObject(forKey: key)
    } else {
      defaults?.set(false, forKey: key)
    }
  }

  static func store(
    enabledIDs: Set<String>,
    in defaults: UserDefaults?,
    registryIDs: [String] = MarkdownHTML.renderExtensions.map(\.id)
  ) {
    for id in registryIDs {
      setEnabled(enabledIDs.contains(id), for: id, in: defaults)
    }
  }

  /// IDs may gain punctuation or Unicode. Encode them before forming a
  /// defaults key, avoiding collisions and invalid key-path semantics.
  static func defaultsKey(for id: String) -> String {
    let encoded = Data(id.utf8)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return defaultsKeyPrefix + encoded
  }
}

/// Owns a Markdown-to-HTML transform and only assets needed when its output is
/// present. Extensions deliberately have no access to view, file, or app state.
nonisolated protocol MarkdownRenderExtension: Sendable {
  var id: String { get }

  func transform(_ context: MarkdownHTML.RenderContext) -> MarkdownHTML.RenderResult
  func assets(mode: MarkdownHTML.VendorLoading) -> MarkdownHTML.RenderAssets
}

nonisolated extension MarkdownRenderExtension {
  func assets(mode _: MarkdownHTML.VendorLoading) -> MarkdownHTML.RenderAssets {
    MarkdownHTML.RenderAssets()
  }
}

nonisolated extension MarkdownHTML {
  /// Input available to every extension.
  struct RenderContext: Sendable {
    let html: String
    let markdown: String
  }

  struct RenderResult: Sendable {
    let html: String
    let active: Bool
  }

  /// CSS is emitted in `<head>` while JavaScript retains its existing
  /// head/body placement. This keeps Quick Look self-contained and lets app
  /// previews lazy-load large vendor bundles after first paint.
  struct RenderAssets: Sendable {
    var css: String = ""
    var headJS: String = ""
    var bodyJS: String = ""
  }

  /// Snapshot passed from each render host. Rendering never reads defaults
  /// directly, keeping concurrent work deterministic while Settings changes.
  struct RenderExtensionConfiguration: Sendable, Equatable {
    let enabledIDs: Set<String>

    static var allEnabled: Self {
      Self(enabledIDs: Set(renderExtensions.map(\.id)))
    }

    func isEnabled(_ id: String) -> Bool {
      enabledIDs.contains(id)
    }
  }

  /// Compiled-in, toggleable extensions. Mermaid, Math, and Callout render
  /// unconditionally outside this registry (see `MarkdownHTML.render`) —
  /// only the heading extensions are optional.
  static let renderExtensions: [any MarkdownRenderExtension] = [
    ColorfulHeadersExtension(),
    CollapsibleHeadersExtension()
  ]

  static func renderExtensionTitle(for id: String) -> String {
    switch id {
    case "colorful-headings": NSLocalizedString("Colorful headings", comment: "Render extension setting")
    case "collapsible-headings": NSLocalizedString("Collapsible headings", comment: "Render extension setting")
    default: id
    }
  }

  struct RenderExtensionRun {
    let html: String
    let active: [any MarkdownRenderExtension]

    func contains(_ id: String) -> Bool {
      active.contains { $0.id == id }
    }
  }

  static func applyRenderExtensions(
    to html: String,
    markdown: String,
    configuration: RenderExtensionConfiguration = .allEnabled
  ) -> RenderExtensionRun {
    var rendered = html
    var active: [any MarkdownRenderExtension] = []
    for ext in renderExtensions where configuration.isEnabled(ext.id) {
      let result = ext.transform(RenderContext(html: rendered, markdown: markdown))
      rendered = result.html
      if result.active {
        active.append(ext)
      }
    }
    return RenderExtensionRun(html: rendered, active: active)
  }
}
