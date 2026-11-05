import Flutter
import UIKit

/// Phase 2.5 UIKit More tab. Navigation and switches are forwarded to the
/// existing Dart routes/providers; no duplicate settings storage is created.
final class NovayomiNativeMoreFactory: NSObject, FlutterPlatformViewFactory {
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
    NovayomiNativeMoreView(frame: frame, identifier: viewId,
                           messenger: messenger, data: args as? [String: Any] ?? [:])
  }
}

private final class NovayomiNativeMoreView: NSObject, FlutterPlatformView,
    UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
  private struct Item {
    let title: String
    let symbol: String
    let path: String
    let toggle: Bool
    let detail: String?
    init(_ title: String, _ symbol: String, _ path: String,
         toggle: Bool = false, detail: String? = nil) {
      self.title = title
      self.symbol = symbol
      self.path = path
      self.toggle = toggle
      self.detail = detail
    }
  }

  private let root: UIView
  private let channel: FlutterMethodChannel
  private let heading = UILabel()
  private let summary = UILabel()
  private let scrollingHeader = UIView()
  private let search = UISearchBar()
  private var allGroups: [(String, [Item])] = []
  private var searchText = ""
  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private var downloadedOnly = false
  private var incognito = false
  private var showHistory = true
  private var groups: [(String, [Item])] = []

  init(frame: CGRect, identifier: Int64, messenger: FlutterBinaryMessenger,
       data: [String: Any]) {
    root = UIView(frame: frame)
    channel = FlutterMethodChannel(name: "novayomi/native-more/\(identifier)",
                                   binaryMessenger: messenger)
    super.init()
    root.backgroundColor = .systemGroupedBackground
    root.tintColor = .novayomiAccent
    heading.text = "Settings"
    heading.font = .preferredFont(forTextStyle: .largeTitle)
    heading.adjustsFontForContentSizeCategory = true
    heading.translatesAutoresizingMaskIntoConstraints = false

    summary.textColor = .secondaryLabel
    summary.font = .preferredFont(forTextStyle: .subheadline)
    summary.numberOfLines = 2
    summary.adjustsFontForContentSizeCategory = true
    summary.translatesAutoresizingMaskIntoConstraints = false
    scrollingHeader.frame = CGRect(x: 0, y: 0, width: frame.width, height: 146)
    search.delegate = self
    search.placeholder = "Search"
    search.searchBarStyle = .minimal
    search.translatesAutoresizingMaskIntoConstraints = false
    scrollingHeader.addSubview(heading)
    scrollingHeader.addSubview(search)
    NSLayoutConstraint.activate([
      heading.topAnchor.constraint(equalTo: scrollingHeader.topAnchor, constant: 18),
      heading.leadingAnchor.constraint(equalTo: scrollingHeader.leadingAnchor, constant: 22),
      heading.trailingAnchor.constraint(equalTo: scrollingHeader.trailingAnchor, constant: -18),
      search.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14),
      search.leadingAnchor.constraint(equalTo: scrollingHeader.leadingAnchor, constant: 8),
      search.trailingAnchor.constraint(equalTo: scrollingHeader.trailingAnchor, constant: -8),
      search.heightAnchor.constraint(equalToConstant: 52)
    ])
    table.tableHeaderView = scrollingHeader

    table.backgroundColor = .clear
    table.dataSource = self
    table.delegate = self
    table.rowHeight = UITableView.automaticDimension
    table.estimatedRowHeight = 65
    table.keyboardDismissMode = .onDrag
    // Keep the last grouped settings row fully reachable above the
    // persistent floating iOS tabs. Do not simply shorten the table.
    table.contentInset.bottom = 114
    table.verticalScrollIndicatorInsets.bottom = 114
    table.sectionHeaderTopPadding = 12
    table.estimatedSectionHeaderHeight = 30
    table.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(table)
    NSLayoutConstraint.activate([
      table.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
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
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }
  deinit { channel.setMethodCallHandler(nil) }
  func view() -> UIView { root }

  private func apply(_ data: [String: Any]) {
    downloadedOnly = data["downloadedOnly"] as? Bool ?? false
    incognito = data["incognito"] as? Bool ?? false
    showHistory = data["showHistory"] as? Bool ?? true
    let series = data["series"] as? Int ?? 0
    let chapters = data["read"] as? Int ?? 0
    let seconds = data["seconds"] as? Int ?? 0
    let time = seconds >= 3600 ? "\(seconds / 3600) h" : "\(seconds / 60) min"
    summary.text = "\(series) novels  ·  \(chapters) chapters read  ·  \(time)"
    allGroups = [
      ("", [
        Item("Incognito Mode", "eye.slash", "incognito", toggle: true,
             detail: "Pauses reading history when enabled")
      ]),
      ("", [
        Item("Appearance", "textformat.size", "/appearance"),
        Item("Library", "books.vertical", "/categories"),
        Item("Reader", "book.pages", "/novelReaderMode"),
        Item("Tracking", "arrow.triangle.2.circlepath", "/track"),
        Item("Downloads", "arrow.down.circle", "/downloads"),
        Item("iCloud / Sync", "icloud", "/sync"),
        Item("Advanced", "gearshape.2.fill", "/settings")
      ]),
      ("", [
        Item("About", "info.circle.fill", "/about"),
        Item("Insights", "chart.bar.fill", "/statistics"),
        Item("Data & Storage", "externaldrive.fill", "/dataAndStorage"),
        Item("Download Queue", "tray.full.fill", "/downloadQueue"),
        Item("Collections", "folder.fill", "/categories"),
        Item("Calendar", "calendar", "/calendarScreen"),
        Item("Mass Migration", "arrow.left.arrow.right", "/massMigration"),
        Item("Downloaded Only", "arrow.down.circle.fill", "downloadedOnly", toggle: true)
      ])
    ]
    if showHistory {
      var extraEntries = allGroups[2].1
      extraEntries.insert(Item("Reading History", "clock", "/history"), at: 2)
      allGroups[2] = ("", extraEntries)
    }
    filter(searchText)

  }

  private func filter(_ query: String) {
    searchText = query
    groups = allGroups.compactMap { title, entries in
      let selected = entries.filter {
        query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
            || ($0.detail ?? "").localizedCaseInsensitiveContains(query)
      }
      return selected.isEmpty ? nil : (title, selected)
    }
    table.reloadData()
  }
  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    filter(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
  }
  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
  }
  func numberOfSections(in tableView: UITableView) -> Int { groups.count }
  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    groups[section].0.isEmpty ? nil : groups[section].0
  }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    groups[section].1.count
  }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let item = groups[indexPath.section].1[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "native-more")
      ?? UITableViewCell(style: .subtitle, reuseIdentifier: "native-more")
    var content = cell.defaultContentConfiguration()
    content.text = item.title
    content.textProperties.font = .preferredFont(forTextStyle: .body)
    content.secondaryText = item.detail
    content.secondaryTextProperties.color = .secondaryLabel
    content.secondaryTextProperties.numberOfLines = 2
    content.image = tile(for: item)
    content.imageProperties.maximumSize = CGSize(width: 34, height: 34)
    cell.contentConfiguration = content
    if item.toggle {
      let toggle = UISwitch()
      toggle.isOn = item.path == "downloadedOnly" ? downloadedOnly : incognito
      toggle.accessibilityLabel = item.title
      toggle.tag = item.path == "downloadedOnly" ? 0 : 1
      toggle.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)
      cell.accessoryView = toggle
      cell.accessoryType = .none
      cell.selectionStyle = .none
    } else {
      cell.accessoryView = nil
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    }
    return cell
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let item = groups[indexPath.section].1[indexPath.row]
    guard !item.toggle else { return }
    channel.invokeMethod("navigate", arguments: item.path)
  }
  private func tile(for item: Item) -> UIImage? {
    let color: UIColor
    switch item.path {
    case "/appearance", "/sync", "/categories": color = .systemBlue
    case "/novelReaderMode", "/calendarScreen": color = .systemGreen
    case "/track", "/downloads": color = .systemOrange
    case "/settings", "/dataAndStorage": color = .systemGray
    case "/statistics", "/history": color = .systemIndigo
    case "incognito", "/downloadQueue": color = .systemRed
    default: color = .systemGray2
    }
    let canvas = CGSize(width: 34, height: 34)
    return UIGraphicsImageRenderer(size: canvas).image { _ in
      color.setFill()
      UIBezierPath(roundedRect: CGRect(origin: .zero, size: canvas), cornerRadius: 8).fill()
      let symbol = UIImage(systemName: item.symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))?.withTintColor(
          .white, renderingMode: .alwaysOriginal)
      symbol?.draw(in: CGRect(x: 7, y: 7, width: 20, height: 20))
    }
  }

  @objc private func toggleChanged(_ control: UISwitch) {
    let name = control.tag == 0 ? "downloadedOnly" : "incognito"
    if control.tag == 0 { downloadedOnly = control.isOn }
    else { incognito = control.isOn }
    channel.invokeMethod("mode", arguments: ["name": name, "value": control.isOn])
  }
}
