import Flutter
import UIKit

/// Reusable UIKit settings form. All values and mutations are provided by
/// the existing Riverpod settings providers in Dart; no Swift persistence.
final class NovayomiNativePreferencesFactory: NSObject, FlutterPlatformViewFactory {
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
    NovayomiNativePreferencesView(frame: frame, id: viewId, messenger: messenger,
                                  data: args as? [String: Any] ?? [:])
  }
}
private final class NovayomiNativePreferencesView: NSObject, FlutterPlatformView,
    UITableViewDataSource, UITableViewDelegate {
  private let root: UIView
  private let channel: FlutterMethodChannel
  private let nav = UINavigationBar()
  private let navigation = UINavigationItem(title: "Settings")
  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private var sections: [[String: Any]] = []
  init(frame: CGRect, id: Int64, messenger: FlutterBinaryMessenger,
       data: [String: Any]) {
    root = UIView(frame: frame)
    channel = FlutterMethodChannel(name: "novayomi/native-preferences/\(id)",
                                   binaryMessenger: messenger)
    super.init()
    root.backgroundColor = .systemGroupedBackground
    navigation.leftBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "chevron.backward"),
      primaryAction: UIAction { [weak self] _ in self?.send("close") })
    navigation.leftBarButtonItem?.accessibilityLabel = "Back to Settings"
    nav.translatesAutoresizingMaskIntoConstraints = false
    nav.setItems([navigation], animated: false)
    root.addSubview(nav)
    table.translatesAutoresizingMaskIntoConstraints = false
    table.backgroundColor = .clear
    table.rowHeight = UITableView.automaticDimension
    table.estimatedRowHeight = 66
    table.dataSource = self
    table.delegate = self
    table.keyboardDismissMode = .onDrag
    root.addSubview(table)
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
      if call.method == "update", let content = call.arguments as? [String: Any] {
        self.apply(content)
        result(nil)
      } else if call.method == "error" {
        let message = call.arguments as? String ?? "Unable to save setting"
        let alert = UIAlertController(title: "Setting failed", message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.present(alert)
        result(nil)
      } else { result(FlutterMethodNotImplemented) }
    }
  }
  deinit { channel.setMethodCallHandler(nil) }
  func view() -> UIView { root }

  private func present(_ child: UIViewController) {
    guard var host = root.window?.rootViewController else { return }
    while let next = host.presentedViewController { host = next }
    host.present(child, animated: true)
  }
  private func send(_ action: String, _ arg: Any? = nil) {
    channel.invokeMethod(action, arguments: arg)
  }
  private func apply(_ data: [String: Any]) {
    navigation.title = data["title"] as? String ?? "Settings"
    sections = data["sections"] as? [[String: Any]] ?? []
    table.reloadData()
  }
  func numberOfSections(in tableView: UITableView) -> Int { sections.count }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    (sections[section]["rows"] as? [[String: Any]] ?? []).count
  }
  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    sections[section]["title"] as? String
  }
  func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    sections[section]["footer"] as? String
  }
  private func row(_ index: IndexPath) -> [String: Any] {
    let items = sections[index.section]["rows"] as? [[String: Any]] ?? []
    return items[index.row]
  }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let data = row(indexPath)
    let cell = tableView.dequeueReusableCell(withIdentifier: "preference")
      ?? UITableViewCell(style: .subtitle, reuseIdentifier: "preference")
    let kind = data["type"] as? String ?? "link"
    let id = data["id"] as? String ?? ""
    let destructive = data["destructive"] as? Bool ?? false
    var content = cell.defaultContentConfiguration()
    content.text = data["title"] as? String ?? id
    content.textProperties.color = destructive ? .systemRed : .label
    content.secondaryText = data["detail"] as? String
    content.secondaryTextProperties.numberOfLines = 2
    if let symbol = data["symbol"] as? String {
      content.image = UIImage(systemName: symbol)
      content.imageProperties.tintColor = destructive ? .systemRed : root.tintColor
    }
    cell.contentConfiguration = content
    cell.accessoryView = nil
    cell.accessoryType = .none
    cell.selectionStyle = kind == "toggle" || kind == "slider" ? .none : .default
    if kind == "toggle" {
      let toggle = UISwitch()
      toggle.isOn = data["value"] as? Bool ?? false
      toggle.accessibilityLabel = content.text
      toggle.addAction(UIAction { [weak self, weak toggle] _ in
        guard let toggle else { return }
        self?.send("change", ["id": id, "value": toggle.isOn])
      }, for: .valueChanged)
      cell.accessoryView = toggle
    } else if kind == "slider" {
      let minValue = Float((data["min"] as? NSNumber)?.doubleValue ?? 0)
      let maxValue = Float((data["max"] as? NSNumber)?.doubleValue ?? 10)
      let current = Float((data["value"] as? NSNumber)?.doubleValue ?? 0)
      let step = Float((data["step"] as? NSNumber)?.doubleValue ?? 1)
      let holder = UIStackView()
      holder.axis = .horizontal
      holder.alignment = .center
      holder.spacing = 5
      let label = UILabel()
      label.text = String(format: step < 1 ? "%.2f" : "%.0f", current)
      label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
      label.textColor = .secondaryLabel
      label.widthAnchor.constraint(equalToConstant: 34).isActive = true
      let slider = UISlider()
      slider.minimumValue = minValue
      slider.maximumValue = maxValue
      slider.value = current
      slider.accessibilityLabel = content.text
      slider.widthAnchor.constraint(equalToConstant: 130).isActive = true
      slider.addAction(UIAction { [weak self, weak slider, weak label] _ in
        guard let slider else { return }
        let tick = step > 0 ? (slider.value / step).rounded() * step : slider.value
        label?.text = String(format: step < 1 ? "%.2f" : "%.0f", tick)
        self?.send("change", ["id": id, "value": Double(tick)])
      }, for: .touchUpInside)
      slider.addAction(UIAction { [weak self, weak slider, weak label] _ in
        guard let slider else { return }
        let tick = step > 0 ? (slider.value / step).rounded() * step : slider.value
        label?.text = String(format: step < 1 ? "%.2f" : "%.0f", tick)
        self?.send("change", ["id": id, "value": Double(tick)])
      }, for: .touchUpOutside)
      holder.addArrangedSubview(slider)
      holder.addArrangedSubview(label)
      cell.accessoryView = holder
    } else if kind == "choice" {
      let choice = UIButton(type: .system)
      choice.setTitle(data["display"] as? String ?? "Select", for: .normal)
      let selections = data["choices"] as? [[String: Any]] ?? []
      choice.menu = UIMenu(children: selections.map { option in
        let key = option["value"] as? String ?? ""
        let name = option["title"] as? String ?? key
        let selected = key == (data["value"] as? String ?? "")
        return UIAction(title: name, state: selected ? .on : .off) { [weak self] _ in
          self?.send("change", ["id": id, "value": key])
        }
      })
      choice.showsMenuAsPrimaryAction = true
      choice.sizeToFit()
      cell.accessoryView = choice
    } else if kind == "text" {
      cell.accessoryType = .disclosureIndicator
    } else {
      cell.accessoryType = .disclosureIndicator
    }
    return cell
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let data = row(indexPath)
    let type = data["type"] as? String ?? "link"
    let id = data["id"] as? String ?? ""
    if type == "text" {
      let alert = UIAlertController(title: data["title"] as? String ?? "Edit",
                                    message: data["detail"] as? String, preferredStyle: .alert)
      alert.addTextField { field in
        field.text = data["value"] as? String ?? ""
        field.clearButtonMode = .whileEditing
      }
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
      alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
        self?.send("change", ["id": id, "value": alert?.textFields?.first?.text ?? ""])
      })
      present(alert)
    } else if type == "credentials" {
      let alert = UIAlertController(title: data["title"] as? String ?? "Log in",
        message: "Your credentials are sent only to the existing service.",
        preferredStyle: .alert)
      alert.addTextField { field in
        field.placeholder = "Email or username"
        field.textContentType = .username
        field.keyboardType = .emailAddress
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
      }
      alert.addTextField { field in
        field.placeholder = "Password"
        field.textContentType = .password
        field.isSecureTextEntry = true
        field.autocorrectionType = .no
      }
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
      alert.addAction(UIAlertAction(title: "Log in", style: .default) { [weak self, weak alert] _ in
        guard let fields = alert?.textFields, fields.count == 2 else { return }
        // Do not store these strings in a snapshot, UserDefaults or logs.
        self?.send("credentials", ["id": id,
          "username": fields[0].text ?? "",
          "password": fields[1].text ?? ""])
      })
      present(alert)
    } else if type == "link" {
      send("navigate", id)
    } else if type == "action" {
      if data["destructive"] as? Bool == true {
        let confirmation = UIAlertController(title: data["title"] as? String ?? "Confirm",
          message: data["detail"] as? String ?? "This cannot be undone",
          preferredStyle: .alert)
        confirmation.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        confirmation.addAction(UIAlertAction(title: "Continue", style: .destructive) { [weak self] _ in
          self?.send("action", id)
        })
        present(confirmation)
      } else { send("action", id) }
    }
  }
}
