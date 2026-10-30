import Flutter
import UIKit

/// Phase 2.3: native UIKit novel-source browser. Source discovery, installation
/// and execution remain exclusively in the existing Dart repositories.
final class NovayomiNativeBrowseFactory: NSObject, FlutterPlatformViewFactory {
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
    NovayomiNativeBrowseView(frame: frame, id: viewId, messenger: messenger,
                             data: args as? [String: Any] ?? [:])
  }
}

private final class NovayomiNativeBrowseView: NSObject, FlutterPlatformView,
    UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
  private let root: UIView
  private let channel: FlutterMethodChannel
  private let heading = UILabel()
  private let search = UISearchBar()
  private let segments = UISegmentedControl(items: ["Sources", "Extensions"])
  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private var allSources: [[String: Any]] = []
  private var filtered: [[String: Any]] = []
  private var text = ""
  private let extensionActions: [(String, String, String)] = [
    ("Manage extensions", "puzzlepiece.extension", "extensions"),
    ("Extension repositories", "shippingbox", "repositories"),
    ("Source filters", "line.3.horizontal.decrease", "sourceFilters"),
    ("Global novel search", "magnifyingglass", "globalSearch")
  ]

  init(frame: CGRect, id: Int64, messenger: FlutterBinaryMessenger,
       data: [String: Any]) {
    root = UIView(frame: frame)
    channel = FlutterMethodChannel(name: "novayomi/native-browse/\(id)",
                                   binaryMessenger: messenger)
    super.init()
    root.backgroundColor = .systemGroupedBackground
    heading.text = "Browse"
    heading.font = .preferredFont(forTextStyle: .largeTitle)
    heading.adjustsFontForContentSizeCategory = true
    heading.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(heading)
    search.searchBarStyle = .minimal
    search.placeholder = "Search sources"
    search.delegate = self
    search.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(search)
    segments.selectedSegmentIndex = 0
    segments.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
    segments.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(segments)

    table.dataSource = self
    table.delegate = self
    table.backgroundColor = .clear
    table.rowHeight = 60
    table.keyboardDismissMode = .onDrag
    table.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(table)
    NSLayoutConstraint.activate([
      heading.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 12),
      heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
      heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      search.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
      search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
      search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
      search.heightAnchor.constraint(equalToConstant: 52),
      segments.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
      segments.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
      segments.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
      table.topAnchor.constraint(equalTo: segments.bottomAnchor, constant: 8),
      table.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      table.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      table.bottomAnchor.constraint(equalTo: root.bottomAnchor)
    ])
    apply(data)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      if call.method == "update", let data = call.arguments as? [String: Any] {
        self.apply(data)
        result(nil)
      } else { result(FlutterMethodNotImplemented) }
    }
  }
  deinit { channel.setMethodCallHandler(nil) }
  func view() -> UIView { root }

  private func apply(_ data: [String: Any]) {
    allSources = data["sources"] as? [[String: Any]] ?? []
    filter()
  }
  private func filter() {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    filtered = allSources.filter { item in
      trimmed.isEmpty ||
      (item["name"] as? String ?? "").localizedCaseInsensitiveContains(trimmed) ||
      (item["lang"] as? String ?? "").localizedCaseInsensitiveContains(trimmed)
    }
    filtered.sort { a, b in
      let lhs = a["pinned"] as? Bool ?? false
      let rhs = b["pinned"] as? Bool ?? false
      if lhs != rhs { return lhs }
      return (a["name"] as? String ?? "").localizedCompare(
        b["name"] as? String ?? "") == .orderedAscending
    }
    table.reloadData()
  }
  @objc private func tabChanged() {
    search.placeholder = segments.selectedSegmentIndex == 0 ? "Search sources" : "Search extensions"
    filter()
  }
  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    text = searchText
    filter()
  }
  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
  }

  func numberOfSections(in tableView: UITableView) -> Int { 1 }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    if segments.selectedSegmentIndex == 1 {
      return extensionActions.filter { text.isEmpty ||
        $0.0.localizedCaseInsensitiveContains(text) }.count
    }
    // Local imports always remain visible without a remotely installed source.
    return filtered.count + 1
  }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "source")
      ?? UITableViewCell(style: .subtitle, reuseIdentifier: "source")
    let label: String
    let subtitle: String
    let symbol: String
    if segments.selectedSegmentIndex == 1 {
      let actions = extensionActions.filter { text.isEmpty ||
        $0.0.localizedCaseInsensitiveContains(text) }
      let action = actions[indexPath.row]
      label = action.0
      subtitle = "Manage existing source extensions"
      symbol = action.1
    } else if indexPath.row == filtered.count {
      label = "Local novels"
      subtitle = "Read imported EPUBs"
      symbol = "books.vertical"
    } else {
      let source = filtered[indexPath.row]
      label = source["name"] as? String ?? "Source"
      subtitle = source["lang"] as? String ?? ""
      symbol = source["pinned"] as? Bool == true ? "pin.fill" : "books.vertical"
    }
    var content = cell.defaultContentConfiguration()
    content.text = label
    content.secondaryText = subtitle
    content.image = UIImage(systemName: symbol)
    content.imageProperties.tintColor = root.tintColor
    cell.contentConfiguration = content
    cell.accessoryType = .disclosureIndicator
    return cell
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if segments.selectedSegmentIndex == 1 {
      let options = extensionActions.filter { text.isEmpty ||
        $0.0.localizedCaseInsensitiveContains(text) }
      channel.invokeMethod("action", arguments: options[indexPath.row].2)
      return
    }
    if indexPath.row == filtered.count {
      channel.invokeMethod("action", arguments: "local")
      return
    }
    if let id = filtered[indexPath.row]["id"] as? Int {
      channel.invokeMethod("openSource", arguments: id)
    }
  }
  func tableView(_ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
    guard segments.selectedSegmentIndex == 0, indexPath.row < filtered.count,
          let id = filtered[indexPath.row]["id"] as? Int else { return nil }
    let pinned = filtered[indexPath.row]["pinned"] as? Bool ?? false
    let pin = UIContextualAction(style: .normal, title: pinned ? "Unpin" : "Pin") {
      [weak self] _, _, completion in
      self?.channel.invokeMethod("pin", arguments: id)
      completion(true)
    }
    pin.backgroundColor = .systemBlue
    return UISwipeActionsConfiguration(actions: [pin])
  }
}
