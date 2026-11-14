import Foundation

struct ModelConfiguration: Codable, Equatable, Sendable {
    var baseURL: String
    var model: String
    private var previousProtocol: String?

    var requiresResponsesConfirmation: Bool { previousProtocol != nil }

    init(baseURL: String = "", model: String = "", storedProtocol: String? = nil) {
        self.baseURL = baseURL
        self.model = model
        previousProtocol = storedProtocol.flatMap { $0.isEmpty || $0 == "responses" ? nil : $0 }
    }

    private enum CodingKeys: String, CodingKey { case baseURL, model, apiProtocol }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            baseURL: try values.decode(String.self, forKey: .baseURL),
            model: try values.decode(String.self, forKey: .model),
            storedProtocol: try values.decodeIfPresent(String.self, forKey: .apiProtocol))
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(baseURL, forKey: .baseURL)
        try values.encode(model, forKey: .model)
        // Retain an unconfirmed old connection without enabling its old protocol.
        try values.encode(previousProtocol ?? "responses", forKey: .apiProtocol)
    }

    func endpoint() throws -> URL {
        guard !requiresResponsesConfirmation else { throw ModelConfigurationError.responsesConfirmationRequired }
        let url = try endpoint(path: "responses")
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelConfigurationError.missingModel
        }
        return url
    }

    func modelsEndpoint() throws -> URL { try endpoint(path: "models") }

    func validateForSaving() throws {
        if !baseURL.isEmpty || !model.isEmpty { _ = try endpoint() }
    }

    private func endpoint(path suffix: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ModelConfigurationError.missingBaseURL }
        guard let url = URL(string: trimmed), let scheme = url.scheme,
            ["https", "http"].contains(scheme.lowercased()), url.host != nil,
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else {
            throw ModelConfigurationError.invalidBaseURL
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var path = components.percentEncodedPath
        // Accept a pasted complete endpoint while always using Responses.
        while path.hasSuffix("/") { path.removeLast() }
        for existingSuffix in ["/chat/completions", "/responses", "/models"] where path.hasSuffix(existingSuffix) {
            path.removeLast(existingSuffix.count)
            break
        }
        components.percentEncodedPath = path + "/" + suffix
        guard let endpoint = components.url else { throw ModelConfigurationError.invalidBaseURL }
        return endpoint
    }
}

enum ModelConfigurationError: LocalizedError, Equatable {
    case missingBaseURL, invalidBaseURL, missingModel, responsesConfirmationRequired

    var errorDescription: String? {
        switch self {
        case .missingBaseURL: String(localized: "Enter a Base URL.")
        case .invalidBaseURL: String(localized: "Enter a valid Base URL.")
        case .missingModel: String(localized: "Select a model.")
        case .responsesConfirmationRequired:
            String(localized: "Only Responses is supported. Confirm the connection settings.")
        }
    }
}

enum ModelError: LocalizedError {
    case configuration, missingKey, sharingPermission, invalidResponse, interrupted, incomplete, contextLimit,
        requestTooLarge,
        generationFailed, contextPreparation
    case rateLimited(TimeInterval)
    case service(Int, String)

    var errorDescription: String? {
        switch self {
        case .configuration: String(localized: "Check the service URL and model.")
        case .missingKey: String(localized: "Enter your API key in Model Settings.")
        case .sharingPermission: String(localized: "Allow sending to this AI service before trying again.")
        case .invalidResponse:
            String(localized: "The service returned an invalid Responses response.")
        case .interrupted: String(localized: "The response was interrupted.")
        case .incomplete: String(localized: "The response is incomplete. Try generating it again.")
        case .contextLimit: String(localized: "The content exceeds the model’s context limit.")
        case .requestTooLarge: String(localized: "The request is too large.")
        case .generationFailed: String(localized: "The model could not generate a response.")
        case .contextPreparation: String(localized: "Unable to prepare the conversation. Try again.")
        case .rateLimited: String(localized: "Too many requests. Try again later.")
        case .service(let code, let message): String(localized: "The model service returned HTTP \(code). \(message)")
        }
    }
}

/// Keep the provider's explanation separate from the classification used by the UI.
struct ModelServiceFailure: LocalizedError {
    let reason: ModelError
    let httpStatus: Int?
    let message: String?

    var errorDescription: String? {
        if let httpStatus {
            if message == nil, case .service = reason { return reason.localizedDescription }
            return ModelError.service(httpStatus, message ?? reason.localizedDescription).localizedDescription
        }
        return message ?? reason.localizedDescription
    }

    func redacting(_ key: String) -> ModelServiceFailure {
        ModelServiceFailure(
            reason: reason, httpStatus: httpStatus,
            message: message.map { String($0.replacingOccurrences(of: key, with: "••••••").prefix(500)) })
    }
}

struct ModelImage: Codable, Sendable, Equatable {
    let id: String
    let data: Data
    let mimeType: String

    var dataURL: String { "data:\(mimeType);base64," + data.base64EncodedString() }
}

struct ChatMessage: Codable, Sendable {
    var role: String
    var content: String
    var images: [ModelImage] = []
}

/// Keep documents and credentials at the explicitly configured endpoint.
/// A redirect is returned as its original HTTP response, never followed silently.
final class ModelRequestPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = ModelRequestPolicy()

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
