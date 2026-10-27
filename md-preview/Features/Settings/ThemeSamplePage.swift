//
//  ThemeSamplePage.swift
//  md-preview
//
//  A sample page in a reading look: an "Aa" in the reading face over prose
//  set with the look's spacing and margins, cut off by a fade at the bottom.
//  The Customize Theme sheet shows its draft in it; the Appearance settings
//  pane shows the live settings.
//

import SwiftUI

struct ThemeSamplePage<Header: View>: View {
    let readerLayout: ReaderLayoutSetting
    let documentFont: DocumentFontSetting
    let themeColors: ThemeColorsSetting
    var columns: [String]
    var titleSize: CGFloat = 40
    var bodySize: CGFloat = 18
    var sampleHeight: CGFloat = 250
    /// A fixed height for the whole page, for a host whose layout must not
    /// move when the reading face changes. nil fits the content.
    var pageHeight: CGFloat? = nil
    @ViewBuilder var header: Header
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let scheme: ThemeColorScheme = colorScheme == .dark ? .dark : .light
        // Same fallback the colour wells use, so with no overrides stored the
        // sample shows what the page actually renders.
        let page = Color(nsColor: themeColors.color(.windowBackground, scheme)
            ?? ThemeColorsSetting.defaultColor(.windowBackground, scheme))
        let text = Color(nsColor: themeColors.color(.textColor, scheme)
            ?? ThemeColorsSetting.defaultColor(.textColor, scheme))
        VStack(alignment: .leading, spacing: 16) {
            header
            Text(verbatim: "Aa")
                .font(documentFont.font(size: titleSize))
                .fontWeight(readerLayout.boldText ? .bold : .medium)
                .foregroundStyle(text)
                .padding(.horizontal, 28)
            prose(text: text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: pageHeight, alignment: .top)
        .background(page)
    }

    /// Wrapped over enough lines that line spacing, word spacing and the
    /// margins read as themselves. The page continues past the fade the way
    /// a real page would.
    private func prose(text: Color) -> some View {
        let applied = readerLayout.effective
        let extraLeading = bodySize * CGFloat(applied.lineSpacing - 1.0)
        let kerning = bodySize * CGFloat(applied.characterSpacingPercent / 100)
        let inset = 28 + CGFloat(applied.pageInset)
        return HStack(alignment: .top, spacing: 24) {
            ForEach(Array(columns.enumerated()), id: \.offset) { column in
                Text(column.element)
                    .font(documentFont.font(size: bodySize))
                    .fontWeight(readerLayout.boldText ? .semibold : .regular)
                    .kerning(kerning)
                    .lineSpacing(extraLeading)
                    .foregroundStyle(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, inset)
        .frame(height: sampleHeight, alignment: .top)
        .clipped()
        .mask(
            LinearGradient(stops: [.init(color: .black, location: 0),
                                   .init(color: .black, location: 0.55),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top,
                           endPoint: .bottom)
        )
    }
}

/// The sample page's prose, shared by the Customize Theme sheet and the
/// Appearance settings pane.
enum ThemeSampleProse {
    /// Reading prose rather than a description of the controls: the point is to
    /// judge a face and a spacing, which needs ordinary sentences.
    static let columns: [String] = [
        L("""
        The team looking after our recommendation system has been spiking out \
        some new algorithms, and the results are promising enough that we are \
        planning to put them in front of readers next month. Long paragraphs \
        are what make a reading face show its character: the rhythm of the \
        lines, how the spacing settles, where the eye lands when it returns \
        from the end of one line to the start of the next.
        """),
        L("""
        Nothing you change here reaches your open documents until you tap the \
        check mark, so try a few faces and spacings, then close with the cross \
        to leave everything exactly as you found it. The sample keeps going \
        past the bottom of this panel, the way a page would, so the measure \
        and the margins have somewhere to show themselves before you commit \
        to them.
        """)
    ]
}
