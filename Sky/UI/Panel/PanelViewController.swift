import AppKit
import Combine

/// Main view controller for the floating command bar panel.
/// Hosts the vibrancy background, text input, confirmation card, and contact dropdown.
final class PanelViewController: NSViewController {

    // MARK: - View Model

    /// Exposed for AppDelegate to read panel state (e.g., reset on hide).
    let viewModel = PanelViewModel()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Views

    /// Frosted glass vibrancy container
    private let vibrancyView: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = Constants.Panel.cornerRadius
        v.layer?.masksToBounds = true
        return v
    }()

    /// Main text input field
    private let textField: NSTextField = {
        let tf = NSTextField()
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.isEditable = true
        tf.isSelectable = true
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: Constants.Panel.inputFontSize, weight: .regular)
        tf.placeholderString = Constants.Panel.placeholder
        tf.textColor = .labelColor
        return tf
    }()

    /// Spinner shown during API request or action execution
    private let spinner: NSProgressIndicator = {
        let s = NSProgressIndicator()
        s.style = .spinning
        s.controlSize = .small
        s.isHidden = true
        return s
    }()

    /// Container for the confirmation card (slides down)
    private let cardContainer: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.isHidden = true
        return v
    }()

    /// Thin separator between input and card/success/dropdown areas
    private let separator: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        v.isHidden = true
        return v
    }()

    /// Label showing the AI's one-line action summary
    private let summaryLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: Constants.Panel.summaryFontSize, weight: .medium)
        tf.textColor = .labelColor
        tf.lineBreakMode = .byTruncatingTail
        return tf
    }()

    /// Primary action button
    private let doItButton: NSButton = {
        let b = NSButton(title: "Do it", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .regular
        b.keyEquivalent = "\r"
        return b
    }()

    /// Secondary cancel / dismiss button
    private let cancelButton: NSButton = {
        let b = NSButton(title: "Cancel", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .regular
        b.keyEquivalent = "\u{1B}"
        return b
    }()

    /// Brief success message shown after a completed action (no card — just clean text)
    private let successLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: Constants.Panel.summaryFontSize, weight: .medium)
        tf.textColor = NSColor.systemGreen
        tf.alignment = .center
        tf.isHidden = true
        return tf
    }()

    /// Contact @mention suggestion dropdown
    private let contactDropdown = ContactDropdownView(frame: .zero)

    /// Active @mention text range in inputText (nil when no active mention)
    private var activeMentionRange: Range<String.Index>?

    /// Scroll view containing the inline answer text view
    private let answerScrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.borderType = .noBorder
        sv.drawsBackground = false   // transparent — inherits vibrancy from parent
        sv.isHidden = true
        return sv
    }()

    /// Read-only text view for displaying inline answers
    private let answerTextView: NSTextView = {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .systemFont(ofSize: 14, weight: .regular)
        tv.textColor = .secondaryLabelColor
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 12, height: 10)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        return tv
    }()

    // MARK: - API Key Setup Views (shown on first launch / awaitingAPIKey state)

    private let setupContainer: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.isHidden = true
        return v
    }()

    private let providerControl: NSSegmentedControl = {
        let s = NSSegmentedControl(labels: ["Anthropic", "OpenAI"],
                                   trackingMode: .selectOne,
                                   target: nil,
                                   action: nil)
        s.selectedSegment = 0
        s.controlSize = .regular
        return s
    }()

    private let anthropicKeyField: NSSecureTextField = {
        let f = NSSecureTextField()
        f.placeholderString = "Anthropic API key  (sk-ant-...)"
        f.font = .systemFont(ofSize: 13)
        f.isBezeled = true
        f.bezelStyle = .roundedBezel
        return f
    }()

    private let openaiKeyField: NSSecureTextField = {
        let f = NSSecureTextField()
        f.placeholderString = "OpenAI API key  (sk-...)"
        f.font = .systemFont(ofSize: 13)
        f.isBezeled = true
        f.bezelStyle = .roundedBezel
        f.isHidden = true
        return f
    }()

    private let setupSaveButton: NSButton = {
        let b = NSButton(title: "Save & Continue", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .regular
        b.keyEquivalent = "\r"
        return b
    }()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0,
                                   width: Constants.Panel.width,
                                   height: Constants.Panel.inputHeight))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupLayout()
        bindViewModel()
        textField.delegate = self
        doItButton.target = self
        doItButton.action = #selector(doItTapped)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        contactDropdown.onSelect = { [weak self] contact in
            guard let self else { return }
            if case .asking = self.viewModel.state {
                self.viewModel.resolveAmbiguity(contact: contact)
                self.activeMentionRange = nil
            } else if let range = self.activeMentionRange {
                self.viewModel.selectContact(contact, replacingMention: range)
                self.activeMentionRange = nil
                self.hideContactDropdown()
            }
        }

        setupSaveButton.target = self
        setupSaveButton.action = #selector(setupSaveTapped)
        providerControl.target = self
        providerControl.action = #selector(providerChanged)
        anthropicKeyField.delegate = self
        openaiKeyField.delegate = self
    }

    // MARK: - Layout

    /// Assembles the view hierarchy and AutoLayout constraints.
    private func setupLayout() {
        // Configure answer text view for scrolling long responses
        answerTextView.minSize = NSSize(width: 0, height: 0)
        answerTextView.maxSize = NSSize(width: Constants.Panel.width,
                                        height: CGFloat.greatestFiniteMagnitude)
        answerTextView.isVerticallyResizable = true
        answerTextView.isHorizontallyResizable = false
        answerTextView.autoresizingMask = [.width]
        answerTextView.textContainer?.containerSize = NSSize(width: Constants.Panel.width,
                                                             height: CGFloat.greatestFiniteMagnitude)
        answerTextView.textContainer?.widthTracksTextView = true
        answerScrollView.documentView = answerTextView

        view.addSubview(vibrancyView)
        vibrancyView.addSubview(textField)
        vibrancyView.addSubview(spinner)
        vibrancyView.addSubview(separator)
        vibrancyView.addSubview(cardContainer)
        vibrancyView.addSubview(successLabel)
        vibrancyView.addSubview(contactDropdown)
        vibrancyView.addSubview(setupContainer)
        vibrancyView.addSubview(answerScrollView)
        cardContainer.addSubview(summaryLabel)
        cardContainer.addSubview(doItButton)
        cardContainer.addSubview(cancelButton)
        setupContainer.addSubview(providerControl)
        setupContainer.addSubview(anthropicKeyField)
        setupContainer.addSubview(openaiKeyField)
        setupContainer.addSubview(setupSaveButton)

        [vibrancyView, textField, spinner, separator, cardContainer,
         summaryLabel, doItButton, cancelButton, successLabel, contactDropdown,
         setupContainer, providerControl, anthropicKeyField, openaiKeyField,
         setupSaveButton, answerScrollView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        let h = Constants.Panel.inputHeight
        let cardH = Constants.Panel.cardHeight

        NSLayoutConstraint.activate([
            // Vibrancy fills view
            vibrancyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vibrancyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            vibrancyView.topAnchor.constraint(equalTo: view.topAnchor),
            vibrancyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Input field
            textField.leadingAnchor.constraint(equalTo: vibrancyView.leadingAnchor, constant: 20),
            textField.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -8),
            textField.centerYAnchor.constraint(equalTo: vibrancyView.topAnchor, constant: h / 2),
            textField.heightAnchor.constraint(equalToConstant: 24),

            // Spinner
            spinner.trailingAnchor.constraint(equalTo: vibrancyView.trailingAnchor, constant: -20),
            spinner.centerYAnchor.constraint(equalTo: textField.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),

            // Separator
            separator.leadingAnchor.constraint(equalTo: vibrancyView.leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: vibrancyView.trailingAnchor, constant: -16),
            separator.topAnchor.constraint(equalTo: vibrancyView.topAnchor, constant: h),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            // Card container
            cardContainer.leadingAnchor.constraint(equalTo: vibrancyView.leadingAnchor),
            cardContainer.trailingAnchor.constraint(equalTo: vibrancyView.trailingAnchor),
            cardContainer.topAnchor.constraint(equalTo: separator.bottomAnchor),
            cardContainer.heightAnchor.constraint(equalToConstant: cardH),

            // Summary label
            summaryLabel.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: 20),
            summaryLabel.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -20),
            summaryLabel.topAnchor.constraint(equalTo: cardContainer.topAnchor, constant: 14),

            // Buttons
            doItButton.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: 20),
            doItButton.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor, constant: -12),

            cancelButton.leadingAnchor.constraint(equalTo: doItButton.trailingAnchor, constant: 8),
            cancelButton.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor, constant: -12),

            // Success label — centered in the input row
            successLabel.leadingAnchor.constraint(equalTo: vibrancyView.leadingAnchor, constant: 20),
            successLabel.trailingAnchor.constraint(equalTo: vibrancyView.trailingAnchor, constant: -20),
            successLabel.centerYAnchor.constraint(equalTo: vibrancyView.topAnchor, constant: h / 2),

            // Contact dropdown — pinned just below the input row
            contactDropdown.leadingAnchor.constraint(equalTo: vibrancyView.leadingAnchor),
            contactDropdown.trailingAnchor.constraint(equalTo: vibrancyView.trailingAnchor),
            contactDropdown.topAnchor.constraint(equalTo: vibrancyView.topAnchor, constant: h),

            // Setup container — same slot as card container (below separator)
            setupContainer.leadingAnchor.constraint(equalTo: vibrancyView.leadingAnchor),
            setupContainer.trailingAnchor.constraint(equalTo: vibrancyView.trailingAnchor),
            setupContainer.topAnchor.constraint(equalTo: separator.bottomAnchor),
            setupContainer.heightAnchor.constraint(equalToConstant: Constants.Panel.setupHeight),

            // Provider segmented control — centered near top of setup container
            providerControl.centerXAnchor.constraint(equalTo: setupContainer.centerXAnchor),
            providerControl.topAnchor.constraint(equalTo: setupContainer.topAnchor, constant: 16),
            providerControl.widthAnchor.constraint(equalToConstant: 220),

            // Anthropic key field
            anthropicKeyField.leadingAnchor.constraint(equalTo: setupContainer.leadingAnchor, constant: 20),
            anthropicKeyField.trailingAnchor.constraint(equalTo: setupContainer.trailingAnchor, constant: -20),
            anthropicKeyField.topAnchor.constraint(equalTo: providerControl.bottomAnchor, constant: 14),
            anthropicKeyField.heightAnchor.constraint(equalToConstant: 26),

            // OpenAI key field (same position as anthropic, swapped visibility)
            openaiKeyField.leadingAnchor.constraint(equalTo: setupContainer.leadingAnchor, constant: 20),
            openaiKeyField.trailingAnchor.constraint(equalTo: setupContainer.trailingAnchor, constant: -20),
            openaiKeyField.topAnchor.constraint(equalTo: providerControl.bottomAnchor, constant: 14),
            openaiKeyField.heightAnchor.constraint(equalToConstant: 26),

            // Save button
            setupSaveButton.trailingAnchor.constraint(equalTo: setupContainer.trailingAnchor, constant: -20),
            setupSaveButton.topAnchor.constraint(equalTo: anthropicKeyField.bottomAnchor, constant: 14),

            // Answer scroll view — same slot as card/setup containers
            answerScrollView.leadingAnchor.constraint(equalTo: vibrancyView.leadingAnchor),
            answerScrollView.trailingAnchor.constraint(equalTo: vibrancyView.trailingAnchor),
            answerScrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            answerScrollView.heightAnchor.constraint(equalToConstant: Constants.Panel.answerHeight),
        ])
    }

    // MARK: - ViewModel Binding

    /// Observes viewModel state and suggestion changes, then drives the UI.
    private func bindViewModel() {
        viewModel.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.apply(state: state) }
            .store(in: &cancellables)

        viewModel.$inputText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self, self.textField.stringValue != text else { return }
                self.textField.stringValue = text
            }
            .store(in: &cancellables)

        viewModel.$contactSuggestions
            .receive(on: RunLoop.main)
            .sink { [weak self] contacts in self?.updateDropdown(contacts: contacts) }
            .store(in: &cancellables)
    }

    /// Drives UI from the current PanelState.
    private func apply(state: PanelState) {
        switch state {
        case .idle:
            showCard(false, animated: false)
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            textField.isEnabled = true
            textField.isHidden = false
            successLabel.isHidden = true
            setupContainer.isHidden = true
            answerScrollView.isHidden = true
            separator.isHidden = true
            resizePanel(showCard: false)
            textField.placeholderString = Constants.Panel.placeholder

        case .loading:
            showCard(false, animated: false)
            hideContactDropdown()
            spinner.isHidden = false
            spinner.startAnimation(nil)
            textField.isEnabled = false
            resizePanel(showCard: false)

        case .confirmation(let intent):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            textField.isEnabled = true
            successLabel.isHidden = true
            setupContainer.isHidden = true
            summaryLabel.stringValue = intent.displaySummary
            summaryLabel.textColor = .labelColor
            let firstActionType = intent.firstAction?.action
            if firstActionType == Constants.ActionType.unknown || firstActionType == nil {
                doItButton.isHidden = true
                cancelButton.title = "Got it"
            } else {
                doItButton.title = "Do it"
                doItButton.isHidden = false
                cancelButton.title = "Cancel"
            }
            hideContactDropdown()
            showCard(true, animated: true)
            resizePanel(showCard: true)

        case .error(let message):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            textField.isEnabled = true
            successLabel.isHidden = true
            summaryLabel.stringValue = message
            summaryLabel.textColor = .systemRed
            doItButton.isHidden = true
            cancelButton.title = "Dismiss"
            hideContactDropdown()
            showCard(true, animated: true)
            resizePanel(showCard: true)

        case .awaitingAPIKey:
            showCard(false, animated: false)
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            successLabel.isHidden = true
            textField.isHidden = true
            textField.isEnabled = false
            separator.isHidden = false
            let cfg = ConfigService.shared.config
            anthropicKeyField.stringValue = cfg.anthropicAPIKey
            openaiKeyField.stringValue = cfg.openaiApiKey
            let selectedIndex = cfg.aiProvider == "openai" ? 1 : 0
            providerControl.selectedSegment = selectedIndex
            anthropicKeyField.isHidden = selectedIndex == 1
            openaiKeyField.isHidden = selectedIndex == 0
            setupContainer.isHidden = false
            resizePanelForSetup()

        case .success(let message):
            showCard(false, animated: false)
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            textField.isHidden = true
            successLabel.stringValue = message
            successLabel.isHidden = false
            resizePanel(showCard: false)

        case .clarifying(let question):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            textField.isEnabled = true
            textField.isHidden = false
            successLabel.isHidden = true
            setupContainer.isHidden = true
            summaryLabel.stringValue = question
            summaryLabel.textColor = NSColor.systemBlue
            doItButton.isHidden = true
            cancelButton.title = "Never mind"
            hideContactDropdown()
            showCard(true, animated: true)
            resizePanel(showCard: true)

        case .countdown(_, let secondsLeft):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            textField.isEnabled = false
            successLabel.isHidden = true
            setupContainer.isHidden = true
            summaryLabel.stringValue = "Sending in \(secondsLeft)…"
            summaryLabel.textColor = .secondaryLabelColor
            doItButton.isHidden = true
            cancelButton.title = "Cancel"
            hideContactDropdown()
            showCard(true, animated: cardContainer.isHidden)
            resizePanel(showCard: true)

        case .answer(let text):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            textField.isEnabled = true
            textField.isHidden = false
            successLabel.isHidden = true
            setupContainer.isHidden = true
            showCard(false, animated: false)
            hideContactDropdown()
            answerTextView.string = text
            separator.isHidden = false
            answerScrollView.isHidden = false
            resizePanelForAnswer()

        case .workflowConfirmation(let workflow):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            textField.isEnabled = true
            successLabel.isHidden = true
            setupContainer.isHidden = true
            answerScrollView.isHidden = true
            let n = workflow.steps.count
            summaryLabel.stringValue = "Run '\(workflow.trigger)' (\(n) step\(n == 1 ? "" : "s"))"
            summaryLabel.textColor = .labelColor
            doItButton.title = "Run"
            doItButton.isHidden = false
            cancelButton.title = "Cancel"
            hideContactDropdown()
            showCard(true, animated: true)
            resizePanel(showCard: true)

        case .asking(let question, _, _):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            textField.isEnabled = true
            textField.isHidden = false
            textField.stringValue = ""
            textField.placeholderString = question
            successLabel.isHidden = true
            setupContainer.isHidden = true
            answerScrollView.isHidden = true
            showCard(false, animated: false)
            separator.isHidden = false
        }
    }

    // MARK: - Contact Dropdown

    private func updateDropdown(contacts: [ResolvedContact]) {
        if contacts.isEmpty {
            hideContactDropdown()
        } else {
            contactDropdown.contacts = contacts
            let dropdownH = CGFloat(min(contacts.count, 4)) * 44
            resizePanelForDropdown(height: dropdownH)
            separator.isHidden = false
            contactDropdown.isHidden = false
        }
    }

    private func hideContactDropdown() {
        guard !contactDropdown.isHidden else { return }
        contactDropdown.isHidden = true
        contactDropdown.contacts = []
        separator.isHidden = true
        resizePanel(showCard: !cardContainer.isHidden)
    }

    private func resizePanelForDropdown(height: CGFloat) {
        guard let panel = view.window else { return }
        DispatchQueue.main.async {
            let targetHeight = Constants.Panel.inputHeight + height
            var frame = panel.frame
            let delta = targetHeight - frame.height
            frame.size.height = targetHeight
            frame.origin.y -= delta
            panel.setFrame(frame, display: true, animate: false)
        }
    }

    // MARK: - Animations

    private func showCard(_ show: Bool, animated: Bool) {
        guard cardContainer.isHidden == show else { return }
        separator.isHidden = !show

        if show {
            cardContainer.isHidden = false
            cardContainer.alphaValue = 0
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Constants.Panel.slideDownDuration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    cardContainer.animator().alphaValue = 1
                }
            } else {
                cardContainer.alphaValue = 1
            }
        } else {
            if animated {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = Constants.Panel.slideDownDuration * 0.5
                    cardContainer.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        self?.cardContainer.isHidden = true
                        self?.resizePanel(showCard: false)
                    }
                })
            } else {
                cardContainer.isHidden = true
                resizePanel(showCard: false)
            }
        }
    }

    private func resizePanel(showCard: Bool) {
        guard let panel = view.window else { return }
        DispatchQueue.main.async {
            let targetHeight = showCard
                ? Constants.Panel.inputHeight + Constants.Panel.cardHeight
                : Constants.Panel.inputHeight
            var frame = panel.frame
            let delta = targetHeight - frame.height
            frame.size.height = targetHeight
            frame.origin.y -= delta
            panel.setFrame(frame, display: true, animate: true)
        }
    }

    // MARK: - Button Actions

    @objc private func doItTapped() {
        switch viewModel.state {
        case .confirmation(let intent):
            viewModel.confirm(intent: intent)
        case .workflowConfirmation(let workflow):
            viewModel.runWorkflow(workflow)
        default:
            break
        }
    }

    @objc private func cancelTapped() {
        viewModel.cancel()
        resizePanel(showCard: false)
        NotificationCenter.default.post(name: Constants.NotificationName.hidePanel, object: nil)
    }

    @objc private func setupSaveTapped() {
        let provider = providerControl.selectedSegment == 1 ? "openai" : "anthropic"
        viewModel.saveKeys(
            anthropicKey: anthropicKeyField.stringValue,
            openaiKey: openaiKeyField.stringValue,
            provider: provider
        )
        resizePanel(showCard: false)
    }

    @objc private func providerChanged() {
        let isOpenAI = providerControl.selectedSegment == 1
        anthropicKeyField.isHidden = isOpenAI
        openaiKeyField.isHidden = !isOpenAI
        if isOpenAI {
            view.window?.makeFirstResponder(openaiKeyField)
        } else {
            view.window?.makeFirstResponder(anthropicKeyField)
        }
    }

    private func resizePanelForAnswer() {
        guard let panel = view.window else { return }
        DispatchQueue.main.async {
            let targetHeight = Constants.Panel.inputHeight + Constants.Panel.answerHeight
            var frame = panel.frame
            let delta = targetHeight - frame.height
            frame.size.height = targetHeight
            frame.origin.y -= delta
            panel.setFrame(frame, display: true, animate: true)
        }
    }

    private func resizePanelForSetup() {
        guard let panel = view.window else { return }
        DispatchQueue.main.async {
            let targetHeight = Constants.Panel.inputHeight + Constants.Panel.setupHeight
            var frame = panel.frame
            let delta = targetHeight - frame.height
            frame.size.height = targetHeight
            frame.origin.y -= delta
            panel.setFrame(frame, display: true, animate: true)
        }
    }

    // MARK: - Focus

    func focusInput() {
        if case .awaitingAPIKey = viewModel.state {
            let isOpenAI = providerControl.selectedSegment == 1
            view.window?.makeFirstResponder(isOpenAI ? openaiKeyField : anthropicKeyField)
        } else {
            view.window?.makeFirstResponder(textField)
            successLabel.isHidden = true
            textField.isHidden = false
        }
    }
}

// MARK: - NSTextFieldDelegate

extension PanelViewController: NSTextFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        let text = textField.stringValue
        viewModel.dismissAnswer()
        if case .asking = viewModel.state {
            viewModel.cancelAsking()
        }
        viewModel.inputText = text
        detectMention(in: text)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Route arrow keys to dropdown when it is visible
        if !contactDropdown.isHidden {
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                contactDropdown.selectNext(); return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                contactDropdown.selectPrevious(); return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if case .asking = viewModel.state {
                    if let contact = contactDropdown.confirmSelection() {
                        viewModel.resolveAmbiguity(contact: contact)
                        activeMentionRange = nil
                        return true
                    }
                } else if let contact = contactDropdown.confirmSelection(),
                          let range = activeMentionRange {
                    viewModel.selectContact(contact, replacingMention: range)
                    activeMentionRange = nil
                    hideContactDropdown()
                    return true
                }
            }
        }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if case .awaitingAPIKey = viewModel.state {
                viewModel.saveAPIKey(textField.stringValue)
            } else {
                viewModel.submit()
            }
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if !contactDropdown.isHidden {
                hideContactDropdown()
                activeMentionRange = nil
                return true
            }
            viewModel.reset()
            resizePanel(showCard: false)
            NotificationCenter.default.post(name: Constants.NotificationName.hidePanel, object: nil)
            return true
        }

        // Allow Tab between setup fields
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            if control === anthropicKeyField {
                view.window?.makeFirstResponder(openaiKeyField); return true
            }
            if control === openaiKeyField {
                view.window?.makeFirstResponder(anthropicKeyField); return true
            }
        }

        return false
    }

    // MARK: - @mention detection

    private func detectMention(in text: String) {
        guard let atRange = text.range(of: "@", options: .backwards),
              !text[atRange.upperBound...].contains(" ") else {
            if !contactDropdown.isHidden { hideContactDropdown() }
            activeMentionRange = nil
            return
        }

        let query = String(text[atRange.lowerBound...].dropFirst())
        activeMentionRange = atRange.lowerBound ..< text.endIndex
        viewModel.updateContactSuggestions(query: query)
    }
}
