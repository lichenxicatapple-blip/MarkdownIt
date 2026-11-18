import StoreKit
import SwiftUI

struct AppInformationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var storefrontCountryCode: String?
    private let storefrontCountryCodeOverride: String?

    init(storefrontCountryCodeOverride: String? = nil) {
        self.storefrontCountryCodeOverride = storefrontCountryCodeOverride
        _storefrontCountryCode = State(initialValue: storefrontCountryCodeOverride)
    }

    private var version: String {
        let release = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(release) (\(build))"
    }

    private var filingNumber: String? {
        guard storefrontCountryCode == "CHN",
            let number = Bundle.main.object(forInfoDictionaryKey: "MarkdownItICPFilingNumber") as? String,
            !number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return number
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Version", value: version)
                        .accessibilityIdentifier("AppVersion")
                    NavigationLink {
                        PrivacyPolicyView()
                    } label: {
                        Text("Privacy Policy")
                    }
                    .accessibilityIdentifier("PrivacyPolicy")
                }
                if let filingNumber {
                    Section {
                        Link(destination: URL(string: "https://beian.miit.gov.cn/")!) {
                            Text(verbatim: filingNumber)
                        }
                        .accessibilityIdentifier("ICPFilingNumber")
                    }
                }
            }
            .navigationTitle("About").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly).keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("CloseAbout")
                }
            }
        }
        .presentationSizing(.form)
        .presentationBackgroundInteraction(.disabled)
        .task {
            guard storefrontCountryCodeOverride == nil else { return }
            let current = await Storefront.current
            guard !Task.isCancelled else { return }
            storefrontCountryCode = current?.countryCode
            for await storefront in Storefront.updates {
                guard !Task.isCancelled else { return }
                storefrontCountryCode = storefront.countryCode
            }
        }
    }
}
