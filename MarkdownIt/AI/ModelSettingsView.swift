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
    @State private var apiProtocol: ModelAPIProtocol = .responses
    @State private var attemptedSave = false
    @State private var saveError: String?
    @State private var confirmingReset = false

    init(session: ReaderSession, onSaved: @escaping () -> Void = {}) {
        self.session = session
        self.onSaved = onSaved
        _baseURL = State(initialValue: session.configuration.baseURL)
        _model = State(initialValue: session.configuration.model)
        _apiProtocol = State(initialValue: session.configuration.apiProtocol)
        _key = State(initialValue: session.apiKey)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("API Type", selection: $apiProtocol) {
                        ForEach(ModelAPIProtocol.allCases, id: \.self) { api in
                            Text(api.title).tag(api)
                        }
                    }
                    .accessibilityIdentifier("ModelAPIProtocol")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Base URL").font(.subheadline).foregroundStyle(.secondary)
                        TextField(
                            "", text: $baseURL,
                            prompt: Text(verbatim: "https://api.example.com/v1")
                                .foregroundStyle(Color(uiColor: .placeholderText))
                        )
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.URL)
                        .accessibilityLabel("Base URL").accessibilityIdentifier("ModelBaseURL")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key").font(.subheadline).foregroundStyle(.secondary)
                        SecureField("", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                            // iOS has no API-token content type. Code semantics
                            // preserve secure entry without login-password saving;
                            // an empty type still invokes heuristics on iOS 26.
                            .textContentType(.oneTimeCode)
                            .keyboardType(.asciiCapable)
                            .accessibilityLabel("API Key").accessibilityIdentifier("ModelAPIKey")
                    }
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
                                .textContentType(UITextContentType(rawValue: ""))
                                .focused($customModelFocused)
                                .accessibilityLabel("Model ID").accessibilityIdentifier("ModelID")
                        }
                    }
                } footer: {
                    Text("Your API key is stored only in this device’s Keychain.")
                }
                if let error = validationError ?? saveError ?? session.modelSettingsError {
                    Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("ModelSettingsError") }
                }
                Section {
                    Button("Reset", role: .destructive) { confirmingReset = true }
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
                    Button("Done") {
                        attemptedSave = true
                        saveError = nil
                        guard validationError == nil else { return }
                        do {
                            try session.saveConfiguration(draftConfiguration, key: key)
                            onSaved()
                            dismiss()
                        } catch { saveError = error.localizedDescription }
                    }
                    .accessibilityIdentifier("SettingsDone")
                }
            }
        }
        .alert("Reset Model Settings?", isPresented: $confirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                do {
                    try session.resetModelSettings()
                    baseURL = ""
                    model = ""
                    key = ""
                    apiProtocol = .responses
                    customModel = false
                    customModelFocused = false
                    attemptedSave = false
                    saveError = nil
                } catch { saveError = error.localizedDescription }
            }
            .accessibilityIdentifier("ConfirmResetModelSettings")
        } message: {
            Text("The saved connection settings and API key will be removed.")
        }
        .onAppear { session.modelCatalog.prefetch(baseURL: baseURL, key: key) }
        .onChange(of: baseURL) { _, _ in prefetchAfterInput() }
        .onChange(of: key) { _, _ in
            prefetchAfterInput()
            saveError = nil
        }
        .onChange(of: draftConfiguration) { _, _ in saveError = nil }
        .onDisappear {
            session.modelCatalog.cancel()
            key = ""
        }
    }

    private var draftConfiguration: ModelConfiguration {
        ModelConfiguration(
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines), apiProtocol: apiProtocol)
    }

    private var validationError: String? {
        guard attemptedSave else { return nil }
        do {
            try draftConfiguration.validateForSaving()
            return nil
        } catch ModelConfigurationError.missingModel where customModel {
            return String(localized: "Enter a Model ID.")
        } catch {
            return error.localizedDescription
        }
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
