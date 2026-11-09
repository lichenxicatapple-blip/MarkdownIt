import SwiftUI
import UIKit

/// A seed for the system save dialog, never an editing buffer.
final class NewDocumentExport: Identifiable {
    let id = UUID()
    let fileURL: URL
    private let directory: URL

    init(filename: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileURL = directory.appendingPathComponent(filename).appendingPathExtension("md")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try Data().write(to: fileURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

struct NewDocumentPicker: UIViewControllerRepresentable {
    let document: NewDocumentExport?
    let completion: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> Presenter {
        let presenter = Presenter()
        context.coordinator.presenter = presenter
        presenter.didAppear = { [weak coordinator = context.coordinator] in coordinator?.presentIfReady() }
        return presenter
    }

    func updateUIViewController(_ uiViewController: Presenter, context: Context) {
        context.coordinator.document = document
        context.coordinator.completion = completion
        context.coordinator.presentIfReady()
    }

    final class Presenter: UIViewController {
        var didAppear: (() -> Void)?

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            didAppear?()
        }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        weak var presenter: Presenter?
        var document: NewDocumentExport?
        var completion: ((URL?) -> Void)?
        private var activeID: UUID?
        private var finishing = false

        func presentIfReady() {
            guard activeID == nil, !finishing, let document, let presenter,
                presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil
            else { return }
            activeID = document.id
            let picker = UIDocumentPickerViewController(forExporting: [document.fileURL], asCopy: true)
            picker.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            picker.modalPresentationStyle = .pageSheet
            picker.sheetPresentationController?.detents = [.large()]
            picker.delegate = self
            picker.presentationController?.delegate = self
            presenter.present(picker, animated: true)
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(controller, url: urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(controller, url: nil)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            finish(presentationController.presentedViewController, url: nil, alreadyDismissed: true)
        }

        private func finish(_ controller: UIViewController, url: URL?, alreadyDismissed: Bool = false) {
            guard activeID != nil, !finishing else { return }
            finishing = true
            let complete = { [self] in
                activeID = nil
                document = nil
                completion?(url)
                finishing = false
            }
            if alreadyDismissed || controller.presentingViewController == nil {
                complete()
            } else {
                controller.dismiss(animated: true, completion: complete)
            }
        }
    }
}
