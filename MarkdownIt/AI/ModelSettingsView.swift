import SwiftUI
import UIKit

struct ModelSettingsView: View {
    @ObservedObject var session: ReaderSession
    var onSaved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = ""
    @State private var model = ""
    @State private var customModel = false
    @FocusState private var customModelFocused: Bool
    @State private var key = ""
    @State private var search = WebSearchSettings()
    @State private var confirmingReset = false
    @State private var errorMessage: String?

    init(session: ReaderSession, onSaved: @escaping () -> Void = {}) {
        self.session = session
        self.onSaved = onSaved
        _baseURL = State(initialValue: session.configuration.baseURL)
        _model = State(initialValue: session.configuration.model)
        _key = State(initialValue: session.apiKey)
        _search = State(initialValue: session.searchSettings)
        _errorMessage = State(initialValue: session.modelSettingsError)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // No API-token content type exists. AutoFill also inspects
                    // adjacent fields, so all connection inputs use code semantics.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Base URL").font(.subheadline).foregroundStyle(.secondary)
                        TextField(
                            "", text: $baseURL,
                            prompt: Text(verbatim: "https://api.example.com/v1")
                                .foregroundStyle(Color(uiColor: .placeholderText))
                        )
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.oneTimeCode)
                        .accessibilityLabel("Base URL").accessibilityIdentifier("ModelBaseURL")
                    }
                    apiKeyField($key, label: "API Key", identifier: "ModelAPIKey")
                    NavigationLink {
                        ModelSelectionView(
                            catalog: session.modelCatalog, baseURL: baseURL, key: key, model: $model,
                            custom: $customModel)
                    } label: {
                        LabeledContent("Model") {
                            Text(
                                customModel
                                    ? String(localized: "Custom") : model.isEmpty ? String(localized: "Select") : model
                            )
                            .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .accessibilityIdentifier("ModelPicker")
                    .accessibilityLabel("Model")
                    .accessibilityValue(model)
                    if customModel {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Model ID").font(.subheadline).foregroundStyle(.secondary)
                            TextField("", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textContentType(.oneTimeCode)
                                .focused($customModelFocused)
                                .accessibilityLabel("Model ID").accessibilityIdentifier("ModelID")
                        }
                    }
                }
                if session.configuration.requiresResponsesConfirmation {
                    Section {
                        Text("Only Responses is supported. Confirm the connection settings.")
                            .foregroundStyle(.secondary)
                    }
                }
                searchSection
                Section {
                    Button("Reset", role: .destructive) {
                        confirmingReset = true
                    }
                    .accessibilityIdentifier("ResetModelSettings")
                }
            }
            .navigationTitle("Model Settings").navigationBarTitleDisplayMode(.inline)
            .background {
                SettingsAppearanceObserver {
                    if customModel { customModelFocused = true }
                }
                .accessibilityHidden(true)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: saveSettings)
                        .accessibilityIdentifier("SettingsDone")
                }
            }
        }
        .alert(
            errorMessage ?? "",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        }
        .background {
            ReaderAlert(
                isPresented: $confirmingReset, title: String(localized: "Reset Model Settings?"),
                message: String(localized: "Saved connection information and API keys will be removed."),
                actions: [
                    .init(id: "cancel", title: String(localized: "Cancel"), style: .cancel) {},
                    .init(id: "reset", title: String(localized: "Reset"), style: .destructive, perform: resetSettings),
                ]
            )
            .accessibilityHidden(true)
        }
        .onAppear { session.modelCatalog.prefetch(baseURL: baseURL, key: key) }
        .onChange(of: baseURL) { _, _ in prefetchAfterInput() }
        .onChange(of: key) { _, _ in prefetchAfterInput() }
        .onDisappear {
            session.modelCatalog.cancel()
            key = ""
            search.keys.removeAll()
        }
    }

    private var searchSection: some View {
        Section {
            Picker("Search Service", selection: $search.provider) {
                Text("Off").tag(Optional<WebSearchProvider>.none)
                ForEach(WebSearchProvider.allCases, id: \.self) { provider in
                    Text(verbatim: provider.title).tag(Optional(provider))
                }
            }
            .accessibilityIdentifier("SearchProvider")
            if let provider = search.provider {
                apiKeyField(
                    Binding(
                        get: { search.keys[provider.rawValue] ?? "" }, set: { search.keys[provider.rawValue] = $0 }),
                    label: "Search API Key", identifier: "SearchAPIKey")
            }
        } header: {
            Text("Web Search")
        } footer: {
            Text("Connection information will be stored only in this device’s Keychain.")
        }
    }

    private func apiKeyField(_ value: Binding<String>, label: LocalizedStringKey, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API Key").font(.subheadline).foregroundStyle(.secondary)
            SecureField("", text: value)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textContentType(.oneTimeCode).keyboardType(.asciiCapable)
                .accessibilityLabel(Text(label)).accessibilityIdentifier(identifier)
        }
    }

    private var draftConfiguration: ModelConfiguration {
        ModelConfiguration(
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func saveSettings() {
        do {
            try session.saveConfiguration(draftConfiguration, key: key, search: search)
            onSaved()
            dismiss()
        } catch ModelConfigurationError.missingModel where customModel {
            showError(String(localized: "Enter a Model ID."))
        } catch let error as ModelConfigurationError {
            showError(error.localizedDescription)
        } catch let error as WebSearchSettingsError {
            showError(error.localizedDescription)
        } catch {
            showError(String(localized: "Unable to save connection information."))
        }
    }

    private func resetSettings() {
        do {
            try session.resetModelSettings()
            baseURL = ""
            model = ""
            key = ""
            search = WebSearchSettings()
            customModel = false
            customModelFocused = false
        } catch { showError(String(localized: "Unable to reset connection information.")) }
    }

    private func showError(_ message: String) {
        errorMessage = message
    }

    private func prefetchAfterInput() {
        session.modelCatalog.prefetch(baseURL: baseURL, key: key, debounce: .milliseconds(500))
    }
}

/// SwiftUI's onAppear precedes completion of the navigation transition.
/// Request text focus once the settings controller is actually on screen.
private struct SettingsAppearanceObserver: UIViewControllerRepresentable {
    var onDidAppear: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onDidAppear = onDidAppear
    }

    final class Controller: UIViewController {
        var onDidAppear: (() -> Void)?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onDidAppear?()
        }
    }
}
