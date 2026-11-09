import UIKit

/// The same native text surface is used for creating, reading and editing a note,
/// whether attached to the document or presented in a compact sheet.
@MainActor
final class AnnotationCardView: UIView, UITextViewDelegate {
    let textView = UITextView()
    private let cancel = UIButton(type: .system)
    private let done = UIButton(type: .system)
    private let underline = UIButton(type: .system)
    private let delete = UIButton(type: .system)
    private let header = UIStackView()
    private let footer = UIStackView()
    private let rule = UIView()
    private let arrow = UIView()
    private var hasNote = false
    private var original = ""
    private var busy = false
    private var pendingStyleUpdate = false
    var onCancel: (() -> Void)?
    var onDone: ((String) -> Void)?
    var onUnderline: (() -> Void)?
    var onDelete: (() -> Void)?
    var onChange: (() -> Void)?
    var hasUnsavedChanges: Bool { textView.text != original }

    init(note: String, underlined: Bool, existing: Bool) {
        super.init(frame: .zero)
        original = note
        hasNote = existing
        accessibilityIdentifier = "AnnotationCard"
        backgroundColor = ReaderDesign.annotationPaper
        layer.cornerRadius = ReaderDesign.annotationRadius
        layer.borderWidth = 1 / traitCollection.displayScale
        layer.shadowOpacity = 0.14
        layer.shadowRadius = ReaderDesign.annotationBodyGap
        layer.shadowOffset = CGSize(width: 0, height: ReaderDesign.annotationGap)
        arrow.backgroundColor = backgroundColor
        arrow.transform = CGAffineTransform(rotationAngle: .pi / 4)
        insertSubview(arrow, at: 0)
        header.axis = .horizontal
        header.distribution = .equalSpacing
        for button in [cancel, done, underline, delete] {
            button.configuration = .plain()
            button.configuration?.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: ReaderDesign.annotationGap, bottom: 0, trailing: ReaderDesign.annotationGap)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: ReaderDesign.hitTarget).isActive = true
        }
        cancel.setTitle(String(localized: "Cancel"), for: .normal)
        cancel.tintColor = ReaderDesign.annotationMuted
        done.setTitle(String(localized: "Done"), for: .normal)
        done.accessibilityIdentifier = "AnnotationDone"
        cancel.accessibilityIdentifier = "AnnotationCancel"
        header.addArrangedSubview(cancel)
        header.addArrangedSubview(done)
        addSubview(header)
        textView.text = note
        textView.backgroundColor = .clear
        textView.delegate = self
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(
            top: 0, left: 0, bottom: 0, right: ReaderDesign.annotationScrollbarGap)
        textView.accessibilityIdentifier = "AnnotationInput"
        textView.accessibilityLabel = String(localized: "Annotation")
        textView.keyboardDismissMode = .interactive
        addSubview(textView)
        rule.backgroundColor = ReaderDesign.annotationLine
        addSubview(rule)
        footer.axis = .horizontal
        footer.distribution = .equalSpacing
        underline.setTitle(
            underlined ? String(localized: "Remove Underline") : String(localized: "Underline"), for: .normal)
        underline.setImage(UIImage(systemName: "underline"), for: .normal)
        underline.tintColor = underlined ? .systemRed : ReaderDesign.annotationMuted
        underline.accessibilityIdentifier = "AnnotationUnderline"
        delete.setTitle(String(localized: "Delete Annotation…"), for: .normal)
        delete.setImage(UIImage(systemName: "trash"), for: .normal)
        delete.tintColor = .systemRed
        delete.accessibilityIdentifier = "AnnotationDelete"
        for button in [underline, delete] {
            button.configuration?.imagePadding = ReaderDesign.annotationScrollbarInset
            button.titleLabel?.numberOfLines = 1
            button.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                textStyle: .footnote)
        }
        footer.addArrangedSubview(underline)
        footer.addArrangedSubview(delete)
        addSubview(footer)
        footer.isHidden = !existing
        rule.isHidden = !existing
        cancel.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
        done.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.textView.endEditing(true)
                self.onDone?(self.textView.text)
            }, for: .touchUpInside)
        underline.addAction(UIAction { [weak self] _ in self?.onUnderline?() }, for: .touchUpInside)
        delete.addAction(UIAction { [weak self] _ in self?.onDelete?() }, for: .touchUpInside)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) {
            (view: AnnotationCardView, _) in view.updateStyle()
        }
        updateStyle()
        updateActions()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateStyle() {
        guard textView.markedTextRange == nil else {
            pendingStyleUpdate = true
            return
        }
        pendingStyleUpdate = false
        backgroundColor = ReaderDesign.annotationPaper
        arrow.backgroundColor = backgroundColor
        layer.borderColor = ReaderDesign.annotationLine.resolvedColor(with: traitCollection).cgColor
        layer.shadowColor = UIColor.black.cgColor
        let base =
            UIFont(name: "SongtiSC-Regular", size: ReaderDesign.annotationBodySize)
            ?? UIFont(
                descriptor: UIFont.systemFont(ofSize: ReaderDesign.annotationBodySize).fontDescriptor.withDesign(.serif)
                    ?? UIFont.systemFont(ofSize: ReaderDesign.annotationBodySize).fontDescriptor,
                size: ReaderDesign.annotationBodySize)
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
        let actionFont = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traitCollection)
        for button in [underline, delete] {
            button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { value in
                var attributes = value
                attributes.font = actionFont
                return attributes
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = max(0, font.pointSize * ReaderDesign.annotationLeading - font.lineHeight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: paragraph, .foregroundColor: ReaderDesign.annotationInk,
        ]
        let selection = textView.selectedRange
        textView.typingAttributes = attributes
        if !textView.text.isEmpty {
            textView.textStorage.addAttributes(
                attributes, range: NSRange(location: 0, length: textView.text.utf16.count))
        }
        textView.font = font
        textView.textColor = ReaderDesign.annotationInk
        textView.selectedRange = selection
        setNeedsLayout()
        onChange?()
    }

    func fittingSize(width: CGFloat, maximumHeight: CGFloat) -> CGSize {
        let fixed =
            ReaderDesign.hitTarget + ReaderDesign.annotationScrollbarInset + ReaderDesign.annotationBodyGap
            + footerHeight(width: width)
        let textWidth = max(1, width - ReaderDesign.annotationInset - ReaderDesign.annotationScrollbarInset)
        let natural = textView.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        let maximum = min(ReaderDesign.annotationMaximumEditor, max(1, maximumHeight - fixed))
        let height = min(max(ReaderDesign.annotationMinimumEditor, natural), maximum)
        return CGSize(width: width, height: min(maximumHeight, fixed + height))
    }

    private func footerHeight(width: CGFloat) -> CGFloat {
        guard hasNote else { return 0 }
        let needed = underline.intrinsicContentSize.width + delete.intrinsicContentSize.width
        let rows: CGFloat = needed > width - ReaderDesign.annotationScrollbarInset * 2 ? 2 : 1
        return ReaderDesign.hitTarget * rows + ReaderDesign.annotationScrollbarInset
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = ReaderDesign.annotationScrollbarInset
        header.frame = CGRect(x: inset, y: inset / 2, width: bounds.width - inset * 2, height: ReaderDesign.hitTarget)
        let bottom = footerHeight(width: bounds.width)
        let stacked = bottom > ReaderDesign.hitTarget + inset
        footer.axis = stacked ? .vertical : .horizontal
        footer.distribution = stacked ? .fillEqually : .equalSpacing
        footer.frame = CGRect(x: inset, y: bounds.height - bottom, width: bounds.width - inset * 2, height: bottom)
        rule.frame = CGRect(x: 0, y: footer.frame.minY, width: bounds.width, height: 1 / traitCollection.displayScale)
        textView.frame = CGRect(
            x: ReaderDesign.annotationInset, y: header.frame.maxY + inset / 2,
            width: max(0, bounds.width - ReaderDesign.annotationInset - inset),
            height: max(0, bounds.height - bottom - ReaderDesign.annotationBodyGap - header.frame.maxY - inset / 2))
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    func setArrow(x: CGFloat, below: Bool, hidden: Bool = false) {
        arrow.isHidden = hidden
        let size = ReaderDesign.annotationArrow
        arrow.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        arrow.center = CGPoint(
            x: min(max(x, ReaderDesign.annotationRadius), bounds.width - ReaderDesign.annotationRadius),
            y: below ? bounds.height : 0)
    }

    func restoreDraft(text: String, selection: NSRange) {
        textView.text = text
        textView.selectedRange = NSRange(location: max(0, min(selection.location, text.utf16.count)), length: 0)
        if selection.location >= 0, selection.location <= text.utf16.count, selection.length >= 0,
            selection.length <= text.utf16.count - selection.location
        {
            textView.selectedRange = selection
        }
        updateStyle()
        updateActions()
    }

    func setUnderlined(_ value: Bool) {
        underline.setTitle(value ? String(localized: "Remove Underline") : String(localized: "Underline"), for: .normal)
        underline.tintColor = value ? .systemRed : ReaderDesign.annotationMuted
    }

    func setBusy(_ value: Bool) {
        busy = value
        updateActions()
    }
    private func updateActions() {
        done.isEnabled = !busy && !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        cancel.isEnabled = !busy
        underline.isEnabled = !busy && !hasUnsavedChanges
        delete.isEnabled = !busy && !hasUnsavedChanges
    }
    func textViewDidChange(_ textView: UITextView) {
        if pendingStyleUpdate && textView.markedTextRange == nil { updateStyle() }
        updateActions()
        onChange?()
    }
}
