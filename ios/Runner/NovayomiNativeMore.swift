import Flutter
import UIKit

/// Phase 2.5 UIKit More tab. Navigation and switches are forwarded to the
/// existing Dart routes/providers; no duplicate settings storage is created.
final class NovayomiNativeMoreFactory: NSObject, FlutterPlatformViewFactory {
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
    NovayomiNativeMoreView(frame: frame, identifier: viewId,
                           messenger: messenger, data: args as? [String: Any] ?? [:])
  }
}

private final class NovayomiNativeMoreView: NSObject, FlutterPlatformView,
    UITableViewDataSource, UITableViewDelegate {
  private struct Item {
    let title: String
    let symbol: String
    let path: String
    let toggle: Bool
    init(_ title: String, _ symbol: String, _ path: String, toggle: Bool = false) {
      self.title = title
      self.symbol = symbol
      self.path = path
      self.toggle = toggle
    }
  }

  private let root: UIView
  private let channel: FlutterMethodChannel
  private let heading = UILabel()
  private let summary = UILabel()
  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private var downloadedOnly = false
  private var incognito = false
  private var showHistory = true
  private var groups: [(String, [Item])] = []

  init(frame: CGRect, identifier: Int64, messenger: FlutterBinaryMessenger,
       data: [String: Any]) {
    root = UIView(frame: frame)
    channel = FlutterMethodChannel(name: "novayomi/native-more/\(identifier)",
                                   binaryMessenger: messenger)
    super.init()
    root.backgroundColor = .systemGroupedBackground
    heading.text = "More"
    heading.font = .preferredFont(forTextStyle: .largeTitle)
    heading.adjustsFontForContentSizeCategory = true
    heading.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(heading)

    summary.textColor = .secondaryLabel
    summary.font = .preferredFont(forTextStyle: .subheadline)
    summary.numberOfLines = 2
    summary.adjustsFontForContentSizeCategory = true
    summary.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(summary)

    table.backgroundColor = .clear
    table.dataSource = self
    table.delegate = self
    table.rowHeight = 54
    table.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(table)
    NSLayoutConstraint.activate([
      heading.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 14),
      heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
      heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
      summary.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
      summary.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
      summary.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
      table.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 8),
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
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }
  deinit { channel.setMethodCallHandler(nil) }
  func view() -> UIView { root }

  private func apply(_ data: [String: Any]) {
    downloadedOnly = data["downloadedOnly"] as? Bool ?? false
    incognito = data["incognito"] as? Bool ?? false
    showHistory = data["showHistory"] as? Bool ?? true
    let series = data["series"] as? Int ?? 0
    let chapters = data["read"] as? Int ?? 0
    let seconds = data["seconds"] as? Int ?? 0
    let time = seconds >= 3600 ? "\(seconds / 3600) h" : "\(seconds / 60) min"
    summary.text = "\(series) novels  ·  \(chapters) chapters read  ·  \(time)"
    var library = [
      Item("Download Queue", "arrow.down.circle", "/downloadQueue"),
      Item("Collections", "folder", "/categories"),
      Item("Statistics", "chart.bar.xaxis", "/statistics"),
      Item("Calendar", "calendar", "/calendarScreen"),
      Item("Mass Migration", "arrow.left.arrow.right", "/massMigration")
    ]
    if showHistory { library.insert(Item("Reading History", "clock.arrow.circlepath", "/history"), at: 0) }
    groups = [
      ("Reading Modes", [
        Item("Downloaded Only", "arrow.down.circle", "downloadedOnly", toggle: true),
        Item("Incognito Mode", "eye.slash", "incognito", toggle: true)
      ]),
      ("Library", library),
      ("Application", [
        Item("Data & Storage", "externaldrive", "/dataAndStorage"),
        Item("Settings", "gearshape", "/settings"),
        Item("About Novayomi", "info.circle", "/about")
      ])
    ]
    table.reloadData()
  }

  func numberOfSections(in tableView: UITableView) -> Int { groups.count }
  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    groups[section].0
  }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    groups[section].1.count
  }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let item = groups[indexPath.section].1[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "native-more")
      ?? UITableViewCell(style: .default, reuseIdentifier: "native-more")
    var content = cell.defaultContentConfiguration()
    content.text = item.title
    content.image = UIImage(systemName: item.symbol)
    content.imageProperties.tintColor = root.tintColor
    cell.contentConfiguration = content
    if item.toggle {
      let toggle = UISwitch()
      toggle.isOn = item.path == "downloadedOnly" ? downloadedOnly : incognito
      toggle.accessibilityLabel = item.title
      toggle.tag = item.path == "downloadedOnly" ? 0 : 1
      toggle.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)
      cell.accessoryView = toggle
      cell.accessoryType = .none
      cell.selectionStyle = .none
    } else {
      cell.accessoryView = nil
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    }
    return cell
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let item = groups[indexPath.section].1[indexPath.row]
    guard !item.toggle else { return }
    channel.invokeMethod("navigate", arguments: item.path)
  }
  @objc private func toggleChanged(_ control: UISwitch) {
    let name = control.tag == 0 ? "downloadedOnly" : "incognito"
    if control.tag == 0 { downloadedOnly = control.isOn }
    else { incognito = control.isOn }
    channel.invokeMethod("mode", arguments: ["name": name, "value": control.isOn])
  }
}
