import Flutter
import UIKit

/// Phase 2.2. The entire visible novel-details screen is UIKit; all chapter,
/// extension, download, history and database operations stay in existing Dart.
final class NovayomiNovelDetailFactory: NSObject, FlutterPlatformViewFactory {
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
    NovayomiNovelDetailView(frame: frame, id: viewId, messenger: messenger,
                            data: args as? [String: Any] ?? [:])
  }
}

private final class NovayomiNovelDetailView: NSObject, FlutterPlatformView,
    UITableViewDelegate, UITableViewDataSource, UISearchBarDelegate {
  private let root: UIView
  private let channel: FlutterMethodChannel
  private let nav = UINavigationBar()
  private let navItem = UINavigationItem(title: "Novel")
  private let search = UISearchBar()
  private let chapterHeader = UIView()
  private let chapterCountLabel = UILabel()
  private let chapterSortButton = UIButton(type: .system)
  private let table = UITableView(frame: .zero, style: .plain)
  private let refresh = UIRefreshControl()
  private var info: [String: Any] = [:]
  private var chapters: [[String: Any]] = []
  private var visibleChapters: [[String: Any]] = []
  private var query = ""
  private var reversed = false
  private var readChapterId: Int?
  private var favorite = false
  private var descriptionExpanded = false

  init(frame: CGRect, id: Int64, messenger: FlutterBinaryMessenger,
       data: [String: Any]) {
    root = UIView(frame: frame)
    channel = FlutterMethodChannel(name: "novayomi/native-novel-detail/\(id)",
                                   binaryMessenger: messenger)
    super.init()
    root.backgroundColor = .systemBackground
    root.tintColor = .novayomiAccent
    nav.translatesAutoresizingMaskIntoConstraints = false
    let appearance = UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    nav.standardAppearance = appearance
    nav.scrollEdgeAppearance = appearance
    nav.compactAppearance = appearance
    navItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "chevron.left"),
      primaryAction: UIAction { [weak self] _ in self?.send("close") })
    navItem.leftBarButtonItem?.accessibilityLabel = "Back to Library"
    nav.setItems([navItem], animated: false)
    root.addSubview(nav)

    search.placeholder = "Search chapters"
    search.searchBarStyle = .minimal
    search.delegate = self
    // Aidoku's cover/details header appears first; chapter searching belongs
    // with the chapter list rather than above the novel cover.
    search.translatesAutoresizingMaskIntoConstraints = false
    configureChapterHeader()

    table.translatesAutoresizingMaskIntoConstraints = false
    table.backgroundColor = .systemBackground
    table.sectionHeaderTopPadding = 0
    table.separatorStyle = .singleLine
    table.separatorInset = UIEdgeInsets(top: 0, left: 22, bottom: 0, right: 16)
    table.estimatedRowHeight = 76
    table.rowHeight = UITableView.automaticDimension
    table.dataSource = self
    table.delegate = self
    table.register(NovayomiNovelInfoCell.self, forCellReuseIdentifier: "novel-info")
    table.register(UITableViewCell.self, forCellReuseIdentifier: "novel-chapter")
    refresh.addTarget(self, action: #selector(refreshRequested), for: .valueChanged)
    table.refreshControl = refresh
    root.addSubview(table)
    // Aidoku-style edge navigation. The underlying route remains Flutter,
    // but the gesture is recognized natively without a separate back button.
    let backSwipe = UIScreenEdgePanGestureRecognizer(
      target: self, action: #selector(handleBackSwipe(_:)))
    backSwipe.edges = .left
    root.addGestureRecognizer(backSwipe)

    NSLayoutConstraint.activate([
      nav.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
      nav.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      nav.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      table.topAnchor.constraint(equalTo: nav.bottomAnchor),
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
        let alert = UIAlertController(title: "Novel action failed",
          message: call.arguments as? String ?? "Unknown error", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.presentNative(alert)
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
  deinit { channel.setMethodCallHandler(nil) }
  func view() -> UIView { root }

  private func send(_ kind: String, _ value: Any? = nil) {
    channel.invokeMethod(kind, arguments: value)
  }

  private func apply(_ data: [String: Any]) {
    info = data
    chapters = data["chapters"] as? [[String: Any]] ?? []
    favorite = data["favorite"] as? Bool ?? false
    readChapterId = data["readChapterId"] as? Int
    navItem.title = data["title"] as? String ?? "Novel"
    navItem.rightBarButtonItems = [
      UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"),
        menu: UIMenu(children: [
          UIAction(title: "Check for updates", image: UIImage(systemName: "arrow.clockwise")) {
            [weak self] _ in self?.send("refresh")
          },
          UIAction(title: "Download unread chapters", image: UIImage(systemName: "arrow.down.circle")) {
            [weak self] _ in self?.send("downloadUnread")
          },
          UIAction(title: "Sort chapters", image: UIImage(systemName: "arrow.up.arrow.down")) {
            [weak self] _ in
            self?.reversed.toggle()
            self?.filter()
          },
          UIAction(title: "Copy novel title", image: UIImage(systemName: "doc.on.doc")) {
            [weak self] _ in UIPasteboard.general.string = self?.info["title"] as? String
          }
        ])),
      UIBarButtonItem(image: UIImage(systemName: favorite ? "heart.fill" : "heart"),
        primaryAction: UIAction { [weak self] _ in self?.send("favorite") })
    ]
    navItem.rightBarButtonItems?.last?.accessibilityLabel =
      favorite ? "Remove from Library" : "Add to Library"
    filter()
  }

  private func filter() {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    visibleChapters = chapters.filter {
      trimmed.isEmpty ||
      ($0["name"] as? String ?? "").localizedCaseInsensitiveContains(trimmed) ||
      ($0["scanlator"] as? String ?? "").localizedCaseInsensitiveContains(trimmed)
    }
    if reversed { visibleChapters.reverse() }
    chapterCountLabel.text = "Chapters · \(visibleChapters.count)"
    table.reloadData()
  }

  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    query = searchText
    filter()
  }
  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
  }

  @objc private func refreshRequested() { send("refresh") }
  @objc private func handleBackSwipe(_ sender: UIScreenEdgePanGestureRecognizer) {
    guard sender.state == .ended,
          sender.translation(in: root).x > 70 else { return }
    send("close")
  }

  func numberOfSections(in tableView: UITableView) -> Int { 2 }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    section == 0 ? 1 : visibleChapters.count
  }
  func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
    section == 1 ? 112 : .leastNormalMagnitude
  }

  func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    section == 1 ? chapterHeader : nil
  }

  private func configureChapterHeader() {
    chapterHeader.backgroundColor = .systemBackground
    chapterCountLabel.font = .preferredFont(forTextStyle: .headline)
    chapterCountLabel.adjustsFontForContentSizeCategory = true
    chapterSortButton.setImage(UIImage(systemName: "arrow.up.arrow.down"), for: .normal)
    chapterSortButton.accessibilityLabel = "Reverse chapter sort order"
    chapterSortButton.addTarget(self, action: #selector(toggleChapterSort), for: .touchUpInside)
    let heading = UIStackView(arrangedSubviews: [chapterCountLabel, chapterSortButton])
    heading.axis = .horizontal
    heading.alignment = .center
    chapterSortButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    chapterSortButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    heading.translatesAutoresizingMaskIntoConstraints = false
    chapterHeader.addSubview(heading)
    chapterHeader.addSubview(search)
    NSLayoutConstraint.activate([
      heading.leadingAnchor.constraint(equalTo: chapterHeader.leadingAnchor, constant: 22),
      heading.trailingAnchor.constraint(equalTo: chapterHeader.trailingAnchor, constant: -18),
      heading.topAnchor.constraint(equalTo: chapterHeader.topAnchor, constant: 6),
      heading.heightAnchor.constraint(equalToConstant: 44),
      search.topAnchor.constraint(equalTo: heading.bottomAnchor),
      search.leadingAnchor.constraint(equalTo: chapterHeader.leadingAnchor, constant: 12),
      search.trailingAnchor.constraint(equalTo: chapterHeader.trailingAnchor, constant: -12),
      search.bottomAnchor.constraint(equalTo: chapterHeader.bottomAnchor, constant: -6)
    ])
  }
  @objc private func toggleChapterSort() {
    reversed.toggle()
    filter()
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    if indexPath.section == 0 {
      let cell = tableView.dequeueReusableCell(withIdentifier: "novel-info", for: indexPath)
        as! NovayomiNovelInfoCell
      cell.configure(info, expanded: descriptionExpanded)
      cell.onRead = { [weak self] in self?.send("resume") }
      cell.onCover = { [weak self] image in
        guard let image else { return }
        let viewer = UINavigationController(rootViewController: NovayomiCoverViewer(image: image))
        viewer.modalPresentationStyle = .fullScreen
        viewer.overrideUserInterfaceStyle = .dark
        self?.presentNative(viewer)
      }
      cell.onExpand = { [weak self] in
        guard let self else { return }
        self.descriptionExpanded.toggle()
        self.table.reloadRows(at: [indexPath], with: .automatic)
      }
      return cell
    }
    let chapter = visibleChapters[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "novel-chapter", for: indexPath)
    cell.backgroundColor = .systemBackground
    var configuration = UIListContentConfiguration.subtitleCell()
    configuration.text = chapter["name"] as? String ?? "Chapter"
    let isRead = chapter["read"] as? Bool ?? false
    let bookmarked = chapter["bookmark"] as? Bool ?? false
    let downloaded = chapter["downloaded"] as? Bool ?? false
    configuration.image = UIImage(systemName: bookmarked ? "bookmark.fill" : downloaded ? "arrow.down.circle.fill" : "doc.text")
    configuration.imageProperties.tintColor = bookmarked ? .systemBlue : downloaded ? .systemGreen : .tertiaryLabel
    configuration.secondaryText = [
      chapter["date"] as? String ?? "",
      chapter["scanlator"] as? String ?? "",
      isRead ? "Read" : "Unread"
    ].filter { !$0.isEmpty }.joined(separator: " · ")
    configuration.textProperties.color = isRead ? .secondaryLabel : .label
    configuration.textProperties.numberOfLines = 2
    configuration.secondaryTextProperties.numberOfLines = 1
    cell.contentConfiguration = configuration
    let id = chapter["id"] as? Int ?? -1
    cell.accessoryView = nil
    let button = UIButton(type: .system)
    button.setImage(UIImage(systemName: "ellipsis"), for: .normal)
    button.accessibilityLabel = "Chapter actions"
    button.showsMenuAsPrimaryAction = true
    button.menu = UIMenu(children: [
      UIAction(title: isRead ? "Mark unread" : "Mark read",
        image: UIImage(systemName: isRead ? "circle" : "checkmark.circle")) {
        [weak self] _ in self?.send("toggleRead", id)
      },
      UIAction(title: bookmarked ? "Remove bookmark" : "Bookmark",
        image: UIImage(systemName: "bookmark")) {
        [weak self] _ in self?.send("toggleBookmark", id)
      },
      UIAction(title: downloaded ? "Downloaded" : "Download chapter",
        image: UIImage(systemName: "arrow.down.circle"),
        attributes: downloaded ? [.disabled] : []) {
        [weak self] _ in self?.send("download", id)
      }
    ])
    button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
    cell.accessoryView = button
    cell.accessibilityHint = "Double tap to read"
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if indexPath.section == 0 {
      send("resume")
    } else if visibleChapters.indices.contains(indexPath.row),
              let id = visibleChapters[indexPath.row]["id"] as? Int {
      send("read", id)
    }
  }

  func tableView(_ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
    guard indexPath.section == 1, visibleChapters.indices.contains(indexPath.row),
          let id = visibleChapters[indexPath.row]["id"] as? Int else { return nil }
    let read = visibleChapters[indexPath.row]["read"] as? Bool ?? false
    let mark = UIContextualAction(style: .normal, title: read ? "Unread" : "Read") {
      [weak self] _, _, completion in
      self?.send("toggleRead", id)
      completion(true)
    }
    mark.backgroundColor = .systemBlue
    let download = UIContextualAction(style: .normal, title: "Download") {
      [weak self] _, _, completion in
      self?.send("download", id)
      completion(true)
    }
    download.backgroundColor = .systemTeal
    return UISwipeActionsConfiguration(actions: [download, mark])
  }

  private func presentNative(_ child: UIViewController) {
    guard var presenter = root.window?.rootViewController else { return }
    while let next = presenter.presentedViewController { presenter = next }
    presenter.present(child, animated: true)
  }
}

/// The native header reads existing Manga fields without a second backend.
private final class NovayomiNovelInfoCell: UITableViewCell {
  var onRead: (() -> Void)?
  var onCover: ((UIImage?) -> Void)?
  var onExpand: (() -> Void)?
  private let cover = UIImageView()
  private let heading = UILabel()
  private let detail = UILabel()
  private let descriptionLabel = UILabel()
  private let genreScroll = UIScrollView()
  private let genreStack = UIStackView()
  private let expandButton = UIButton(type: .system)
  private let readButton = UIButton(type: .system)
  private var coverRequest: URLSessionDataTask?
  private var coverKey: String = ""

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    cover.layer.cornerRadius = 12
    cover.clipsToBounds = true
    cover.contentMode = .scaleAspectFill
    cover.isUserInteractionEnabled = true
    cover.addGestureRecognizer(UITapGestureRecognizer(target: self,
      action: #selector(coverTapped)))
    cover.accessibilityTraits = [.image, .button]
    cover.accessibilityLabel = "Show full-size novel cover"
    cover.backgroundColor = .secondarySystemGroupedBackground
    cover.translatesAutoresizingMaskIntoConstraints = false
    cover.widthAnchor.constraint(equalToConstant: 112).isActive = true
    cover.heightAnchor.constraint(equalToConstant: 164).isActive = true

    heading.font = .preferredFont(forTextStyle: .title2)
    heading.font = .systemFont(ofSize: 25, weight: .bold)
    heading.numberOfLines = 3
    heading.adjustsFontForContentSizeCategory = true
    detail.font = .preferredFont(forTextStyle: .subheadline)
    detail.textColor = .secondaryLabel
    detail.numberOfLines = 3
    descriptionLabel.font = .preferredFont(forTextStyle: .body)
    descriptionLabel.numberOfLines = 0
    descriptionLabel.adjustsFontForContentSizeCategory = true
    genreScroll.showsHorizontalScrollIndicator = false
    genreScroll.alwaysBounceHorizontal = true
    genreScroll.heightAnchor.constraint(equalToConstant: 34).isActive = true
    genreStack.axis = .horizontal
    genreStack.alignment = .center
    genreStack.spacing = 8
    genreStack.translatesAutoresizingMaskIntoConstraints = false
    genreScroll.addSubview(genreStack)
    NSLayoutConstraint.activate([
      genreStack.leadingAnchor.constraint(equalTo: genreScroll.contentLayoutGuide.leadingAnchor),
      genreStack.trailingAnchor.constraint(equalTo: genreScroll.contentLayoutGuide.trailingAnchor),
      genreStack.topAnchor.constraint(equalTo: genreScroll.contentLayoutGuide.topAnchor),
      genreStack.bottomAnchor.constraint(equalTo: genreScroll.contentLayoutGuide.bottomAnchor),
      genreStack.heightAnchor.constraint(equalTo: genreScroll.frameLayoutGuide.heightAnchor)
    ])
    expandButton.setTitle("Show more", for: .normal)
    expandButton.contentHorizontalAlignment = .leading
    expandButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
    expandButton.addTarget(self, action: #selector(expandTapped), for: .touchUpInside)
    readButton.configuration = .filled()
    readButton.configuration?.cornerStyle = .large
    readButton.setTitle("Continue reading", for: .normal)
    readButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    readButton.addTarget(self, action: #selector(readTapped), for: .touchUpInside)

    let right = UIStackView(arrangedSubviews: [heading, detail])
    right.axis = .vertical
    right.spacing = 12
    right.alignment = .leading
    let row = UIStackView(arrangedSubviews: [cover, right])
    row.axis = .horizontal
    row.alignment = .top
    row.spacing = 14
    let column = UIStackView(arrangedSubviews: [row, descriptionLabel, expandButton, genreScroll, readButton])
    column.axis = .vertical
    column.spacing = 14
    column.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(column)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor, constant: 6),
      column.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor, constant: -6),
      column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
      column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22)
    ])
  }
  required init?(coder: NSCoder) { fatalError("Storyboard unsupported") }

  override func prepareForReuse() {
    super.prepareForReuse()
    coverRequest?.cancel()
    coverRequest = nil
    coverKey = ""
    cover.image = UIImage(systemName: "book.closed")
    onRead = nil
    onCover = nil
    onExpand = nil
  }

  func configure(_ data: [String: Any], expanded: Bool) {
    heading.text = data["title"] as? String ?? "Untitled"
    let info = [
      data["author"] as? String ?? "",
      data["status"] as? String ?? "",
      data["source"] as? String ?? ""
    ].filter { !$0.isEmpty }
    detail.text = info.joined(separator: "\n")
    let html = data["description"] as? String ?? ""
    let plain = html.replacingOccurrences(of: "<[^>]+>", with: " ",
       options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    descriptionLabel.text = plain
    descriptionLabel.numberOfLines = expanded ? 0 : 4
    descriptionLabel.isHidden = plain.isEmpty
    expandButton.isHidden = plain.count < 180
    expandButton.setTitle(expanded ? "Show less" : "Show more", for: .normal)
    for chip in genreStack.arrangedSubviews {
      genreStack.removeArrangedSubview(chip)
      chip.removeFromSuperview()
    }
    let labels = Array((data["genres"] as? [String] ?? []).prefix(12))
    genreScroll.isHidden = labels.isEmpty
    for name in labels where !name.isEmpty {
      let chip = UIButton(type: .system)
      var configuration = UIButton.Configuration.gray()
      configuration.title = name
      configuration.cornerStyle = .capsule
      configuration.contentInsets = NSDirectionalEdgeInsets(
        top: 5, leading: 12, bottom: 5, trailing: 12)
      chip.configuration = configuration
      chip.isUserInteractionEnabled = false
      chip.accessibilityLabel = name
      genreStack.addArrangedSubview(chip)
    }
    genreScroll.setContentOffset(.zero, animated: false)
    readButton.setTitle(data["readChapterId"] == nil ? "Start reading" : "Continue reading",
                        for: .normal)
    readButton.isEnabled = (data["chapterCount"] as? Int ?? 0) > 0

    cover.image = UIImage(systemName: "book.closed")
    if let bytes = (data["coverBytes"] as? FlutterStandardTypedData)?.data,
       let image = UIImage(data: bytes) {
      cover.image = image
      return
    }
    guard let name = data["cover"] as? String, let url = URL(string: name),
          ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
    coverKey = name
    var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad,
                             timeoutInterval: 16)
    for (key, value) in data["headers"] as? [String: String] ?? [:] {
      request.setValue(value, forHTTPHeaderField: key)
    }
    coverRequest = URLSession.shared.dataTask(with: request) { [weak self] content, _, _ in
      guard let content, let img = UIImage(data: content) else { return }
      DispatchQueue.main.async {
        guard let self, self.coverKey == name else { return }
        self.cover.image = img
      }
    }
    coverRequest?.resume()
  }
  @objc private func readTapped() { onRead?() }
  @objc private func coverTapped() { onCover?(cover.image) }
  @objc private func expandTapped() { onExpand?() }
}

private final class NovayomiCoverViewer: UIViewController, UIScrollViewDelegate {
  private let artwork: UIImage
  private let scroll = UIScrollView()
  private let imageView = UIImageView()

  init(image: UIImage) {
    artwork = image
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("Storyboards are not supported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    title = "Cover"
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "xmark"), style: .plain,
      target: self, action: #selector(close))
    scroll.minimumZoomScale = 1
    scroll.maximumZoomScale = 4
    scroll.delegate = self
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll)
    imageView.image = artwork
    imageView.contentMode = .scaleAspectFit
    imageView.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(imageView)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: view.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
      imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
      imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor)
    ])
    let doubleTap = UITapGestureRecognizer(target: self,
      action: #selector(toggleZoom(_:)))
    doubleTap.numberOfTapsRequired = 2
    scroll.addGestureRecognizer(doubleTap)
    let dismissSwipe = UISwipeGestureRecognizer(target: self,
      action: #selector(close))
    dismissSwipe.direction = .down
    view.addGestureRecognizer(dismissSwipe)
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
  @objc private func toggleZoom(_ recognizer: UITapGestureRecognizer) {
    let scale: CGFloat = scroll.zoomScale > 1 ? 1 : 2.5
    scroll.setZoomScale(scale, animated: true)
  }
  @objc private func close() { dismiss(animated: true) }
}
