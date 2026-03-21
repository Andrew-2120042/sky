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

    /// NSScrollView wrapping the text view (replaces the old NSTextField)
    private let inputScrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.hasVerticalScroller = false
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.borderType = .noBorder
        return sv
    }()

    /// Multi-line text input (replaces the old NSTextField)
    private let textView: NSTextView = {
        let tv = NSTextView()
        tv.isRichText = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: Constants.Panel.inputFontSize, weight: .regular)
        tv.textColor = .white
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.enabledTextCheckingTypes = 0
        tv.textContainerInset = NSSize(width: 0, height: 8)
        tv.textContainer?.lineBreakMode = .byWordWrapping
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        return tv
    }()

    /// Placeholder label shown when textView is empty
    private let placeholderLabel: NSTextField = {
        let tf = NSTextField(labelWithString: Constants.Panel.placeholder)
        tf.font = .systemFont(ofSize: Constants.Panel.inputFontSize, weight: .regular)
        tf.textColor = NSColor.placeholderTextColor
        tf.isEditable = false
        tf.isSelectable = false
        tf.drawsBackground = false
        tf.isBezeled = false
        tf.lineBreakMode = .byTruncatingTail
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
        tf.textColor = .white
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

    /// "Allow Always" button — shown only on browser confirmation card
    private let allowAlwaysButton: NSButton = {
        let b = NSButton(title: "Always", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .regular
        b.isHidden = true
        return b
    }()

    // MARK: - Flow Running Views

    /// Container for live flow progress (goal + steps + cancel)
    private let flowContainer: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.isHidden = true
        return v
    }()

    /// Shows the flow goal
    private let flowGoalLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: 14, weight: .medium)
        tf.textColor = .white
        tf.lineBreakMode = .byTruncatingTail
        return tf
    }()

    /// Scrollable list of step rows
    private let flowStepsScrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.hasVerticalScroller = false
        sv.autohidesScrollers = true
        sv.borderType = .noBorder
        sv.drawsBackground = false
        return sv
    }()

    /// Stack view containing step label rows
    private let flowStepsStackView: NSStackView = {
        let sv = NSStackView()
        sv.orientation = .vertical
        sv.alignment = .leading
        sv.spacing = 2
        sv.edgeInsets = NSEdgeInsets(top: 6, left: 20, bottom: 6, right: 20)
        return sv
    }()

    /// Cancel button for flow
    private let flowCancelButton: NSButton = {
        let b = NSButton(title: "Cancel Flow", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }()

    /// Minimize button for flow — hides panel while flow runs in background
    private let flowMinimizeButton: NSButton = {
        let b = NSButton(title: "Minimize", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }()

    // MARK: - Skill Creation Views

    /// Small badge shown in the trailing edge of the input row during skill creation
    private let skillBadgeLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "✦ SKILL")
        tf.font = .systemFont(ofSize: 10, weight: .bold)
        tf.textColor = NSColor.systemPurple
        tf.isHidden = true
        return tf
    }()

    /// Header label for skill creation stages
    private let skillHeaderLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: 14, weight: .medium)
        tf.textColor = .white
        tf.alignment = .center
        tf.isHidden = true
        return tf
    }()

    /// Question/feedback text shown during skill creation
    private let skillFeedbackLabel: NSTextField = {
        let tf = NSTextField(wrappingLabelWithString: "")
        tf.font = .systemFont(ofSize: 13)
        tf.textColor = .white
        tf.isHidden = true
        return tf
    }()

    /// Hint shown at the bottom of the panel during skill creation
    private let escHintLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "esc to cancel")
        tf.font = .systemFont(ofSize: 11)
        tf.textColor = .tertiaryLabelColor
        tf.alignment = .center
        tf.isHidden = true
        return tf
    }()

    /// Stored reference to the text field fixed-height constraint (deactivated during skill creation)
    private var textFieldHeightConstraint: NSLayoutConstraint?
    /// Stored reference to the text field centerY constraint (deactivated during skill creation)
    private var textFieldCenterYConstraint: NSLayoutConstraint?
    /// Top-anchor constraint for text field — activated during skill creation for top alignment
    private var textFieldTopConstraint: NSLayoutConstraint?

    /// Tracks the last rendered input height — used by resizeForContent() to compute panel deltas
    private var lastInputHeight: CGFloat = 36

    /// Tracks current flow steps for display
    private var flowStepsData: [FlowStep] = []

    /// Height constraint for the flow container
    private var flowContainerHeightConstraint: NSLayoutConstraint?

    /// Height constraint for steps scroll view
    private var flowScrollHeightConstraint: NSLayoutConstraint?

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
        tv.textColor = .white
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
        textView.delegate = self
        doItButton.target = self
        doItButton.action = #selector(doItTapped)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        allowAlwaysButton.target = self
        allowAlwaysButton.action = #selector(allowAlwaysTapped)
        flowCancelButton.target = self
        flowCancelButton.action = #selector(flowCancelTapped)
        flowMinimizeButton.target = self
        flowMinimizeButton.action = #selector(flowMinimizeTapped)

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

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = inputScrollView.contentSize.width
        if width > 0 {
            textView.textContainer?.containerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
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

        inputScrollView.documentView = textView
        view.addSubview(vibrancyView)
        vibrancyView.addSubview(inputScrollView)
        vibrancyView.addSubview(placeholderLabel)
        vibrancyView.addSubview(spinner)
        vibrancyView.addSubview(separator)
        vibrancyView.addSubview(cardContainer)
        vibrancyView.addSubview(successLabel)
        vibrancyView.addSubview(contactDropdown)
        vibrancyView.addSubview(setupContainer)
        vibrancyView.addSubview(answerScrollView)
        vibrancyView.addSubview(flowContainer)
        vibrancyView.addSubview(skillBadgeLabel)
        vibrancyView.addSubview(skillHeaderLabel)
        vibrancyView.addSubview(skillFeedbackLabel)
        vibrancyView.addSubview(escHintLabel)
        cardContainer.addSubview(summaryLabel)
        cardContainer.addSubview(doItButton)
        cardContainer.addSubview(cancelButton)
        cardContainer.addSubview(allowAlwaysButton)
        flowStepsScrollView.documentView = flowStepsStackView
        flowContainer.addSubview(flowGoalLabel)
        flowContainer.addSubview(flowStepsScrollView)
        flowContainer.addSubview(flowMinimizeButton)
        flowContainer.addSubview(flowCancelButton)
        setupContainer.addSubview(providerControl)
        setupContainer.addSubview(anthropicKeyField)
        setupContainer.addSubview(openaiKeyField)
        setupContainer.addSubview(setupSaveButton)

        [vibrancyView, inputScrollView, placeholderLabel, spinner, separator, cardContainer,
         summaryLabel, doItButton, cancelButton, allowAlwaysButton, successLabel, contactDropdown,
         setupContainer, providerControl, anthropicKeyField, openaiKeyField,
         setupSaveButton, answerScrollView,
         flowContainer, flowGoalLabel, flowStepsScrollView, flowStepsStackView, flowCancelButton, flowMinimizeButton,
         skillBadgeLabel, skillHeaderLabel, skillFeedbackLabel, escHintLabel].forEach {
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

            // Input scroll view
            inputScrollView.leadingAnchor.constraint(equalTo: vibrancyView.leadingAnchor, constant: 20),
            inputScrollView.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -8),

            // Placeholder label — same position as inputScrollView
            placeholderLabel.leadingAnchor.constraint(equalTo: inputScrollView.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(equalTo: inputScrollView.trailingAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: inputScrollView.centerYAnchor),

            // Spinner
            spinner.trailingAnchor.constraint(equalTo: vibrancyView.trailingAnchor, constant: -20),
            spinner.centerYAnchor.constraint(equalTo: inputScrollView.centerYAnchor),
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

            // "Allow Always" button — pinned to trailing edge, visible only on browser confirmation
            allowAlwaysButton.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -20),
            allowAlwaysButton.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor, constant: -12),

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

            // Flow container — same slot as card container (below separator)
            flowContainer.leadingAnchor.constraint(equalTo: vibrancyView.leadingAnchor),
            flowContainer.trailingAnchor.constraint(equalTo: vibrancyView.trailingAnchor),
            flowContainer.topAnchor.constraint(equalTo: separator.bottomAnchor),

            // Flow goal label
            flowGoalLabel.leadingAnchor.constraint(equalTo: flowContainer.leadingAnchor, constant: 20),
            flowGoalLabel.trailingAnchor.constraint(equalTo: flowContainer.trailingAnchor, constant: -20),
            flowGoalLabel.topAnchor.constraint(equalTo: flowContainer.topAnchor, constant: 8),

            // Flow steps scroll view
            flowStepsScrollView.leadingAnchor.constraint(equalTo: flowContainer.leadingAnchor),
            flowStepsScrollView.trailingAnchor.constraint(equalTo: flowContainer.trailingAnchor),
            flowStepsScrollView.topAnchor.constraint(equalTo: flowGoalLabel.bottomAnchor, constant: 4),

            // Flow minimize + cancel buttons (bottom row of flow container)
            flowMinimizeButton.leadingAnchor.constraint(equalTo: flowContainer.leadingAnchor, constant: 20),
            flowMinimizeButton.topAnchor.constraint(equalTo: flowStepsScrollView.bottomAnchor, constant: 8),
            flowCancelButton.leadingAnchor.constraint(equalTo: flowMinimizeButton.trailingAnchor, constant: 8),
            flowCancelButton.topAnchor.constraint(equalTo: flowStepsScrollView.bottomAnchor, constant: 8),

            // Skill badge — sits at trailing edge of input row (same slot as spinner)
            skillBadgeLabel.trailingAnchor.constraint(equalTo: vibrancyView.trailingAnchor, constant: -16),
            skillBadgeLabel.centerYAnchor.constraint(equalTo: vibrancyView.topAnchor, constant: h / 2),

            // Skill header label — centered in input row
            skillHeaderLabel.leadingAnchor.constraint(equalTo: vibrancyView.leadingAnchor, constant: 20),
            skillHeaderLabel.trailingAnchor.constraint(equalTo: vibrancyView.trailingAnchor, constant: -20),
            skillHeaderLabel.centerYAnchor.constraint(equalTo: vibrancyView.topAnchor, constant: h / 2),

            // Skill feedback label — in card area
            skillFeedbackLabel.leadingAnchor.constraint(equalTo: vibrancyView.leadingAnchor, constant: 20),
            skillFeedbackLabel.trailingAnchor.constraint(equalTo: vibrancyView.trailingAnchor, constant: -20),
            skillFeedbackLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 12),
            skillFeedbackLabel.widthAnchor.constraint(equalToConstant: Constants.Panel.width - 40),
        ])

        // Input scroll view mode constraints — swapped between normal and skill creation
        let tfCenterY = inputScrollView.topAnchor.constraint(equalTo: vibrancyView.topAnchor, constant: 12)
        tfCenterY.isActive = true
        textFieldCenterYConstraint = tfCenterY

        let tfHeight = inputScrollView.heightAnchor.constraint(equalToConstant: 24)
        tfHeight.isActive = true
        textFieldHeightConstraint = tfHeight

        let tfTop = inputScrollView.topAnchor.constraint(equalTo: vibrancyView.topAnchor, constant: 14)
        tfTop.isActive = false
        textFieldTopConstraint = tfTop

        // Esc hint label — pinned to bottom of vibrancy view, full width, 24pt
        NSLayoutConstraint.activate([
            escHintLabel.leadingAnchor.constraint(equalTo: vibrancyView.leadingAnchor),
            escHintLabel.trailingAnchor.constraint(equalTo: vibrancyView.trailingAnchor),
            escHintLabel.bottomAnchor.constraint(equalTo: vibrancyView.bottomAnchor, constant: -8),
            escHintLabel.heightAnchor.constraint(equalToConstant: 24),
        ])

        let flowContH = flowContainer.heightAnchor.constraint(equalToConstant: 0)
        flowContH.isActive = true
        flowContainerHeightConstraint = flowContH

        let scrollH = flowStepsScrollView.heightAnchor.constraint(equalToConstant: 0)
        scrollH.isActive = true
        flowScrollHeightConstraint = scrollH

        // These two constraints fight flowContH == 0 when the flow panel is hidden.
        // Lower their priority so they break silently instead of logging conflicts.
        let goalH = flowGoalLabel.heightAnchor.constraint(equalToConstant: Constants.Panel.flowGoalHeight)
        goalH.priority = .defaultHigh
        goalH.isActive = true

        let cancelBottom = flowCancelButton.bottomAnchor.constraint(equalTo: flowContainer.bottomAnchor, constant: -8)
        cancelBottom.priority = .defaultHigh
        cancelBottom.isActive = true
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
                guard let self, self.textView.string != text else { return }
                self.textView.string = text
                self.updatePlaceholder()
                self.resizeForContent()
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
            textView.isEditable = true
            inputScrollView.isHidden = false
            updatePlaceholder()
            successLabel.isHidden = true
            setupContainer.isHidden = true
            answerScrollView.isHidden = true
            allowAlwaysButton.isHidden = true
            separator.isHidden = true
            flowContainer.isHidden = true
            skillHeaderLabel.isHidden = true
            skillBadgeLabel.isHidden = true
            skillFeedbackLabel.isHidden = true
            resizePanel(showCard: false)
            placeholderLabel.stringValue = Constants.Panel.placeholder
            // Restore positioning constraints if they were changed by skill creation
            if textFieldTopConstraint?.isActive == true {
                textFieldTopConstraint?.isActive = false
                textFieldCenterYConstraint?.isActive = true
                textFieldHeightConstraint?.constant = 24
                escHintLabel.isHidden = true
            }

        case .loading:
            showCard(false, animated: false)
            hideContactDropdown()
            spinner.isHidden = false
            spinner.startAnimation(nil)
            textView.isEditable = false
            flowContainer.isHidden = true
            skillHeaderLabel.isHidden = true
            skillBadgeLabel.isHidden = true
            skillFeedbackLabel.isHidden = true
            resizePanel(showCard: false)

        case .confirmation(let intent):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            textView.isEditable = true
            successLabel.isHidden = true
            setupContainer.isHidden = true
            allowAlwaysButton.isHidden = true
            flowContainer.isHidden = true
            summaryLabel.stringValue = intent.displaySummary
            summaryLabel.textColor = .white
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
            textView.isEditable = true
            successLabel.isHidden = true
            flowContainer.isHidden = true
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
            inputScrollView.isHidden = true
            placeholderLabel.isHidden = true
            textView.isEditable = false
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
            inputScrollView.isHidden = true
            placeholderLabel.isHidden = true
            successLabel.stringValue = message
            successLabel.isHidden = false
            flowContainer.isHidden = true
            resizePanel(showCard: false)

        case .clarifying(let question):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            textView.isEditable = true
            inputScrollView.isHidden = false
            updatePlaceholder()
            successLabel.isHidden = true
            setupContainer.isHidden = true
            summaryLabel.stringValue = question
            summaryLabel.textColor = .white
            doItButton.isHidden = true
            cancelButton.title = "Never mind"
            hideContactDropdown()
            showCard(true, animated: true)
            resizePanel(showCard: true)

        case .countdown(_, let secondsLeft):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            textView.isEditable = false
            successLabel.isHidden = true
            setupContainer.isHidden = true
            summaryLabel.stringValue = "Sending in \(secondsLeft)…"
            summaryLabel.textColor = NSColor.white.withAlphaComponent(0.6)
            doItButton.isHidden = true
            cancelButton.title = "Cancel"
            hideContactDropdown()
            showCard(true, animated: cardContainer.isHidden)
            resizePanel(showCard: true)

        case .answer(let text):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            textView.isEditable = true
            inputScrollView.isHidden = false
            updatePlaceholder()
            successLabel.isHidden = true
            setupContainer.isHidden = true
            flowContainer.isHidden = true
            skillHeaderLabel.isHidden = true
            skillBadgeLabel.isHidden = true
            skillFeedbackLabel.isHidden = true
            showCard(false, animated: false)
            hideContactDropdown()
            answerTextView.string = text
            separator.isHidden = false
            answerScrollView.isHidden = false
            resizePanelForAnswer()

        case .workflowConfirmation(let workflow):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            textView.isEditable = true
            successLabel.isHidden = true
            setupContainer.isHidden = true
            answerScrollView.isHidden = true
            let n = workflow.steps.count
            summaryLabel.stringValue = "Run '\(workflow.trigger)' (\(n) step\(n == 1 ? "" : "s"))"
            summaryLabel.textColor = .white
            doItButton.title = "Run"
            doItButton.isHidden = false
            cancelButton.title = "Cancel"
            hideContactDropdown()
            showCard(true, animated: true)
            resizePanel(showCard: true)

        case .browserConfirmation(let message, _):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            textView.isEditable = false
            inputScrollView.isHidden = false
            updatePlaceholder()
            successLabel.isHidden = true
            setupContainer.isHidden = true
            answerScrollView.isHidden = true
            summaryLabel.stringValue = message
            summaryLabel.textColor = .white
            doItButton.title = "Allow Once"
            doItButton.isHidden = false
            cancelButton.title = "Cancel"
            allowAlwaysButton.isHidden = false
            hideContactDropdown()
            showCard(true, animated: true)
            resizePanel(showCard: true)

        case .asking(let question, _, _):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            textView.isEditable = true
            inputScrollView.isHidden = false
            textView.string = ""; updatePlaceholder(); lastInputHeight = 36; resizeForContent()
            placeholderLabel.stringValue = question
            successLabel.isHidden = true
            setupContainer.isHidden = true
            answerScrollView.isHidden = true
            showCard(false, animated: false)
            separator.isHidden = false

        case .flowRunning(let goal, let steps, _):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            inputScrollView.isHidden = true
            placeholderLabel.isHidden = true
            successLabel.isHidden = true
            setupContainer.isHidden = true
            answerScrollView.isHidden = true
            cardContainer.isHidden = true
            allowAlwaysButton.isHidden = true
            skillHeaderLabel.isHidden = true
            skillBadgeLabel.isHidden = true
            skillFeedbackLabel.isHidden = true
            separator.isHidden = false
            flowGoalLabel.stringValue = goal
            updateFlowSteps(steps)
            flowContainer.isHidden = false
            resizePanelForFlow()

        case .flowMinimized(let goal, let stepCount):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            inputScrollView.isHidden = false
            textView.isEditable = false
            placeholderLabel.stringValue = "⟳ \(goal) (\(stepCount) steps)..."
            textView.string = ""; updatePlaceholder(); lastInputHeight = 36; resizeForContent()
            successLabel.isHidden = true
            setupContainer.isHidden = true
            answerScrollView.isHidden = true
            cardContainer.isHidden = true
            flowContainer.isHidden = true
            skillHeaderLabel.isHidden = true
            skillBadgeLabel.isHidden = true
            skillFeedbackLabel.isHidden = true
            separator.isHidden = true
            resizePanel(showCard: false)

        case .skillCreation(let stage):
            applySkillCreationState(stage: stage)
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
        case .browserConfirmation:
            viewModel.confirmBrowserAction(confirm: true, always: false)
        default:
            break
        }
    }

    @objc private func allowAlwaysTapped() {
        guard case .browserConfirmation = viewModel.state else { return }
        viewModel.confirmBrowserAction(confirm: true, always: true)
    }

    @objc private func cancelTapped() {
        if case .browserConfirmation = viewModel.state {
            viewModel.confirmBrowserAction(confirm: false)
            return
        }
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

    // MARK: - Flow UI

    private func updateFlowSteps(_ steps: [FlowStep]) {
        flowStepsData = steps
        // Remove all existing rows
        flowStepsStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Add rows for current steps
        for step in steps {
            let icon: String
            let color: NSColor
            switch step.status {
            case .running:  icon = "⏳"; color = .white
            case .success:  icon = "✅"; color = .white
            case .failed:   icon = "❌"; color = .systemRed
            }
            let row = NSTextField(labelWithString: "\(icon) \(step.text)")
            row.font = .systemFont(ofSize: 13)
            row.textColor = color
            row.lineBreakMode = .byTruncatingTail
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: Constants.Panel.width - 40).isActive = true
            flowStepsStackView.addArrangedSubview(row)
        }
        // Layout stack view so it gets its intrinsic size
        flowStepsStackView.layoutSubtreeIfNeeded()
    }

    private func resizePanelForFlow() {
        guard let panel = view.window else { return }
        let rowH = CGFloat(flowStepsData.count) * Constants.Panel.flowStepRowHeight + 12
        let stepsH = min(rowH, Constants.Panel.maxFlowStepsHeight)
        let cancelH = Constants.Panel.flowCancelRowHeight
        let goalH = Constants.Panel.flowGoalHeight + 8 + 4 // top padding + gap
        let flowH = goalH + stepsH + cancelH

        flowScrollHeightConstraint?.constant = stepsH
        flowContainerHeightConstraint?.constant = flowH

        DispatchQueue.main.async {
            let targetHeight = Constants.Panel.inputHeight + flowH
            var frame = panel.frame
            let delta = targetHeight - frame.height
            frame.size.height = targetHeight
            frame.origin.y -= delta
            panel.setFrame(frame, display: true, animate: true)
        }
    }

    // MARK: - Skill Creation Window Behavior

    private func applySkillCreationWindowBehavior() {
        // hidesOnDeactivate is already false globally in FloatingPanel.configure()
        // Nothing extra needed here.
    }

    private func restoreNormalWindowBehavior() {
        // hidesOnDeactivate stays false — AppDelegate's didResignActiveNotification handles normal dismiss.
    }

    // MARK: - Skill Creation UI

    private func applySkillCreationState(stage: SkillCreationStage) {
        applySkillCreationWindowBehavior()
        // Hide flow and other containers
        flowContainer.isHidden = true
        cardContainer.isHidden = true
        answerScrollView.isHidden = true
        setupContainer.isHidden = true
        successLabel.isHidden = true
        allowAlwaysButton.isHidden = true

        switch stage {
        case .waitingForDescription:
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            inputScrollView.isHidden = false
            textView.isEditable = true
            textView.string = ""; updatePlaceholder(); lastInputHeight = 36; resizeForContent()
            placeholderLabel.stringValue = "Describe the flow — what site, what steps, what success looks like..."
            skillBadgeLabel.isHidden = false
            skillHeaderLabel.isHidden = true
            skillFeedbackLabel.isHidden = true
            separator.isHidden = true
            escHintLabel.isHidden = false
            // Switch positioning constraints: center → top anchor
            if textFieldCenterYConstraint?.isActive == true {
                textFieldCenterYConstraint?.isActive = false
                textFieldTopConstraint?.isActive = true
            }
            resizeForContent()

        case .generating:
            spinner.isHidden = false
            spinner.startAnimation(nil)
            inputScrollView.isHidden = true
            placeholderLabel.isHidden = true
            textView.isEditable = false
            skillHeaderLabel.stringValue = "Generating skill..."
            skillHeaderLabel.isHidden = false
            skillFeedbackLabel.isHidden = true
            separator.isHidden = true
            resizePanel(showCard: false)

        case .testing:
            // Flow running UI handles this — state transitions to flowRunning via startFlow()
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            skillHeaderLabel.isHidden = true
            skillBadgeLabel.isHidden = true
            skillFeedbackLabel.isHidden = true

        case .awaitingFeedback(_, let question):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            inputScrollView.isHidden = false
            textView.isEditable = true
            textView.string = ""; updatePlaceholder(); lastInputHeight = 36; resizeForContent()
            placeholderLabel.stringValue = "What should I try differently?"
            skillBadgeLabel.isHidden = false
            skillHeaderLabel.isHidden = true
            skillFeedbackLabel.stringValue = question
            skillFeedbackLabel.isHidden = false
            separator.isHidden = false
            escHintLabel.isHidden = false
            // Switch positioning constraints: center → top anchor
            if textFieldCenterYConstraint?.isActive == true {
                textFieldCenterYConstraint?.isActive = false
                textFieldTopConstraint?.isActive = true
            }
            resizePanelForSkillFeedback()

        case .saved(let name):
            restoreNormalWindowBehavior()
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            inputScrollView.isHidden = true
            placeholderLabel.isHidden = true
            skillHeaderLabel.isHidden = true
            skillBadgeLabel.isHidden = true
            skillFeedbackLabel.isHidden = true
            separator.isHidden = false
            let displayName = name.replacingOccurrences(of: "_", with: " ")
            summaryLabel.stringValue = "Skill '\(displayName)' saved ✓"
            summaryLabel.textColor = .systemGreen
            doItButton.isHidden = true
            cancelButton.title = "Done"
            showCard(true, animated: true)
            resizePanel(showCard: true)
        }
    }

    private func resizePanelForSkillFeedback() {
        guard let panel = view.window else { return }
        DispatchQueue.main.async {
            let targetHeight = Constants.Panel.inputHeight + 120
            var frame = panel.frame
            let delta = targetHeight - frame.height
            frame.size.height = targetHeight
            frame.origin.y -= delta
            panel.setFrame(frame, display: true, animate: true)
        }
    }

    @objc private func flowCancelTapped() {
        viewModel.cancelFlow()
        resizePanel(showCard: false)
    }

    @objc private func flowMinimizeTapped() {
        viewModel.minimizeFlow()
        NotificationCenter.default.post(name: Constants.NotificationName.hidePanel, object: nil)
    }

    // MARK: - Focus

    func focusInput() {
        lastInputHeight = 36
        if case .awaitingAPIKey = viewModel.state {
            let isOpenAI = providerControl.selectedSegment == 1
            view.window?.makeFirstResponder(isOpenAI ? openaiKeyField : anthropicKeyField)
        } else {
            view.window?.makeFirstResponder(textView)
            successLabel.isHidden = true
            inputScrollView.isHidden = false
            updatePlaceholder()
            resizeForContent()
        }
    }

    // MARK: - Placeholder Helper

    private func updatePlaceholder() {
        placeholderLabel.isHidden = !textView.string.isEmpty
    }
}

// MARK: - NSTextViewDelegate + NSTextFieldDelegate

extension PanelViewController: NSTextViewDelegate, NSTextFieldDelegate {

    // MARK: NSTextViewDelegate — main input textView

    func textDidChange(_ notification: Notification) {
        updatePlaceholder()
        resizeForContent()
        handleTextDidChange(textView.string)
    }

    private func handleTextDidChange(_ text: String) {
        viewModel.dismissAnswer()
        if case .asking = viewModel.state {
            viewModel.cancelAsking()
        }
        viewModel.inputText = text
        detectMention(in: text)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
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

        // Skill creation input handling
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if case .skillCreation(let stage) = viewModel.state {
                switch stage {
                case .waitingForDescription:
                    let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return false }
                    textView.string = ""; updatePlaceholder(); lastInputHeight = 36; resizeForContent()
                    viewModel.submitSkillDescription(text)
                    return true
                case .awaitingFeedback:
                    let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return false }
                    textView.string = ""; updatePlaceholder(); lastInputHeight = 36; resizeForContent()
                    viewModel.submitSkillFeedback(text)
                    return true
                default:
                    break
                }
            }
        }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Enter confirms the action when the confirmation card is showing
            if case .confirmation(let intent) = viewModel.state {
                viewModel.confirm(intent: intent)
                return true
            }
            if case .loading = viewModel.state { return true }
            PanelInputMemory.shared.clear()
            // Sync textView content before submitting — ensures viewModel.inputText is current
            // regardless of how text was entered (typed, pasted, autocomplete, etc.)
            viewModel.inputText = textView.string
            if case .awaitingAPIKey = viewModel.state {
                viewModel.saveAPIKey(textView.string)
            } else {
                viewModel.submit()
            }
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if viewModel.isInSkillCreationMode {
                // Exit skill creation entirely — clears flag, sets state = .idle, applies(state:) resets text field
                viewModel.exitSkillCreationMode()
                NotificationCenter.default.post(name: Constants.NotificationName.hidePanel, object: nil)
                return true
            }
            if !contactDropdown.isHidden {
                hideContactDropdown()
                activeMentionRange = nil
                return true
            }
            // Save text before Escape dismiss — only submit clears memory
            let typed = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty { PanelInputMemory.shared.save(typed) }
            viewModel.reset()
            resizePanel(showCard: false)
            NotificationCenter.default.post(name: Constants.NotificationName.hidePanel, object: nil)
            return true
        }

        return false
    }

    // MARK: NSTextFieldDelegate — anthropicKeyField / openaiKeyField

    func controlTextDidChange(_ obj: Notification) {
        // Only handles secure text fields — main input is handled by textDidChange above
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
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

    // MARK: - Input Resize

    private func resizeForContent() {
        // Only resize the panel in free-form input modes — other states manage their own sizing
        var isSkillCreation = false
        switch viewModel.state {
        case .idle, .asking:
            break
        case .skillCreation:
            isSkillCreation = true
        default:
            return
        }

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        layoutManager.ensureLayout(for: textContainer)

        let usedRect = layoutManager.usedRect(for: textContainer)
        let contentHeight = ceil(usedRect.height) + textView.textContainerInset.height * 2
        let inputHeight = max(36, min(300, contentHeight))

        textFieldHeightConstraint?.constant = inputHeight

        guard let window = view.window else { return }

        // Skill creation: 14pt top + content + 16pt gap + 24pt esc hint + 8pt bottom, min 120
        // Normal: 12pt top + content + 12pt bottom, min inputHeight
        let newTotalHeight: CGFloat = isSkillCreation
            ? max(120, inputHeight + 62)
            : max(Constants.Panel.inputHeight, inputHeight + 24)

        let currentFrame = window.frame
        guard abs(newTotalHeight - currentFrame.height) > 1 else { return }

        let newFrame = NSRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y - (newTotalHeight - currentFrame.height),
            width: currentFrame.width,
            height: newTotalHeight
        )

        window.setFrame(newFrame, display: true, animate: false)
        lastInputHeight = inputHeight
        view.needsLayout = true
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
