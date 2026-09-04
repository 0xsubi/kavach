import UIKit

/// Lists the passkeys this device holds for one relying party, for the
/// "usernameless"/discoverable-credential flow (`prepareCredentialList(for:
/// requestParameters:)`), where the OS doesn't already know which credential
/// the user wants.
final class CredentialPickerViewController: UITableViewController {
    private let records: [PasskeyRecord]
    private let onSelect: (PasskeyRecord) -> Void

    init(records: [PasskeyRecord], onSelect: @escaping (PasskeyRecord) -> Void) {
        self.records = records
        self.onSelect = onSelect
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Choose a passkey"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        records.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let record = records[indexPath.row]
        var config = UIListContentConfiguration.subtitleCell()
        config.text = record.userName
        config.secondaryText = record.rpName
        cell.contentConfiguration = config
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect(records[indexPath.row])
    }
}
