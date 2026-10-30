import Flutter
import UIKit

/// Native UIKit download queue. Download state, retries, cancellation and
/// physical files remain managed by the existing Dart download services.
final class NovayomiNativeDownloadsFactory: NSObject, FlutterPlatformViewFactory {
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
    NovayomiNativeDownloadsView(frame: frame, id: viewId, messenger: messenger,
                                data: args as? [String: Any] ?? [:])
  }
}

private final class NovayomiNativeDownloadsView: NSObject, FlutterPlatformView,
    UITableViewDataSource, UITableViewDelegate {
  private let root: UIView
  private let channel: FlutterMethodChannel
  private let nav = UINavigationBar()
  private let navigation = UINavigationItem(title: "Download Queue")
  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private var items: [[String: Any]] = []

  init(frame: CGRect, id: Int64, messenger: FlutterBinaryMessenger, data: [String: Any]) {
    root = UIView(frame: frame)
    channel = FlutterMethodChannel(name: "novayomi/native-downloads/\(id)",
                                   binaryMessenger: messenger)
    super.init()
    root.backgroundColor = .systemGroupedBackground
    nav.translatesAutoresizingMaskIntoConstraints = false
    navigation.leftBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "chevron.backward"),
      primaryAction: UIAction { [weak self] _ in
        self?.channel.invokeMethod("close", arguments: nil)
      })
    navigation.leftBarButtonItem?.accessibilityLabel = "Back"
    navigation.rightBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "play.fill"),
      primaryAction: UIAction { [weak self] _ in
        self?.channel.invokeMethod("resumeAll", arguments: nil)
      })
    navigation.rightBarButtonItem?.accessibilityLabel = "Resume all downloads"
    nav.setItems([navigation], animated: false)
    root.addSubview(nav)
    table.dataSource = self
    table.delegate = self
    table.rowHeight = 84
    table.backgroundColor = .clear
    table.translatesAutoresizingMaskIntoConstraints = false
    table.isEditing = false
    root.addSubview(table)
    NSLayoutConstraint.activate([
      nav.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      nav.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      nav.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
      table.topAnchor.constraint(equalTo: nav.bottomAnchor),
      table.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      table.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      table.bottomAnchor.constraint(equalTo: root.bottomAnchor)
    ])
    apply(data)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      if call.method == "update", let data = call.arguments as? [String: Any] {
        self.apply(data)
        result(nil)
      } else if call.method == "error" {
        let alert = UIAlertController(title: "Download action failed",
          message: call.arguments as? String, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.present(alert)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }
  deinit { channel.setMethodCallHandler(nil) }
  func view() -> UIView { root }

  private func present(_ child: UIViewController) {
    guard var parent = root.window?.rootViewController else { return }
    while let next = parent.presentedViewController { parent = next }
    parent.present(child, animated: true)
  }

  private func apply(_ data: [String: Any]) {
    items = data["items"] as? [[String: Any]] ?? []
    navigation.title = "Download Queue · \(items.count)"
    navigation.rightBarButtonItem?.isEnabled = !items.isEmpty
    table.reloadData()
    let empty = UILabel()
    empty.text = "No pending downloads"
    empty.textColor = .secondaryLabel
    empty.textAlignment = .center
    table.backgroundView = items.isEmpty ? empty : nil
  }

  func numberOfSections(in tableView: UITableView) -> Int { 1 }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    items.count
  }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let item = items[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "download")
      ?? UITableViewCell(style: .subtitle, reuseIdentifier: "download")
    let done = item["done"] as? Int ?? 0
    let failed = item["failed"] as? Int ?? 0
    let total = item["total"] as? Int ?? 0
    var config = cell.defaultContentConfiguration()
    config.text = item["chapter"] as? String ?? "Chapter"
    config.secondaryText = [
      item["book"] as? String ?? "",
      total > 0 ? "\(done) / \(total) · \(failed) failed" : "Waiting"
    ].filter { !$0.isEmpty }.joined(separator: " · ")
    config.secondaryTextProperties.numberOfLines = 2
    config.image = UIImage(systemName: failed > 0 ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.down.circle")
    config.imageProperties.tintColor = failed > 0 ? .systemOrange : root.tintColor
    cell.contentConfiguration = config
    let button = UIButton(type: .system)
    button.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
    button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
    button.accessibilityLabel = "Download actions"
    button.showsMenuAsPrimaryAction = true
    guard let id = item["id"] as? Int else { return cell }
    button.menu = UIMenu(children: [
      UIAction(title: "Retry / Resume", image: UIImage(systemName: "play.fill")) { [weak self] _ in
        self?.channel.invokeMethod("resume", arguments: id)
      },
      UIAction(title: "Cancel", image: UIImage(systemName: "xmark.circle"), attributes: .destructive) {
        [weak self] _ in
        self?.channel.invokeMethod("cancel", arguments: id)
      },
      UIAction(title: "Cancel series downloads", image: UIImage(systemName: "trash"), attributes: .destructive) {
        [weak self] _ in self?.confirmCancelSeries(id: id)
      }
    ])
    cell.accessoryView = button
    return cell
  }
  private func confirmCancelSeries(id: Int) {
    let alert = UIAlertController(title: "Cancel downloads for this novel?",
      message: "The queued downloads for this series will be cancelled.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Keep", style: .cancel))
    alert.addAction(UIAlertAction(title: "Cancel downloads", style: .destructive) { [weak self] _ in
      self?.channel.invokeMethod("cancelSeries", arguments: id)
    })
    present(alert)
  }

  func tableView(_ tableView: UITableView,
                 trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
    guard let id = items[indexPath.row]["id"] as? Int else { return nil }
    let action = UIContextualAction(style: .destructive, title: "Cancel") { [weak self] _, _, done in
      self?.channel.invokeMethod("cancel", arguments: id)
      done(true)
    }
    return UISwipeActionsConfiguration(actions: [action])
  }
}
