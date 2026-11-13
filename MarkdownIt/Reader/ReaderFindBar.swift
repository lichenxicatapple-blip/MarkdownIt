import UIKit

/// A floating native input and navigator. The reader viewport owns its position;
/// this view lays out only its contents and never extends the keyboard region.
@MainActor
final class ReaderFindBar: UIView, UITextFieldDelegate {
    let field = UISearchTextField()
    private let material = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let result = UILabel()
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let settings = UIButton(type: .system)
    private var focusRequested = false
    private var showing = false
    var onQuery: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?
    var onOptions: ((ReaderFindController.Options) -> Void)?

    var preferredHeight: CGFloat {
        max(ReaderDesign.hitTarget, field.font?.lineHeight ?? 0) + 2 * ReaderDesign.findInset
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        accessibilityIdentifier = "DocumentFindBar"
        material.isUserInteractionEnabled = false
        material.accessibilityElementsHidden = true
        material.cornerConfiguration = .capsule()
        addSubview(material)
        [settings, field, result, previousButton, nextButton, closeButton].forEach(addSubview)
        field.delegate = self
        field.placeholder = String(localized: "Find")
        field.accessibilityLabel = String(localized: "Find in Document")
        field.accessibilityIdentifier = "DocumentFindField"
        field.backgroundColor = .clear
        field.borderStyle = .none
        field.clearButtonMode = .whileEditing
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.returnKeyType = .search
        field.enablesReturnKeyAutomatically = true
        field.adjustsFontForContentSizeCategory = true
        field.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
        configure(
            settings, symbol: "magnifyingglass", title: String(localized: "Search Options"), id: "DocumentFindOptions")
        settings.showsMenuAsPrimaryAction = true
        field.leftView = nil
        field.leftViewMode = .never
        result.textColor = .secondaryLabel
        result.accessibilityIdentifier = "DocumentFindCount"
        result.accessibilityLabel = String(localized: "Search Results")
        result.textAlignment = .center
        result.adjustsFontForContentSizeCategory = true
        configure(
            previousButton, symbol: "chevron.up", title: String(localized: "Previous Match"), id: "DocumentFindPrevious"
        )
        configure(nextButton, symbol: "chevron.down", title: String(localized: "Next Match"), id: "DocumentFindNext")
        configure(closeButton, symbol: "xmark", title: String(localized: "Close Find"), id: "DocumentFindClose")
        previousButton.addAction(UIAction { [weak self] _ in self?.onPrevious?() }, for: .touchUpInside)
        nextButton.addAction(UIAction { [weak self] _ in self?.onNext?() }, for: .touchUpInside)
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (view: ReaderFindBar, _: UITraitCollection) in
            view.updateTypography()
        }
        updateTypography()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        material.frame = bounds
        let inset = ReaderDesign.findInset
        let hit = ReaderDesign.hitTarget
        let y = (bounds.height - hit) / 2
        closeButton.frame = CGRect(x: bounds.width - inset - hit, y: y, width: hit, height: hit)
        nextButton.frame = closeButton.frame.offsetBy(dx: -hit, dy: 0)
        previousButton.frame = nextButton.frame.offsetBy(dx: -hit, dy: 0)
        let countWidth = result.isHidden ? 0 : min(result.intrinsicContentSize.width + inset * 2, bounds.width / 4)
        result.frame = CGRect(x: previousButton.frame.minX - countWidth, y: 0, width: countWidth, height: bounds.height)
        settings.frame = CGRect(x: inset, y: y, width: hit, height: hit)
        field.frame = CGRect(
            x: settings.frame.maxX, y: inset,
            width: max(0, result.frame.minX - settings.frame.maxX), height: bounds.height - inset * 2)
        if focusRequested, window != nil, !isHidden, !bounds.isEmpty {
            focusRequested = false
            field.becomeFirstResponder()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if focusRequested { setNeedsLayout() }
    }

    private func configure(_ button: UIButton, symbol: String, title: String, id: String) {
        var config = UIButton.Configuration.plain()
        config.image = ReaderChromeSymbols.symbol(symbol, pointSize: ReaderDesign.readerChromeIcon)
        config.baseForegroundColor = .secondaryLabel
        config.contentInsets = .zero
        config.cornerStyle = .capsule
        button.configuration = config
        button.accessibilityLabel = title
        button.accessibilityIdentifier = id
        button.isPointerInteractionEnabled = true
    }

    private func updateTypography() {
        field.font = .preferredFont(forTextStyle: .body)
        result.font = .monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        superview?.setNeedsLayout()
        setNeedsLayout()
    }

    func focus() {
        focusRequested = true
        setNeedsLayout()
    }

    func setVisible(_ visible: Bool) {
        guard showing != visible else { return }
        showing = visible
        isUserInteractionEnabled = visible
        accessibilityElementsHidden = !visible
        if visible {
            if isHidden {
                alpha = 0
                transform = CGAffineTransform(translationX: 0, y: -ReaderDesign.floatingGap / 2)
            }
            isHidden = false
            superview?.setNeedsLayout()
        }
        let updates = {
            self.alpha = visible ? 1 : 0
            self.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: -ReaderDesign.floatingGap / 2)
        }
        let finish: (Bool) -> Void = { [weak self] _ in
            guard let self, !self.showing else { return }
            self.isHidden = true
        }
        if UIAccessibility.isReduceMotionEnabled {
            UIView.performWithoutAnimation(updates)
            finish(true)
        } else {
            UIView.animate(
                withDuration: ReaderDesign.contentDuration, delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
                animations: updates, completion: finish)
        }
    }

    func blur() {
        focusRequested = false
        field.resignFirstResponder()
    }

    @objc private func queryChanged() {
        guard field.markedTextRange == nil else { return }
        onQuery?(field.text ?? "")
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard textField.markedTextRange == nil else { return true }
        onNext?()
        return false
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeFind)),
            UIKeyCommand(input: "g", modifierFlags: .command, action: #selector(nextMatch)),
            UIKeyCommand(input: "g", modifierFlags: [.command, .shift], action: #selector(previousMatch)),
        ]
    }
    @objc private func closeFind() { onClose?() }
    @objc private func nextMatch() { onNext?() }
    @objc private func previousMatch() { onPrevious?() }

    func update(query: String, index: Int?, count: Int, searching: Bool, options: ReaderFindController.Options) {
        result.isHidden = query.isEmpty
        result.text = searching ? "…" : count == 0 ? String(localized: "No Results") : "\((index ?? 0) + 1)/\(count)"
        result.accessibilityValue = result.text
        previousButton.isEnabled = count > 0 && !searching
        nextButton.isEnabled = previousButton.isEnabled
        var caseOptions = options
        caseOptions.matchCase.toggle()
        var accentOptions = options
        accentOptions.ignoreDiacritics.toggle()
        let matchCase = UIAction(title: String(localized: "Match Case"), state: options.matchCase ? .on : .off) {
            [weak self] _ in self?.onOptions?(caseOptions)
        }
        let accents = UIAction(
            title: String(localized: "Ignore Diacritics"), state: options.ignoreDiacritics ? .on : .off
        ) {
            [weak self] _ in self?.onOptions?(accentOptions)
        }
        let words = ReaderFindController.Options.WordMatch.allCases.map { method in
            var changed = options
            changed.wordMatchMethod = method
            let title: String
            switch method {
            case .contains: title = String(localized: "Contains")
            case .startsWith: title = String(localized: "Starts With")
            case .fullWord: title = String(localized: "Whole Words")
            }
            return UIAction(title: title, state: options.wordMatchMethod == method ? .on : .off) { [weak self] _ in
                self?.onOptions?(changed)
            }
        }
        settings.menu = UIMenu(children: [
            UIMenu(options: .displayInline, children: [matchCase, accents]),
            UIMenu(options: [.displayInline, .singleSelection], children: words),
        ])
        setNeedsLayout()
    }
}
