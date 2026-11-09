import SwiftUI

/// A pending network permission belongs to one live request, not to a Web page or draft.
@MainActor
final class WebSearchAuthorization: ObservableObject {
    struct Request: Identifiable {
        let id: UUID
        let provider: WebSearchProvider
        let query: String
    }

    @Published private(set) var request: Request?
    @Published var isPresented = false
    private let consent: WebSearchConsent
    private var continuation: CheckedContinuation<Bool, Never>?
    private var isCurrent: (@MainActor () -> Bool)?

    init(defaults: UserDefaults) { consent = WebSearchConsent(defaults: defaults) }

    func authorize(
        provider: WebSearchProvider, query: String, isCurrent: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
        if consent.allows(provider) { return true }
        guard request == nil else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, isCurrent() else {
                    continuation.resume(returning: false)
                    return
                }
                self.continuation = continuation
                self.isCurrent = isCurrent
                request = Request(id: id, provider: provider, query: query)
                isPresented = true
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(allowed: false, id: id) }
        }
    }

    func finish(allowed: Bool, id: UUID? = nil) {
        guard let request, id == nil || request.id == id else { return }
        let valid = allowed && isCurrent?() == true
        let pending = continuation
        self.request = nil
        isPresented = false
        continuation = nil
        isCurrent = nil
        if valid { consent.allow(request.provider) }
        pending?.resume(returning: valid)
    }
}

struct WebSearchConsentPresenter: View {
    @ObservedObject var authorization: WebSearchAuthorization

    var body: some View {
        let requestID = authorization.request?.id
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .alert(
                "Allow Web Search?",
                isPresented: $authorization.isPresented
            ) {
                Button("Cancel", role: .cancel) {
                    if let requestID { authorization.finish(allowed: false, id: requestID) }
                }
                .accessibilityIdentifier("CancelSearchDataSharing")
                Button("Allow") {
                    if let requestID { authorization.finish(allowed: true, id: requestID) }
                }
                .accessibilityIdentifier("AllowSearchDataSharing")
            } message: {
                if let request = authorization.request {
                    if request.provider.extractionEndpoint != nil {
                        Text(
                            "Search terms and selected webpage URLs will be sent to \(request.provider.title). Search results and page content will be shared with your AI service.\n\n\(request.query)"
                        )
                    } else {
                        Text(
                            "Search terms will be sent to \(request.provider.title), and the results will be shared with your AI service.\n\n\(request.query)"
                        )
                    }
                }
            }
    }
}
