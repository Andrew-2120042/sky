import AppKit

// MARK: - Safe subscript helper (file-private)

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - ContactDropdownView

/// A keyboard-navigable dropdown list of contact suggestions shown below the panel input field.
@MainActor
final class ContactDropdownView: NSView {

    // MARK: - Layout constants

    private enum Layout {
        static let rowHeight: CGFloat  = 44
        static let maxVisibleRows: Int = 4
        static let width: CGFloat      = 640
    }

    // MARK: - Public interface

    /// The contacts to display. Setting this property reloads all rows.
    var contacts: [ResolvedContact] = [] {
        didSet { reloadRows() }
    }

    /// Called when the user selects a contact (click or keyboard confirm).
    var onSelect: ((ResolvedContact) -> Void)?

    // MARK: - Private state

    private var selectedIndex: Int = 0
    private var rowViews: [ContactRowView] = []

    // MARK: - Views

    private let stackView: NSStackView = {
        let sv = NSStackView()
        sv.orientation = .vertical
        sv.spacing = 0
        sv.distribution = .fillEqually
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupLayout()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupLayout()
    }

    // MARK: - Layout

    private func setupLayout() {
        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        stackView.distribution = .fillEqually
    }

    // MARK: - Reload

    private func reloadRows() {
        // Remove previous rows from the stack and release them.
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rowViews = []

        for (index, contact) in contacts.enumerated() {
            let row = ContactRowView(contact: contact)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: Layout.rowHeight).isActive = true
            // Capture index by value for the closure.
            let capturedIndex = index
            row.onTap = { [weak self] in
                guard let self else { return }
                self.selectedIndex = capturedIndex
                self.updateHighlights()
                if let selected = self.contacts[safe: self.selectedIndex] {
                    self.onSelect?(selected)
                }
            }
            stackView.addArrangedSubview(row)
            rowViews.append(row)
        }

        selectedIndex = 0
        updateHighlights()

        // Resize self to show at most maxVisibleRows rows.
        // Defer the frame/constraint mutation out of any in-progress layout pass.
        let visibleRows = min(contacts.count, Layout.maxVisibleRows)
        let targetHeight = CGFloat(visibleRows) * Layout.rowHeight
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let heightConstraint = self.constraints.first(where: { $0.firstAttribute == .height && $0.secondItem == nil }) {
                heightConstraint.constant = targetHeight
            } else {
                self.frame.size = NSSize(width: Layout.width, height: targetHeight)
            }
        }
    }

    // MARK: - Keyboard navigation

    /// Moves the highlight to the next row (wraps at the bottom).
    func selectNext() {
        guard !contacts.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % contacts.count
        updateHighlights()
    }

    /// Moves the highlight to the previous row (wraps at the top).
    func selectPrevious() {
        guard !contacts.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + contacts.count) % contacts.count
        updateHighlights()
    }

    /// Returns the currently highlighted contact, or nil if the list is empty.
    func confirmSelection() -> ResolvedContact? {
        contacts[safe: selectedIndex]
    }

    // MARK: - Highlight management

    private func updateHighlights() {
        for (index, row) in rowViews.enumerated() {
            row.isHighlighted = (index == selectedIndex)
        }
    }
}

// MARK: - ContactRowView

/// A single row in the contact dropdown showing name and subtitle.
@MainActor
final class ContactRowView: NSView {

    // MARK: - Model

    let contact: ResolvedContact

    // MARK: - State

    var isHighlighted: Bool = false {
        didSet { updateBackground() }
    }

    /// Called when the user clicks this row.
    var onTap: (() -> Void)?

    // MARK: - Subviews

    private let nameLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: 13, weight: .medium)
        tf.textColor = .labelColor
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        return tf
    }()

    private let subtitleLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: 11, weight: .regular)
        tf.textColor = .secondaryLabelColor
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        return tf
    }()

    // MARK: - Init

    init(contact: ResolvedContact) {
        self.contact = contact
        super.init(frame: .zero)
        wantsLayer = true
        nameLabel.stringValue = contact.displayName
        subtitleLabel.stringValue = contact.subtitle
        setupLayout()
        updateBackground()
        addClickRecogniser()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported — use init(contact:)")
    }

    // MARK: - Layout

    private func setupLayout() {
        addSubview(nameLabel)
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            // Name label — top half, 12pt leading inset
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),

            // Subtitle label — below name
            subtitleLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
        ])
    }

    // MARK: - Background

    private func updateBackground() {
        if isHighlighted {
            layer?.backgroundColor = NSColor.selectedContentBackgroundColor
                .withAlphaComponent(0.15)
                .cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    // MARK: - Click handling

    private func addClickRecogniser() {
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
    }

    @objc private func handleClick() {
        onTap?()
    }
}
