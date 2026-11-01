import Foundation
import Security

enum ModelAPIProtocol: String, CaseIterable, Sendable {
    case responses
    case chatCompletions

    var title: String {
        switch self {
        case .responses: "Responses"
        case .chatCompletions: "Chat Completions"
        }
    }

    var path: String { self == .responses ? "responses" : "chat/completions" }
}

struct ModelConfiguration: Equatable, Sendable {
    var baseURL = ""
    var model = ""
    var apiProtocol: ModelAPIProtocol = .responses

    func endpoint() throws -> URL {
        let url = try endpoint(path: apiProtocol.path)
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
        // Accept a pasted complete endpoint while keeping the explicit protocol authoritative.
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
    case missingBaseURL, invalidBaseURL, missingModel

    var errorDescription: String? {
        switch self {
        case .missingBaseURL: String(localized: "Enter a Base URL.")
        case .invalidBaseURL: String(localized: "Enter a valid Base URL.")
        case .missingModel: String(localized: "Select a model.")
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
        case .configuration: String(localized: "Enter a valid Base URL and Model ID in Model Settings.")
        case .missingKey: String(localized: "Enter your API key in Model Settings.")
        case .sharingPermission: String(localized: "Allow sending to this AI service before trying again.")
        case .invalidResponse:
            String(localized: "The model service returned an unreadable response. Check the API type and Model ID.")
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

enum ModelKeychain {
    static var service: String {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                return "dev.catli.MarkdownIt.model.ui-testing"
            }
        #endif
        return "dev.catli.MarkdownIt.model"
    }
    static func read(service: String = ModelKeychain.service) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
            let data = value as? Data
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func write(_ value: String, service: String = ModelKeychain.service) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "api-key",
        ]
        let data = Data(value.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(update)) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let result = SecItemAdd(item as CFDictionary, nil)
        guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
    }

    static func delete(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "api-key",
        ]
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
    }
}

struct ModelImage: Sendable, Equatable {
    let id: String
    let data: Data
    let mimeType: String

    var dataURL: String { "data:\(mimeType);base64," + data.base64EncodedString() }
}

struct ChatMessage: Sendable {
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
