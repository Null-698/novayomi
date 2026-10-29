import Flutter
import UIKit

/// UIKit system bars hosted directly in the iOS view hierarchy.
/// No Flutter blur, fake glass shaders, or custom glass colors are used.
final class NovayomiNativeBarFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return NovayomiNativeBar(
      frame: frame,
      viewId: viewId,
      args: args as? [String: Any] ?? [:],
      messenger: messenger
    )
  }
}

private final class NovayomiNativeBar: NSObject, FlutterPlatformView, UITabBarDelegate {
  private let container: UIView
  private let channel: FlutterMethodChannel
  private let kind: String
  private var tabs: UITabBar?
  private var navigation: UINavigationBar?
  private var readerTop: NovayomiReaderTopView?
  private var toolbar: UIToolbar?
  private var readerBottom: NovayomiReaderBottomView?
  private var currentTabs: [UITabBarItem] = []
  private var canOpenWeb = false
  private var canRefresh = false

  init(frame: CGRect, viewId: Int64, args: [String: Any], messenger: FlutterBinaryMessenger) {
    container = UIView(frame: frame)
    container.backgroundColor = .clear
    kind = args["kind"] as? String ?? ""
    channel = FlutterMethodChannel(
      name: "novayomi/native-bar/\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    switch kind {
    case "tabs":
      let control = UITabBar(frame: .zero)
      control.delegate = self
      control.isTranslucent = true
      tabs = control
      mount(control)
    case "readerTop":
      let control = NovayomiReaderTopView(frame: .zero)
      control.onAction = { [weak self] action in self?.emit(action) }
      readerTop = control
      mount(control)
    case "readerToolbar":
      let control = UIToolbar(frame: .zero)
      control.isTranslucent = true
      toolbar = control
      mount(control)
    case "readerBottom":
      let control = NovayomiReaderBottomView(frame: .zero)
      control.onAction = { [weak self] action in self?.emit(action) }
      control.onSeek = { [weak self] progress in
        self?.channel.invokeMethod("seek", arguments: progress)
      }
      readerBottom = control
      mount(control)
    case "readerEdgeTop":
      mount(NovayomiReaderEdgeView(top: true))
    case "readerEdgeBottom":
      mount(NovayomiReaderEdgeView(top: false))
    default:
      break
    }

    update(args)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "disposed", message: "Native bar released", details: nil))
        return
      }
      if call.method == "update", let data = call.arguments as? [String: Any] {
        self.update(data)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView { container }

  private func mount(_ control: UIView) {
    control.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(control)
    NSLayoutConstraint.activate([
      control.topAnchor.constraint(equalTo: container.topAnchor),
      control.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      control.bottomAnchor.constraint(equalTo: container.bottomAnchor)
    ])
  }

  private func update(_ args: [String: Any]) {
    switch kind {
    case "tabs":
      guard let bar = tabs else { return }
      let entries = args["items"] as? [[String: Any]] ?? []
      let items: [UITabBarItem] = entries.enumerated().map { index, entry in
        let title = entry["title"] as? String ?? ""
        let symbol = entry["symbol"] as? String ?? "square.grid.2x2"
        let item = UITabBarItem(
          title: title,
          image: UIImage(systemName: symbol),
          selectedImage: UIImage(systemName: symbol + ".fill") ?? UIImage(systemName: symbol)
        )
        item.tag = index
        return item
      }
      currentTabs = items
      bar.setItems(items, animated: false)
      let selected = args["selected"] as? Int ?? 0
      bar.selectedItem = items.indices.contains(selected) ? items[selected] : items.first
    case "readerTop":
      readerTop?.update(args)
    case "readerToolbar":
      configureReaderToolbar(args)
    case "readerBottom":
      readerBottom?.update(args)
    default:
      break
    }
  }

  private func configureReaderNavigation(_ args: [String: Any]) {
    guard let bar = navigation else { return }
    let title = args["title"] as? String ?? ""
    let subtitle = args["subtitle"] as? String ?? ""
    canOpenWeb = args["canOpenWeb"] as? Bool ?? false
    canRefresh = args["canRefresh"] as? Bool ?? false
    let item = UINavigationItem(title: title)

    let heading = UILabel()
    heading.text = title
    heading.font = .preferredFont(forTextStyle: .headline)
    heading.lineBreakMode = .byTruncatingTail
    heading.textAlignment = .center
    let subheading = UILabel()
    subheading.text = subtitle
    subheading.font = .preferredFont(forTextStyle: .caption1)
    subheading.textColor = .secondaryLabel
    subheading.lineBreakMode = .byTruncatingTail
    subheading.textAlignment = .center
    let titles = UIStackView(arrangedSubviews: [heading, subheading])
    titles.axis = .vertical
    titles.alignment = .center
    titles.spacing = 1
    item.titleView = titles

    item.leftBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "chevron.backward"),
      style: .plain,
      target: self,
      action: #selector(backPressed)
    )

    let saved = args["bookmarked"] as? Bool ?? false
    let bookmark = UIBarButtonItem(
      image: UIImage(systemName: saved ? "bookmark.fill" : "bookmark"),
      style: .plain,
      target: self,
      action: #selector(bookmarkPressed)
    )
    var trailing = [bookmark]
    var actions: [UIAction] = []
    if canRefresh {
      actions.append(UIAction(title: "Reload", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
        self?.emit("refresh")
      })
    }
    if canOpenWeb {
      actions.append(UIAction(title: "Open in Web View", image: UIImage(systemName: "globe")) { [weak self] _ in
        self?.emit("web")
      })
    }
    if !actions.isEmpty {
      trailing.append(UIBarButtonItem(
        image: UIImage(systemName: "ellipsis.circle"),
        menu: UIMenu(children: actions)
      ))
    }
    item.rightBarButtonItems = trailing
    bar.setItems([item], animated: false)
  }

  private func configureReaderToolbar(_ args: [String: Any]) {
    guard let bar = toolbar else { return }
    let options: [(String, String)] = [
      ("chapters", "list.number"),
      ("font", "textformat.size"),
      ("layout", args["layoutSymbol"] as? String ?? "book"),
      ("tts", "waveform"),
      ("settings", "slider.horizontal.3")
    ]
    let allowTts = args["ttsSupported"] as? Bool ?? false
    var items = [UIBarButtonItem]()
    for (index, pair) in options.enumerated() {
      if pair.0 == "tts" && !allowTts { continue }
      if !items.isEmpty {
        items.append(UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil))
      }
      let button = UIBarButtonItem(
        image: UIImage(systemName: pair.1),
        style: .plain,
        target: self,
        action: #selector(readerAction(_:))
      )
      button.tag = index
      button.accessibilityLabel = pair.0
      if pair.0 == "tts" && (args["ttsActive"] as? Bool ?? false) {
        button.tintColor = .systemBlue
      }
      items.append(button)
    }
    bar.setItems(items, animated: false)
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    channel.invokeMethod("select", arguments: item.tag)
  }

  @objc private func backPressed() { emit("back") }
  @objc private func bookmarkPressed() { emit("bookmark") }
  @objc private func readerAction(_ sender: UIBarButtonItem) {
    let actions = ["chapters", "font", "layout", "tts", "settings"]
    guard actions.indices.contains(sender.tag) else { return }
    emit(actions[sender.tag])
  }

  private func emit(_ action: String) {
    channel.invokeMethod("action", arguments: action)
  }
}


/// Platform-native blur at the content edge. Flutter's scroll view is not a
/// UIKit UIScrollView, so it cannot participate in the automatic scroll-edge
/// interaction. This native material is graduated to let the book run beneath
/// the status bar and reader controls without having text clash with them.
private final class NovayomiReaderEdgeView: UIView {
  private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
  private let gradient = CAGradientLayer()

  init(top: Bool) {
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    blur.translatesAutoresizingMaskIntoConstraints = false
    addSubview(blur)
    NSLayoutConstraint.activate([
      blur.topAnchor.constraint(equalTo: topAnchor),
      blur.bottomAnchor.constraint(equalTo: bottomAnchor),
      blur.leadingAnchor.constraint(equalTo: leadingAnchor),
      blur.trailingAnchor.constraint(equalTo: trailingAnchor)
    ])
    // Fade native blur away from the actual controls; no solid opaque bar.
    gradient.colors = top
      ? [UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
      : [UIColor.clear.cgColor, UIColor.white.cgColor, UIColor.white.cgColor]
    gradient.locations = top ? [0, 0.38, 1] : [0, 0.62, 1]
    gradient.startPoint = CGPoint(x: 0.5, y: 0)
    gradient.endPoint = CGPoint(x: 0.5, y: 1)
    blur.layer.mask = gradient
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    gradient.frame = blur.bounds
  }
}

/// A unified reader control surface backed by *real* UIKit system glass.
/// UIGlassEffect(.regular) follows the platform's own iOS 26/27 appearance,
/// accessibility settings, and iOS 27 frosted-glass preference.
private final class NovayomiReaderBottomView: UIView {
  var onAction: ((String) -> Void)?
  var onSeek: ((Double) -> Void)?

  private let glass: UIVisualEffectView
  private let previous = UIButton(type: .system)
  private let nextChapterButton = UIButton(type: .system)
  private let progress = UISlider()
  private let currentLabel = UILabel()
  private let totalLabel = UILabel()
  private var actions: [String: UIButton] = [:]

  override init(frame: CGRect) {
    if #available(iOS 26.0, *) {
      glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    } else {
      glass = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    }
    super.init(frame: frame)
    backgroundColor = .clear

    glass.translatesAutoresizingMaskIntoConstraints = false
    if #available(iOS 26.0, *) {
      glass.cornerConfiguration = .corners(radius: 26)
    } else {
      glass.layer.cornerRadius = 26
      glass.clipsToBounds = true
    }
    addSubview(glass)
    NSLayoutConstraint.activate([
      glass.leadingAnchor.constraint(equalTo: leadingAnchor),
      glass.trailingAnchor.constraint(equalTo: trailingAnchor),
      glass.topAnchor.constraint(equalTo: topAnchor),
      glass.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])

    configureButton(previous, symbol: "backward.end.fill", identifier: "previousChapter")
    configureButton(nextChapterButton, symbol: "forward.end.fill", identifier: "nextChapter")
    for label in [currentLabel, totalLabel] {
      label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
      label.textColor = .label
      label.textAlignment = .center
      label.setContentCompressionResistancePriority(.required, for: .horizontal)
      label.widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
    }
    progress.minimumValue = 0
    progress.maximumValue = 1
    progress.minimumTrackTintColor = .label
    progress.maximumTrackTintColor = .tertiaryLabel
    progress.accessibilityLabel = "Reading progress"
    progress.addTarget(self, action: #selector(seekChanged(_:)), for: .valueChanged)

    let top = UIStackView(arrangedSubviews: [
      previous, currentLabel, progress, totalLabel, nextChapterButton
    ])
    top.axis = .horizontal
    top.alignment = .center
    top.spacing = 7
    top.translatesAutoresizingMaskIntoConstraints = false

    let symbols: [(String, String)] = [
      ("chapters", "list.number"), ("font", "textformat.size"),
      ("layout", "book.closed"), ("tts", "waveform"),
      ("settings", "slider.horizontal.3")
    ]
    let bottom = UIStackView()
    bottom.axis = .horizontal
    bottom.distribution = .fillEqually
    bottom.alignment = .center
    bottom.translatesAutoresizingMaskIntoConstraints = false
    for (name, symbol) in symbols {
      let button = UIButton(type: .system)
      configureButton(button, symbol: symbol, identifier: name)
      actions[name] = button
      bottom.addArrangedSubview(button)
    }

    glass.contentView.addSubview(top)
    glass.contentView.addSubview(bottom)
    NSLayoutConstraint.activate([
      top.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 10),
      top.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -10),
      top.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 9),
      top.heightAnchor.constraint(equalToConstant: 44),
      bottom.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 8),
      bottom.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -8),
      bottom.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 4),
      bottom.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -8)
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

  private func configureButton(_ button: UIButton, symbol: String, identifier: String) {
    button.setImage(UIImage(systemName: symbol), for: .normal)
    button.tintColor = .label
    button.accessibilityIdentifier = identifier
    button.accessibilityLabel = identifier
    button.addTarget(self, action: #selector(buttonPressed(_:)), for: .touchUpInside)
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
    button.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
  }

  func update(_ args: [String: Any]) {
    currentLabel.text = args["current"] as? String ?? ""
    totalLabel.text = args["total"] as? String ?? ""
    if !progress.isTracking {
      progress.value = Float(min(max(args["progress"] as? Double ?? 0, 0), 1))
    }
    previous.isEnabled = args["hasPrevious"] as? Bool ?? false
    nextChapterButton.isEnabled = args["hasNext"] as? Bool ?? false
    actions["tts"]?.isHidden = !(args["ttsSupported"] as? Bool ?? false)
    actions["tts"]?.tintColor = (args["ttsActive"] as? Bool ?? false)
      ? .systemBlue : .label
    let layoutSymbol = args["layoutSymbol"] as? String ?? "book.closed"
    actions["layout"]?.setImage(UIImage(systemName: layoutSymbol), for: .normal)
  }

  @objc private func buttonPressed(_ sender: UIButton) {
    guard sender.isEnabled, let action = sender.accessibilityIdentifier else { return }
    onAction?(action)
  }

  @objc private func seekChanged(_ sender: UISlider) {
    onSeek?(Double(sender.value))
  }
}



/// Each iOS reader control group has its own real system glass surface.
/// The center title is also backed by glass, so novel text cannot show
/// through the title or its subtitle as it scrolls under the top controls.
private final class NovayomiReaderTopView: UIView {
  var onAction: ((String) -> Void)?

  private let back = UIButton(type: .system)
  private let bookmark = UIButton(type: .system)
  private let more = UIButton(type: .system)
  private let title = UILabel()
  private let subtitle = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear

    let leadingGlass = makeGlass()
    let titleGlass = makeGlass()
    let trailingGlass = makeGlass()
    [leadingGlass, titleGlass, trailingGlass].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      addSubview($0)
    }

    back.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
    back.accessibilityLabel = "Back"
    back.addTarget(self, action: #selector(goBack), for: .touchUpInside)

    bookmark.setImage(UIImage(systemName: "bookmark"), for: .normal)
    bookmark.accessibilityLabel = "Bookmark"
    bookmark.addTarget(self, action: #selector(toggleBookmark), for: .touchUpInside)

    more.setImage(UIImage(systemName: "ellipsis"), for: .normal)
    more.accessibilityLabel = "More options"
    more.showsMenuAsPrimaryAction = true

    [back, bookmark, more].forEach {
      $0.tintColor = .label
      $0.translatesAutoresizingMaskIntoConstraints = false
    }
    leadingGlass.contentView.addSubview(back)

    let actions = UIStackView(arrangedSubviews: [more, bookmark])
    actions.axis = .horizontal
    actions.distribution = .fillEqually
    actions.translatesAutoresizingMaskIntoConstraints = false
    trailingGlass.contentView.addSubview(actions)

    title.font = .preferredFont(forTextStyle: .subheadline)
    title.textColor = .label
    title.textAlignment = .center
    title.lineBreakMode = .byTruncatingTail
    subtitle.font = .preferredFont(forTextStyle: .caption2)
    subtitle.textColor = .secondaryLabel
    subtitle.textAlignment = .center
    subtitle.lineBreakMode = .byTruncatingTail

    let labels = UIStackView(arrangedSubviews: [title, subtitle])
    labels.axis = .vertical
    labels.alignment = .fill
    labels.spacing = 0
    labels.translatesAutoresizingMaskIntoConstraints = false
    titleGlass.contentView.addSubview(labels)

    NSLayoutConstraint.activate([
      leadingGlass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      leadingGlass.centerYAnchor.constraint(equalTo: centerYAnchor),
      leadingGlass.widthAnchor.constraint(equalToConstant: 50),
      leadingGlass.heightAnchor.constraint(equalToConstant: 48),

      trailingGlass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      trailingGlass.centerYAnchor.constraint(equalTo: centerYAnchor),
      trailingGlass.widthAnchor.constraint(equalToConstant: 100),
      trailingGlass.heightAnchor.constraint(equalToConstant: 48),

      titleGlass.leadingAnchor.constraint(equalTo: leadingGlass.trailingAnchor, constant: 8),
      titleGlass.trailingAnchor.constraint(equalTo: trailingGlass.leadingAnchor, constant: -8),
      titleGlass.centerYAnchor.constraint(equalTo: centerYAnchor),
      titleGlass.heightAnchor.constraint(equalToConstant: 48),

      back.leadingAnchor.constraint(equalTo: leadingGlass.contentView.leadingAnchor),
      back.trailingAnchor.constraint(equalTo: leadingGlass.contentView.trailingAnchor),
      back.topAnchor.constraint(equalTo: leadingGlass.contentView.topAnchor),
      back.bottomAnchor.constraint(equalTo: leadingGlass.contentView.bottomAnchor),

      actions.leadingAnchor.constraint(equalTo: trailingGlass.contentView.leadingAnchor),
      actions.trailingAnchor.constraint(equalTo: trailingGlass.contentView.trailingAnchor),
      actions.topAnchor.constraint(equalTo: trailingGlass.contentView.topAnchor),
      actions.bottomAnchor.constraint(equalTo: trailingGlass.contentView.bottomAnchor),

      labels.leadingAnchor.constraint(equalTo: titleGlass.contentView.leadingAnchor, constant: 8),
      labels.trailingAnchor.constraint(equalTo: titleGlass.contentView.trailingAnchor, constant: -8),
      labels.centerYAnchor.constraint(equalTo: titleGlass.contentView.centerYAnchor)
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

  private func makeGlass() -> UIVisualEffectView {
    let view: UIVisualEffectView
    if #available(iOS 26.0, *) {
      view = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
      view.cornerConfiguration = .capsule()
    } else {
      view = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
      view.layer.cornerRadius = 24
      view.clipsToBounds = true
    }
    return view
  }

  func update(_ args: [String: Any]) {
    title.text = args["title"] as? String ?? ""
    subtitle.text = args["subtitle"] as? String ?? ""
    let saved = args["bookmarked"] as? Bool ?? false
    bookmark.setImage(UIImage(systemName: saved ? "bookmark.fill" : "bookmark"), for: .normal)
    bookmark.accessibilityLabel = saved ? "Remove bookmark" : "Bookmark"

    var menuActions: [UIAction] = []
    if args["canRefresh"] as? Bool ?? false {
      menuActions.append(UIAction(title: "Reload", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
        self?.onAction?("refresh")
      })
    }
    if args["canOpenWeb"] as? Bool ?? false {
      menuActions.append(UIAction(title: "Open in Web View", image: UIImage(systemName: "globe")) { [weak self] _ in
        self?.onAction?("web")
      })
    }
    more.isEnabled = !menuActions.isEmpty
    more.menu = UIMenu(children: menuActions)
  }

  @objc private func goBack() { onAction?("back") }
  @objc private func toggleBookmark() { onAction?("bookmark") }
}
