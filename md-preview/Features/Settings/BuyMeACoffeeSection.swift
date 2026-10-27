//
//  BuyMeACoffeeSection.swift
//  md-preview
//
//  The Buy Me a Coffee row at the top of the General settings pane. It stays
//  until the user closes it. The About pane keeps a permanent link.
//

import SwiftUI

enum BuyMeACoffee {
    static let url = URL(string: "https://buymeacoffee.com/pluk")!
}

struct BuyMeACoffeeSection: View {
    let onClose: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            HStack(spacing: 12) {
                SettingsIconTile(size: 32, fill: Color(red: 1.0, green: 0.867, blue: 0.0)) {
                    Image("BuyMeACoffeeCup")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 21)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Support Markdown Preview"))
                        .font(.headline)
                    Text(L("Markdown Preview is free and open source. A coffee helps keep it that way."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button(L("Buy Me a Coffee")) {
                    openURL(BuyMeACoffee.url)
                }

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L("Close"))
                .accessibilityLabel(L("Close"))
            }
            .padding(.vertical, 4)
        }
    }
}
