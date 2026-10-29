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
  private var toolbar: UIToolbar?
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
      let control = UINavigationBar(frame: .zero)
      control.isTranslucent = true
      navigation = control
      mount(control)
    case "readerToolbar":
      let control = UIToolbar(frame: .zero)
      control.isTranslucent = true
      toolbar = control
      mount(control)
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
      configureReaderNavigation(args)
    case "readerToolbar":
      configureReaderToolbar(args)
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
