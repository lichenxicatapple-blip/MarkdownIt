import CryptoKit
import Foundation

enum DocumentRevision {
    static func data(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func text(_ text: String) -> String { data(Data(text.utf8)) }
}
