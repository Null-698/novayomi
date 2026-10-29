import Flutter
import UIKit

/// Phase 2.1: a UIKit-only Novel Library surface.
///
/// The Dart/Isar source of truth stays untouched: it sends snapshots of
/// existing library data and receives explicit user actions. No scraping,
/// duplicate persistence, or replacement extension engine.
final class NovayomiLibraryViewFactory: NSObject, FlutterPlatformViewFactory {
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
    NovayomiLibraryView(frame: frame, identifier: viewId,
                       messenger: messenger, data: args as? [String: Any] ?? [:])
  }
}

private final class NovayomiLibraryView: NSObject, FlutterPlatformView,
    UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UISearchBarDelegate {
  private let root: UIView
  private let channel: FlutterMethodChannel
  private let heading = UILabel()
  private let total = UILabel()
  private let search = UISearchBar()
  private let categoryScroll = UIScrollView()
  private let categoryStack = UIStackView()
  private let sortButton = UIButton(type: .system)
  private let layoutButton = UIButton(type: .system)
  private let refresh = UIRefreshControl()
  private let collection: UICollectionView
  private var entries: [[String: Any]] = []
  private var displayed: [[String: Any]] = []
  private var categoryItems: [[String: Any]] = []
  private var selectedCategory: Int? = nil
  private var onlyUncategorized = false
  private var query = ""
  private var isList = false
  private var sortIndex = 0

  init(frame: CGRect, identifier: Int64, messenger: FlutterBinaryMessenger,
       data: [String: Any]) {
    root = UIView(frame: frame)
    channel = FlutterMethodChannel(name: "novayomi/native-library/\(identifier)",
                                    binaryMessenger: messenger)
    let flow = UICollectionViewFlowLayout()
    flow.minimumInteritemSpacing = 10
    flow.minimumLineSpacing = 16
    collection = UICollectionView(frame: .zero, collectionViewLayout: flow)
    super.init()

    root.backgroundColor = .systemBackground
    heading.text = "Library"
    heading.font = .preferredFont(forTextStyle: .largeTitle)
    heading.adjustsFontForContentSizeCategory = true
    total.font = .preferredFont(forTextStyle: .footnote)
    total.textColor = .secondaryLabel

    sortButton.setImage(UIImage(systemName: "line.3.horizontal.decrease"), for: .normal)
    sortButton.accessibilityLabel = "Sort library"
    sortButton.showsMenuAsPrimaryAction = true
    layoutButton.setImage(UIImage(systemName: "square.grid.2x2"), for: .normal)
    layoutButton.accessibilityLabel = "Change layout"
    layoutButton.addTarget(self, action: #selector(toggleLayout), for: .touchUpInside)

    let labels = UIStackView(arrangedSubviews: [heading, total])
    labels.axis = .vertical
    labels.alignment = .leading
    labels.spacing = 1
    let header = UIStackView(arrangedSubviews: [
      labels, UIView(), sortButton, layoutButton
    ])
    header.axis = .horizontal
    header.alignment = .center
    header.spacing = 12
    header.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(header)
    NSLayoutConstraint.activate([
      sortButton.widthAnchor.constraint(equalToConstant: 44),
      sortButton.heightAnchor.constraint(equalToConstant: 44),
      layoutButton.widthAnchor.constraint(equalToConstant: 44),
      layoutButton.heightAnchor.constraint(equalToConstant: 44)
    ])

    search.placeholder = "Search novels"
    search.searchBarStyle = .minimal
    search.delegate = self
    search.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(search)

    categoryStack.axis = .horizontal
    categoryStack.spacing = 8
    categoryStack.alignment = .center
    categoryStack.translatesAutoresizingMaskIntoConstraints = false
    categoryScroll.showsHorizontalScrollIndicator = false
    categoryScroll.translatesAutoresizingMaskIntoConstraints = false
    categoryScroll.addSubview(categoryStack)
    root.addSubview(categoryScroll)

    collection.backgroundColor = .clear
    collection.alwaysBounceVertical = true
    collection.keyboardDismissMode = .onDrag
    collection.dataSource = self
    collection.delegate = self
    collection.register(NovayomiLibraryCell.self, forCellWithReuseIdentifier: "novel")
    collection.translatesAutoresizingMaskIntoConstraints = false
    refresh.addTarget(self, action: #selector(refreshLibrary), for: .valueChanged)
    collection.refreshControl = refresh
    root.addSubview(collection)

    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
      header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
      header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
      header.heightAnchor.constraint(equalToConstant: 62),
      search.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
      search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
      search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
      search.heightAnchor.constraint(equalToConstant: 52),
      categoryScroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 4),
      categoryScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      categoryScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      categoryScroll.heightAnchor.constraint(equalToConstant: 42),
      categoryStack.leadingAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.leadingAnchor, constant: 18),
      categoryStack.trailingAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.trailingAnchor, constant: -18),
      categoryStack.topAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.topAnchor),
      categoryStack.bottomAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.bottomAnchor),
      categoryStack.heightAnchor.constraint(equalTo: categoryScroll.frameLayoutGuide.heightAnchor),
      collection.topAnchor.constraint(equalTo: categoryScroll.bottomAnchor, constant: 4),
      collection.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      collection.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      collection.bottomAnchor.constraint(equalTo: root.bottomAnchor)
    ])

    apply(data)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      if call.method == "update", let content = call.arguments as? [String: Any] {
        self.apply(content)
        result(nil)
      } else if call.method == "refreshComplete" {
        self.refresh.endRefreshing()
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit { channel.setMethodCallHandler(nil) }

  func view() -> UIView { root }

  private func apply(_ data: [String: Any]) {
    if let list = data["items"] as? [[String: Any]] { entries = list }
    if let list = data["categories"] as? [[String: Any]] {
      categoryItems = list
    }
    if let label = data["title"] as? String { heading.text = label }
    if let index = data["sortIndex"] as? Int { sortIndex = index }
    if let list = data["isList"] as? Bool {
      isList = list
      layoutButton.setImage(UIImage(systemName: isList ? "square.grid.2x2" : "list.bullet"),
                            for: .normal)
    }
    updateSortMenu()
    rebuildCategories()
    filterAndReload()
  }

  private func updateSortMenu() {
    let labels = [
      (0, "Title"), (1, "Last read"), (2, "Last updated"),
      (3, "Unread chapters"), (4, "Total chapters"), (5, "Last chapter"),
      (6, "Date added")
    ]
    sortButton.menu = UIMenu(children: labels.map { key, title in
      UIAction(title: title, state: key == sortIndex ? .on : .off) { [weak self] _ in
        self?.channel.invokeMethod("sort", arguments: key)
      }
    })
  }

  private func rebuildCategories() {
    categoryStack.arrangedSubviews.forEach {
      categoryStack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    var categories: [(String, Int?)] = [("All", nil)]
    if entries.contains(where: { ($0["categories"] as? [Int] ?? []).isEmpty }) {
      categories.append(("Uncategorized", -1))
    }
    categories.append(contentsOf: categoryItems.compactMap { item in
      guard let id = item["id"] as? Int,
            let title = item["name"] as? String else { return nil }
      return (title, id)
    })
    for (index, option) in categories.enumerated() {
      let button = UIButton(type: .system)
      var configuration = UIButton.Configuration.tinted()
      configuration.cornerStyle = .capsule
      let selected = option.1 == -1
        ? onlyUncategorized
        : (option.1 == nil ? selectedCategory == nil && !onlyUncategorized
                            : selectedCategory == option.1 && !onlyUncategorized)
      configuration.title = option.0
      configuration.baseForegroundColor = selected ? .white : .label
      configuration.baseBackgroundColor = selected ? .systemBlue : .secondarySystemBackground
      button.configuration = configuration
      button.tag = index
      button.accessibilityIdentifier = "category-\(option.1 ?? 0)"
      button.addAction(UIAction { [weak self] _ in
        guard let self else { return }
        self.onlyUncategorized = option.1 == -1
        self.selectedCategory = option.1 == -1 ? nil : option.1
        self.rebuildCategories()
        self.filterAndReload()
      }, for: .touchUpInside)
      categoryStack.addArrangedSubview(button)
    }
  }

  private func filterAndReload() {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    displayed = entries.filter { item in
      let categories = item["categories"] as? [Int] ?? []
      if onlyUncategorized && !categories.isEmpty { return false }
      if let category = selectedCategory, !categories.contains(category) { return false }
      if !text.isEmpty {
        let name = item["name"] as? String ?? ""
        let author = item["author"] as? String ?? ""
        if !name.localizedCaseInsensitiveContains(text) &&
           !author.localizedCaseInsensitiveContains(text) { return false }
      }
      return true
    }
    total.text = "\(displayed.count) novels"
    collection.reloadData()
  }

  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    query = searchText
    filterAndReload()
  }

  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
  }

  @objc private func toggleLayout() {
    isList.toggle()
    layoutButton.setImage(UIImage(systemName: isList ? "square.grid.2x2" : "list.bullet"),
                          for: .normal)
    collection.collectionViewLayout.invalidateLayout()
    collection.reloadData()
    channel.invokeMethod("layout", arguments: isList)
  }

  @objc private func refreshLibrary() {
    channel.invokeMethod("refresh", arguments: nil)
  }

  func numberOfSections(in collectionView: UICollectionView) -> Int { 1 }

  func collectionView(_ collectionView: UICollectionView,
                      numberOfItemsInSection section: Int) -> Int { displayed.count }

  func collectionView(_ collectionView: UICollectionView,
                      cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "novel", for: indexPath)
      as! NovayomiLibraryCell
    cell.configure(item: displayed[indexPath.item], isList: isList)
    return cell
  }

  func collectionView(_ collectionView: UICollectionView,
                      didSelectItemAt indexPath: IndexPath) {
    guard displayed.indices.contains(indexPath.item),
          let id = displayed[indexPath.item]["id"] as? Int else { return }
    channel.invokeMethod("open", arguments: id)
  }

  func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                      sizeForItemAt indexPath: IndexPath) -> CGSize {
    let width = collectionView.bounds.inset(by: collectionView.adjustedContentInset).width
    if isList { return CGSize(width: max(1, width - 28), height: 92) }
    let columns: CGFloat = width > 700 ? 6 : width > 450 ? 4 : 3
    let itemWidth = max(65, floor((width - 36 - (columns - 1) * 10) / columns))
    return CGSize(width: itemWidth, height: itemWidth * 1.51 + 36)
  }

  func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                      insetForSectionAt section: Int) -> UIEdgeInsets {
    UIEdgeInsets(top: 10, left: 14, bottom: 28, right: 14)
  }

  func collectionView(_ collectionView: UICollectionView,
                      contextMenuConfigurationForItemAt indexPath: IndexPath,
                      point: CGPoint) -> UIContextMenuConfiguration? {
    guard displayed.indices.contains(indexPath.item),
          let id = displayed[indexPath.item]["id"] as? Int else { return nil }
    let name = displayed[indexPath.item]["name"] as? String ?? ""
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      UIMenu(children: [
        UIAction(title: "Open novel", image: UIImage(systemName: "book")) { _ in
          self?.channel.invokeMethod("open", arguments: id)
        },
        UIAction(title: "Copy title", image: UIImage(systemName: "doc.on.doc")) { _ in
          UIPasteboard.general.string = name
        }
      ])
    }
  }
}

private final class NovayomiLibraryCell: UICollectionViewCell {
  private static let images = NSCache<NSString, UIImage>()
  private let cover = UIImageView()
  private let title = UILabel()
  private let author = UILabel()
  private let stack = UIStackView()
  private let textStack = UIStackView()
  private var coverHeight: NSLayoutConstraint!
  private var coverWidth: NSLayoutConstraint!
  private var loadTask: URLSessionDataTask?
  private var represented = ""

  override init(frame: CGRect) {
    super.init(frame: frame)
    contentView.backgroundColor = .clear
    cover.contentMode = .scaleAspectFill
    cover.clipsToBounds = true
    cover.layer.cornerRadius = 8
    cover.backgroundColor = .secondarySystemGroupedBackground
    title.font = .preferredFont(forTextStyle: .caption1)
    title.numberOfLines = 2
    title.textColor = .label
    author.font = .preferredFont(forTextStyle: .caption2)
    author.numberOfLines = 1
    author.textColor = .secondaryLabel
    stack.axis = .vertical
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false
    textStack.axis = .vertical
    textStack.spacing = 2
    textStack.addArrangedSubview(title)
    textStack.addArrangedSubview(author)
    stack.addArrangedSubview(cover)
    stack.addArrangedSubview(textStack)
    contentView.addSubview(stack)
    coverHeight = cover.heightAnchor.constraint(equalToConstant: 170)
    coverWidth = cover.widthAnchor.constraint(equalToConstant: 60)
    coverHeight.isActive = true
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
      title.heightAnchor.constraint(greaterThanOrEqualToConstant: 15),
      author.heightAnchor.constraint(greaterThanOrEqualToConstant: 12)
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

  override func prepareForReuse() {
    super.prepareForReuse()
    loadTask?.cancel()
    loadTask = nil
    represented = ""
    cover.image = UIImage(systemName: "book.closed")
  }

  func configure(item: [String: Any], isList: Bool) {
    let id = item["id"] as? Int ?? -1
    represented = String(id)
    title.text = item["name"] as? String ?? "Untitled"
    author.text = item["author"] as? String ?? ""
    cover.image = UIImage(systemName: "book.closed")

    if isList {
      coverHeight.constant = 78
      coverWidth.isActive = true
      stack.axis = .horizontal
      stack.alignment = .center
    } else {
      coverWidth.isActive = false
      coverHeight.constant = max(80, bounds.width * 1.44)
      stack.axis = .vertical
      stack.alignment = .fill
    }
    if let bytes = (item["coverBytes"] as? FlutterStandardTypedData)?.data,
       let image = UIImage(data: bytes) {
      cover.image = image
      return
    }
    guard let urlText = item["cover"] as? String,
          let url = URL(string: urlText),
          ["http","https"].contains(url.scheme?.lowercased() ?? "") else { return }
    let key = urlText as NSString
    if let existing = Self.images.object(forKey: key) {
      cover.image = existing
      return
    }
    var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 18)
    for (name, value) in item["headers"] as? [String: String] ?? [:] {
      request.setValue(value, forHTTPHeaderField: name)
    }
    let token = represented
    loadTask = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
      guard let data, let image = UIImage(data: data) else { return }
      Self.images.setObject(image, forKey: key)
      DispatchQueue.main.async {
        guard let self, self.represented == token else { return }
        self.cover.image = image
      }
    }
    loadTask?.resume()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if stack.axis == .vertical {
      coverHeight.constant = max(80, bounds.width * 1.44)
    }
  }
}
