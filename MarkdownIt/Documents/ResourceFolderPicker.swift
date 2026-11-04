import SwiftUI
import UniformTypeIdentifiers

/// Presentation only: these labels never participate in permission checks or file access.
enum ResourceFolderPath {
    static func display(_ url: URL) -> String {
        var components = url.standardizedFileURL.pathComponents.filter { $0 != "/" }
        if components.starts(with: ["private", "var"]) { components.removeFirst() }
        let cloud = ["var", "mobile", "Library", "Mobile Documents", "com~apple~CloudDocs"]
        if components.starts(with: cloud) {
            return ([String(localized: "iCloud Drive")] + components.dropFirst(cloud.count))
                .joined(separator: " / ")
        }
        let appStorage = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
            .standardizedFileURL.pathComponents.filter { $0 != "/" }
        for container in [
            appStorage,
            ["var", "mobile", "Containers", "Shared", "AppGroup"],
            ["var", "mobile", "Containers", "Data", "Application"],
        ] {
            guard components.starts(with: container), components.count > container.count,
                UUID(uuidString: components[container.count]) != nil
            else { continue }
            var folders = Array(components.dropFirst(container.count + 1))
            if folders.first == "File Provider Storage" { folders.removeFirst() }
            if folders.first == "Documents", folders.count > 1 { folders.removeFirst() }
            if !folders.isEmpty { return folders.joined(separator: " / ") }
        }
        return components.joined(separator: " / ")
    }
}

/// Owns the single permission prompt and native folder selection.
struct ResourceFolderPermission: ViewModifier {
    @ObservedObject var session: ReaderSession
    @State private var pickerPresented = false
    @State private var requestToken: String?

    func body(content: Content) -> some View {
        content
            .sheet(
                isPresented: Binding(
                    get: { session.needsResourcePermission },
                    set: { if session.needsResourcePermission != $0 { session.needsResourcePermission = $0 } })
            ) {
                ResourceFolderPrompt(path: folderPath) {
                    session.needsResourcePermission = false
                } choose: {
                    requestToken = session.documentToken
                    pickerPresented = true
                }
                .presentationSizing(.fitted)
                .presentationBackgroundInteraction(.disabled)
                .fileImporter(
                    isPresented: $pickerPresented, allowedContentTypes: [.folder], allowsMultipleSelection: false,
                    onCompletion: finishSelection,
                    onCancellation: {
                        let token = requestToken
                        requestToken = nil
                        guard token == session.documentToken else { return }
                        session.needsResourcePermission = false
                    })
            }
    }

    private func finishSelection(_ result: Result<[URL], Error>) {
        guard let token = requestToken else { return }
        requestToken = nil
        guard token == session.documentToken else { return }
        guard case .success(let urls) = result, let url = urls.first else { return }
        Task { if await session.grant(url) { session.reloadResources() } }
    }

    private var folderPath: String {
        session.resourcePermissionDirectory.map(ResourceFolderPath.display) ?? ""
    }

}

private struct ResourceFolderPrompt: View {
    let path: String
    let cancel: () -> Void
    let choose: () -> Void
    @State private var messageHeight: CGFloat = 0
    @State private var actionsHeight: CGFloat = 0
    private let inset: CGFloat = 24
    private let groupSpacing: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: groupSpacing) {
            ScrollView {
                message
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        messageHeight = $0
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(idealHeight: messageHeight, maxHeight: messageHeight > 0 ? messageHeight : nil)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    cancelButton
                    chooseButton
                }
                VStack(spacing: 12) {
                    chooseButton
                    cancelButton
                }
            }
            .controlSize(.large)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                actionsHeight = $0
            }
        }
        .padding(inset)
        .frame(idealWidth: 420, maxWidth: 480)
        // Compact sheets use detents rather than the fitted presentation size.
        // Measure natural content so paths and Dynamic Type determine the height.
        .presentationDetents(
            messageHeight > 0 && actionsHeight > 0
                ? [.height(messageHeight + actionsHeight + groupSpacing + inset * 2)] : [.medium])
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Load Local Images")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("ResourcePermissionTitle")
            Text("This document references images in the folder below. Please allow access.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("ResourcePermissionExplanation")
            Text(verbatim: path)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .accessibilityIdentifier("ResourcePermissionPath")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var cancelButton: some View {
        Button(role: .cancel, action: cancel) { Text("Cancel").frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("CancelResourcePermission")
    }

    private var chooseButton: some View {
        Button(action: choose) { Text("Choose Folder").frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("ContinueResourcePermission")
    }
}
