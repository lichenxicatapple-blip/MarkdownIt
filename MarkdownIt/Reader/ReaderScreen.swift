import SwiftUI
import UniformTypeIdentifiers

private enum ReaderAccessibilityAction { case tools, ai, more, open, recents }
private enum HomeItem: CaseIterable, Hashable {
    case mark, slogan, openDocument, recentDocuments

    var spacingBefore: CGFloat {
        switch self {
        case .mark: 0
        case .slogan: ReaderDesign.homeBrandGap
        case .openDocument: ReaderDesign.homeGroupGap
        case .recentDocuments: ReaderDesign.homeActionGap
        }
    }
}

struct ReaderScreen: View {
    private let homeSlogan = ["just markdown,", "pure reading."]
    @ObservedObject var session: ReaderSession
    @State private var modelSettingsPresented = false
    @State private var modelSettingsOpening = false
    @State private var importing = false
    @State private var importingFolder = false
    @State private var toolsExpanded = false
    @State private var modelSettingsSaved = false
    @State private var visibleHomeItems: Set<HomeItem> = []
    @State private var recentsPresented = false
    @State private var privacyPresented = false
    @AccessibilityFocusState private var focusedAction: ReaderAccessibilityAction?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var markdownTypes: [UTType] {
        MarkdownDocument.supportedFilenameExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    private var appBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if session.document == nil {
                    welcome
                        .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                            VStack(alignment: .trailing, spacing: 0) {
                                Button {
                                    privacyPresented = true
                                } label: {
                                    Text("Privacy Policy")
                                        .frame(minWidth: ReaderDesign.hitTarget, minHeight: ReaderDesign.hitTarget)
                                        .contentShape(Rectangle())
                                }
                                .font(.caption).foregroundStyle(.secondary).buttonStyle(.plain)
                                .accessibilityIdentifier("PrivacyPolicy")
                                Text("Version \(appVersion) (\(appBuild))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                                    .accessibilityIdentifier("AppVersion")
                            }
                            .padding(.horizontal, 24).padding(.bottom, 8)
                        }
                        .transition(.opacity)
                } else {
                    ZStack {
                        ReaderWebView(session: session)
                            .ignoresSafeArea(.all, edges: .bottom)
                        if !session.rendererReady { ProgressView().accessibilityLabel("Formatting document") }
                    }
                    .overlay(alignment: .topLeading) {
                        if showsOutlineControl {
                            Button {
                                session.toggleOutline()
                            } label: {
                                chromeIcon("sidebar.left")
                            }
                            .modifier(ReaderGlassControl()).foregroundStyle(.secondary)
                            .padding(.leading, ReaderDesign.chromeInset).padding(.top, ReaderDesign.floatingInset)
                            .accessibilityLabel(
                                session.outlineExpanded
                                    ? String(localized: "Hide contents") : String(localized: "Show contents")
                            )
                            .accessibilityIdentifier("OutlineToggle")
                            .disabled(!session.rendererReady)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if !session.agentModalActive {
                            Button {
                                toolsExpanded = false
                                Task { await session.closeDocument() }
                            } label: {
                                chromeIcon("xmark")
                            }
                            .modifier(ReaderGlassControl()).foregroundStyle(.secondary)
                            .modifier(
                                ReaderDocumentCloseMotion(
                                    destination: closeDocumentOffset(width: geometry.size.width),
                                    reduceMotion: reduceMotion)
                            )
                            .padding(.top, ReaderDesign.floatingInset)
                            .accessibilityLabel("Close document")
                            .accessibilityIdentifier("CloseDocument")
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !session.agentModalActive {
                            ReaderFloatingControls(
                                trailingInset: session.agentReservedWidth + ReaderDesign.floatingInset,
                                expanded: toolsExpanded
                            ) { floatingActions }
                            .ignoresSafeArea(.all, edges: .bottom)
                            .animation(
                                reduceMotion ? nil : .easeOut(duration: ReaderDesign.agentDuration),
                                value: session.agentReservedWidth)
                        }
                    }
                    .allowsHitTesting(!session.isClosingDocument)
                    .accessibilityHidden(session.isClosingDocument)
                    .transition(.opacity)
                }
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: ReaderDesign.contentDuration), value: session.document == nil
            )
            .onChange(of: session.document == nil) { _, empty in
                if empty {
                    toolsExpanded = false
                    focusedAction = .open
                }
            }
            .onChange(of: session.agentOpen) { _, open in
                if open {
                    toolsExpanded = false
                } else if !session.agentModalActive {
                    focusedAction = .tools
                }
            }
            .onChange(of: session.agentModalActive) { _, active in
                if !active && !session.agentOpen { focusedAction = .tools }
            }
            .onChange(of: session.modelSettingsRequested) { _, requested in
                if requested {
                    session.modelSettingsRequested = false
                    presentModelSettings()
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .fileImporter(
            isPresented: $importing, allowedContentTypes: importingFolder ? [.folder] : markdownTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if importingFolder {
                    Task {
                        await session.grant(url)
                        session.reloadResources()
                    }
                } else {
                    Task { await session.open(url) }
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { session.errorMessage = error.localizedDescription }
            }
        }
        .fileDialogDefaultDirectory(importingFolder ? session.resourcePermissionDirectory : nil)
        .sheet(
            isPresented: $modelSettingsPresented,
            onDismiss: {
                toolsExpanded = false
                focusedAction = .tools
                session.finishAgentConfiguration(saved: modelSettingsSaved)
                modelSettingsSaved = false
            }
        ) {
            ModelSettingsView(session: session) { modelSettingsSaved = true }
                .presentationBackgroundInteraction(.disabled)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $privacyPresented) { PrivacyPolicyView() }
        .alert(
            "Unable to Complete Action",
            isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 && session.errorMessage != nil { session.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? "")
        }
        .alert("Load Local Images", isPresented: alertPresentation(\.needsResourcePermission)) {
            Button("Continue") {
                importingFolder = true
                importing = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Access to the “\(session.resourcePermissionDirectory?.lastPathComponent ?? "")” folder is required.")
        }
        .alert(
            "Allow Sending to This AI Service?",
            isPresented: alertPresentation(\.needsDataSharingConsent)
        ) {
            Button("Cancel", role: .cancel) { session.finishDataSharingConsent(allowed: false) }
                .accessibilityIdentifier("CancelModelDataSharing")
            Button("Allow") { session.finishDataSharingConsent(allowed: true) }
                .accessibilityIdentifier("AllowModelDataSharing")
        } message: {
            Text(
                "When you use AI, the full current document, your questions, this conversation, and images you select or the model reads will be sent to \(session.dataSharingServiceAddress).\n\nOnce you allow this, you won’t be asked again for this service."
            )
        }
        .background {
            ReaderAlert(
                isPresented: $session.needsModelConfiguration,
                title: String(localized: "AI Model Not Configured"),
                actions: [
                    .init(id: "cancel", title: String(localized: "Cancel"), style: .cancel) {
                        session.finishAgentConfiguration(saved: false)
                    },
                    .init(id: "settings", title: String(localized: "Open Settings"), preferred: true) {
                        session.modelSettingsRequested = true
                    },
                ]
            )
            .accessibilityHidden(true)
        }
        .background {
            ReaderAlert(
                isPresented: $session.closeSaveFailed,
                title: String(localized: "Unable to Save Document"),
                message: String(localized: "Closing without saving will discard your changes."),
                actions: [
                    .init(id: "retry", title: String(localized: "Retry"), preferred: true) {
                        Task { await session.closeDocument() }
                    },
                    .init(id: "discard", title: String(localized: "Discard Changes and Close"), style: .destructive) {
                        Task { await session.closeDocument(discardChanges: true) }
                    },
                    .init(id: "cancel", title: String(localized: "Cancel"), style: .cancel) {
                        session.cancelDocumentClose()
                    },
                ]
            )
            .accessibilityHidden(true)
        }

    }

    private func alertPresentation(_ keyPath: ReferenceWritableKeyPath<ReaderSession, Bool>) -> Binding<Bool> {
        Binding(
            get: { session[keyPath: keyPath] },
            set: { value in
                // SwiftUI may reset an alert twice while updating its dialog.
                // Do not publish an unchanged value back into that view update.
                if session[keyPath: keyPath] != value { session[keyPath: keyPath] = value }
            })
    }

    private var welcome: some View {
        GeometryReader { geometry in
            let markSize = min(ReaderDesign.homeMark, max(ReaderDesign.homeMark / 2, geometry.size.height * 0.22))
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(HomeItem.allCases, id: \.self) { item in
                        let visible = reduceMotion || visibleHomeItems.contains(item)
                        homeContent(item, markSize: markSize)
                            .modifier(HomeEntrance(visible: visible, reduceMotion: reduceMotion))
                            .accessibilityHidden(item == .mark || !visible)
                            .padding(.top, item.spacingBefore)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24).padding(.vertical, 32)
                .frame(minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize)
        }
        .task(id: reduceMotion) { await revealHome() }
        .onDisappear {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { visibleHomeItems.removeAll() }
        }
    }

    @ViewBuilder
    private func homeContent(_ item: HomeItem, markSize: CGFloat) -> some View {
        switch item {
        case .mark:
            Image("BrandMark").renderingMode(.original).resizable().scaledToFit()
                .frame(width: markSize)
        case .slogan:
            ViewThatFits(in: .horizontal) {
                Text(homeSlogan.joined(separator: " ")).fixedSize()
                Text(homeSlogan.joined(separator: "\n"))
            }
            .font(.custom("Newsreader16pt-Regular", size: ReaderDesign.homeSlogan, relativeTo: .title2))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(homeSlogan.joined(separator: " "))
            .accessibilityIdentifier("HomeSlogan")
        case .openDocument:
            Button("Open Document", systemImage: "doc", action: openDocument)
                .buttonStyle(.glassProminent).controlSize(.large)
                .accessibilityIdentifier("OpenDocument")
                .accessibilityFocused($focusedAction, equals: .open)
        case .recentDocuments:
            Button {
                recentsPresented = true
            } label: {
                Text("Recent Documents...")
                    .frame(minWidth: ReaderDesign.hitTarget, minHeight: ReaderDesign.hitTarget)
                    .contentShape(Rectangle())
            }
            .font(.subheadline).foregroundStyle(.secondary).buttonStyle(.plain)
            .accessibilityIdentifier("RecentDocuments")
            .accessibilityFocused($focusedAction, equals: .recents)
            .popover(isPresented: $recentsPresented, arrowEdge: .top) {
                RecentDocumentsView(
                    store: session.recentDocuments, compact: horizontalSizeClass == .compact,
                    open: { try await session.openRecent($0) }
                )
                .presentationCompactAdaptation(.sheet)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.disabled)
            }
            .onChange(of: recentsPresented) { _, presented in
                if !presented && session.document == nil { focusedAction = .recents }
            }
        }
    }

    private func revealHome() async {
        if reduceMotion {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { visibleHomeItems = Set(HomeItem.allCases) }
            return
        }
        guard visibleHomeItems.isEmpty else { return }
        await Task.yield()
        for (index, item) in HomeItem.allCases.enumerated() {
            if index > 0 {
                do { try await Task.sleep(for: .seconds(ReaderDesign.homeStagger)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: ReaderDesign.homeDuration)) { _ = visibleHomeItems.insert(item) }
        }
    }

    private var showsOutlineControl: Bool { session.mode == "preview" && session.hasOutline }

    private func closeDocumentOffset(width: CGFloat) -> CGFloat {
        if session.agentOpen {
            let outlineClearance =
                showsOutlineControl
                ? ReaderDesign.hitTarget + 2 * ReaderDesign.floatingInset : 0
            return ReaderDesign.chromeInset + max(session.documentLeading, outlineClearance)
        }
        return max(ReaderDesign.chromeInset, width - ReaderDesign.hitTarget - ReaderDesign.chromeInset)
    }

    private func chromeIcon(_ name: String) -> some View {
        Group {
            if let image = ReaderChromeSymbols.image(name) {
                Image(uiImage: image).renderingMode(.template)
            }
        }
        .frame(width: ReaderDesign.readerChromeCanvas, height: ReaderDesign.readerChromeCanvas)
        .frame(width: ReaderDesign.hitTarget, height: ReaderDesign.hitTarget)
        .contentShape(Circle())
    }

    private var toolsAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: ReaderDesign.toolsDuration)
    }

    private var floatingActions: some View {
        let compact = horizontalSizeClass == .compact
        return GlassEffectContainer(spacing: ReaderDesign.floatingGap) {
            ReaderToolsLayout(expansion: toolsExpanded ? 1 : 0) {
                if session.mode == "source" {
                    Button {
                        session.performSourceHistory(forward: false)
                    } label: {
                        actionIcon("arrow.uturn.backward", compact: compact)
                    }
                    .modifier(ReaderGlassControl())
                    .disabled(!session.canUndoSource)
                    .accessibilityLabel("Undo").accessibilityIdentifier("SourceUndo")
                    .modifier(ReaderToolVisibility(expanded: toolsExpanded))
                    Button {
                        session.performSourceHistory(forward: true)
                    } label: {
                        actionIcon("arrow.uturn.forward", compact: compact)
                    }
                    .modifier(ReaderGlassControl())
                    .disabled(!session.canRedoSource)
                    .accessibilityLabel("Redo").accessibilityIdentifier("SourceRedo")
                    .modifier(ReaderToolVisibility(expanded: toolsExpanded))
                }
                Button {
                    session.toggleAgent()
                    toolsExpanded = false
                } label: {
                    actionIcon("bubble.left", compact: compact)
                }
                .modifier(ReaderGlassControl())
                .accessibilityLabel("AI").accessibilityIdentifier("GlobalAI")
                .accessibilityFocused($focusedAction, equals: .ai)
                .modifier(ReaderToolVisibility(expanded: toolsExpanded))
                Button {
                    session.toggleMode()
                    toolsExpanded = false
                } label: {
                    actionIcon(
                        session.mode == "source" ? "book" : "chevron.left.forwardslash.chevron.right",
                        compact: compact)
                }
                .modifier(ReaderGlassControl())
                .accessibilityLabel(
                    session.mode == "source"
                        ? String(localized: "Switch to preview") : String(localized: "Switch to source mode")
                )
                .accessibilityIdentifier("ModeToggle")
                .modifier(ReaderToolVisibility(expanded: toolsExpanded))
                ReaderMoreMenu(
                    iconSize: compact ? ReaderDesign.compactFloatingIcon : ReaderDesign.floatingIcon,
                    openModelSettings: presentModelSettings
                )
                .contentShape(Circle())
                .modifier(ReaderGlassControl())
                .accessibilityFocused($focusedAction, equals: .more)
                .modifier(ReaderToolVisibility(expanded: toolsExpanded))
                Button {
                    toolsExpanded.toggle()
                } label: {
                    actionIcon("chevron.left", compact: true).rotationEffect(.degrees(toolsExpanded ? 180 : 0))
                }
                .modifier(ReaderGlassControl())
                .accessibilityLabel(
                    toolsExpanded
                        ? String(localized: "Hide reading tools") : String(localized: "Show reading tools")
                )
                .accessibilityIdentifier("ToolsToggle")
                .accessibilityFocused($focusedAction, equals: .tools)
            }
        }
        .foregroundStyle(.primary)
        .disabled(!session.rendererReady)
        .animation(toolsAnimation, value: toolsExpanded)
    }

    private func presentModelSettings() {
        guard !modelSettingsOpening, !modelSettingsPresented else { return }
        modelSettingsOpening = true
        modelSettingsSaved = false
        let token = session.documentToken
        Task {
            defer { modelSettingsOpening = false }
            guard await session.closeAgent() else { return }
            guard session.document != nil, session.documentToken == token, !session.isClosingDocument else { return }
            if session.modelSettingsError != nil { session.reloadModelSettings() }
            modelSettingsPresented = true
        }
    }

    private func openDocument() {
        importingFolder = false
        importing = true
    }

    private func actionIcon(_ symbol: String, compact: Bool) -> some View {
        Image(systemName: symbol).font(
            .system(size: compact ? ReaderDesign.compactFloatingIcon : ReaderDesign.floatingIcon)
        )
        .frame(width: ReaderDesign.hitTarget, height: ReaderDesign.hitTarget).contentShape(Circle())
    }

}

private struct HomeEntrance: ViewModifier {
    let visible: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content.opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : -ReaderDesign.homeEntranceOffset)
            .allowsHitTesting(visible)
            .transaction {
                if reduceMotion {
                    $0.animation = nil
                    $0.disablesAnimations = true
                }
            }
    }
}

/// All floating reader controls use the same system material and circular feedback.
private struct ReaderGlassControl: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle)
    }
}
