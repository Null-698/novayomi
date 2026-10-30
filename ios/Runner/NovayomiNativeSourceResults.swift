import Flutter
import UIKit

/// UIKit source-results browser. All paging, search, filtering and detail
/// resolution use the same extension-engine providers as Flutter.
final class NovayomiNativeSourceResultsFactory: NSObject, FlutterPlatformViewFactory {
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
    NovayomiNativeSourceResultsView(frame: frame, id: viewId, messenger: messenger,
                                    data: args as? [String: Any] ?? [:])
  }
}

private final class NovayomiNativeSourceResultsView: NSObject, FlutterPlatformView,
    UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
  private let root: UIView
  private let channel: FlutterMethodChannel
  private let nav = UINavigationBar()
  private let navItem = UINavigationItem(title: "Novels")
  private let search = UISearchBar()
  private let segmented = UISegmentedControl(items: ["Popular", "Latest"])
  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private let refresh = UIRefreshControl()
  private var novels: [[String: Any]] = []
  private var hasMore = false
  private var busy = false
  private var selected = 0
  private var query = ""
  private var globalMode = false
  private static let coverCache = NSCache<NSString, UIImage>()

  init(frame: CGRect, id: Int64, messenger: FlutterBinaryMessenger,
       data: [String: Any]) {
    root = UIView(frame: frame)
    channel = FlutterMethodChannel(name: "novayomi/native-source-results/\(id)",
                                   binaryMessenger: messenger)
    super.init()
    root.backgroundColor = .systemGroupedBackground
    nav.translatesAutoresizingMaskIntoConstraints = false
    navItem.leftBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "chevron.backward"),
      primaryAction: UIAction { [weak self] _ in self?.send("close") })
    navItem.leftBarButtonItem?.accessibilityLabel = "Back"
    navItem.rightBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "ellipsis.circle"),
      menu: UIMenu(children: [
        UIAction(title: "Source settings", image: UIImage(systemName: "gearshape")) {
          [weak self] _ in self?.send("settings")
        },
        UIAction(title: "Open source website", image: UIImage(systemName: "safari")) {
          [weak self] _ in self?.send("website")
        }
      ]))
    nav.setItems([navItem], animated: false)
    root.addSubview(nav)

    search.placeholder = "Search novels in source"
    search.searchBarStyle = .minimal
    search.delegate = self
    search.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(search)
    segmented.selectedSegmentIndex = 0
    segmented.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
    segmented.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(segmented)

    table.backgroundColor = .clear
    table.rowHeight = 78
    table.dataSource = self
    table.delegate = self
    table.keyboardDismissMode = .onDrag
    table.translatesAutoresizingMaskIntoConstraints = false
    refresh.addTarget(self, action: #selector(refreshRequested), for: .valueChanged)
    table.refreshControl = refresh
    root.addSubview(table)
    NSLayoutConstraint.activate([
      nav.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
      nav.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      nav.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      search.topAnchor.constraint(equalTo: nav.bottomAnchor),
      search.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      search.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      search.heightAnchor.constraint(equalToConstant: 52),
      segmented.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
      segmented.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
      segmented.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      table.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 8),
      table.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      table.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      table.bottomAnchor.constraint(equalTo: root.bottomAnchor)
    ])
    globalMode = data["globalMode"] as? Bool ?? false
    if globalMode {
      search.placeholder = "Search all novel sources"
      search.text = data["query"] as? String ?? ""
      segmented.isHidden = true
      navItem.rightBarButtonItem = nil
    }
    apply(data)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      if call.method == "update", let data = call.arguments as? [String: Any] {
        self.apply(data)
        self.refresh.endRefreshing()
        result(nil)
      } else if call.method == "error" {
        self.busy = false
        self.refresh.endRefreshing()
        let alert = UIAlertController(title: "Source failed",
          message: call.arguments as? String, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Retry", style: .default) {
          [weak self] _ in self?.send("refresh")
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        self.present(alert)
        result(nil)
      } else { result(FlutterMethodNotImplemented) }
    }
  }
  deinit { channel.setMethodCallHandler(nil) }
  func view() -> UIView { root }
  private func send(_ name: String, _ value: Any? = nil) {
    channel.invokeMethod(name, arguments: value)
  }
  private func present(_ child: UIViewController) {
    guard var host = root.window?.rootViewController else { return }
    while let next = host.presentedViewController { host = next }
    host.present(child, animated: true)
  }
  private func apply(_ data: [String: Any]) {
    navItem.title = data["title"] as? String ?? "Novels"
    if globalMode {
      let text = data["emptyMessage"] as? String
      if novels.isEmpty, let text { search.accessibilityHint = text }
    }
    novels = data["items"] as? [[String: Any]] ?? []
    hasMore = data["hasMore"] as? Bool ?? false
    busy = data["loading"] as? Bool ?? false
    table.reloadData()
    let empty = UILabel()
    empty.text = busy ? "Loading novels…" : "No novels found"
    empty.textColor = .secondaryLabel
    empty.textAlignment = .center
    if novels.isEmpty, !busy, let text = data["emptyMessage"] as? String {
      empty.text = text
      empty.numberOfLines = 3
    }
    table.backgroundView = novels.isEmpty ? empty : nil
  }
  @objc private func segmentChanged() {
    selected = segmented.selectedSegmentIndex
    search.text = ""
    query = ""
    send("mode", selected)
  }
  @objc private func refreshRequested() { send("refresh") }
  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    query = searchText
  }
  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
    send("search", query)
  }
  func numberOfSections(in tableView: UITableView) -> Int { 1 }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    novels.count + (hasMore ? 1 : 0)
  }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "novel")
      ?? UITableViewCell(style: .subtitle, reuseIdentifier: "novel")
    var config = cell.defaultContentConfiguration()
    // Reused cells may still have an image request in flight.
    cell.accessibilityIdentifier = nil
    if indexPath.row == novels.count {
      config.text = busy ? "Loading more…" : "Load more"
      config.image = UIImage(systemName: "arrow.down.circle")
      cell.accessoryType = .none
    } else {
      let item = novels[indexPath.row]
      config.text = item["title"] as? String ?? "Novel"
      let summary = item["description"] as? String ?? ""
      let source = item["source"] as? String ?? ""
      config.secondaryText = globalMode && !source.isEmpty
        ? source + (summary.isEmpty ? "" : " · " + summary)
        : summary
      config.secondaryTextProperties.numberOfLines = 2
      config.image = UIImage(systemName: "book.closed")
      config.imageProperties.maximumSize = CGSize(width: 48, height: 70)
      if let urlText = item["cover"] as? String,
         let url = URL(string: urlText),
         ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
        cell.accessibilityIdentifier = urlText
        if let cached = Self.coverCache.object(forKey: urlText as NSString) {
          config.image = cached
        } else {
          // The cell's token prevents an earlier request from painting a
          // recycled row after a fast scroll or source search.
          cell.accessibilityIdentifier = urlText
          var request = URLRequest(url: url,
            cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
          for (name, value) in item["headers"] as? [String: String] ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
          }
          URLSession.shared.dataTask(with: request) { [weak cell] data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            Self.coverCache.setObject(image, forKey: urlText as NSString)
            DispatchQueue.main.async {
              guard let cell, cell.accessibilityIdentifier == urlText,
                    var current = cell.contentConfiguration as? UIListContentConfiguration
              else { return }
              current.image = image
              cell.contentConfiguration = current
            }
          }.resume()
        }
      } else {
        cell.accessibilityIdentifier = nil
      }
      cell.accessoryType = .disclosureIndicator
    }
    config.imageProperties.tintColor = root.tintColor
    cell.contentConfiguration = config
    return cell
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if indexPath.row == novels.count {
      guard hasMore && !busy else { return }
      busy = true
      send("loadMore")
    } else {
      send("open", indexPath.row)
    }
  }
}
