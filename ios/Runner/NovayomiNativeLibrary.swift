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
  private var categoryHeight: NSLayoutConstraint!
  private let categoryStack = UIStackView()
  private let sortButton = UIButton(type: .system)
  private let preferencesButton = UIButton(type: .system)
  private let layoutButton = UIButton(type: .system)
  private let refresh = UIRefreshControl()
  private let selectionBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
  private var selectionHeight: NSLayoutConstraint!
  private var collectionBottom: NSLayoutConstraint!
  private let selectedCount = UILabel()
  private var selectedIds = Set<Int>()
  private let collection: UICollectionView
  private let continueHeading = UILabel()
  private let continueCollection: UICollectionView
  private var continueHeadingHeight: NSLayoutConstraint!
  private var continueCollectionHeight: NSLayoutConstraint!
  private var continueItems: [[String: Any]] = []
  private var entries: [[String: Any]] = []
  private var displayed: [[String: Any]] = []
  private var visibleIds = Set<Int>()
  private var visibleOrder = [Int: Int]()
  private var categoryItems: [[String: Any]] = []
  private var selectedCategory: Int? = nil
  private var onlyUncategorized = false
  private var query = ""
  private var isList = false
  private var sortIndex = 0
  private var gridSize = 0
  private var configuration: [String: Any] = [:]

  init(frame: CGRect, identifier: Int64, messenger: FlutterBinaryMessenger,
       data: [String: Any]) {
    root = UIView(frame: frame)
    channel = FlutterMethodChannel(name: "novayomi/native-library/\(identifier)",
                                    binaryMessenger: messenger)
    let flow = UICollectionViewFlowLayout()
    flow.minimumInteritemSpacing = 10
    flow.minimumLineSpacing = 16
    collection = UICollectionView(frame: .zero, collectionViewLayout: flow)
    let continueFlow = UICollectionViewFlowLayout()
    continueFlow.scrollDirection = .horizontal
    continueFlow.minimumLineSpacing = 12
    continueFlow.minimumInteritemSpacing = 12
    continueCollection = UICollectionView(frame: .zero, collectionViewLayout: continueFlow)
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
    preferencesButton.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
    preferencesButton.accessibilityLabel = "Library filters and display settings"
    preferencesButton.addTarget(self, action: #selector(openPreferences), for: .touchUpInside)
    layoutButton.setImage(UIImage(systemName: "square.grid.2x2"), for: .normal)
    layoutButton.accessibilityLabel = "Change layout"
    layoutButton.addTarget(self, action: #selector(toggleLayout), for: .touchUpInside)

    let labels = UIStackView(arrangedSubviews: [heading, total])
    labels.axis = .vertical
    labels.alignment = .leading
    labels.spacing = 1
    let header = UIStackView(arrangedSubviews: [
      labels, UIView(), preferencesButton, sortButton, layoutButton
    ])
    header.axis = .horizontal
    header.alignment = .center
    header.spacing = 12
    header.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(header)
    NSLayoutConstraint.activate([
      preferencesButton.widthAnchor.constraint(equalToConstant: 44),
      preferencesButton.heightAnchor.constraint(equalToConstant: 44),
      sortButton.widthAnchor.constraint(equalToConstant: 44),
      sortButton.heightAnchor.constraint(equalToConstant: 44),
      layoutButton.widthAnchor.constraint(equalToConstant: 44),
      layoutButton.heightAnchor.constraint(equalToConstant: 44)
    ])

    search.placeholder = "Search novels"
    search.searchBarStyle = .minimal
    search.scopeButtonTitles = ["Filtered", "All"]
    search.selectedScopeButtonIndex = 0
    search.showsScopeBar = true
    search.delegate = self
    search.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(search)

    categoryStack.axis = .horizontal
    categoryStack.spacing = 8
    categoryStack.alignment = .center
    categoryStack.translatesAutoresizingMaskIntoConstraints = false
    categoryScroll.showsHorizontalScrollIndicator = false
    categoryHeight = categoryScroll.heightAnchor.constraint(equalToConstant: 42)
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

    continueHeading.text = "Continue Reading"
    continueHeading.font = .preferredFont(forTextStyle: .headline)
    continueHeading.textColor = .label
    continueHeading.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(continueHeading)
    continueCollection.backgroundColor = .clear
    continueCollection.showsHorizontalScrollIndicator = false
    continueCollection.dataSource = self
    continueCollection.delegate = self
    continueCollection.register(NovayomiLibraryCell.self,
                                forCellWithReuseIdentifier: "novel")
    continueCollection.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(continueCollection)
    continueHeadingHeight = continueHeading.heightAnchor.constraint(equalToConstant: 0)
    continueCollectionHeight = continueCollection.heightAnchor.constraint(equalToConstant: 0)
    if #available(iOS 26.0, *) {
      selectionBar.effect = UIGlassEffect(style: .regular)
      selectionBar.cornerConfiguration = .capsule()
    } else {
      selectionBar.layer.cornerRadius = 18
      selectionBar.clipsToBounds = true
    }
    selectionBar.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(selectionBar)
    selectedCount.font = .preferredFont(forTextStyle: .subheadline)
    selectedCount.text = "0 selected"
    selectedCount.textAlignment = .center
    let clear = nativeButton("xmark", hint: "Cancel selection", action: #selector(clearSelection))
    let mark = nativeButton("checkmark.circle", hint: "Mark novels as read", action: #selector(markSelectedRead))
    let unread = nativeButton("circle", hint: "Mark novels as unread", action: #selector(markSelectedUnread))
    let categories = nativeButton("tag", hint: "Set categories", action: #selector(selectCategories))
    let remove = nativeButton("trash", hint: "Remove from library", action: #selector(confirmRemove))
    let selections = UIStackView(arrangedSubviews: [clear, selectedCount, mark, unread, categories, remove])
    selections.axis = .horizontal
    selections.alignment = .center
    selections.distribution = .fillProportionally
    selections.spacing = 6
    selections.translatesAutoresizingMaskIntoConstraints = false
    selectionBar.contentView.addSubview(selections)
    selectionHeight = selectionBar.heightAnchor.constraint(equalToConstant: 54)
    collectionBottom = collection.bottomAnchor.constraint(
      equalTo: root.safeAreaLayoutGuide.bottomAnchor)
    NSLayoutConstraint.activate([
      selectionHeight,
      selectionBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
      selectionBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
      selectionBar.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor, constant: -6),
      selections.leadingAnchor.constraint(equalTo: selectionBar.contentView.leadingAnchor, constant: 10),
      selections.trailingAnchor.constraint(equalTo: selectionBar.contentView.trailingAnchor, constant: -10),
      selections.topAnchor.constraint(equalTo: selectionBar.contentView.topAnchor, constant: 4),
      selections.bottomAnchor.constraint(equalTo: selectionBar.contentView.bottomAnchor, constant: -4)
    ])
    selectionBar.isHidden = true

    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
      header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
      header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
      header.heightAnchor.constraint(equalToConstant: 62),
      search.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
      search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
      search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
      search.heightAnchor.constraint(equalToConstant: 76),
      categoryScroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 4),
      categoryScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      categoryScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      categoryHeight,
      categoryStack.leadingAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.leadingAnchor, constant: 18),
      categoryStack.trailingAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.trailingAnchor, constant: -18),
      categoryStack.topAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.topAnchor),
      categoryStack.bottomAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.bottomAnchor),
      categoryStack.heightAnchor.constraint(equalTo: categoryScroll.frameLayoutGuide.heightAnchor),
      continueHeading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
      continueHeading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
      continueHeading.topAnchor.constraint(equalTo: categoryScroll.bottomAnchor, constant: 4),
      continueHeadingHeight,
      continueCollection.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      continueCollection.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      continueCollection.topAnchor.constraint(equalTo: continueHeading.bottomAnchor, constant: 3),
      continueCollectionHeight,
      collection.topAnchor.constraint(equalTo: continueCollection.bottomAnchor, constant: 4),
      collection.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      collection.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      collectionBottom
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
    configuration = data
    if let list = data["items"] as? [[String: Any]] {
      entries = list
      let ids = Set(list.compactMap { $0["id"] as? Int })
      selectedIds.formIntersection(ids)
    }
    if let ids = data["visibleIds"] as? [Int] {
      visibleIds = Set(ids)
      visibleOrder = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
    }
    if let list = data["categories"] as? [[String: Any]] {
      categoryItems = list
    }
    let index = Dictionary(uniqueKeysWithValues:
      entries.compactMap { item -> (Int, [String: Any])? in
        guard let id = item["id"] as? Int else { return nil }
        return (id, item)
      })
    continueItems = (data["continueItems"] as? [[String: Any]] ?? []).compactMap { item in
      guard let id = item["id"] as? Int, var book = index[id] else { return nil }
      book["chapterId"] = item["chapterId"]
      book["author"] = item["chapterName"]
      book["progress"] = item["progress"]
      book["showContinue"] = false
      return book
    }
    let hasShelf = !continueItems.isEmpty
    continueHeadingHeight.constant = hasShelf ? 30 : 0
    continueCollectionHeight.constant = hasShelf ? 198 : 0
    continueHeading.isHidden = !hasShelf
    continueCollection.isHidden = !hasShelf
    continueCollection.reloadData()
    if let label = data["title"] as? String { heading.text = label }
    if let index = data["sortIndex"] as? Int { sortIndex = index }
    if let size = data["gridSize"] as? Int { gridSize = size }
    collection.collectionViewLayout.invalidateLayout()
    if let list = data["isList"] as? Bool {
      isList = list
      layoutButton.setImage(UIImage(systemName: isList ? "square.grid.2x2" : "list.bullet"),
                            for: .normal)
    }
    let appearance = data["displaySettings"] as? [String: Bool] ?? [:]
    categoryScroll.isHidden = !(appearance["showCategories"] ?? true)
    categoryHeight.constant = categoryScroll.isHidden ? 0 : 42
    updateSortMenu()
    rebuildCategories()
    updateSelectionBar()
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
    if categoryScroll.isHidden { return }
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
    let ignoreFilters = !text.isEmpty && search.selectedScopeButtonIndex == 1
    let tokens = text.lowercased().split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    displayed = entries.filter { item in
      guard let id = item["id"] as? Int else { return false }
      if !ignoreFilters && !visibleIds.contains(id) { return false }
      let categories = item["categories"] as? [Int] ?? []
      if onlyUncategorized && !categories.isEmpty { return false }
      if let category = selectedCategory, !categories.contains(category) { return false }
      if !tokens.isEmpty {
        let name = (item["name"] as? String ?? "").lowercased()
        let author = (item["author"] as? String ?? "").lowercased()
        let source = (item["source"] as? String ?? "").lowercased()
        let genres = (item["genre"] as? [String] ?? []).map { $0.lowercased() }
        if !tokens.contains(where: { token in
          name.contains(token) || source.contains(token) ||
          author.contains(token) || genres.contains(where: { $0.contains(token) })
        }) { return false }
      }
      return true
    }
    displayed.sort { lhs, rhs in
      let a = lhs["id"] as? Int ?? -1
      let b = rhs["id"] as? Int ?? -1
      let ar = visibleOrder[a] ?? Int.max
      let br = visibleOrder[b] ?? Int.max
      if ar != br { return ar < br }
      return (lhs["name"] as? String ?? "").localizedCompare(
        rhs["name"] as? String ?? "") == .orderedAscending
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

  func searchBar(_ searchBar: UISearchBar, selectedScopeButtonIndexDidChange selectedScope: Int) {
    filterAndReload()
  }

  @objc private func openPreferences() {
    let controller = NovayomiLibraryPreferencesSheet(data: configuration) { [weak self] method, argument in
      self?.channel.invokeMethod(method, arguments: argument)
    }
    let navigation = UINavigationController(rootViewController: controller)
    navigation.modalPresentationStyle = .pageSheet
    if let sheet = navigation.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    guard var presenting = root.window?.rootViewController else { return }
    while let next = presenting.presentedViewController { presenting = next }
    presenting.present(navigation, animated: true)
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
                      numberOfItemsInSection section: Int) -> Int {
    collectionView === continueCollection ? continueItems.count : displayed.count
  }

  func collectionView(_ collectionView: UICollectionView,
                      cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "novel", for: indexPath)
      as! NovayomiLibraryCell
    let isContinue = collectionView === continueCollection
    let item = isContinue ? continueItems[indexPath.item] : displayed[indexPath.item]
    cell.configure(item: item, isList: !isContinue && isList,
                   selected: !isContinue && selectedIds.contains(item["id"] as? Int ?? -1))
    cell.onResume = { [weak self] in
      guard let id = item["id"] as? Int else { return }
      self?.channel.invokeMethod("resume", arguments: id)
    }
    return cell
  }

  func collectionView(_ collectionView: UICollectionView,
                      didSelectItemAt indexPath: IndexPath) {
    if collectionView === continueCollection {
      guard continueItems.indices.contains(indexPath.item),
            let chapterId = continueItems[indexPath.item]["chapterId"] as? Int else { return }
      channel.invokeMethod("resumeChapter", arguments: chapterId)
      return
    }
    guard displayed.indices.contains(indexPath.item),
          let id = displayed[indexPath.item]["id"] as? Int else { return }
    if !selectedIds.isEmpty {
      toggleSelection(id)
    } else {
      channel.invokeMethod("open", arguments: id)
    }
  }

  private func nativeButton(_ name: String, hint: String, action: Selector) -> UIButton {
    let button = UIButton(type: .system)
    button.setImage(UIImage(systemName: name), for: .normal)
    button.tintColor = .label
    button.accessibilityLabel = hint
    button.addTarget(self, action: action, for: .touchUpInside)
    button.widthAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
    return button
  }

  private func toggleSelection(_ id: Int) {
    if !selectedIds.insert(id).inserted { selectedIds.remove(id) }
    updateSelectionBar()
    collection.reloadData()
  }

  private func updateSelectionBar() {
    selectedCount.text = "\(selectedIds.count) selected"
    let active = !selectedIds.isEmpty
    collectionBottom.constant = active ? -68 : 0
    selectionBar.isHidden = !active
    root.layoutIfNeeded()
  }

  @objc private func clearSelection() {
    selectedIds.removeAll()
    updateSelectionBar()
    collection.reloadData()
  }

  @objc private func markSelectedRead() { performBatch("markRead") }
  @objc private func markSelectedUnread() { performBatch("markUnread") }

  private func performBatch(_ kind: String) {
    guard !selectedIds.isEmpty else { return }
    channel.invokeMethod("batch", arguments: [
      "kind": kind,
      "ids": Array(selectedIds)
    ] as [String: Any])
    clearSelection()
  }

  @objc private func selectCategories() {
    guard !selectedIds.isEmpty else { return }
    let categories = configuration["categories"] as? [[String: Any]] ?? []
    let picker = NovayomiLibraryCategorySheet(categories: categories) { [weak self] ids in
      self?.channel.invokeMethod("batch", arguments: [
        "kind": "setCategories",
        "ids": Array(self?.selectedIds ?? []),
        "categories": ids
      ] as [String: Any])
      self?.clearSelection()
    }
    presentSheet(picker)
  }

  @objc private func confirmRemove() {
    guard !selectedIds.isEmpty else { return }
    let count = selectedIds.count
    let sheet = UIAlertController(
      title: "Remove \(count) novel\(count == 1 ? "" : "s") from Library?",
      message: "Only the library entries will be removed. Downloaded files will be kept.",
      preferredStyle: .alert)
    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    sheet.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
      self?.performBatch("removeFromLibrary")
    })
    presentNative(sheet)
  }

  private func presentNative(_ child: UIViewController) {
    guard var presenter = root.window?.rootViewController else { return }
    while let next = presenter.presentedViewController { presenter = next }
    presenter.present(child, animated: true)
  }

  private func presentSheet(_ child: UIViewController) {
    let nav = UINavigationController(rootViewController: child)
    nav.modalPresentationStyle = .pageSheet
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    presentNative(nav)
  }

  func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                      sizeForItemAt indexPath: IndexPath) -> CGSize {
    if collectionView === continueCollection {
      return CGSize(width: 110, height: 192)
    }
    let width = collectionView.bounds.inset(by: collectionView.adjustedContentInset).width
    if isList { return CGSize(width: max(1, width - 28), height: 92) }
    let columns: CGFloat = gridSize > 0
      ? CGFloat(min(max(gridSize, 1), 7))
      : (width > 700 ? 6 : width > 450 ? 4 : 3)
    let itemWidth = max(65, floor((width - 36 - (columns - 1) * 10) / columns))
    return CGSize(width: itemWidth, height: itemWidth * 1.51 + 36)
  }

  func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                      insetForSectionAt section: Int) -> UIEdgeInsets {
    collectionView === continueCollection
      ? UIEdgeInsets(top: 2, left: 18, bottom: 2, right: 18)
      : UIEdgeInsets(top: 10, left: 14, bottom: 28, right: 14)
  }

  func collectionView(_ collectionView: UICollectionView,
                      contextMenuConfigurationForItemAt indexPath: IndexPath,
                      point: CGPoint) -> UIContextMenuConfiguration? {
    if collectionView === continueCollection { return nil }
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
        },
        UIAction(title: "Select", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
          self?.toggleSelection(id)
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
  private let badge = UILabel()
  private let resume = UIButton(type: .system)
  var onResume: (() -> Void)?
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
    // Buttons overlaid on UIImageView only receive touches when enabled.
    cover.isUserInteractionEnabled = true
    cover.clipsToBounds = true
    cover.layer.cornerRadius = 8
    cover.backgroundColor = .secondarySystemGroupedBackground
    badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    badge.textColor = .label
    badge.backgroundColor = .secondarySystemBackground
    badge.layer.cornerRadius = 7
    badge.clipsToBounds = true
    badge.textAlignment = .center
    badge.translatesAutoresizingMaskIntoConstraints = false
    cover.addSubview(badge)
    resume.setImage(UIImage(systemName: "play.fill"), for: .normal)
    resume.tintColor = .white
    resume.backgroundColor = .systemBlue
    resume.layer.cornerRadius = 17
    resume.accessibilityLabel = "Continue reading"
    resume.translatesAutoresizingMaskIntoConstraints = false
    resume.addTarget(self, action: #selector(resumeTapped), for: .touchUpInside)
    cover.addSubview(resume)
    NSLayoutConstraint.activate([
      badge.leadingAnchor.constraint(equalTo: cover.leadingAnchor, constant: 5),
      badge.topAnchor.constraint(equalTo: cover.topAnchor, constant: 5),
      badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 32),
      badge.heightAnchor.constraint(equalToConstant: 24),
      resume.trailingAnchor.constraint(equalTo: cover.trailingAnchor, constant: -5),
      resume.bottomAnchor.constraint(equalTo: cover.bottomAnchor, constant: -5),
      resume.widthAnchor.constraint(equalToConstant: 34),
      resume.heightAnchor.constraint(equalToConstant: 34)
    ])
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
    onResume = nil
    badge.isHidden = true
    resume.isHidden = true
    cover.image = UIImage(systemName: "book.closed")
  }

  func configure(item: [String: Any], isList: Bool, selected: Bool) {
    let id = item["id"] as? Int ?? -1
    represented = String(id)
    contentView.layer.borderWidth = selected ? 2 : 0
    contentView.layer.borderColor = UIColor.systemBlue.cgColor
    contentView.layer.cornerRadius = 9
    title.text = item["name"] as? String ?? "Untitled"
    author.text = item["author"] as? String ?? ""
    let unread = item["unreadCount"] as? Int ?? 0
    let downloaded = item["downloadedCount"] as? Int ?? 0
    badge.text = unread > 0 ? "  \(unread)  " : "  \(downloaded)  "
    badge.isHidden = unread == 0 && downloaded == 0
    resume.isHidden = !(item["showContinue"] as? Bool ?? false)
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

  @objc private func resumeTapped() { onResume?() }

  override func layoutSubviews() {
    super.layoutSubviews()
    if stack.axis == .vertical {
      coverHeight.constant = max(80, bounds.width * 1.44)
    }
  }
}


/// Native library preferences matching the original Flutter
/// Filter / Sort / Display sheet. All persistence remains in Dart providers.
private final class NovayomiLibraryPreferencesSheet: UITableViewController {
  private let tabs = UISegmentedControl(items: ["Filter", "Sort", "Display"])
  private let onAction: (String, Any) -> Void
  private var filters: [String: Int]
  private var settings: [String: Bool]
  private var sources: [String]
  private var selectedSources: Set<String>
  private var sortIndex: Int
  private var sortReverse: Bool
  private var displayIndex: Int
  private var gridSize: Int

  private let filterItems: [(String, String)] = [
    ("downloaded", "Downloaded"),
    ("unread", "Unread"),
    ("started", "Started reading"),
    ("bookmarked", "Bookmarked chapters"),
    ("completed", "Completed"),
    ("tracking", "Tracking")
  ]
  private let sortItems = [
    "Title", "Last read", "Last update check", "Unread chapters",
    "Total chapters", "Latest chapter", "Date added"
  ]
  private let displayItems = [
    "Compact grid", "Comfortable grid", "Cover-only grid", "List"
  ]
  private let toggles: [(String, String)] = [
    ("showCategories", "Show category tabs"),
    ("showCounts", "Show item counts"),
    ("downloadBadges", "Downloaded chapter badges"),
    ("showLanguage", "Language badges"),
    ("showSource", "Source badges"),
    ("showLocal", "Local source badges"),
    ("continueButton", "Continue-reading buttons"),
    ("continueShelf", "Continue-reading shelf")
  ]

  init(data: [String: Any], onAction: @escaping (String, Any) -> Void) {
    self.onAction = onAction
    filters = data["filters"] as? [String: Int] ?? [:]
    settings = data["displaySettings"] as? [String: Bool] ?? [:]
    sources = data["sources"] as? [String] ?? []
    selectedSources = Set(data["selectedSources"] as? [String] ?? [])
    sortIndex = data["sortIndex"] as? Int ?? 0
    sortReverse = data["sortReverse"] as? Bool ?? false
    displayIndex = data["displayIndex"] as? Int ?? 0
    gridSize = data["gridSize"] as? Int ?? 0
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("Not created from storyboard") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Library settings"
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done, target: self, action: #selector(done))
    tabs.selectedSegmentIndex = 0
    tabs.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
    navigationItem.titleView = tabs
    tableView.keyboardDismissMode = .onDrag
    tableView.rowHeight = 54
  }

  @objc private func done() { dismiss(animated: true) }
  @objc private func tabChanged() { tableView.reloadData() }

  override func numberOfSections(in tableView: UITableView) -> Int {
    switch tabs.selectedSegmentIndex {
    case 0: return sources.isEmpty ? 1 : 2
    case 2: return 2
    default: return 1
    }
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    switch tabs.selectedSegmentIndex {
    case 0: return section == 0 ? "Novel filters" : "Sources"
    case 1: return "Sort novels · tap again to reverse"
    default: return section == 0 ? "Display mode" : "Appearance and badges"
    }
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch tabs.selectedSegmentIndex {
    case 0: return section == 0 ? filterItems.count : sources.count
    case 1: return sortItems.count
    default: return section == 0 ? displayItems.count + 1 : toggles.count
    }
  }

  override func tableView(_ tableView: UITableView,
                          cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "setting")
      ?? UITableViewCell(style: .value1, reuseIdentifier: "setting")
    cell.accessoryType = .none
    cell.detailTextLabel?.text = nil
    cell.textLabel?.textColor = .label
    switch tabs.selectedSegmentIndex {
    case 0:
      if indexPath.section == 0 {
        let filter = filterItems[indexPath.row]
        let value = filters[filter.0] ?? 0
        cell.textLabel?.text = filter.1
        cell.detailTextLabel?.text = ["Any", "Include", "Exclude"][min(max(value, 0), 2)]
      } else {
        let name = sources[indexPath.row]
        cell.textLabel?.text = name
        cell.accessoryType = selectedSources.contains(name) ? .checkmark : .none
      }
    case 1:
      cell.textLabel?.text = sortItems[indexPath.row]
      if sortIndex == indexPath.row {
        cell.accessoryType = .checkmark
        cell.detailTextLabel?.text = sortReverse ? "Descending" : "Ascending"
      }
    default:
      if indexPath.section == 0 {
        if indexPath.row == displayItems.count {
          cell.textLabel?.text = "Grid columns"
          cell.detailTextLabel?.text = gridSize == 0 ? "Automatic" : "\(gridSize) per row"
        } else {
          cell.textLabel?.text = displayItems[indexPath.row]
          cell.accessoryType = displayIndex == indexPath.row ? .checkmark : .none
        }
      } else {
        let entry = toggles[indexPath.row]
        cell.textLabel?.text = entry.1
        cell.accessoryType = settings[entry.0] == true ? .checkmark : .none
      }
    }
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    switch tabs.selectedSegmentIndex {
    case 0:
      if indexPath.section == 0 {
        let key = filterItems[indexPath.row].0
        let next = ((filters[key] ?? 0) + 1) % 3
        filters[key] = next
        onAction("filter", ["key": key, "value": next])
      } else {
        let name = sources[indexPath.row]
        if !selectedSources.insert(name).inserted { selectedSources.remove(name) }
        onAction("sources", Array(selectedSources).sorted())
      }
    case 1:
      if sortIndex == indexPath.row { sortReverse.toggle() }
      else { sortIndex = indexPath.row }
      onAction("sort", indexPath.row)
    default:
      if indexPath.section == 0 {
        if indexPath.row == displayItems.count {
          gridSize = (gridSize + 1) % 8
          onAction("gridSize", gridSize)
        } else {
          displayIndex = indexPath.row
          onAction("display", displayIndex)
        }
      } else {
        let key = toggles[indexPath.row].0
        let next = !(settings[key] ?? false)
        settings[key] = next
        onAction("displayToggle", ["key": key, "value": next])
      }
    }
    tableView.reloadData()
  }
}


/// Native UIKit category picker, passing only chosen IDs to Dart's original
/// MangaRepository.putAll implementation. No native database writes.
private final class NovayomiLibraryCategorySheet: UITableViewController {
  private let categories: [(id: Int, title: String)]
  private let onConfirm: ([Int]) -> Void
  private var chosen = Set<Int>()

  init(categories: [[String: Any]], onConfirm: @escaping ([Int]) -> Void) {
    self.categories = categories.compactMap { c in
      guard let id = c["id"] as? Int else { return nil }
      return (id, c["name"] as? String ?? "Collection")
    }
    self.onConfirm = onConfirm
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("Storyboard unsupported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Set categories"
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done, target: self, action: #selector(done))
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    categories.count
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "category")
      ?? UITableViewCell(style: .default, reuseIdentifier: "category")
    let category = categories[indexPath.row]
    cell.textLabel?.text = category.title
    cell.accessoryType = chosen.contains(category.id) ? .checkmark : .none
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let id = categories[indexPath.row].id
    if !chosen.insert(id).inserted { chosen.remove(id) }
    tableView.reloadRows(at: [indexPath], with: .none)
  }

  @objc private func cancel() { dismiss(animated: true) }
  @objc private func done() {
    let values = Array(chosen)
    dismiss(animated: true) { [onConfirm] in onConfirm(values) }
  }
}
