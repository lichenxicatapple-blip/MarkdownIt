import SwiftUI

/// Typed content generated from docs/privacy.md; no Markdown engine runs in this view.
struct PrivacyPolicyContent: Decodable {
    struct Run: Decodable {
        let text: String
        let strong: Bool?
        let link: URL?
    }

    enum Block: Decodable {
        case paragraph([Run])
        case heading([Run])
        case list([[Run]])
        case table([[[Run]]])

        private enum CodingKeys: String, CodingKey { case kind, text, items, rows }
        private enum Kind: String, Decodable { case paragraph, heading, list, table }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self =
                switch try values.decode(Kind.self, forKey: .kind) {
                case .paragraph: .paragraph(try values.decode([Run].self, forKey: .text))
                case .heading: .heading(try values.decode([Run].self, forKey: .text))
                case .list: .list(try values.decode([[Run]].self, forKey: .items))
                case .table: .table(try values.decode([[[Run]]].self, forKey: .rows))
                }
        }
    }

    let blocks: [Block]

    static func load(language: String, bundle: Bundle = .main) throws -> Self {
        let language = language == "zh-Hans" ? "zh-Hans" : "en"
        guard let url = bundle.url(forResource: language, withExtension: "json", subdirectory: "Privacy") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    static func attributed(_ runs: [Run]) -> AttributedString {
        runs.reduce(into: AttributedString()) { result, run in
            var text = AttributedString(run.text)
            if run.strong == true { text.inlinePresentationIntent = .stronglyEmphasized }
            text.link = run.link
            result += text
        }
    }
}

struct PrivacyPolicyView: View {
    private let policy = try? PrivacyPolicyContent.load(language: Bundle.main.preferredLocalizations.first ?? "en")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let policy {
                    ForEach(Array(policy.blocks.enumerated()), id: \.offset) { index, block in
                        content(block)
                            .font(index == 0 ? .footnote : .body)
                            .foregroundStyle(index == 0 ? .secondary : .primary)
                    }
                } else {
                    Text("Offline rendering resources are missing.")
                }
            }
            .textSelection(.enabled).lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
        .accessibilityIdentifier("PrivacyPolicyContent")
        .navigationTitle("Privacy Policy").navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(_ block: PrivacyPolicyContent.Block) -> some View {
        switch block {
        case .paragraph(let runs):
            Text(PrivacyPolicyContent.attributed(runs))
        case .heading(let runs):
            Text(PrivacyPolicyContent.attributed(runs)).font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
        case .list(let items):
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, runs in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").accessibilityHidden(true)
                        Text(PrivacyPolicyContent.attributed(runs))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        case .table(let rows):
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                    if index > 0 { Divider().gridCellColumns(2) }
                    GridRow(alignment: .top) {
                        ForEach(Array(cells.enumerated()), id: \.offset) { _, runs in
                            Text(PrivacyPolicyContent.attributed(runs))
                                .fontWeight(index == 0 ? .semibold : .regular)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .font(.subheadline)
        }
    }
}
