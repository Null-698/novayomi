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
  private let backButton = UIButton(type: .system)
  private let search = UISearchBar()
  private let segments = UISegmentedControl(items: ["Sources", "Extensions"])
  private let table = UITableView(frame: .zero, style: .plain)
  private let grid = NovayomiPosterGrid(style: .sources)
  private let layoutButton = UIButton(type: .system)
  private var showGrid = UserDefaults.standard.bool(forKey: "novayomi.browse.grid")
  private var allSources: [[String: Any]] = []
  private var allExtensions: [[String: Any]] = []
  private var filteredExtensions: [[String: Any]] = []
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
    root.backgroundColor = .systemBackground
    root.tintColor = .novayomiAccent
    let extensionLanding = data["initialSegment"] as? Int == 1
    backButton.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
    backButton.accessibilityLabel = "Back"
    backButton.isHidden = !extensionLanding
    backButton.addAction(UIAction { [weak self] _ in
      self?.channel.invokeMethod("close", arguments: nil)
    }, for: .touchUpInside)
    backButton.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(backButton)
    heading.text = extensionLanding ? "Extensions" : "Browse"
    heading.font = .preferredFont(forTextStyle: .largeTitle)
    heading.adjustsFontForContentSizeCategory = true
    heading.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(heading)
    layoutButton.setImage(UIImage(systemName: "square.grid.2x2"), for: .normal)
    layoutButton.accessibilityLabel = "Switch list and grid layout"
    layoutButton.addTarget(self, action: #selector(toggleLayout), for: .touchUpInside)
    layoutButton.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(layoutButton)
    search.searchBarStyle = .minimal
    search.placeholder = "Search sources"
    search.delegate = self
    search.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(search)
    segments.selectedSegmentIndex = extensionLanding ? 1 : 0
    segments.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
    segments.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(segments)

    table.dataSource = self
    table.delegate = self
    table.backgroundColor = .systemBackground
    table.rowHeight = 78
    table.separatorInset = UIEdgeInsets(top: 0, left: 82, bottom: 0, right: 16)
    table.sectionHeaderTopPadding = 10
    table.keyboardDismissMode = .onDrag
    table.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(table)
    grid.translatesAutoresizingMaskIntoConstraints = false
    grid.onSelect = { [weak self] index in self?.selectItem(index) }
    grid.menuFor = { [weak self] index in self?.menuForGridItem(index) }
    root.addSubview(grid)
    NSLayoutConstraint.activate([
      heading.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 12),
      heading.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                       constant: extensionLanding ? 62 : 20),
      backButton.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
      backButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
      backButton.widthAnchor.constraint(equalToConstant: 44),
      backButton.heightAnchor.constraint(equalToConstant: 44),
      heading.trailingAnchor.constraint(lessThanOrEqualTo: layoutButton.leadingAnchor, constant: -8),
      layoutButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      layoutButton.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
      layoutButton.widthAnchor.constraint(equalToConstant: 44),
      layoutButton.heightAnchor.constraint(equalToConstant: 44),
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
      table.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      grid.topAnchor.constraint(equalTo: table.topAnchor),
      grid.leadingAnchor.constraint(equalTo: table.leadingAnchor),
      grid.trailingAnchor.constraint(equalTo: table.trailingAnchor),
      grid.bottomAnchor.constraint(equalTo: table.bottomAnchor)
    ])
    updateLayout()
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
    allExtensions = data["extensions"] as? [[String: Any]] ?? []
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
    filteredExtensions = allExtensions.filter { item in
      trimmed.isEmpty ||
      (item["name"] as? String ?? "").localizedCaseInsensitiveContains(trimmed) ||
      (item["lang"] as? String ?? "").localizedCaseInsensitiveContains(trimmed)
    }
    filteredExtensions.sort { a, b in
      let ai = a["installed"] as? Bool ?? false
      let bi = b["installed"] as? Bool ?? false
      if ai != bi { return ai }
      return (a["name"] as? String ?? "").localizedCompare(
        b["name"] as? String ?? "") == .orderedAscending
    }
    table.reloadData()
    var posters: [[String: Any]] = []
    if segments.selectedSegmentIndex == 0 {
      posters = filtered
      posters.append(["name": "Local novels", "lang": "Imported EPUBs"])
    } else {
      posters = filteredExtensions
      for entry in filteredExtensionActions {
        posters.append(["name": entry.0, "lang": "Extension tools"])
      }
    }
    grid.display(posters)
  }

  private var filteredExtensionActions: [(String, String, String)] {
    extensionActions.filter { text.isEmpty ||
      $0.0.localizedCaseInsensitiveContains(text) }
  }

  @objc private func toggleLayout() {
    showGrid.toggle()
    UserDefaults.standard.set(showGrid, forKey: "novayomi.browse.grid")
    updateLayout()
  }

  private func updateLayout() {
    table.isHidden = showGrid
    grid.isHidden = !showGrid
    layoutButton.setImage(UIImage(systemName: showGrid ? "list.bullet" : "square.grid.2x2"),
                          for: .normal)
    layoutButton.accessibilityLabel = showGrid ? "Show list" : "Show grid"
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
  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    segments.selectedSegmentIndex == 0 ? "Sources" : "Extensions"
  }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    if segments.selectedSegmentIndex == 1 {
      return filteredExtensions.count + extensionActions.filter { text.isEmpty ||
        $0.0.localizedCaseInsensitiveContains(text) }.count
    }
    // Local imports always remain visible without a remotely installed source.
    return filtered.count + 1
  }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "source")
      as? NovayomiSourceRowCell
      ?? NovayomiSourceRowCell(style: .subtitle, reuseIdentifier: "source")
    let label: String
    let subtitle: String
    let symbol: String
    var imageURL: String?
    if segments.selectedSegmentIndex == 1 {
      if indexPath.row < filteredExtensions.count {
        let item = filteredExtensions[indexPath.row]
        imageURL = item["icon"] as? String
        label = item["name"] as? String ?? "Extension"
        let installed = item["installed"] as? Bool ?? false
        let updated = item["updateAvailable"] as? Bool ?? false
        subtitle = (item["lang"] as? String ?? "") + " · " +
          (updated ? "Update available" : installed ? "Installed" : "Not installed")
        symbol = updated ? "arrow.down.circle" :
          installed ? "checkmark.seal" : "puzzlepiece.extension"
      } else {
        let actions = extensionActions.filter { text.isEmpty ||
          $0.0.localizedCaseInsensitiveContains(text) }
        let action = actions[indexPath.row - filteredExtensions.count]
        label = action.0
        subtitle = "Manage source extensions"
        symbol = action.1
      }
    } else if indexPath.row == filtered.count {
      label = "Local novels"
      subtitle = "Read imported EPUBs"
      symbol = "books.vertical"
    } else {
      let source = filtered[indexPath.row]
      imageURL = source["icon"] as? String
      label = source["name"] as? String ?? "Source"
      subtitle = source["lang"] as? String ?? ""
      symbol = source["pinned"] as? Bool == true ? "pin.fill" : "books.vertical"
    }
    var content = cell.defaultContentConfiguration()
    content.text = label
    content.secondaryText = subtitle
    content.image = UIImage(systemName: symbol)
    content.imageProperties.tintColor = .secondaryLabel
    content.imageProperties.maximumSize = CGSize(width: 48, height: 48)
    content.textProperties.font = .preferredFont(forTextStyle: .body)
    content.secondaryTextProperties.color = .secondaryLabel
    cell.contentConfiguration = content
    cell.loadIcon(imageURL)
    cell.accessoryView = nil
    cell.accessoryType = .disclosureIndicator
    if segments.selectedSegmentIndex == 1 && indexPath.row < filteredExtensions.count,
       let id = filteredExtensions[indexPath.row]["id"] as? Int {
      let item = filteredExtensions[indexPath.row]
      let installed = item["installed"] as? Bool ?? false
      let action = UIButton(type: .system)
      action.accessibilityLabel = installed ? "Extension actions" : "Install extension"
      action.frame = CGRect(x: 0, y: 0, width: installed ? 44 : 76, height: 40)
      if !installed {
        var config = UIButton.Configuration.tinted()
        config.title = "Get"
        config.cornerStyle = .capsule
        action.configuration = config
        action.addAction(UIAction { [weak self] _ in
          self?.channel.invokeMethod("updateExtension", arguments: id)
        }, for: .touchUpInside)
      } else {
      action.setImage(UIImage(systemName: "ellipsis"), for: .normal)
      action.showsMenuAsPrimaryAction = true
      action.menu = UIMenu(children: [
        UIAction(title: installed ? "Settings" : "Install",
                 image: UIImage(systemName: installed ? "gearshape" : "arrow.down.circle")) {
          [weak self] _ in
          self?.channel.invokeMethod(installed ? "openExtension" : "updateExtension", arguments: id)
        },
        UIAction(title: "Install / Update", image: UIImage(systemName: "arrow.clockwise")) {
          [weak self] _ in self?.channel.invokeMethod("updateExtension", arguments: id)
        },
        UIAction(title: "Uninstall", image: UIImage(systemName: "trash"), attributes: installed ? [.destructive] : [.disabled]) {
          [weak self] _ in self?.confirmUninstall(id: id)
        }
      ])
      }
      cell.accessoryView = action
      cell.accessoryType = .none
    }
    return cell
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    selectItem(indexPath.row)
  }

  private func selectItem(_ index: Int) {
    if segments.selectedSegmentIndex == 1 {
      if index < filteredExtensions.count {
        let ext = filteredExtensions[index]
        guard let id = ext["id"] as? Int else { return }
        let installed = ext["installed"] as? Bool ?? false
        channel.invokeMethod(installed ? "openExtension" : "updateExtension", arguments: id)
      } else {
        let options = extensionActions.filter { text.isEmpty ||
          $0.0.localizedCaseInsensitiveContains(text) }
        channel.invokeMethod("action", arguments: options[index - filteredExtensions.count].2)
      }
      return
    }
    if index == filtered.count {
      channel.invokeMethod("action", arguments: "local")
      return
    }
    guard filtered.indices.contains(index) else { return }
    if let id = filtered[index]["id"] as? Int {
      channel.invokeMethod("openSource", arguments: id)
    }
  }
  private func menuForGridItem(_ index: Int) -> UIMenu? {
    if segments.selectedSegmentIndex == 0 {
      guard filtered.indices.contains(index),
        let id = filtered[index]["id"] as? Int else { return nil }
      let pinned = filtered[index]["pinned"] as? Bool ?? false
      return UIMenu(children: [
        UIAction(title: pinned ? "Unpin" : "Pin",
                 image: UIImage(systemName: pinned ? "pin.slash" : "pin")) {
          [weak self] _ in self?.channel.invokeMethod("pin", arguments: id)
        }
      ])
    }
    guard filteredExtensions.indices.contains(index),
      let id = filteredExtensions[index]["id"] as? Int else { return nil }
    let installed = filteredExtensions[index]["installed"] as? Bool ?? false
    return UIMenu(children: [
      UIAction(title: installed ? "Settings" : "Install",
               image: UIImage(systemName: installed ? "gearshape" : "arrow.down.circle")) {
        [weak self] _ in
        self?.channel.invokeMethod(installed ? "openExtension" : "updateExtension", arguments: id)
      },
      UIAction(title: "Install / Update", image: UIImage(systemName: "arrow.clockwise")) {
        [weak self] _ in self?.channel.invokeMethod("updateExtension", arguments: id)
      },
      UIAction(title: "Uninstall", image: UIImage(systemName: "trash"),
               attributes: installed ? [.destructive] : [.disabled]) {
        [weak self] _ in self?.confirmUninstall(id: id)
      }
    ])
  }

  private func confirmUninstall(id: Int) {
    let alert = UIAlertController(title: "Uninstall extension?",
      message: "This removes its executable source. Your novels remain in the Library.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Uninstall", style: .destructive) { [weak self] _ in
      self?.channel.invokeMethod("uninstallExtension", arguments: id)
    })
    guard var host = root.window?.rootViewController else { return }
    while let next = host.presentedViewController { host = next }
    host.present(alert, animated: true)
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


/// Reuse-safe remote source artwork, using the same request/cache strategy as
/// the library covers. Source icons are actual artwork instead of SF placeholders.
private final class NovayomiSourceRowCell: UITableViewCell {
  private static let images = NSCache<NSString, UIImage>()
  private var imageRequest: URLSessionDataTask?
  private var representedIcon: String?

  override func prepareForReuse() {
    super.prepareForReuse()
    imageRequest?.cancel()
    imageRequest = nil
    representedIcon = nil
    accessoryView = nil
  }

  func loadIcon(_ path: String?) {
    imageRequest?.cancel()
    imageRequest = nil
    representedIcon = path
    guard let path, let url = URL(string: path),
          ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
    if let image = Self.images.object(forKey: path as NSString) {
      updateIcon(image)
      return
    }
    imageRequest = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let data, let image = UIImage(data: data) else { return }
      Self.images.setObject(image, forKey: path as NSString)
      DispatchQueue.main.async {
        guard let self, self.representedIcon == path else { return }
        self.updateIcon(image)
      }
    }
    imageRequest?.resume()
  }

  private func updateIcon(_ image: UIImage) {
    guard var configuration = contentConfiguration as? UIListContentConfiguration else { return }
    configuration.image = image
    configuration.imageProperties.maximumSize = CGSize(width: 48, height: 48)
    configuration.imageProperties.cornerRadius = 11
    contentConfiguration = configuration
  }
}
