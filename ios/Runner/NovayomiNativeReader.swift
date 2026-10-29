import UIKit
import WebKit
import AVFoundation

/// Novayomi's sole iOS novel reading surface. The Flutter engine never paints
/// chapter text or supplies a platform-view overlay while this controller is
/// on screen: the full hierarchy is UIKit + WKWebView + UIScrollView.
final class NovayomiNativeReaderController: UIViewController, WKNavigationDelegate,
    UIScrollViewDelegate, AVSpeechSynthesizerDelegate {

  var onEvent: (([String: Any]) -> Void)?
  var onDismiss: (() -> Void)?
  private let webView: WKWebView
  private let speech = AVSpeechSynthesizer()
  private let progressControl = UISlider(frame: CGRect(x: 0, y: 0, width: 130, height: 35))
  private let progressItem: UIBarButtonItem
  private var chapter: [String: Any]
  private var currentProgress = 0.0
  private var applyingProgress = false
  private var chromeVisible = true
  private var lastReportedProgress = -1.0
  private var lastReportTime = Date.distantPast
  private var didInitialLoad = false
  private var contentInsets = UIEdgeInsets.zero
  private var fontSize: Int
  private var lineHeight: Double
  private var readingMode: String
  private var isBookmarked = false

  init(chapter: [String: Any]) {
    self.chapter = chapter
    fontSize = chapter["fontSize"] as? Int ?? 16
    lineHeight = chapter["lineHeight"] as? Double ?? 1.5
    readingMode = chapter["mode"] as? String ?? "scroll"
    currentProgress = min(max(chapter["progress"] as? Double ?? 0, 0), 1)
    isBookmarked = chapter["bookmarked"] as? Bool ?? false
    let config = WKWebViewConfiguration()
    config.defaultWebpagePreferences.allowsContentJavaScript = false
    config.allowsInlineMediaPlayback = false
    webView = WKWebView(frame: .zero, configuration: config)
    progressItem = UIBarButtonItem(customView: progressControl)
    super.init(nibName: nil, bundle: nil)
    speech.delegate = self
  }

  required init?(coder: NSCoder) { fatalError("Storyboard init unsupported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = readerBackground()
    webView.backgroundColor = readerBackground()
    webView.isOpaque = false
    webView.navigationDelegate = self
    webView.scrollView.delegate = self
    webView.scrollView.alwaysBounceVertical = true
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.scrollView.keyboardDismissMode = .interactive
    webView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(webView)

    NSLayoutConstraint.activate([
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.topAnchor.constraint(equalTo: view.topAnchor),
      webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ])
    edgesForExtendedLayout = [.top, .bottom]
    extendedLayoutIncludesOpaqueBars = true

    let tap = UITapGestureRecognizer(target: self, action: #selector(toggleChrome))
    tap.cancelsTouchesInView = false
    tap.numberOfTapsRequired = 1
    webView.scrollView.addGestureRecognizer(tap)

    progressControl.minimumValue = 0
    progressControl.maximumValue = 1
    progressControl.value = Float(currentProgress)
    progressControl.accessibilityLabel = "Reading progress"
    progressControl.addTarget(self, action: #selector(progressChanged(_:)), for: .valueChanged)
    progressControl.addTarget(self, action: #selector(progressEnded(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])

    updateBars()
    renderChapter()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setNavigationBarHidden(false, animated: false)
    navigationController?.setToolbarHidden(false, animated: false)
    navigationController?.navigationBar.isTranslucent = true
    navigationController?.toolbar.isTranslucent = true
    navigationController?.navigationBar.prefersLargeTitles = false
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // The actual WKWebView scroll view extends behind the Dynamic Island and
    // UIKit toolbar, so iOS 26+ supplies its scroll-edge treatment natively.
    // Insets ensure the beginning and end of a chapter remain readable.
    let safeTop = view.safeAreaInsets.top
    let safeBottom = view.safeAreaInsets.bottom
    let top = max(60, safeTop + (chromeVisible ? 56 : 10))
    let bottom = max(50, safeBottom + (chromeVisible ? 62 : 10))
    if abs(contentInsets.top - top) > 0.5 || abs(contentInsets.bottom - bottom) > 0.5 {
      let oldProgress = progressFraction()
      contentInsets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
      webView.scrollView.contentInset = contentInsets
      webView.scrollView.verticalScrollIndicatorInsets = contentInsets
      if didInitialLoad { restoreProgress(oldProgress) }
    }
  }

  override var prefersStatusBarHidden: Bool { false }

  private func safeString(_ name: String, fallback: String) -> String {
    chapter[name] as? String ?? fallback
  }

  private func readerBackground() -> UIColor {
    uiColor(safeString("background", fallback: "#292832"), fallback: .systemBackground)
  }

  private func uiColor(_ text: String, fallback: UIColor) -> UIColor {
    let hex = text.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard hex.count == 6, let n = UInt32(hex, radix: 16) else { return fallback }
    return UIColor(
      red: CGFloat((n >> 16) & 255) / 255,
      green: CGFloat((n >> 8) & 255) / 255,
      blue: CGFloat(n & 255) / 255,
      alpha: 1
    )
  }

  private func cssColor(_ name: String, fallback: String) -> String {
    let value = safeString(name, fallback: fallback)
    let pattern = #"^#[0-9A-Fa-f]{6}$"#
    return value.range(of: pattern, options: .regularExpression) == nil ? fallback : value
  }

  private func htmlDocument() -> String {
    let background = cssColor("background", fallback: "#292832")
    let foreground = cssColor("foreground", fallback: "#CCCCCC")
    let paragraphSpace = chapter["compactParagraphs"] as? Bool ?? false ? 4 : 8
    let padding = max(6, min(chapter["padding"] as? Int ?? 16, 64))
    let alignment = ["left", "right", "center", "justify"].contains(safeString("alignment", fallback: "left"))
      ? safeString("alignment", fallback: "left") : "left"
    // Only a fixed set of CSS fonts are supported by WebKit; no remote CSS or
    // Flutter font assets are downloaded while reading.
    let familyName = safeString("fontFamily", fallback: "")
    let font = familyName == "Georgia" ? "Georgia, serif" :
      familyName == "Palatino" ? "Palatino, serif" :
      familyName == "Helvetica" ? "Helvetica, sans-serif" :
      "-apple-system, BlinkMacSystemFont, serif"
    let modeStyle: String
    if readingMode == "pages" {
      modeStyle = "html,body{height:100%;overflow:hidden} #book{height:100vh;column-width:100vw;column-gap:0;column-fill:auto;overflow-x:auto;overflow-y:hidden;box-sizing:border-box}"
    } else {
      modeStyle = "html,body{min-height:100%;overflow-x:hidden} #book{box-sizing:border-box;min-height:100%;}"
    }
    return """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
    <style>
    :root { color-scheme: light dark; --reader-size: \(fontSize)px; --reader-line: \(lineHeight); }
    html, body { margin:0; padding:0; background:\(background); color:\(foreground);
      font-size:var(--reader-size); line-height:var(--reader-line);
      font-family:\(font); -webkit-text-size-adjust:100%; }
    #book { padding:0 \(padding)px; text-align:\(alignment);
      overflow-wrap:anywhere; }
    p { margin: 0 0 \(paragraphSpace)px; } img,video { max-width:100%; height:auto; }
    pre { white-space:pre-wrap; } table { max-width:100%; overflow:auto; }
    blockquote { border-left:3px solid currentColor; padding-left:12px; opacity:0.9; }
    a { color: #3b8eea; }
    \(modeStyle)
    </style></head><body><main id="book">\(safeString("html", fallback: ""))</main></body></html>
    """
  }

  private func renderChapter() {
    didInitialLoad = false
    applyingProgress = true
    view.backgroundColor = readerBackground()
    webView.backgroundColor = readerBackground()
    let base: URL?
    if let uri = chapter["baseURL"] as? String,
       let parsed = URL(string: uri),
       ["https","http"].contains(parsed.scheme?.lowercased() ?? "") {
      base = parsed
    } else {
      base = nil
    }
    webView.loadHTMLString(htmlDocument(), baseURL: base)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    didInitialLoad = true
    applyingProgress = false
    webView.scrollView.isPagingEnabled = readingMode == "pages"
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.restoreProgress(self.currentProgress)
      self.reportProgress(force: true)
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if action.navigationType == .linkActivated {
      if let url = action.request.url,
         ["http","https"].contains(url.scheme?.lowercased() ?? "") {
        UIApplication.shared.open(url)
      }
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  private func progressFraction() -> Double {
    let scroll = webView.scrollView
    if readingMode == "pages" {
      let extent = max(0, scroll.contentSize.width - scroll.bounds.width + contentInsets.right)
      return extent > 0 ? min(max(Double(scroll.contentOffset.x / extent), 0), 1) : currentProgress
    }
    let minY = -contentInsets.top
    let maxY = max(minY, scroll.contentSize.height - scroll.bounds.height + contentInsets.bottom)
    return maxY > minY ? min(max(Double((scroll.contentOffset.y - minY) / (maxY - minY)), 0), 1) : 0
  }

  private func restoreProgress(_ fraction: Double) {
    guard didInitialLoad else { return }
    let scroll = webView.scrollView
    let value = min(max(fraction, 0), 1)
    applyingProgress = true
    if readingMode == "pages" {
      let extent = max(0, scroll.contentSize.width - scroll.bounds.width + contentInsets.right)
      scroll.setContentOffset(CGPoint(x: extent * value, y: -contentInsets.top), animated: false)
    } else {
      let minY = -contentInsets.top
      let maxY = max(minY, scroll.contentSize.height - scroll.bounds.height + contentInsets.bottom)
      scroll.setContentOffset(CGPoint(x: 0, y: minY + (maxY - minY) * value), animated: false)
    }
    applyingProgress = false
    currentProgress = value
    progressControl.value = Float(value)
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard didInitialLoad && !applyingProgress else { return }
    currentProgress = progressFraction()
    if !progressControl.isTracking { progressControl.value = Float(currentProgress) }
    reportProgress(force: false)
  }

  private func reportProgress(force: Bool) {
    let now = Date()
    guard force ||
      (now.timeIntervalSince(lastReportTime) >= 0.35 &&
       abs(currentProgress - lastReportedProgress) >= 0.0008) else { return }
    lastReportTime = now
    lastReportedProgress = currentProgress
    onEvent?(["type": "progress", "value": currentProgress])
  }

  private func updateBars() {
    let bookmarked = isBookmarked
    navigationItem.title = safeString("title", fallback: "Novel")
    navigationItem.largeTitleDisplayMode = .never
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .close, target: self, action: #selector(closeReader))
    let bookmarkItem = UIBarButtonItem(
      image: UIImage(systemName: bookmarked ? "bookmark.fill" : "bookmark"),
      style: .plain, target: self, action: #selector(toggleBookmark))
    bookmarkItem.accessibilityLabel = bookmarked ? "Remove bookmark" : "Bookmark"

    let menuItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: makeMenu())
    navigationItem.rightBarButtonItems = [menuItem, bookmarkItem]

    let previous = UIBarButtonItem(
      image: UIImage(systemName: "backward.end.fill"), style: .plain,
      target: self, action: #selector(previousChapter))
    previous.isEnabled = chapter["hasPrevious"] as? Bool ?? false
    let next = UIBarButtonItem(
      image: UIImage(systemName: "forward.end.fill"), style: .plain,
      target: self, action: #selector(nextChapter))
    next.isEnabled = chapter["hasNext"] as? Bool ?? false
    let stretch = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
    progressControl.isEnabled = true
    toolbarItems = [
      previous, stretch, progressItem,
      UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
      next
    ]
    // No custom gradients, opaque bar backgrounds, or Flutter overlays.
    navigationController?.toolbar.tintColor = .label
    navigationController?.navigationBar.tintColor = .label
  }

  private func makeMenu() -> UIMenu {
    let chapters = UIAction(title: "Chapters", image: UIImage(systemName: "list.number")) { [weak self] _ in
      self?.showChapters()
    }
    let smaller = UIAction(title: "Smaller Text", image: UIImage(systemName: "textformat.size.smaller")) { [weak self] _ in
      self?.adjustFont(-1)
    }
    let larger = UIAction(title: "Larger Text", image: UIImage(systemName: "textformat.size.larger")) { [weak self] _ in
      self?.adjustFont(1)
    }
    let lineTight = UIAction(title: "Less Line Spacing", image: UIImage(systemName: "decrease.indent")) { [weak self] _ in
      self?.adjustLineHeight(-0.1)
    }
    let lineLoose = UIAction(title: "More Line Spacing", image: UIImage(systemName: "increase.indent")) { [weak self] _ in
      self?.adjustLineHeight(0.1)
    }
    let mode = UIAction(
      title: readingMode == "scroll" ? "Paged Reading" : "Continuous Scrolling",
      image: UIImage(systemName: readingMode == "scroll" ? "book.pages" : "scroll")
    ) { [weak self] _ in self?.switchMode() }
    let voice = UIAction(
      title: speech.isSpeaking ? "Stop Reading Aloud" : "Read Aloud",
      image: UIImage(systemName: "waveform")
    ) { [weak self] _ in self?.toggleSpeech() }
    return UIMenu(children: [
      chapters, UIMenu(title: "Appearance", image: UIImage(systemName: "textformat.size"),
                       children: [smaller, larger, lineTight, lineLoose, mode]),
      voice
    ])
  }

  private func showChapters() {
    guard let chapters = chapter["chapters"] as? [[String: Any]] else { return }
    let sheet = UIAlertController(title: "Chapters", message: nil, preferredStyle: .actionSheet)
    for item in chapters {
      guard let id = item["id"] as? Int else { continue }
      let title = item["title"] as? String ?? "Chapter"
      sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
        self?.onEvent?(["type":"chapter", "id":id])
      })
    }
    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    if let popover = sheet.popoverPresentationController {
      popover.barButtonItem = navigationItem.rightBarButtonItems?.first
    }
    present(sheet, animated: true)
  }

  private func adjustFont(_ amount: Int) {
    fontSize = min(36, max(10, fontSize + amount))
    let previous = progressFraction()
    onEvent?(["type":"fontSize", "value":fontSize])
    webView.evaluateJavaScript("document.documentElement.style.setProperty('--reader-size', '" + String(fontSize) + "px')") { [weak self] _,_ in
      self?.restoreProgress(previous)
    }
  }

  private func adjustLineHeight(_ amount: Double) {
    lineHeight = min(2.6, max(1.0, (lineHeight * 10 + amount * 10).rounded() / 10))
    let previous = progressFraction()
    onEvent?(["type":"lineHeight", "value":lineHeight])
    webView.evaluateJavaScript("document.documentElement.style.setProperty('--reader-line','" + String(lineHeight) + "')") { [weak self] _,_ in
      self?.restoreProgress(previous)
    }
  }

  private func switchMode() {
    currentProgress = progressFraction()
    readingMode = readingMode == "scroll" ? "pages" : "scroll"
    chapter["mode"] = readingMode
    onEvent?(["type":"mode", "value":readingMode])
    updateBars()
    renderChapter()
  }

  private func toggleSpeech() {
    if speech.isSpeaking || speech.isPaused {
      speech.stopSpeaking(at: .immediate)
      updateBars()
      return
    }
    webView.evaluateJavaScript("document.body.innerText") { [weak self] result, _ in
      guard let self, let content = result as? String, !content.isEmpty else { return }
      let utterance = AVSpeechUtterance(string: content)
      utterance.rate = AVSpeechUtteranceDefaultSpeechRate
      self.speech.speak(utterance)
      self.updateBars()
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    updateBars()
  }

  @objc private func toggleChrome() {
    chromeVisible.toggle()
    navigationController?.setNavigationBarHidden(!chromeVisible, animated: true)
    navigationController?.setToolbarHidden(!chromeVisible, animated: true)
    view.setNeedsLayout()
  }

  @objc private func progressChanged(_ sender: UISlider) {
    currentProgress = Double(sender.value)
    restoreProgress(currentProgress)
  }

  @objc private func progressEnded(_ sender: UISlider) {
    currentProgress = Double(sender.value)
    reportProgress(force: true)
  }

  @objc private func toggleBookmark() {
    isBookmarked.toggle()
    onEvent?(["type":"bookmark", "value":isBookmarked])
    updateBars()
  }

  @objc private func previousChapter() { onEvent?(["type":"previous"]) }
  @objc private func nextChapter() { onEvent?(["type":"next"]) }

  @objc private func closeReader() {
    reportProgress(force: true)
    speech.stopSpeaking(at: .immediate)
    dismiss(animated: true) { [weak self] in
      self?.onEvent?(["type":"closed"])
      self?.onDismiss?()
    }
  }

  func replaceChapter(_ data: [String: Any]) {
    speech.stopSpeaking(at: .immediate)
    chapter = data
    currentProgress = min(max(data["progress"] as? Double ?? 0, 0), 1)
    fontSize = data["fontSize"] as? Int ?? fontSize
    lineHeight = data["lineHeight"] as? Double ?? lineHeight
    isBookmarked = data["bookmarked"] as? Bool ?? false
    readingMode = data["mode"] as? String ?? readingMode
    progressControl.value = Float(currentProgress)
    updateBars()
    renderChapter()
  }

  func showLoadingError(_ message: String) {
    let alert = UIAlertController(title: "Chapter unavailable", message: message,
                                  preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }
}
