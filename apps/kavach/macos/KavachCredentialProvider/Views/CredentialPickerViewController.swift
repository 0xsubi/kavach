import AppKit

/// AppKit twin of the iOS `CredentialPickerViewController`: lists the
/// passkeys this device holds for one relying party for the discoverable
/// credential flow.
final class CredentialPickerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let records: [PasskeyRecord]
    private let onSelect: (PasskeyRecord) -> Void
    private let tableView = NSTableView()

    init(records: [PasskeyRecord], onSelect: @escaping (PasskeyRecord) -> Void) {
        self.records = records
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let column = NSTableColumn(identifier: .init("main"))
        column.title = "Passkey"
        column.width = 380
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(didDoubleClickRow)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let record = records[row]
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "\(record.userName) — \(record.rpName)")
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func didDoubleClickRow() {
        let row = tableView.clickedRow
        guard row >= 0, row < records.count else { return }
        onSelect(records[row])
    }
}
