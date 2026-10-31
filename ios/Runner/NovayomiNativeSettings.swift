import Flutter
import UIKit

/// Native UIKit settings navigation. The existing Dart settings providers
/// remain responsible for every preference, account and sync write.
final class NovayomiNativeSettingsFactory: NSObject, FlutterPlatformViewFactory {
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
    NovayomiNativeSettingsView(frame: frame, id: viewId, messenger: messenger)
  }
}

private final class NovayomiNativeSettingsView: NSObject, FlutterPlatformView,
    UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
  private struct Entry {
    let name: String
    let detail: String
    let symbol: String
    let path: String
  }
  private let groups: [(String, [Entry])] = [
    ("Application", [
      Entry(name: "General", detail: "Language, navigation and behavior", symbol: "gearshape.2", path: "/general"),
      Entry(name: "Appearance", detail: "Themes, colors and display", symbol: "paintpalette", path: "/appearance"),
      Entry(name: "Security", detail: "Privacy and access", symbol: "lock.shield", path: "/security")
    ]),
    ("Reading", [
      Entry(name: "Novel Reader", detail: "Typography, pagination and speech", symbol: "book.closed", path: "/novelReaderMode"),
      Entry(name: "Downloads", detail: "Offline storage and connection rules", symbol: "arrow.down.circle", path: "/downloads")
    ]),
    ("Sources & Services", [
      Entry(name: "Browse", detail: "Novel sources and repositories", symbol: "safari", path: "/browseS"),
      Entry(name: "Tracking", detail: "Reading trackers", symbol: "point.3.connected.trianglepath.dotted", path: "/track"),
      Entry(name: "Sync", detail: "Cloud synchronization", symbol: "arrow.triangle.2.circlepath.icloud", path: "/sync")
    ]),
    ("Novayomi", [
      Entry(name: "About", detail: "Version, licenses and information", symbol: "info.circle", path: "/about")
    ])
  ]
  private let root: UIView
  private let channel: FlutterMethodChannel
  private let nav = UINavigationBar()
  private let navigation = UINavigationItem(title: "")
  private let largeTitle = UILabel()
  private let titleHeader = UIView()
  private let search = UISearchBar()
  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private var sections: [(String, [Entry])] = []

  init(frame: CGRect, id: Int64, messenger: FlutterBinaryMessenger) {
    root = UIView(frame: frame)
    channel = FlutterMethodChannel(name: "novayomi/native-settings/\(id)",
                                   binaryMessenger: messenger)
    super.init()
    root.backgroundColor = .systemGroupedBackground
    root.tintColor = .novayomiAccent
    nav.translatesAutoresizingMaskIntoConstraints = false
    let appearance = UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    nav.standardAppearance = appearance
    nav.scrollEdgeAppearance = appearance
    navigation.leftBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "chevron.backward"),
      primaryAction: UIAction { [weak self] _ in
        self?.channel.invokeMethod("close", arguments: nil)
      })
    navigation.leftBarButtonItem?.accessibilityLabel = "Back"
    nav.setItems([navigation], animated: false)
    root.addSubview(nav)
    search.searchBarStyle = .minimal
    search.placeholder = "Search settings"
    search.delegate = self
    search.translatesAutoresizingMaskIntoConstraints = false
    largeTitle.text = "Settings"
    largeTitle.font = .preferredFont(forTextStyle: .largeTitle)
    largeTitle.adjustsFontForContentSizeCategory = true
    largeTitle.translatesAutoresizingMaskIntoConstraints = false
    titleHeader.frame = CGRect(x: 0, y: 0, width: frame.width, height: 148)
    titleHeader.addSubview(largeTitle)
    titleHeader.addSubview(search)
    NSLayoutConstraint.activate([
      largeTitle.topAnchor.constraint(equalTo: titleHeader.topAnchor, constant: 20),
      largeTitle.leadingAnchor.constraint(equalTo: titleHeader.leadingAnchor, constant: 22),
      largeTitle.trailingAnchor.constraint(equalTo: titleHeader.trailingAnchor, constant: -20),
      search.topAnchor.constraint(equalTo: largeTitle.bottomAnchor, constant: 8),
      search.leadingAnchor.constraint(equalTo: titleHeader.leadingAnchor, constant: 8),
      search.trailingAnchor.constraint(equalTo: titleHeader.trailingAnchor, constant: -8),
      search.bottomAnchor.constraint(lessThanOrEqualTo: titleHeader.bottomAnchor, constant: -4)
    ])
    table.tableHeaderView = titleHeader
    table.backgroundColor = .clear
    table.dataSource = self
    table.delegate = self
    table.rowHeight = 64
    table.keyboardDismissMode = .onDrag
    table.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(table)
    NSLayoutConstraint.activate([
      nav.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
      nav.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      nav.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      table.topAnchor.constraint(equalTo: nav.bottomAnchor),
      table.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      table.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      table.bottomAnchor.constraint(equalTo: root.bottomAnchor)
    ])
    filter("")
  }
  func view() -> UIView { root }
  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard scrollView === table else { return }
    let label = scrollView.contentOffset.y > 82 ? "Settings" : ""
    if navigation.title != label { navigation.title = label }
  }
  private func filter(_ query: String) {
    sections = groups.compactMap { section in
      let rows = section.1.filter { entry in
        query.isEmpty || entry.name.localizedCaseInsensitiveContains(query) ||
        entry.detail.localizedCaseInsensitiveContains(query)
      }
      return rows.isEmpty ? nil : (section.0, rows)
    }
    table.reloadData()
  }
  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    filter(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
  }
  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
  }
  func numberOfSections(in tableView: UITableView) -> Int { sections.count }
  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    sections[section].0
  }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    sections[section].1.count
  }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let row = sections[indexPath.section].1[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "settings")
      ?? UITableViewCell(style: .subtitle, reuseIdentifier: "settings")
    var content = cell.defaultContentConfiguration()
    content.text = row.name
    content.secondaryText = row.detail
    content.image = UIImage(systemName: row.symbol) ?? UIImage(systemName: "gearshape")
    content.imageProperties.tintColor = root.tintColor
    cell.contentConfiguration = content
    cell.accessoryType = .disclosureIndicator
    return cell
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    channel.invokeMethod("navigate", arguments: sections[indexPath.section].1[indexPath.row].path)
  }
}
