import Flutter
import UIKit

/// Phase 2.4 native Updates / History interface. Each row is produced by
/// the existing Dart history and update streams; UIKit owns only presentation.
final class NovayomiNativeActivityFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger
  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64,
              arguments args: Any?) -> FlutterPlatformView {
    NovayomiNativeActivityView(frame: frame, id: viewId, messenger: messenger,
                               data: args as? [String: Any] ?? [:])
  }
}

private final class NovayomiNativeActivityView: NSObject, FlutterPlatformView,
    UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
  private let root: UIView
  private let channel: FlutterMethodChannel
  private let heading = UILabel()
  private let search = UISearchBar()
  private let tabs = UISegmentedControl(items: ["Updates", "History"])
  private let actions = UIButton(type: .system)
  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private let refresh = UIRefreshControl()
  private var updates: [[String: Any]] = []
  private var history: [[String: Any]] = []
  private var displayed: [[String: Any]] = []
  private var query = ""

  init(frame: CGRect, id: Int64, messenger: FlutterBinaryMessenger,
       data: [String: Any]) {
    root = UIView(frame: frame)
    channel = FlutterMethodChannel(name: "novayomi/native-activity/\(id)",
                                   binaryMessenger: messenger)
    super.init()
    root.backgroundColor = .systemGroupedBackground
    heading.text = "Activity"
    heading.font = .preferredFont(forTextStyle: .largeTitle)
    heading.adjustsFontForContentSizeCategory = true
    heading.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(heading)
    actions.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
    actions.accessibilityLabel = "Activity actions"
    actions.showsMenuAsPrimaryAction = true
    actions.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(actions)

    tabs.selectedSegmentIndex = min(max(data["tab"] as? Int ?? 0, 0), 1)
    tabs.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
    tabs.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(tabs)
    search.searchBarStyle = .minimal
    search.placeholder = "Search recent activity"
    search.delegate = self
    search.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(search)
    table.backgroundColor = .clear
    table.dataSource = self
    table.delegate = self
    table.rowHeight = 74
    table.keyboardDismissMode = .onDrag
    table.translatesAutoresizingMaskIntoConstraints = false
    refresh.addTarget(self, action: #selector(refreshRequested), for: .valueChanged)
    table.refreshControl = refresh
    root.addSubview(table)

    NSLayoutConstraint.activate([
      heading.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 14),
      heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
      heading.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),
      actions.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
      actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
      actions.widthAnchor.constraint(equalToConstant: 44),
      actions.heightAnchor.constraint(equalToConstant: 44),
      tabs.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
      tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
      tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
      search.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
      search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
      search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
      search.heightAnchor.constraint(equalToConstant: 52),
      table.topAnchor.constraint(equalTo: search.bottomAnchor),
      table.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      table.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      table.bottomAnchor.constraint(equalTo: root.bottomAnchor)
    ])

    apply(data)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      switch call.method {
      case "update":
        if let data = call.arguments as? [String: Any] { self.apply(data) }
        result(nil)
      case "refreshComplete":
        self.refresh.endRefreshing()
        result(nil)
      case "error":
        let alert = UIAlertController(title: "Activity action failed",
          message: call.arguments as? String, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.presentNative(alert)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
  deinit { channel.setMethodCallHandler(nil) }
  func view() -> UIView { root }

  private func apply(_ data: [String: Any]) {
    updates = data["updates"] as? [[String: Any]] ?? []
    history = data["history"] as? [[String: Any]] ?? []
    filter()
  }

  private func filter() {
    let items = tabs.selectedSegmentIndex == 0 ? updates : history
    displayed = items.filter { item in
      query.isEmpty ||
      (item["book"] as? String ?? "").localizedCaseInsensitiveContains(query) ||
      (item["chapter"] as? String ?? "").localizedCaseInsensitiveContains(query)
    }
    table.reloadData()
    updateMenu()
  }

  private func updateMenu() {
    actions.menu = UIMenu(children: [
      UIAction(title: "Update Library", image: UIImage(systemName: "arrow.clockwise")) {
        [weak self] _ in self?.channel.invokeMethod("refresh", arguments: nil)
      },
      UIAction(title: tabs.selectedSegmentIndex == 0 ? "Clear updates" : "Clear history",
        image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
        self?.confirmClear()
      }
    ])
  }

  private func confirmClear() {
    let kind = tabs.selectedSegmentIndex == 0 ? "updates" : "history"
    let alert = UIAlertController(title: "Clear \(kind)?",
      message: "This removes all saved \(kind) entries, without deleting novels or downloads.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
      self?.channel.invokeMethod("clear", arguments: kind)
    })
    presentNative(alert)
  }

  private func presentNative(_ child: UIViewController) {
    guard var presenter = root.window?.rootViewController else { return }
    while let next = presenter.presentedViewController { presenter = next }
    presenter.present(child, animated: true)
  }

  @objc private func refreshRequested() {
    channel.invokeMethod("refresh", arguments: nil)
  }
  @objc private func tabChanged() { filter() }

  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    query = searchText
    filter()
  }
  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
  }
  func numberOfSections(in tableView: UITableView) -> Int { 1 }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    displayed.count
  }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let row = displayed[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "activity")
      ?? UITableViewCell(style: .subtitle, reuseIdentifier: "activity")
    var content = cell.defaultContentConfiguration()
    content.text = row["book"] as? String ?? "Novel"
    content.secondaryText = [
      row["chapter"] as? String ?? "",
      row["date"] as? String ?? ""
    ].filter { !$0.isEmpty }.joined(separator: " · ")
    content.secondaryTextProperties.numberOfLines = 2
    content.image = UIImage(systemName: tabs.selectedSegmentIndex == 0 ?
                            "sparkle.magnifyingglass" : "book.closed")
    content.imageProperties.tintColor = root.tintColor
    cell.contentConfiguration = content
    cell.accessoryType = .disclosureIndicator
    return cell
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let row = displayed[indexPath.row]
    if let id = row["chapterId"] as? Int {
      channel.invokeMethod("read", arguments: id)
    }
  }
  func tableView(_ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
    let item = displayed[indexPath.row]
    guard let id = item["id"] as? Int else { return nil }
    let kind = tabs.selectedSegmentIndex == 0 ? "removeUpdate" : "removeHistory"
    let remove = UIContextualAction(style: .destructive, title: "Remove") {
      [weak self] _, _, done in
      self?.channel.invokeMethod(kind, arguments: id)
      done(true)
    }
    let download = UIContextualAction(style: .normal, title: "Download") {
      [weak self] _, _, done in
      if let chapterId = item["chapterId"] as? Int {
        self?.channel.invokeMethod("download", arguments: chapterId)
      }
      done(true)
    }
    download.backgroundColor = .systemTeal
    return UISwipeActionsConfiguration(actions: tabs.selectedSegmentIndex == 0 ?
      [remove, download] : [remove])
  }
}
