import UIKit

/// Minimal confirmation screen shown before creating or using a passkey.
/// Deliberately plain UIKit (not NeoPop): this runs inside the sandboxed,
/// memory-constrained extension process, which never links the Flutter
/// engine or the app's own theme package (plan §6).
final class ConfirmationViewController: UIViewController {
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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let icon = UIImageView(image: UIImage(systemName: "person.badge.key.fill"))
        icon.tintColor = .systemBlue
        icon.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.text = titleText
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textAlignment = .center

        let rpLabel = UILabel()
        rpLabel.text = relyingParty
        rpLabel.font = .preferredFont(forTextStyle: .headline)
        rpLabel.textAlignment = .center

        let userLabel = UILabel()
        userLabel.text = userName
        userLabel.font = .preferredFont(forTextStyle: .subheadline)
        userLabel.textColor = .secondaryLabel
        userLabel.textAlignment = .center

        let confirmButton = UIButton(type: .system)
        confirmButton.setTitle(confirmTitle, for: .normal)
        confirmButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        confirmButton.backgroundColor = .systemBlue
        confirmButton.setTitleColor(.white, for: .normal)
        confirmButton.layer.cornerRadius = 12
        confirmButton.heightAnchor.constraint(equalToConstant: 50).isActive = true
        confirmButton.addAction(UIAction { [weak self] _ in self?.onConfirm() }, for: .touchUpInside)

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addAction(UIAction { [weak self] _ in self?.onCancel() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, rpLabel, userLabel, confirmButton, cancelButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        stack.setCustomSpacing(24, after: icon)
        stack.translatesAutoresizingMaskIntoConstraints = false
        icon.heightAnchor.constraint(equalToConstant: 60).isActive = true

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
