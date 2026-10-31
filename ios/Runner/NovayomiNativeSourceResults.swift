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
    UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate,
    UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
  private let root: UIView
  private let channel: FlutterMethodChannel
  private let nav = UINavigationBar()
  private let navItem = UINavigationItem(title: "Novels")
  private let search = UISearchBar()
  private let segmented = UISegmentedControl(items: ["Home", "Ranking"])
  private let largeTitle = UILabel()
  private let homeHeader = UIView()
  private let trendingLabel = UILabel()
  private let latestLabel = UILabel()
  private let featuredCollection: UICollectionView
  private var searchHeight: NSLayoutConstraint!
  private let table = UITableView(frame: .zero, style: .plain)
  private let grid = NovayomiPosterGrid(style: .novels)
  private var layoutItem: UIBarButtonItem?
  private var showGrid = UserDefaults.standard.bool(forKey: "novayomi.results.grid")
  private let refresh = UIRefreshControl()
  private var novels: [[String: Any]] = []
  private var featured: [[String: Any]] = []
  private var featuredCount = 0
  private var homeMode = false
  private var hasMore = false
  private var busy = false
  private var selected = 0
  private var query = ""
  private var globalMode = false
  private static let coverCache = NSCache<NSString, UIImage>()

  init(frame: CGRect, id: Int64, messenger: FlutterBinaryMessenger,
       data: [String: Any]) {
    root = UIView(frame: frame)
    let featuredLayout = UICollectionViewFlowLayout()
    featuredLayout.scrollDirection = .horizontal
    featuredLayout.minimumLineSpacing = 14
    featuredLayout.itemSize = CGSize(width: 130, height: 226)
    featuredCollection = UICollectionView(frame: .zero, collectionViewLayout: featuredLayout)
    channel = FlutterMethodChannel(name: "novayomi/native-source-results/\(id)",
                                   binaryMessenger: messenger)
    super.init()
    root.backgroundColor = .systemBackground
    root.tintColor = .novayomiAccent
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
    let menuItem = navItem.rightBarButtonItem
    let searchItem = UIBarButtonItem(
      image: UIImage(systemName: "magnifyingglass"),
      primaryAction: UIAction { [weak self] _ in self?.revealSearch() })
    layoutItem = UIBarButtonItem(
      image: UIImage(systemName: "square.grid.2x2"),
      primaryAction: UIAction { [weak self] _ in self?.toggleLayout() })
    navItem.rightBarButtonItems = [menuItem, searchItem].compactMap { $0 }
    nav.setItems([navItem], animated: false)
    root.addSubview(nav)

    largeTitle.text = data["title"] as? String ?? "Source"
    largeTitle.font = .preferredFont(forTextStyle: .largeTitle)
    largeTitle.adjustsFontForContentSizeCategory = true
    largeTitle.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(largeTitle)

    search.placeholder = "Search novels in source"
    search.searchBarStyle = .minimal
    search.delegate = self
    search.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(search)
    segmented.selectedSegmentIndex = 0
    segmented.selectedSegmentTintColor = .novayomiAccent
    segmented.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
    segmented.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(segmented)

    table.backgroundColor = .clear
    table.rowHeight = 112
    table.separatorInset = UIEdgeInsets(top: 0, left: 22, bottom: 0, right: 16)
    table.sectionHeaderTopPadding = 0
    table.dataSource = self
    table.delegate = self
    table.keyboardDismissMode = .onDrag
    table.translatesAutoresizingMaskIntoConstraints = false
    refresh.addTarget(self, action: #selector(refreshRequested), for: .valueChanged)
    table.refreshControl = refresh
    table.contentInset.bottom = 96
    table.verticalScrollIndicatorInsets.bottom = 96
    root.addSubview(table)
    configureHomeHeader(frame: frame)
    grid.translatesAutoresizingMaskIntoConstraints = false
    grid.onSelect = { [weak self] i in self?.selectItem(i) }
    grid.onRefresh = { [weak self] in self?.send("refresh") }
    root.addSubview(grid)
    let floatingTabs = NovayomiDetailTabOverlay(selected: 1) {
      [weak self] target in self?.send("tab", target)
    }
    floatingTabs.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(floatingTabs)
    NSLayoutConstraint.activate([
      nav.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
      nav.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      nav.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      largeTitle.topAnchor.constraint(equalTo: nav.bottomAnchor, constant: 8),
      largeTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
      largeTitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
      segmented.topAnchor.constraint(equalTo: largeTitle.bottomAnchor, constant: 14),
      segmented.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
      segmented.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      search.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 4),
      search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
      search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
      table.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 4),
      table.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      table.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      table.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      grid.topAnchor.constraint(equalTo: table.topAnchor),
      grid.leadingAnchor.constraint(equalTo: table.leadingAnchor),
      grid.trailingAnchor.constraint(equalTo: table.trailingAnchor),
      grid.bottomAnchor.constraint(equalTo: table.bottomAnchor),
      floatingTabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
      floatingTabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
      floatingTabs.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor, constant: -5),
      floatingTabs.heightAnchor.constraint(equalToConstant: 58)
    ])
    searchHeight = search.heightAnchor.constraint(equalToConstant: 0)
    searchHeight.isActive = true
    updateLayout()
    globalMode = data["globalMode"] as? Bool ?? false
    if globalMode {
      search.placeholder = "Search all novel sources"
      search.text = data["query"] as? String ?? ""
      segmented.isHidden = true
      largeTitle.text = "Search"
      navItem.rightBarButtonItems = [layoutItem].compactMap { $0 }
      searchHeight.constant = 52
    }
    apply(data)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      if call.method == "update", let data = call.arguments as? [String: Any] {
        self.apply(data)
        self.refresh.endRefreshing()
        self.grid.finishRefresh()
        result(nil)
      } else if call.method == "error" {
        self.busy = false
        self.refresh.endRefreshing()
        self.grid.finishRefresh()
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
    navItem.title = ""
    if !globalMode { largeTitle.text = data["title"] as? String ?? "Novels" }
    if globalMode {
      let text = data["emptyMessage"] as? String
      if novels.isEmpty, let text { search.accessibilityHint = text }
    }
    novels = data["items"] as? [[String: Any]] ?? []
    featured = data["featured"] as? [[String: Any]] ?? []
    featuredCount = min(novels.count, data["featuredCount"] as? Int ?? 0)
    homeMode = !globalMode && (data["homeMode"] as? Bool ?? false)
    featuredCollection.reloadData()
    // Reassigning tableHeaderView on every Dart snapshot resets scroll position.
    // Only swap headers when the actual presentation mode changes.
    if homeMode {
      if table.tableHeaderView !== homeHeader {
        table.tableHeaderView = homeHeader
      }
    } else if table.tableHeaderView != nil {
      table.tableHeaderView = nil
    }
    table.rowHeight = homeMode ? 122 : 78
    segmented.selectedSegmentIndex = homeMode ? 0 : 1
    hasMore = data["hasMore"] as? Bool ?? false
    busy = data["loading"] as? Bool ?? false
    table.reloadData()
    updateLayout()
    let posters = novels + (hasMore ? [[
      "title": busy ? "Loading more…" : "Load more",
      "description": "Load the next page of results"
    ]] : [])
    grid.display(posters)
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
  @objc private func toggleLayout() {
    showGrid.toggle()
    UserDefaults.standard.set(showGrid, forKey: "novayomi.results.grid")
    updateLayout()
  }
  private func updateLayout() {
    table.isHidden = !homeMode && showGrid
    grid.isHidden = homeMode || !showGrid
    layoutItem?.isEnabled = !homeMode
    layoutItem?.image = UIImage(systemName: showGrid ? "list.bullet" : "square.grid.2x2")
    layoutItem?.accessibilityLabel = showGrid ? "Show list" : "Show grid"
  }
  @objc private func segmentChanged() {
    selected = segmented.selectedSegmentIndex
    search.text = ""
    query = ""
    searchHeight.constant = 0
    search.resignFirstResponder()
    send("mode", selected == 0 ? 2 : 0)
  }
  @objc private func refreshRequested() { send("refresh") }
  private func revealSearch() {
    searchHeight.constant = 52
    root.layoutIfNeeded()
    search.becomeFirstResponder()
  }
  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    query = searchText
  }
  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
    send("search", query)
  }
  private func configureHomeHeader(frame: CGRect) {
    homeHeader.frame = CGRect(x: 0, y: 0, width: frame.width, height: 310)
    homeHeader.backgroundColor = .systemBackground
    trendingLabel.text = "Trending Novels"
    trendingLabel.font = .preferredFont(forTextStyle: .title3)
    trendingLabel.font = .systemFont(ofSize: 21, weight: .semibold)
    latestLabel.text = "Latest Updates"
    latestLabel.font = .systemFont(ofSize: 21, weight: .semibold)
    featuredCollection.dataSource = self
    featuredCollection.delegate = self
    featuredCollection.backgroundColor = .clear
    featuredCollection.showsHorizontalScrollIndicator = false
    featuredCollection.register(NovayomiFeaturedNovelCell.self,
      forCellWithReuseIdentifier: "featured")
    for label in [trendingLabel, latestLabel] {
      label.translatesAutoresizingMaskIntoConstraints = false
      homeHeader.addSubview(label)
    }
    featuredCollection.translatesAutoresizingMaskIntoConstraints = false
    homeHeader.addSubview(featuredCollection)
    NSLayoutConstraint.activate([
      trendingLabel.leadingAnchor.constraint(equalTo: homeHeader.leadingAnchor, constant: 22),
      trendingLabel.trailingAnchor.constraint(equalTo: homeHeader.trailingAnchor, constant: -14),
      trendingLabel.topAnchor.constraint(equalTo: homeHeader.topAnchor, constant: 8),
      featuredCollection.topAnchor.constraint(equalTo: trendingLabel.bottomAnchor, constant: 12),
      featuredCollection.leadingAnchor.constraint(equalTo: homeHeader.leadingAnchor, constant: 12),
      featuredCollection.trailingAnchor.constraint(equalTo: homeHeader.trailingAnchor),
      featuredCollection.heightAnchor.constraint(equalToConstant: 226),
      latestLabel.topAnchor.constraint(equalTo: featuredCollection.bottomAnchor, constant: 12),
      latestLabel.leadingAnchor.constraint(equalTo: homeHeader.leadingAnchor, constant: 22),
      latestLabel.trailingAnchor.constraint(equalTo: homeHeader.trailingAnchor, constant: -14)
    ])
  }

  func collectionView(_ collectionView: UICollectionView,
      numberOfItemsInSection section: Int) -> Int { featured.count }
  func collectionView(_ collectionView: UICollectionView,
      cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(
      withReuseIdentifier: "featured", for: indexPath) as! NovayomiFeaturedNovelCell
    cell.configure(featured[indexPath.item])
    return cell
  }
  func collectionView(_ collectionView: UICollectionView,
      didSelectItemAt indexPath: IndexPath) {
    guard featured.indices.contains(indexPath.item) else { return }
    send("open", indexPath.item)
  }

  func numberOfSections(in tableView: UITableView) -> Int { 1 }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    (novels.count - (homeMode ? featuredCount : 0)) + (hasMore ? 1 : 0)
  }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "novel")
      ?? UITableViewCell(style: .subtitle, reuseIdentifier: "novel")
    var config = cell.defaultContentConfiguration()
    // Reused cells may still have an image request in flight.
    cell.accessibilityIdentifier = nil
    let novelIndex = indexPath.row + (homeMode ? featuredCount : 0)
    if novelIndex == novels.count {
      config.text = busy ? "Loading more…" : "Load more"
      config.image = UIImage(systemName: "arrow.down.circle")
      cell.accessoryType = .none
    } else {
      let item = novels[novelIndex]
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
    selectItem(indexPath.row + (homeMode ? featuredCount : 0))
  }
  private func selectItem(_ index: Int) {
    if index == novels.count {
      guard hasMore && !busy else { return }
      busy = true
      send("loadMore")
    } else if novels.indices.contains(index) {
      send("open", index)
    }
  }
}


/// Native horizontal cover cards used on a source's home page.
private final class NovayomiFeaturedNovelCell: UICollectionViewCell {
  private static let images = NSCache<NSString, UIImage>()
  private let cover = UIImageView()
  private let title = UILabel()
  private var task: URLSessionDataTask?
  private var imageKey = ""

  override init(frame: CGRect) {
    super.init(frame: frame)
    cover.layer.cornerRadius = 9
    cover.clipsToBounds = true
    cover.contentMode = .scaleAspectFill
    cover.backgroundColor = .tertiarySystemFill
    title.font = .preferredFont(forTextStyle: .subheadline)
    title.numberOfLines = 2
    title.textColor = .label
    cover.translatesAutoresizingMaskIntoConstraints = false
    title.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(cover)
    contentView.addSubview(title)
    NSLayoutConstraint.activate([
      cover.topAnchor.constraint(equalTo: contentView.topAnchor),
      cover.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      cover.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      cover.heightAnchor.constraint(equalToConstant: 183),
      title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 3),
      title.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -3),
      title.topAnchor.constraint(equalTo: cover.bottomAnchor, constant: 6)
    ])
  }
  required init?(coder: NSCoder) { fatalError("Storyboard unsupported") }
  override func prepareForReuse() {
    super.prepareForReuse()
    task?.cancel()
    task = nil
    imageKey = ""
    cover.image = nil
    title.text = nil
  }
  func configure(_ item: [String: Any]) {
    title.text = item["title"] as? String ?? "Novel"
    cover.image = UIImage(systemName: "book.closed")
    guard let imageURL = item["cover"] as? String,
          let url = URL(string: imageURL),
          ["http", "https"].contains(url.scheme?.lowercased() ?? "")
      else { return }
    imageKey = imageURL
    if let cached = Self.images.object(forKey: imageURL as NSString) {
      cover.image = cached
      return
    }
    var request = URLRequest(url: url,
      cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
    for (name, value) in item["headers"] as? [String: String] ?? [:] {
      request.setValue(value, forHTTPHeaderField: name)
    }
    task = URLSession.shared.dataTask(with: request) { [weak self] bytes, _, _ in
      guard let bytes, let img = UIImage(data: bytes) else { return }
      Self.images.setObject(img, forKey: imageURL as NSString)
      DispatchQueue.main.async {
        guard let self, self.imageKey == imageURL else { return }
        self.cover.image = img
      }
    }
    task?.resume()
  }
}
