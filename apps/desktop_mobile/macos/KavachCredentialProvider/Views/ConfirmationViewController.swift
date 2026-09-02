import AppKit

/// AppKit twin of the iOS `ConfirmationViewController` — plain, undecorated
/// UI since this runs inside the sandboxed extension process (plan §6).
final class ConfirmationViewController: NSViewController {
    private let titleText: String
    private let relyingParty: String
    private let userName: String
    private let confirmTitle: String
    private let onConfirm: () -> Void
    private let onCancel: () -> Void

    init(
        title: String,
        relyingParty: String,
        userName: String,
        confirmTitle: String,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.titleText = title
        self.relyingParty = relyingParty
        self.userName = userName
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let titleLabel = NSTextField(labelWithString: titleText)
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.alignment = .center

        let rpLabel = NSTextField(labelWithString: relyingParty)
        rpLabel.font = .systemFont(ofSize: 14, weight: .medium)
        rpLabel.alignment = .center

        let userLabel = NSTextField(labelWithString: userName)
        userLabel.font = .systemFont(ofSize: 12)
        userLabel.textColor = .secondaryLabelColor
        userLabel.alignment = .center

        let confirmButton = NSButton(title: confirmTitle, target: nil, action: nil)
        confirmButton.bezelStyle = .rounded
        confirmButton.keyEquivalent = "\r"
        confirmButton.target = self
        confirmButton.action = #selector(didTapConfirm)

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(didTapCancel)

        let buttonRow = NSStackView(views: [cancelButton, confirmButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12

        let stack = NSStackView(views: [titleLabel, rpLabel, userLabel, buttonRow])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }

    @objc private func didTapConfirm() { onConfirm() }
    @objc private func didTapCancel() { onCancel() }
}
