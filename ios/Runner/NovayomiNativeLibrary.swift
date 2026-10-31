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
  private let libraryTitleHeader = UIStackView()
  private let compactBar = UIStackView()
  private let compactTitle = UILabel()
  private let search = UISearchBar()
  private let categoryScroll = UIScrollView()
  private var categoryHeight: NSLayoutConstraint!
  private let categoryStack = UIStackView()
  private let sortButton = UIButton(type: .system)
  private let actionsButton = UIButton(type: .system)
  private let preferencesButton = UIButton(type: .system)
  private let layoutButton = UIButton(type: .system)
  private let refresh = UIRefreshControl()
  private let selectionBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
  private var selectionHeight: NSLayoutConstraint!
  private var collectionBottom: NSLayoutConstraint!
  private let selectedCount = UILabel()
  private let emptyBackground = UIView()
  private let emptySymbol = UIImageView(image: UIImage(systemName: "books.vertical"))
  private let emptyTitle = UILabel()
  private let emptyMessage = UILabel()
  private let emptyAction = UIButton(type: .system)
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
  private var didRestoreViewState = false
  private var isList = false
  private var sortIndex = 0
  private var gridSize = 0
  private var displayMode = 0
  private var configuration: [String: Any] = [:]
  private weak var categoryManager: NovayomiLibraryCategoryManager?

  init(frame: CGRect, identifier: Int64, messenger: FlutterBinaryMessenger,
       data: [String: Any]) {
    root = UIView(frame: frame)
    channel = FlutterMethodChannel(name: "novayomi/native-library/\(identifier)",
                                    binaryMessenger: messenger)
    let flow = UICollectionViewFlowLayout()
    flow.minimumInteritemSpacing = 12
    flow.minimumLineSpacing = 14
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

    actionsButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
    actionsButton.accessibilityLabel = "Library actions"
    actionsButton.showsMenuAsPrimaryAction = true

    let labels = UIStackView(arrangedSubviews: [heading, total])
    labels.axis = .vertical
    labels.alignment = .leading
    labels.spacing = 3
    libraryTitleHeader.addArrangedSubview(labels)
    libraryTitleHeader.axis = .horizontal
    libraryTitleHeader.alignment = .bottom
    libraryTitleHeader.translatesAutoresizingMaskIntoConstraints = false

    compactTitle.text = "Library"
    compactTitle.font = .preferredFont(forTextStyle: .headline)
    compactTitle.alpha = 0
    compactBar.axis = .horizontal
    compactBar.alignment = .center
    compactBar.spacing = 6
    compactBar.translatesAutoresizingMaskIntoConstraints = false
    compactBar.addArrangedSubview(compactTitle)
    compactBar.addArrangedSubview(UIView())
    for button in [preferencesButton, layoutButton, actionsButton] {
      compactBar.addArrangedSubview(button)
    }
    root.addSubview(compactBar)
    NSLayoutConstraint.activate([
      preferencesButton.widthAnchor.constraint(equalToConstant: 44),
      preferencesButton.heightAnchor.constraint(equalToConstant: 44),
      sortButton.widthAnchor.constraint(equalToConstant: 44),
      sortButton.heightAnchor.constraint(equalToConstant: 44),
      layoutButton.widthAnchor.constraint(equalToConstant: 44),
      layoutButton.heightAnchor.constraint(equalToConstant: 44),
      actionsButton.widthAnchor.constraint(equalToConstant: 44),
      actionsButton.heightAnchor.constraint(equalToConstant: 44)
    ])

    search.placeholder = "Search novels"
    search.searchBarStyle = .minimal
    search.scopeButtonTitles = ["Filtered", "All"]
    search.selectedScopeButtonIndex = 0
    search.showsScopeBar = true
    search.delegate = self
    search.translatesAutoresizingMaskIntoConstraints = false
    // Search and categories belong to the scrolling Library header.

    categoryStack.axis = .horizontal
    categoryStack.spacing = 8
    categoryStack.alignment = .center
    categoryStack.translatesAutoresizingMaskIntoConstraints = false
    categoryScroll.showsHorizontalScrollIndicator = false
    categoryHeight = categoryScroll.heightAnchor.constraint(equalToConstant: 42)
    categoryScroll.translatesAutoresizingMaskIntoConstraints = false
    categoryScroll.addSubview(categoryStack)
    collection.backgroundColor = .clear
    collection.alwaysBounceVertical = true
    collection.keyboardDismissMode = .onDrag
    collection.dataSource = self
    collection.delegate = self
    collection.register(NovayomiLibraryCell.self, forCellWithReuseIdentifier: "novel")
    // Keep the Continue Reading shelf INSIDE this vertical collection's
    // scrollable section header. It must not be pinned above the book grid.
    collection.register(UICollectionReusableView.self,
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
      withReuseIdentifier: "continue-reading-header")
    let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressNovel(_:)))
    longPress.minimumPressDuration = 0.5
    longPress.cancelsTouchesInView = true
    collection.addGestureRecognizer(longPress)
    collection.translatesAutoresizingMaskIntoConstraints = false
    refresh.addTarget(self, action: #selector(refreshLibrary), for: .valueChanged)
    collection.refreshControl = refresh
    root.addSubview(collection)

    // UIKit-native empty results, not an inert blank collection.
    emptySymbol.tintColor = .tertiaryLabel
    emptySymbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 46)
    emptySymbol.contentMode = .scaleAspectFit
    emptyTitle.font = .preferredFont(forTextStyle: .title3)
    emptyTitle.textAlignment = .center
    emptyTitle.adjustsFontForContentSizeCategory = true
    emptyMessage.font = .preferredFont(forTextStyle: .subheadline)
    emptyMessage.textColor = .secondaryLabel
    emptyMessage.numberOfLines = 0
    emptyMessage.textAlignment = .center
    emptyMessage.adjustsFontForContentSizeCategory = true
    emptyAction.configuration = .filled()
    emptyAction.addTarget(self, action: #selector(emptyActionTapped), for: .touchUpInside)
    let emptyColumn = UIStackView(arrangedSubviews: [
      emptySymbol, emptyTitle, emptyMessage, emptyAction
    ])
    emptyColumn.axis = .vertical
    emptyColumn.alignment = .center
    emptyColumn.spacing = 12
    emptyColumn.translatesAutoresizingMaskIntoConstraints = false
    emptyBackground.addSubview(emptyColumn)
    NSLayoutConstraint.activate([
      emptySymbol.heightAnchor.constraint(equalToConstant: 56),
      emptyColumn.centerXAnchor.constraint(equalTo: emptyBackground.centerXAnchor),
      emptyColumn.centerYAnchor.constraint(equalTo: emptyBackground.centerYAnchor, constant: -24),
      emptyColumn.leadingAnchor.constraint(greaterThanOrEqualTo: emptyBackground.leadingAnchor, constant: 30),
      emptyColumn.trailingAnchor.constraint(lessThanOrEqualTo: emptyBackground.trailingAnchor, constant: -30),
      emptyColumn.widthAnchor.constraint(lessThanOrEqualToConstant: 300)
    ])
    collection.backgroundView = emptyBackground

    continueHeading.text = "Continue Reading"
    continueHeading.font = .preferredFont(forTextStyle: .headline)
    continueHeading.textColor = .label
    continueHeading.translatesAutoresizingMaskIntoConstraints = false
    continueCollection.backgroundColor = .clear
    continueCollection.showsHorizontalScrollIndicator = false
    continueCollection.dataSource = self
    continueCollection.delegate = self
    continueCollection.register(NovayomiLibraryCell.self,
                                forCellWithReuseIdentifier: "novel")
    continueCollection.translatesAutoresizingMaskIntoConstraints = false
    // Mounted into the reusable header in viewForSupplementaryElementOfKind.
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
    let choose = UIButton(type: .system)
    choose.setImage(UIImage(systemName: "checklist"), for: .normal)
    choose.tintColor = .label
    choose.accessibilityLabel = "Selection actions"
    choose.showsMenuAsPrimaryAction = true
    choose.menu = UIMenu(children: [
      UIAction(title: "Select all visible", image: UIImage(systemName: "checkmark.circle")) {
        [weak self] _ in self?.selectAllVisible()
      },
      UIAction(title: "Invert selection", image: UIImage(systemName: "arrow.left.arrow.right")) {
        [weak self] _ in self?.invertSelection()
      }
    ])
    choose.widthAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
    choose.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
    let mark = nativeButton("checkmark.circle", hint: "Mark novels as read", action: #selector(markSelectedRead))
    let unread = nativeButton("circle", hint: "Mark novels as unread", action: #selector(markSelectedUnread))
    let categories = nativeButton("tag", hint: "Set categories", action: #selector(selectCategories))
    let remove = nativeButton("trash", hint: "Remove from library", action: #selector(confirmRemove))
    let selections = UIStackView(arrangedSubviews: [clear, selectedCount, choose, mark, unread, categories, remove])
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
      compactBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
      compactBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
      compactBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      compactBar.heightAnchor.constraint(equalToConstant: 48),
      categoryStack.leadingAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.leadingAnchor, constant: 18),
      categoryStack.trailingAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.trailingAnchor, constant: -18),
      categoryStack.topAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.topAnchor),
      categoryStack.bottomAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.bottomAnchor),
      categoryStack.heightAnchor.constraint(equalTo: categoryScroll.frameLayoutGuide.heightAnchor),
      collection.topAnchor.constraint(equalTo: compactBar.bottomAnchor),
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
      } else if call.method == "error", let message = call.arguments as? String {
        let alert = UIAlertController(title: "Library action failed",
          message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.presentNative(alert)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit { channel.setMethodCallHandler(nil) }

  func view() -> UIView { root }

  private func apply(_ data: [String: Any]) {
    if !didRestoreViewState {
      didRestoreViewState = true
      let saved = data["uiState"] as? [String: Any] ?? [:]
      query = saved["search"] as? String ?? ""
      search.text = query
      let scope = saved["scope"] as? Int ?? 0
      search.selectedScopeButtonIndex = min(1, max(0, scope))
      let category = saved["category"] as? Int ?? 0
      selectedCategory = category == 0 ? nil : category
      onlyUncategorized = saved["uncategorized"] as? Bool ?? false
      let offset = saved["offset"] as? Double ?? 0
      if offset > 0 {
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.collection.layoutIfNeeded()
          let maxY = max(0, self.collection.contentSize.height - self.collection.bounds.height)
          self.collection.setContentOffset(CGPoint(x: 0, y: min(maxY, CGFloat(offset))),
                                           animated: false)
        }
      }
    }
    configuration = data
    if let all = data["allCategories"] as? [[String: Any]] {
      categoryManager?.update(all)
    }
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
    collection.collectionViewLayout.invalidateLayout()
    if let label = data["title"] as? String {
      heading.text = label
      compactTitle.text = label
    }
    if let index = data["sortIndex"] as? Int { sortIndex = index }
    if let size = data["gridSize"] as? Int { gridSize = size }
    if let index = data["displayIndex"] as? Int { displayMode = index }
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
    updateActionsMenu()
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

  private func updateActionsMenu() {
    actionsButton.menu = UIMenu(children: [
      UIAction(title: "Update Library", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
        self?.channel.invokeMethod("refresh", arguments: nil)
      },
      UIAction(title: "Open Random Novel", image: UIImage(systemName: "shuffle")) { [weak self] _ in
        self?.channel.invokeMethod("random", arguments: nil)
      },
      UIAction(title: "Import EPUB", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
        self?.showImportOptions()
      },
      UIAction(title: "Manage Collections", image: UIImage(systemName: "folder")) { [weak self] _ in
        self?.openCategoryManager()
      }
    ])
  }

  private func showImportOptions() {
    let alert = UIAlertController(
      title: "Import EPUB",
      message: "Choose how to import chapters. The iOS document picker opens next.",
      preferredStyle: .actionSheet)
    alert.addAction(UIAlertAction(title: "Split into chapters", style: .default) { [weak self] _ in
      self?.channel.invokeMethod("import", arguments: true)
    })
    alert.addAction(UIAlertAction(title: "Keep as one chapter", style: .default) { [weak self] _ in
      self?.channel.invokeMethod("import", arguments: false)
    })
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    if let popover = alert.popoverPresentationController {
      popover.sourceView = actionsButton
      popover.sourceRect = actionsButton.bounds
    }
    presentNative(alert)
  }

  private func openCategoryManager() {
    let manager = NovayomiLibraryCategoryManager(categories: configuration["allCategories"] as? [[String: Any]] ?? []) { [weak self] action in
      self?.channel.invokeMethod("manageCategory", arguments: action)
    }
    categoryManager = manager
    presentSheet(manager)
  }

  private func rebuildCategories() {
    categoryStack.arrangedSubviews.forEach {
      categoryStack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    if categoryScroll.isHidden { return }
    var categories: [(String, Int?)] = [("All", nil)]
    let relevant = entries.filter { item in
      guard let id = item["id"] as? Int else { return false }
      return visibleIds.contains(id)
    }
    if relevant.contains(where: { ($0["categories"] as? [Int] ?? []).isEmpty }) {
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
      let appearance = self.configuration["displaySettings"] as? [String: Bool] ?? [:]
      if appearance["showCounts"] ?? true {
        let count = relevant.filter { item in
          let belonging = item["categories"] as? [Int] ?? []
          if let category = option.1 {
            return category == -1 ? belonging.isEmpty : belonging.contains(category)
          }
          return true
        }.count
        configuration.title = "\(option.0)  \(count)"
      } else {
        configuration.title = option.0
      }
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
        self.saveViewState()
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
    if displayed.isEmpty {
      if entries.isEmpty {
        emptyTitle.text = "Your Novel Library is empty"
        emptyMessage.text = "Browse sources or import an EPUB to get started."
        emptyAction.setTitle("Browse novels", for: .normal)
      } else {
        emptyTitle.text = "No matching novels"
        emptyMessage.text = "Try another search or change your Library filters."
        emptyAction.setTitle("Clear filters and search", for: .normal)
      }
    }
    emptyBackground.isHidden = !displayed.isEmpty
    collection.reloadData()
    // With one or two novels the content can be shorter than the viewport.
    // Make enough room to scroll the entire shelf away even in tiny libraries,
    // instead of leaving the shelf permanently stuck on screen.
    DispatchQueue.main.async { [weak self] in
      self?.ensureShelfCanScrollAway()
    }
  }

  private func ensureShelfCanScrollAway() {
    let scroll = collection
    guard scroll.bounds.height > 0 else { return }
    scroll.layoutIfNeeded()
    let requiredTravel: CGFloat = max(0, libraryHeaderHeight - 45)
    let natural = scroll.collectionViewLayout.collectionViewContentSize.height
    let extra = requiredTravel == 0 ? 0
      : max(0, scroll.bounds.height + requiredTravel - natural)
    if abs(scroll.contentInset.bottom - extra) > 1 {
      scroll.contentInset.bottom = extra
    }
  }

  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    query = searchText
    filterAndReload()
    saveViewState()
  }

  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
  }

  func searchBar(_ searchBar: UISearchBar, selectedScopeButtonIndexDidChange selectedScope: Int) {
    filterAndReload()
    saveViewState()
  }

  private func saveViewState() {
    channel.invokeMethod("uiState", arguments: [
      "search": query,
      "scope": search.selectedScopeButtonIndex,
      "category": selectedCategory ?? 0,
      "uncategorized": onlyUncategorized,
      "offset": Double(collection.contentOffset.y)
    ] as [String: Any])
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard scrollView === collection else { return }
    // UIKit's compact navbar title appears as the large title scrolls away.
    compactTitle.alpha = min(1, max(0, (scrollView.contentOffset.y - 36) / 54))
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if scrollView === collection && !decelerate { saveViewState() }
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    if scrollView === collection { saveViewState() }
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

  @objc private func emptyActionTapped() {
    if entries.isEmpty {
      channel.invokeMethod("browse", arguments: nil)
      return
    }
    search.text = ""
    query = ""
    selectedCategory = nil
    onlyUncategorized = false
    search.selectedScopeButtonIndex = 1
    rebuildCategories()
    filterAndReload()
    saveViewState()
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

  // A normal, non-pinned UICollectionView section header. It travels
  // vertically with the book cells, while its inner shelf scrolls horizontally.
  private var libraryHeaderHeight: CGFloat {
    72 + 76 + categoryHeight.constant + 8 + (continueItems.isEmpty ? 0 : 238)
  }

  func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                      referenceSizeForHeaderInSection section: Int) -> CGSize {
    guard collectionView === collection else { return .zero }
    return CGSize(width: collectionView.bounds.width, height: libraryHeaderHeight)
  }

  func collectionView(_ collectionView: UICollectionView,
                      viewForSupplementaryElementOfKind kind: String,
                      at indexPath: IndexPath) -> UICollectionReusableView {
    guard collectionView === collection, kind == UICollectionView.elementKindSectionHeader else {
      return UICollectionReusableView()
    }
    let header = collectionView.dequeueReusableSupplementaryView(
      ofKind: kind, withReuseIdentifier: "continue-reading-header",
      for: indexPath)
    if libraryTitleHeader.superview !== header {
      for view in [libraryTitleHeader, search, categoryScroll, continueHeading, continueCollection] {
        view.removeFromSuperview()
        header.addSubview(view)
      }
      NSLayoutConstraint.activate([
        libraryTitleHeader.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
        libraryTitleHeader.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
        libraryTitleHeader.topAnchor.constraint(equalTo: header.topAnchor, constant: 4),
        libraryTitleHeader.heightAnchor.constraint(equalToConstant: 68),
        search.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
        search.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
        search.topAnchor.constraint(equalTo: libraryTitleHeader.bottomAnchor),
        search.heightAnchor.constraint(equalToConstant: 76),
        categoryScroll.topAnchor.constraint(equalTo: search.bottomAnchor),
        categoryScroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
        categoryScroll.trailingAnchor.constraint(equalTo: header.trailingAnchor),
        categoryHeight,
        continueHeading.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
        continueHeading.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
        continueHeading.topAnchor.constraint(equalTo: categoryScroll.bottomAnchor, constant: 8),
        continueHeadingHeight,
        continueCollection.leadingAnchor.constraint(equalTo: header.leadingAnchor),
        continueCollection.trailingAnchor.constraint(equalTo: header.trailingAnchor),
        continueCollection.topAnchor.constraint(equalTo: continueHeading.bottomAnchor, constant: 3),
        continueCollectionHeight
      ])
    }
    return header
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
                   displayMode: isContinue ? 0 : displayMode,
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

  @objc private func longPressNovel(_ recognizer: UILongPressGestureRecognizer) {
    guard recognizer.state == .began else { return }
    let point = recognizer.location(in: collection)
    guard let index = collection.indexPathForItem(at: point),
          displayed.indices.contains(index.item),
          let id = displayed[index.item]["id"] as? Int else { return }
    toggleSelection(id)
  }

  private func selectAllVisible() {
    selectedIds.formUnion(displayed.compactMap { $0["id"] as? Int })
    updateSelectionBar()
    collection.reloadData()
  }

  private func invertSelection() {
    selectedIds.formSymmetricDifference(Set(displayed.compactMap { $0["id"] as? Int }))
    updateSelectionBar()
    collection.reloadData()
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
    let chosen = selectedIds
    let hasLocal = entries.contains { item in
      guard let id = item["id"] as? Int, chosen.contains(id) else { return false }
      return item["isLocal"] as? Bool ?? false
    }
    let sheet = NovayomiLibraryRemovalSheet(count: chosen.count, hasLocalArchives: hasLocal) {
      [weak self] removeLibrary, deleteDownloads in
      guard let self else { return }
      self.channel.invokeMethod("batch", arguments: [
        "kind": "remove", "ids": Array(chosen),
        "removeFromLibrary": removeLibrary, "deleteDownloads": deleteDownloads
      ] as [String: Any])
      self.clearSelection()
    }
    presentSheet(sheet)
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
      : (width > 700 ? 5 : width > 450 ? 3 : 2)
    let itemWidth = max(65, floor((width - 36 - (columns - 1) * 12) / columns))
    let labelHeight: CGFloat = 0
    let coverHeight = displayMode == 1 ? itemWidth * 1.57 : itemWidth * 1.44
    return CGSize(width: itemWidth, height: coverHeight + (isList ? labelHeight : 0))
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
  private let coverGradient = CAGradientLayer()
  private let coverCaption = UILabel()
  private let title = UILabel()
  private let author = UILabel()
  private let topLeftBadges = UIStackView()
  private let localBadge = UILabel()
  private let downloadedBadge = UILabel()
  private let unreadBadge = UILabel()
  private let languageBadge = UILabel()
  private let sourceBadge = UILabel()
  private let readingProgress = UIProgressView(progressViewStyle: .bar)
  private let resume = UIButton(type: .system)
  var onResume: (() -> Void)?
  private let stack = UIStackView()
  private let textStack = UIStackView()
  private var coverHeight: NSLayoutConstraint!
  private var coverWidth: NSLayoutConstraint!
  private var loadTask: URLSessionDataTask?
  private var represented = ""
  private var currentDisplayMode = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    contentView.backgroundColor = .clear
    cover.contentMode = .scaleAspectFill
    // Buttons overlaid on UIImageView only receive touches when enabled.
    cover.isUserInteractionEnabled = true
    cover.clipsToBounds = true
    cover.layer.cornerRadius = 8
    cover.backgroundColor = .secondarySystemGroupedBackground
    coverGradient.colors = [
      UIColor.clear.cgColor,
      UIColor.black.withAlphaComponent(0.18).cgColor,
      UIColor.black.withAlphaComponent(0.86).cgColor
    ]
    coverGradient.locations = [0, 0.52, 1]
    cover.layer.addSublayer(coverGradient)
    coverCaption.font = .systemFont(ofSize: 15, weight: .semibold)
    coverCaption.numberOfLines = 2
    coverCaption.textColor = .white
    coverCaption.shadowColor = UIColor.black.withAlphaComponent(0.3)
    coverCaption.shadowOffset = CGSize(width: 0, height: 1)
    coverCaption.translatesAutoresizingMaskIntoConstraints = false
    cover.addSubview(coverCaption)
    topLeftBadges.axis = .horizontal
    topLeftBadges.alignment = .top
    topLeftBadges.spacing = 3
    topLeftBadges.translatesAutoresizingMaskIntoConstraints = false
    for label in [localBadge, downloadedBadge, unreadBadge, languageBadge, sourceBadge] {
      label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
      label.textAlignment = .center
      label.textColor = .white
      label.backgroundColor = UIColor.black.withAlphaComponent(0.72)
      label.layer.cornerRadius = 6
      label.clipsToBounds = true
      label.heightAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
      label.isHidden = true
    }
    downloadedBadge.backgroundColor = .systemTeal
    unreadBadge.backgroundColor = .systemBlue
    for label in [localBadge, downloadedBadge, unreadBadge] {
      topLeftBadges.addArrangedSubview(label)
    }
    cover.addSubview(topLeftBadges)
    languageBadge.translatesAutoresizingMaskIntoConstraints = false
    sourceBadge.translatesAutoresizingMaskIntoConstraints = false
    sourceBadge.lineBreakMode = .byTruncatingTail
    cover.addSubview(languageBadge)
    cover.addSubview(sourceBadge)
    resume.setImage(UIImage(systemName: "play.fill"), for: .normal)
    resume.tintColor = .white
    resume.backgroundColor = .systemBlue
    resume.layer.cornerRadius = 17
    resume.accessibilityLabel = "Continue reading"
    resume.translatesAutoresizingMaskIntoConstraints = false
    resume.addTarget(self, action: #selector(resumeTapped), for: .touchUpInside)
    cover.addSubview(resume)
    readingProgress.progressTintColor = .systemBlue
    readingProgress.trackTintColor = UIColor.secondarySystemBackground.withAlphaComponent(0.75)
    readingProgress.translatesAutoresizingMaskIntoConstraints = false
    cover.addSubview(readingProgress)
    NSLayoutConstraint.activate([
      coverCaption.leadingAnchor.constraint(equalTo: cover.leadingAnchor, constant: 9),
      coverCaption.trailingAnchor.constraint(equalTo: cover.trailingAnchor, constant: -9),
      coverCaption.bottomAnchor.constraint(equalTo: cover.bottomAnchor, constant: -12),
      readingProgress.leadingAnchor.constraint(equalTo: cover.leadingAnchor),
      readingProgress.trailingAnchor.constraint(equalTo: cover.trailingAnchor),
      readingProgress.bottomAnchor.constraint(equalTo: cover.bottomAnchor),
      readingProgress.heightAnchor.constraint(equalToConstant: 3),
      topLeftBadges.leadingAnchor.constraint(equalTo: cover.leadingAnchor, constant: 4),
      topLeftBadges.topAnchor.constraint(equalTo: cover.topAnchor, constant: 4),
      topLeftBadges.trailingAnchor.constraint(lessThanOrEqualTo: cover.trailingAnchor, constant: -4),
      languageBadge.topAnchor.constraint(equalTo: cover.topAnchor, constant: 4),
      languageBadge.trailingAnchor.constraint(equalTo: cover.trailingAnchor, constant: -4),
      sourceBadge.leadingAnchor.constraint(equalTo: cover.leadingAnchor, constant: 4),
      sourceBadge.bottomAnchor.constraint(equalTo: cover.bottomAnchor, constant: -7),
      sourceBadge.widthAnchor.constraint(lessThanOrEqualTo: cover.widthAnchor, multiplier: 0.65),
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
    for label in [localBadge, downloadedBadge, unreadBadge, languageBadge, sourceBadge] {
      label.isHidden = true
    }
    readingProgress.isHidden = true
    resume.isHidden = true
    cover.image = UIImage(systemName: "book.closed")
  }

  func configure(item: [String: Any], isList: Bool, displayMode: Int, selected: Bool) {
    let id = item["id"] as? Int ?? -1
    represented = String(id)
    currentDisplayMode = displayMode
    contentView.layer.borderWidth = selected ? 2 : 0
    contentView.layer.borderColor = UIColor.systemBlue.cgColor
    contentView.layer.cornerRadius = 9
    title.text = item["name"] as? String ?? "Untitled"
    coverCaption.text = title.text
    author.text = item["author"] as? String ?? ""
    let unread = item["unreadCount"] as? Int ?? 0
    let downloaded = item["downloadedCount"] as? Int ?? 0
    let isLocal = item["isLocal"] as? Bool ?? false
    localBadge.isHidden = !isLocal || !(item["localBadge"] as? Bool ?? false)
    localBadge.text = " Local "
    downloadedBadge.isHidden = downloaded == 0
    downloadedBadge.text = " ↓\(downloaded) "
    unreadBadge.isHidden = unread == 0
    unreadBadge.text = " \(unread) "
    let language = (item["language"] as? String ?? "").uppercased()
    languageBadge.isHidden = language.isEmpty || !(item["languageBadge"] as? Bool ?? false)
    languageBadge.text = " \(language) "
    let source = item["source"] as? String ?? ""
    sourceBadge.isHidden = source.isEmpty || !(item["sourceBadge"] as? Bool ?? false)
    sourceBadge.text = " \(source) "
    contentView.isAccessibilityElement = true
    contentView.accessibilityLabel = "\(title.text ?? "Novel"), \(unread) unread, \(downloaded) downloaded"
    contentView.accessibilityTraits = .button
    resume.isHidden = !(item["showContinue"] as? Bool ?? false)
    if let progress = item["progress"] as? Double {
      readingProgress.isHidden = false
      readingProgress.progress = Float(max(0, min(1, progress)))
    } else {
      readingProgress.isHidden = true
    }
    cover.image = UIImage(systemName: "book.closed")

    // Use full-height cover cards; keep accessible metadata in list mode.
    let fullBleed = !isList
    textStack.isHidden = fullBleed
    coverCaption.isHidden = !fullBleed
    coverGradient.isHidden = !fullBleed
    resume.isHidden = fullBleed || !(item["showContinue"] as? Bool ?? false)
    if isList {
      coverHeight.constant = 78
      coverWidth.isActive = true
      stack.axis = .horizontal
      stack.alignment = .center
    } else {
      coverWidth.isActive = false
      coverHeight.constant = max(80, bounds.width * (currentDisplayMode == 1 ? 1.57 : 1.44))
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
      coverHeight.constant = max(80, bounds.width * (currentDisplayMode == 1 ? 1.57 : 1.44))
    }
    coverGradient.frame = cover.bounds
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


/// Native collection management, backed by the existing CategoryRepository.
/// The sheet never writes Isar directly. Every operation is sent to Dart, where
/// current persistence, timestamps and sync event rules remain authoritative.
private final class NovayomiLibraryCategoryManager: UITableViewController {
  private var categories: [[String: Any]]
  private let onAction: ([String: Any]) -> Void

  init(categories: [[String: Any]], onAction: @escaping ([String: Any]) -> Void) {
    self.categories = categories
    self.onAction = onAction
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) { fatalError("Storyboard unsupported") }

  func update(_ data: [[String: Any]]) {
    // Do not disrupt a user mid-drag. Updated Isar snapshots arrive normally.
    if isViewLoaded && tableView.isEditing { return }
    categories = data.sorted {
      ($0["position"] as? Int ?? 0) < ($1["position"] as? Int ?? 0)
    }
    if isViewLoaded { tableView.reloadData() }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Collections"
    navigationItem.leftBarButtonItem = editButtonItem
    navigationItem.rightBarButtonItems = [
      UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done)),
      UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(create))
    ]
    tableView.allowsSelectionDuringEditing = true
    tableView.rowHeight = 54
    update(categories)
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    categories.count
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let c = categories[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "collection")
      ?? UITableViewCell(style: .subtitle, reuseIdentifier: "collection")
    let name = c["name"] as? String ?? "Collection"
    let hidden = c["hidden"] as? Bool ?? false
    let updates = c["updates"] as? Bool ?? true
    cell.textLabel?.text = name
    cell.textLabel?.textColor = hidden ? .secondaryLabel : .label
    cell.detailTextLabel?.text = hidden ? "Hidden" : (updates ? nil : "Skip updates")
    cell.accessibilityLabel = name + (hidden ? ", hidden" : "")
    cell.accessoryType = .disclosureIndicator
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard categories.indices.contains(indexPath.row),
          let id = categories[indexPath.row]["id"] as? Int else { return }
    promptName(title: "Rename collection", current: categories[indexPath.row]["name"] as? String ?? "") {
      [weak self] name in self?.onAction(["kind": "rename", "id": id, "name": name])
    }
  }

  override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }

  override func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
    let item = categories.remove(at: source.row)
    categories.insert(item, at: destination.row)
    let ids = categories.compactMap { $0["id"] as? Int }
    onAction(["kind": "reorder", "ids": ids])
  }

  override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath)
    -> UITableViewCell.EditingStyle { .none }

  override func tableView(_ tableView: UITableView,
                          trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
    guard categories.indices.contains(indexPath.row),
          let id = categories[indexPath.row]["id"] as? Int else { return nil }
    let item = categories[indexPath.row]
    let hidden = item["hidden"] as? Bool ?? false
    let updates = item["updates"] as? Bool ?? true
    let visibility = UIContextualAction(style: .normal, title: hidden ? "Show" : "Hide") {
      [weak self] _, _, completion in
      self?.onAction(["kind": "hide", "id": id, "value": !hidden])
      completion(true)
    }
    visibility.backgroundColor = .systemBlue
    let update = UIContextualAction(style: .normal, title: updates ? "Skip updates" : "Enable updates") {
      [weak self] _, _, completion in
      self?.onAction(["kind": "updates", "id": id, "value": !updates])
      completion(true)
    }
    update.backgroundColor = .systemGray
    let remove = UIContextualAction(style: .destructive, title: "Delete") {
      [weak self] _, _, completion in
      let confirmation = UIAlertController(title: "Delete collection?",
        message: "Novels will stay in your Library but will lose this collection.",
        preferredStyle: .alert)
      confirmation.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false) })
      confirmation.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
        self?.onAction(["kind": "delete", "id": id])
        completion(true)
      })
      self?.present(confirmation, animated: true)
    }
    return UISwipeActionsConfiguration(actions: [remove, update, visibility])
  }

  @objc private func create() {
    promptName(title: "New collection", current: "") { [weak self] name in
      self?.onAction(["kind": "create", "name": name])
    }
  }

  private func promptName(title: String, current: String, callback: @escaping (String) -> Void) {
    let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
    alert.addTextField { input in
      input.text = current
      input.placeholder = "Collection name"
      input.autocapitalizationType = .words
      input.clearButtonMode = .whileEditing
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
      let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !name.isEmpty && name.count <= 80 else { return }
      if self?.categories.contains(where: {
        ($0["name"] as? String ?? "").localizedCaseInsensitiveCompare(name) == .orderedSame
          && ($0["name"] as? String ?? "") != current
      }) == true { return }
      callback(name)
    })
    present(alert, animated: true)
  }

  @objc private func done() { dismiss(animated: true) }
}


/// UIKit equivalent of Flutter's showDeleteMangaDialog. Both toggles are
/// independent. The actual delete transaction/file cleanup is the unchanged
/// Dart implementation shared with the original Flutter dialog.
private final class NovayomiLibraryRemovalSheet: UIViewController {
  private let numberOfNovels: Int
  private let hasLocalArchives: Bool
  private let onConfirm: (Bool, Bool) -> Void
  private let removeLibrary = UISwitch()
  private let deleteDownloads = UISwitch()
  private let deleteButton = UIButton(type: .system)
  private let warning = UILabel()

  init(count: Int, hasLocalArchives: Bool, onConfirm: @escaping (Bool, Bool) -> Void) {
    numberOfNovels = count
    self.hasLocalArchives = hasLocalArchives
    self.onConfirm = onConfirm
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("No storyboard") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Remove · \(numberOfNovels)"
    view.backgroundColor = .systemGroupedBackground
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
    removeLibrary.isOn = false
    deleteDownloads.isOn = false
    removeLibrary.addTarget(self, action: #selector(updateChoice), for: .valueChanged)
    deleteDownloads.addTarget(self, action: #selector(updateChoice), for: .valueChanged)

    let form = UIStackView()
    form.axis = .vertical
    form.spacing = 22
    form.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(form)

    func settingRow(_ text: String, control: UISwitch) -> UIView {
      let label = UILabel()
      label.text = text
      label.font = .preferredFont(forTextStyle: .body)
      label.numberOfLines = 0
      let row = UIStackView(arrangedSubviews: [label, control])
      row.axis = .horizontal
      row.alignment = .center
      row.spacing = 16
      return row
    }

    form.addArrangedSubview(settingRow("Remove from Library", control: removeLibrary))
    form.addArrangedSubview(settingRow("Delete downloaded chapters / local EPUB files",
                                     control: deleteDownloads))
    warning.font = .preferredFont(forTextStyle: .footnote)
    warning.textColor = .secondaryLabel
    warning.numberOfLines = 0
    form.addArrangedSubview(warning)
    deleteButton.configuration = .filled()
    deleteButton.configuration?.baseBackgroundColor = .systemRed
    deleteButton.setTitle("Remove", for: .normal)
    deleteButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    deleteButton.addTarget(self, action: #selector(confirm), for: .touchUpInside)
    form.addArrangedSubview(deleteButton)

    NSLayoutConstraint.activate([
      form.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 22),
      form.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -22),
      form.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 26)
    ])
    updateChoice()
  }

  @objc private func updateChoice() {
    deleteButton.isEnabled = removeLibrary.isOn || deleteDownloads.isOn
    if deleteDownloads.isOn && hasLocalArchives {
      warning.text = "Warning: selected local EPUB archives will be deleted permanently. This also removes their Library entries."
    } else if deleteDownloads.isOn {
      warning.text = "Downloaded chapters will be deleted, but novel entries and chapter metadata can remain for re-downloading."
    } else {
      warning.text = "Removing novels from Library does not delete downloaded chapters."
    }
  }

  @objc private func confirm() {
    let fromLibrary = removeLibrary.isOn
    let downloads = deleteDownloads.isOn
    guard fromLibrary || downloads else { return }
    dismiss(animated: true) { [onConfirm] in onConfirm(fromLibrary, downloads) }
  }

  @objc private func cancel() { dismiss(animated: true) }
}
