//
//  BuyMeACoffeeCard.swift
//  md-preview
//
//  The Buy Me a Coffee card at the top of the General settings pane, laid
//  out like the feature cards in Safari's Settings. It stays until the user
//  closes it. The About pane keeps a permanent link.
//

import SwiftUI

enum BuyMeACoffee {
    static let url = URL(string: "https://buymeacoffee.com/pluk")!
}

struct BuyMeACoffeeCard: View {
    let onClose: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Image("BuyMeACoffeeCup")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 20)
                    .frame(width: 32, height: 32)
                    .background(Color(red: 1.0, green: 0.867, blue: 0.0),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Support Markdown Preview"))
                        .font(.headline)
                    Text(L("Markdown Preview is free and open source. A coffee helps keep it that way."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Close"))
                .accessibilityLabel(L("Close"))
            }

            Divider()
                .padding(.leading, 46)

            Button(L("Buy Me a Coffee")) {
                openURL(BuyMeACoffee.url)
            }
        }
        .padding(16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: 480)
    }
}
