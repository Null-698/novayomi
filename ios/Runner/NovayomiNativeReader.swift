import UIKit
import WebKit
import AVFoundation

/// Novayomi's sole iOS novel reading surface. The Flutter engine never paints
/// chapter text or supplies a platform-view overlay while this controller is
/// on screen: the full hierarchy is UIKit + WKWebView + UIScrollView.
final class NovayomiNativeReaderController: UIViewController, WKNavigationDelegate,
    UIScrollViewDelegate, AVSpeechSynthesizerDelegate, UIGestureRecognizerDelegate {

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
  // Stable insets: changing these during a drag forces WKWebView to jump.
  private var contentInsets = UIEdgeInsets.zero
  private var didConfigureInsets = false
  private var didReportClose = false
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
    if #available(iOS 26.0, *) {
      // The gradual scroll-edge fade belongs to immersive mode. While the
      // controls are visible, UINavigationController owns its native treatment.
      webView.scrollView.topEdgeEffect.style = .soft
      webView.scrollView.bottomEdgeEffect.style = .soft
      webView.scrollView.topEdgeEffect.isHidden = chromeVisible
      webView.scrollView.bottomEdgeEffect.isHidden = chromeVisible
    }
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
    tap.delegate = self
    tap.cancelsTouchesInView = false
    // The gesture belongs to the controller, not the inner WebKit scroll view,
    // so taps still work when WKContentView consumes content touch events.
    view.addGestureRecognizer(tap)

    // Flutter owns the detail route, so an interactivePopGestureRecognizer
    // cannot work here: the native reader is a modal root controller. Install
    // a UIKit left-edge back swipe instead.
    let backSwipe = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleBackSwipe(_:)))
    backSwipe.edges = .left
    backSwipe.delegate = self
    view.addGestureRecognizer(backSwipe)

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
    overrideUserInterfaceStyle = isDarkBook ? .dark : .light
    navigationController?.overrideUserInterfaceStyle = isDarkBook ? .dark : .light
    navigationController?.setNavigationBarHidden(!chromeVisible, animated: false)
    navigationController?.setToolbarHidden(!chromeVisible, animated: false)
    navigationController?.navigationBar.prefersLargeTitles = false
    // No custom navigation-bar background. iOS 26+ supplies native
    // Liquid Glass and its gradual bar-edge treatment automatically.
    navigationController?.navigationBar.tintColor = .label
    navigationController?.toolbar.isTranslucent = true
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // The actual WKWebView scroll view extends behind the Dynamic Island and
    // UIKit toolbar, so iOS 26+ supplies its scroll-edge treatment natively.
    // Insets ensure the beginning and end of a chapter remain readable.
    guard !didConfigureInsets, view.bounds.height > 0 else { return }
    // The inset is fixed for the entire chapter. It does not change when
    // chrome hides, status-bar visibility changes, or a drag is in progress.
    let top = max(110, view.window?.safeAreaInsets.top ?? 0)
    let bottom = max(102, view.window?.safeAreaInsets.bottom ?? 0)
    contentInsets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
    webView.scrollView.contentInset = contentInsets
    webView.scrollView.scrollIndicatorInsets = contentInsets
    didConfigureInsets = true
  }

  override var prefersStatusBarHidden: Bool { !chromeVisible }
  override var prefersHomeIndicatorAutoHidden: Bool { !chromeVisible }
  override var preferredStatusBarStyle: UIStatusBarStyle { isDarkBook ? .lightContent : .darkContent }

  private var isDarkBook: Bool {
    let rgba = readerBackground().cgColor.components ?? [0, 0, 0, 1]
    guard rgba.count >= 3 else { return true }
    let luminance = 0.2126 * rgba[0] + 0.7152 * rgba[1] + 0.0722 * rgba[2]
    return luminance < 0.53
  }

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
    let paragraphSpace = (chapter["compactParagraphs"] as? Bool ?? false) ? 4 : 8
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
      modeStyle = "html,body{height:100%;overflow-x:visible;overflow-y:hidden} #book{height:100vh;width:100vw;column-width:100vw;column-gap:0;column-fill:auto;overflow:visible;box-sizing:border-box}"
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
    webView.scrollView.alwaysBounceVertical = readingMode != "pages"
    webView.scrollView.alwaysBounceHorizontal = readingMode == "pages"
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

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    if chromeVisible { setChromeVisible(false) }
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                         shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    return true
  }

  @objc private func handleBackSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
    guard gesture.state == .ended else { return }
    if gesture.translation(in: view).x > 75 {
      closeReader()
    }
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
      (now.timeIntervalSince(lastReportTime) >= 1.0 &&
       abs(currentProgress - lastReportedProgress) >= 0.003) else { return }
    lastReportTime = now
    lastReportedProgress = currentProgress
    onEvent?(["type": "progress", "value": currentProgress])
  }

  private func updateBars() {
    let bookmarked = isBookmarked
    let bookTitle = safeString("title", fallback: "Novel")
    let chapterTitle = safeString("subtitle", fallback: "Chapter")
    let chapterNumber = chapter["chapterIndex"] as? Int ?? 0
    let chapterTotal = chapter["chapterCount"] as? Int ?? 0

    navigationItem.title = bookTitle
    navigationItem.largeTitleDisplayMode = .never
    let title = UILabel()
    title.text = bookTitle
    title.font = .preferredFont(forTextStyle: .headline)
    title.textColor = .label
    title.textAlignment = .center
    title.lineBreakMode = .byTruncatingTail
    let subtitle = UILabel()
    subtitle.text = chapterNumber > 0
      ? "Chapter \(chapterNumber) of \(chapterTotal) · \(chapterTitle)"
      : chapterTitle
    subtitle.font = .preferredFont(forTextStyle: .caption2)
    subtitle.textColor = .secondaryLabel
    subtitle.textAlignment = .center
    subtitle.lineBreakMode = .byTruncatingTail
    let titles = UIStackView(arrangedSubviews: [title, subtitle])
    titles.axis = .vertical
    titles.distribution = .fill
    titles.spacing = 1
    // Keep the two-line title readable without a rectangular blur strip.
    // This is genuine UIKit glass, respecting Clear/Frosted system settings.
    let titleGlass: UIVisualEffectView
    if #available(iOS 26.0, *) {
      titleGlass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
      titleGlass.cornerConfiguration = .capsule()
    } else {
      titleGlass = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
      titleGlass.layer.cornerRadius = 21
      titleGlass.clipsToBounds = true
    }
    titleGlass.frame = CGRect(x: 0, y: 0, width: 205, height: 44)
    titles.translatesAutoresizingMaskIntoConstraints = false
    titleGlass.contentView.addSubview(titles)
    NSLayoutConstraint.activate([
      titles.leadingAnchor.constraint(equalTo: titleGlass.contentView.leadingAnchor, constant: 10),
      titles.trailingAnchor.constraint(equalTo: titleGlass.contentView.trailingAnchor, constant: -10),
      titles.centerYAnchor.constraint(equalTo: titleGlass.contentView.centerYAnchor)
    ])
    navigationItem.titleView = titleGlass

    navigationItem.leftBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "chevron.backward"),
      style: .plain, target: self, action: #selector(closeReader))
    navigationItem.leftBarButtonItem?.accessibilityLabel = "Return to novel details"
    let bookmarkItem = UIBarButtonItem(
      image: UIImage(systemName: bookmarked ? "bookmark.fill" : "bookmark"),
      style: .plain, target: self, action: #selector(toggleBookmark))
    bookmarkItem.accessibilityLabel = bookmarked ? "Remove bookmark" : "Bookmark"
    navigationItem.rightBarButtonItems = [bookmarkItem]

    let previous = UIBarButtonItem(
      image: UIImage(systemName: "backward.end.fill"), style: .plain,
      target: self, action: #selector(previousChapter))
    previous.isEnabled = chapter["hasPrevious"] as? Bool ?? false
    previous.accessibilityLabel = "Previous chapter"
    let chapterList = UIBarButtonItem(
      image: UIImage(systemName: "list.number"), style: .plain,
      target: self, action: #selector(showChapters))
    chapterList.accessibilityLabel = "All chapters"
    let settings = UIBarButtonItem(
      image: UIImage(systemName: "textformat.size"), style: .plain,
      target: self, action: #selector(showSettings))
    settings.accessibilityLabel = "Reading settings"
    let next = UIBarButtonItem(
      image: UIImage(systemName: "forward.end.fill"), style: .plain,
      target: self, action: #selector(nextChapter))
    next.isEnabled = chapter["hasNext"] as? Bool ?? false
    next.accessibilityLabel = "Next chapter"
    progressControl.isEnabled = true
    progressControl.frame.size.width = 86
    let overflow = UIBarButtonItem(
      image: UIImage(systemName: "ellipsis.circle"),
      menu: makeMenu()
    )
    overflow.accessibilityLabel = "More reader actions"
    toolbarItems = [
      previous, chapterList,
      UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
      progressItem,
      UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
      settings, overflow, next
    ]
    navigationController?.toolbar.tintColor = .label
  }

  private func makeMenu() -> UIMenu {
    let chapters = UIAction(title: "All Chapters", image: UIImage(systemName: "list.number")) { [weak self] _ in
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

  @objc private func showChapters() {
    guard let chapters = chapter["chapters"] as? [[String: Any]] else { return }
    let picker = NovayomiChapterSheet(chapters: chapters, currentId: chapter["chapterId"] as? Int)
    picker.onSelect = { [weak self] id in
      self?.onEvent?(["type": "chapter", "id": id])
    }
    presentReaderSheet(picker)
  }

  private func presentReaderSheet(_ controller: UIViewController) {
    // UISheetPresentationController provides the native expandable bottom
    // sheet, grabber and swipe-to-dismiss behavior on iPhone.
    let navigation = UINavigationController(rootViewController: controller)
    navigation.modalPresentationStyle = .pageSheet
    navigation.overrideUserInterfaceStyle = overrideUserInterfaceStyle
    if let sheet = navigation.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.prefersScrollingExpandsWhenScrolledToEdge = true
    }
    present(navigation, animated: true)
  }

  @objc private func showSettings() {
    let settings = NovayomiReadingSettingsSheet(
      fontSize: fontSize,
      lineHeight: lineHeight,
      padding: chapter["padding"] as? Int ?? 16,
      mode: readingMode,
      background: safeString("background", fallback: "#292832"),
      alignment: safeString("alignment", fallback: "left")
    )
    settings.onChange = { [weak self] key, value in
      self?.applyReaderSetting(key: key, value: value)
    }
    settings.onSpeak = { [weak self] in self?.toggleSpeech() }
    presentReaderSheet(settings)
  }

  private func applyReaderSetting(key: String, value: Any) {
    switch key {
    case "fontSize":
      guard let size = value as? Int else { return }
      setFontSize(size)
    case "lineHeight":
      guard let spacing = value as? Double else { return }
      setLineHeight(spacing)
    case "padding":
      guard let inset = value as? Int else { return }
      chapter["padding"] = inset
      onEvent?(["type": "padding", "value": inset])
      applyReaderCSS("document.getElementById('book').style.padding = '0 \(inset)px'")
    case "mode":
      guard let requested = value as? String, requested != readingMode else { return }
      switchMode()
    case "appearance":
      guard let selected = value as? String else { return }
      let palette: (String, String)
      switch selected {
      case "light": palette = ("#FFFFFF", "#202020")
      case "sepia": palette = ("#F5ECD8", "#473829")
      default: palette = ("#292832", "#CCCCCC")
      }
      chapter["background"] = palette.0
      chapter["foreground"] = palette.1
      onEvent?(["type": "background", "value": palette.0])
      onEvent?(["type": "foreground", "value": palette.1])
      view.backgroundColor = readerBackground()
      webView.backgroundColor = readerBackground()
      overrideUserInterfaceStyle = isDarkBook ? .dark : .light
      navigationController?.overrideUserInterfaceStyle = isDarkBook ? .dark : .light
      setNeedsStatusBarAppearanceUpdate()
      applyReaderCSS("document.documentElement.style.backgroundColor = '\(palette.0)'; document.body.style.backgroundColor = '\(palette.0)'; document.body.style.color = '\(palette.1)'")
    case "alignment":
      guard let align = value as? String, ["left", "center", "right", "justify"].contains(align) else { return }
      chapter["alignment"] = align
      onEvent?(["type": "alignment", "value": align])
      applyReaderCSS("document.getElementById('book').style.textAlign = '\(align)'")
    default:
      break
    }
  }

  private func applyReaderCSS(_ script: String) {
    guard didInitialLoad else { return }
    let position = progressFraction()
    webView.evaluateJavaScript(script) { [weak self] _, _ in
      guard let self, !self.webView.scrollView.isDragging,
            !self.webView.scrollView.isDecelerating else { return }
      self.restoreProgress(position)
    }
  }

  private func setFontSize(_ newSize: Int) {
    fontSize = min(36, max(10, newSize))
    chapter["fontSize"] = fontSize
    onEvent?(["type": "fontSize", "value": fontSize])
    applyReaderCSS("document.documentElement.style.setProperty('--reader-size', '\(fontSize)px')")
  }

  private func setLineHeight(_ newHeight: Double) {
    lineHeight = min(2.6, max(1.0, (newHeight * 10).rounded() / 10))
    chapter["lineHeight"] = lineHeight
    onEvent?(["type": "lineHeight", "value": lineHeight])
    applyReaderCSS("document.documentElement.style.setProperty('--reader-line', '\(lineHeight)')")
  }

  private func adjustFont(_ amount: Int) {
    setFontSize(fontSize + amount)
  }

  private func adjustLineHeight(_ amount: Double) {
    setLineHeight(lineHeight + amount)
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

  private func setChromeVisible(_ visible: Bool) {
    guard chromeVisible != visible else { return }
    chromeVisible = visible
    navigationController?.setNavigationBarHidden(!visible, animated: true)
    navigationController?.setToolbarHidden(!visible, animated: true)
    if #available(iOS 26.0, *) {
      webView.scrollView.topEdgeEffect.isHidden = visible
      webView.scrollView.bottomEdgeEffect.isHidden = visible
    }
    navigationController?.setNeedsStatusBarAppearanceUpdate()
    setNeedsStatusBarAppearanceUpdate()
    navigationController?.setNeedsUpdateOfHomeIndicatorAutoHidden()
    setNeedsUpdateOfHomeIndicatorAutoHidden()
    // No scroll inset changes or progress restoration while chrome animates.
  }

  @objc private func toggleChrome() {
    setChromeVisible(!chromeVisible)
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
    guard !didReportClose else { return }
    didReportClose = true
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


/// Searchable, full-length chapter picker: UIKit table in a native resizable
/// bottom sheet. The reader bridge supplies all chapters, not a 25-item window.
private final class NovayomiChapterSheet: UITableViewController, UISearchResultsUpdating {
  var onSelect: ((Int) -> Void)?
  private let chapters: [(id: Int, title: String)]
  private var visibleIndices: [Int]
  private let currentId: Int?
  private let search = UISearchController(searchResultsController: nil)

  init(chapters: [[String: Any]], currentId: Int?) {
    self.chapters = chapters.compactMap { item in
      guard let id = item["id"] as? Int else { return nil }
      return (id: id, title: item["title"] as? String ?? "Chapter")
    }
    self.visibleIndices = Array(self.chapters.indices)
    self.currentId = currentId
    super.init(style: .plain)
  }

  required init?(coder: NSCoder) { fatalError("Storyboard init unsupported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Chapters (\(chapters.count))"
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done, target: self, action: #selector(done))
    search.searchResultsUpdater = self
    search.obscuresBackgroundDuringPresentation = false
    search.searchBar.placeholder = "Find chapter"
    navigationItem.searchController = search
    navigationItem.hidesSearchBarWhenScrolling = false
    tableView.rowHeight = 54
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if search.searchBar.text?.isEmpty != false,
       let row = visibleIndices.firstIndex(where: { chapters[$0].id == currentId }) {
      tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .middle, animated: false)
    }
  }

  func updateSearchResults(for searchController: UISearchController) {
    let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    visibleIndices = query.isEmpty ? Array(chapters.indices) : chapters.indices.filter {
      chapters[$0].title.localizedCaseInsensitiveContains(query)
        || String($0 + 1).contains(query)
    }
    tableView.reloadData()
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    visibleIndices.count
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "chapter")
      ?? UITableViewCell(style: .subtitle, reuseIdentifier: "chapter")
    let idx = visibleIndices[indexPath.row]
    cell.textLabel?.text = chapters[idx].title
    cell.textLabel?.numberOfLines = 1
    cell.detailTextLabel?.text = "Chapter \(idx + 1)"
    cell.detailTextLabel?.textColor = .secondaryLabel
    cell.accessoryType = chapters[idx].id == currentId ? .checkmark : .none
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    let id = chapters[visibleIndices[indexPath.row]].id
    dismiss(animated: true) { [weak self] in self?.onSelect?(id) }
  }

  @objc private func done() { dismiss(animated: true) }
}


/// Native reader preferences; this is a UIKit sheet, not a Flutter bottom
/// panel. Changes are sent back to the existing Dart preferences providers.
private final class NovayomiReadingSettingsSheet: UIViewController, UIColorPickerViewControllerDelegate {
  var onChange: ((String, Any) -> Void)?
  var onSpeak: (() -> Void)?

  private let tabs = UISegmentedControl(items: ["Reader", "General", "Text-to-Speech"])
  private let scroll = UIScrollView()
  private let form = UIStackView()
  private let fontSlider = UISlider()
  private let lineSlider = UISlider()
  private let marginSlider = UISlider()
  private let fontValue = UILabel()
  private let lineValue = UILabel()
  private let marginValue = UILabel()
  private let modeControl = UISegmentedControl(items: ["Continuous", "Paged"])
  private let pageControl = UISegmentedControl(items: ["Single", "Double", "Auto"])
  private let themeControl = UISegmentedControl(items: ["Dark", "Light", "Black", "Sepia"])
  private let alignmentControl = UISegmentedControl(items: ["Left", "Center", "Right", "Justify"])
  private let backgroundButton = UIButton(type: .system)
  private let textButton = UIButton(type: .system)
  private let fontButton = UIButton(type: .system)
  private let keepAwake = UISwitch()
  private let showPercent = UISwitch()
  private let compactParagraphs = UISwitch()
  private let tapZones = UISwitch()
  private let autoScroll = UISwitch()
  private let autoScrollSpeed = UISlider()
  private let brightness = UISlider()
  private let ttsSpeed = UISlider()
  private let ttsPitch = UISlider()
  private let ttsSpeedLabel = UILabel()
  private let ttsPitchLabel = UILabel()
  private let languageButton = UIButton(type: .system)
  private var colorTarget = "background"
  private var backgroundHex: String
  private var foregroundHex: String
  private var fontKey: String
  private let initialFont: Int
  private let initialLine: Double
  private let initialPadding: Int
  private let initialMode: String
  private let initialAlignment: String
  private let initialPageLayout: String
  private let initialKeepAwake: Bool
  private let initialShowPercent: Bool
  private let initialCompact: Bool
  private let initialTapZones: Bool
  private let initialAutoScroll: Bool
  private let initialAutoScrollSpeed: Double
  private let initialTtsSpeed: Double
  private let initialTtsPitch: Double
  private var ttsLanguage: String?

  init(fontSize: Int, lineHeight: Double, padding: Int, mode: String,
       background: String, foreground: String, alignment: String,
       fontKey: String, pageLayout: String, keepAwake: Bool,
       showPercent: Bool, compactParagraphs: Bool, tapZones: Bool,
       autoScroll: Bool, autoScrollSpeed: Double,
       ttsSpeed: Double, ttsPitch: Double, ttsLanguage: String?) {
    initialFont = fontSize
    initialLine = lineHeight
    initialPadding = padding
    initialMode = mode
    initialAlignment = alignment
    initialPageLayout = pageLayout
    initialKeepAwake = keepAwake
    initialShowPercent = showPercent
    initialCompact = compactParagraphs
    initialTapZones = tapZones
    initialAutoScroll = autoScroll
    initialAutoScrollSpeed = autoScrollSpeed
    initialTtsSpeed = ttsSpeed
    initialTtsPitch = ttsPitch
    self.ttsLanguage = ttsLanguage
    backgroundHex = background
    foregroundHex = foreground
    self.fontKey = fontKey
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("Storyboard init unsupported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Reading Settings"
    view.backgroundColor = .systemGroupedBackground
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done, target: self, action: #selector(done))
    tabs.selectedSegmentIndex = 0
    tabs.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
    tabs.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(tabs)

    scroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll)
    form.axis = .vertical
    form.spacing = 14
    form.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(form)
    NSLayoutConstraint.activate([
      tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      tabs.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
      scroll.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      form.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
      form.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
      form.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
      form.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -34),
      form.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32)
    ])
    configureControls()
    showTab()
  }

  private func configureControls() {
    setupSlider(fontSlider, min: 8, max: 40, value: Float(initialFont),
                selector: #selector(fontChanged(_:)))
    setupSlider(lineSlider, min: 1, max: 3, value: Float(initialLine),
                selector: #selector(lineChanged(_:)))
    setupSlider(marginSlider, min: 0, max: 50, value: Float(initialPadding),
                selector: #selector(marginChanged(_:)))
    fontValue.text = "\(initialFont) px"
    lineValue.text = String(format: "%.1f", initialLine)
    marginValue.text = "\(initialPadding) px"
    modeControl.selectedSegmentIndex = initialMode == "pages" ? 1 : 0
    modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
    pageControl.selectedSegmentIndex = initialPageLayout == "double" ? 1
      : initialPageLayout == "auto" ? 2 : 0
    pageControl.addTarget(self, action: #selector(pageChanged), for: .valueChanged)
    themeControl.selectedSegmentIndex = backgroundHex.uppercased() == "#FFFFFF" ? 1
      : backgroundHex.uppercased() == "#000000" ? 2
      : backgroundHex.uppercased() == "#F5E6D3" ? 3 : 0
    themeControl.addTarget(self, action: #selector(themeChanged), for: .valueChanged)
    alignmentControl.selectedSegmentIndex = initialAlignment == "center" ? 1
      : initialAlignment == "right" ? 2
      : initialAlignment == "justify" ? 3 : 0
    alignmentControl.addTarget(self, action: #selector(alignmentChanged), for: .valueChanged)

    backgroundButton.configuration = .tinted()
    textButton.configuration = .tinted()
    backgroundButton.addTarget(self, action: #selector(backgroundColorTapped), for: .touchUpInside)
    textButton.addTarget(self, action: #selector(textColorTapped), for: .touchUpInside)
    refreshColorLabels()

    fontButton.configuration = .tinted()
    fontButton.showsMenuAsPrimaryAction = true
    updateFontMenu()

    keepAwake.isOn = initialKeepAwake
    showPercent.isOn = initialShowPercent
    compactParagraphs.isOn = initialCompact
    tapZones.isOn = initialTapZones
    autoScroll.isOn = initialAutoScroll
    for control in [keepAwake, showPercent, compactParagraphs, tapZones, autoScroll] {
      control.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
    }
    setupSlider(autoScrollSpeed, min: 2, max: 30, value: Float(initialAutoScrollSpeed),
                selector: #selector(autoScrollSpeedChanged(_:)))
    brightness.minimumValue = 0.1
    brightness.maximumValue = 1
    brightness.value = Float(UIScreen.main.brightness)
    brightness.isContinuous = false
    brightness.addTarget(self, action: #selector(brightnessChanged(_:)), for: .valueChanged)

    setupSlider(ttsSpeed, min: 0.1, max: 1, value: Float(initialTtsSpeed),
                selector: #selector(ttsSpeedChanged(_:)))
    setupSlider(ttsPitch, min: 0.5, max: 2, value: Float(initialTtsPitch),
                selector: #selector(ttsPitchChanged(_:)))
    ttsSpeedLabel.text = String(format: "%.1f×", initialTtsSpeed * 2)
    ttsPitchLabel.text = String(format: "%.1f", initialTtsPitch)
    languageButton.configuration = .tinted()
    languageButton.showsMenuAsPrimaryAction = true
    updateLanguageMenu()
  }

  private func clearForm() {
    for view in form.arrangedSubviews {
      form.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
  }

  private func showTab() {
    clearForm()
    scroll.setContentOffset(.zero, animated: false)
    switch tabs.selectedSegmentIndex {
    case 1: showGeneralSettings()
    case 2: showSpeechSettings()
    default: showReaderSettings()
    }
  }

  private func showReaderSettings() {
    form.addArrangedSubview(section("Theme", children: [
      themeControl,
      horizontalRow([backgroundButton, textButton])
    ]))
    form.addArrangedSubview(section("Text Align", children: [alignmentControl]))
    form.addArrangedSubview(section("Font size", children: [
      sliderRow(fontSlider, value: fontValue)
    ]))
    form.addArrangedSubview(section("Padding", children: [
      sliderRow(marginSlider, value: marginValue)
    ]))
    form.addArrangedSubview(section("Line Height", children: [
      sliderRow(lineSlider, value: lineValue)
    ]))
    form.addArrangedSubview(section("Font", children: [fontButton]))
    form.addArrangedSubview(section("Reading mode", children: [modeControl]))
    if modeControl.selectedSegmentIndex == 1 {
      form.addArrangedSubview(section("Page mode", children: [pageControl]))
    }
  }

  private func showGeneralSettings() {
    form.addArrangedSubview(section("Display", children: [
      switchRow("Keep screen on", control: keepAwake),
      switchRow("Show reading percentage", control: showPercent),
      switchRow("Remove extra paragraph spacing", control: compactParagraphs),
      switchRow("Use tap zones for paging", control: tapZones)
    ]))
    form.addArrangedSubview(section("Auto-scroll", children: [
      switchRow("Auto-scroll while reading", control: autoScroll),
      sliderRow(autoScrollSpeed, value: nil)
    ]))
    form.addArrangedSubview(section("Screen brightness", children: [
      sliderRow(brightness, value: nil)
    ]))
  }

  private func showSpeechSettings() {
    form.addArrangedSubview(section("Text-to-Speech", children: [
      sliderRow(ttsSpeed, value: ttsSpeedLabel),
      sliderRow(ttsPitch, value: ttsPitchLabel),
      languageButton
    ]))
    let play = UIButton(type: .system)
    play.configuration = .filled()
    play.setTitle("Read aloud / Stop", for: .normal)
    play.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    play.addTarget(self, action: #selector(speakTapped), for: .touchUpInside)
    form.addArrangedSubview(section("Playback", children: [play]))
  }

  private func section(_ title: String, children: [UIView]) -> UIView {
    let wrapper = UIStackView()
    wrapper.axis = .vertical
    wrapper.spacing = 12
    wrapper.isLayoutMarginsRelativeArrangement = true
    wrapper.layoutMargins = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    wrapper.backgroundColor = .secondarySystemGroupedBackground
    wrapper.layer.cornerRadius = 18
    let heading = UILabel()
    heading.text = title
    heading.font = .preferredFont(forTextStyle: .headline)
    wrapper.addArrangedSubview(heading)
    children.forEach(wrapper.addArrangedSubview)
    return wrapper
  }

  private func horizontalRow(_ views: [UIView]) -> UIView {
    let row = UIStackView(arrangedSubviews: views)
    row.axis = .horizontal
    row.alignment = .fill
    row.distribution = .fillEqually
    row.spacing = 8
    return row
  }

  private func switchRow(_ title: String, control: UISwitch) -> UIView {
    let label = UILabel()
    label.text = title
    label.font = .preferredFont(forTextStyle: .body)
    label.numberOfLines = 0
    let row = UIStackView(arrangedSubviews: [label, control])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 8
    return row
  }

  private func sliderRow(_ slider: UISlider, value: UILabel?) -> UIView {
    let parts: [UIView] = value.map { [slider, $0] } ?? [slider]
    return horizontalRow(parts)
  }

  private func setupSlider(_ slider: UISlider, min: Float, max: Float,
                           value: Float, selector: Selector) {
    slider.minimumValue = min
    slider.maximumValue = max
    slider.value = value
    slider.addTarget(self, action: selector, for: .valueChanged)
    slider.isContinuous = false
  }

  private func refreshColorLabels() {
    backgroundButton.setTitle("Background  \(backgroundHex)", for: .normal)
    textButton.setTitle("Text  \(foregroundHex)", for: .normal)
  }

  private func updateFontMenu() {
    let options = [
      ("Default", ""), ("OpenDyslexic", "OpenDyslexic"),
      ("Lexend", "Lexend"), ("Atkinson Hyperlegible", "AtkinsonHyperlegible")
    ]
    fontButton.setTitle("Font: \(options.first(where: { $0.1 == fontKey })?.0 ?? "Default")", for: .normal)
    fontButton.menu = UIMenu(children: options.map { option in
      UIAction(title: option.0, state: option.1 == fontKey ? .on : .off) { [weak self] _ in
        guard let self else { return }
        self.fontKey = option.1
        self.updateFontMenu()
        self.onChange?("fontFamily", option.1)
      }
    })
  }

  private func updateLanguageMenu() {
    let all = Set(AVSpeechSynthesisVoice.speechVoices().map { $0.language }).sorted()
    let options: [String?] = [nil] + all.map { Optional($0) }
    let displayed = ttsLanguage.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 } ?? "System Default"
    languageButton.setTitle("Voice language: \(displayed)", for: .normal)
    languageButton.menu = UIMenu(children: options.map { code in
      let label = code.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 } ?? "System Default"
      return UIAction(title: label, state: code == ttsLanguage ? .on : .off) { [weak self] _ in
        self?.ttsLanguage = code
        self?.updateLanguageMenu()
        self?.onChange?("ttsLanguage", code ?? "")
      }
    })
  }

  @objc private func tabChanged() { showTab() }
  @objc private func fontChanged(_ slider: UISlider) {
    let size = Int(slider.value.rounded())
    fontValue.text = "\(size) px"
    onChange?("fontSize", size)
  }
  @objc private func lineChanged(_ slider: UISlider) {
    let value = (Double(slider.value) * 10).rounded() / 10
    lineValue.text = String(format: "%.1f", value)
    onChange?("lineHeight", value)
  }
  @objc private func marginChanged(_ slider: UISlider) {
    let value = Int(slider.value.rounded())
    marginValue.text = "\(value) px"
    onChange?("padding", value)
  }
  @objc private func modeChanged() {
    onChange?("mode", modeControl.selectedSegmentIndex == 1 ? "pages" : "scroll")
    showTab()
  }
  @objc private func pageChanged() {
    let layouts = ["single", "double", "auto"]
    onChange?("pageLayout", layouts[pageControl.selectedSegmentIndex])
  }
  @objc private func themeChanged() {
    onChange?("appearance", ["dark", "light", "black", "sepia"][themeControl.selectedSegmentIndex])
  }
  @objc private func alignmentChanged() {
    onChange?("alignment", ["left", "center", "right", "justify"][alignmentControl.selectedSegmentIndex])
  }
  @objc private func switchChanged(_ control: UISwitch) {
    let key: String
    if control === keepAwake { key = "keepAwake" }
    else if control === showPercent { key = "showPercent" }
    else if control === compactParagraphs { key = "compactParagraphs" }
    else if control === tapZones { key = "tapZones" }
    else { key = "autoScroll" }
    onChange?(key, control.isOn)
  }
  @objc private func autoScrollSpeedChanged(_ slider: UISlider) {
    onChange?("autoScrollSpeed", Double(slider.value))
  }
  @objc private func brightnessChanged(_ slider: UISlider) {
    onChange?("brightness", Double(slider.value))
  }
  @objc private func ttsSpeedChanged(_ slider: UISlider) {
    let speed = (Double(slider.value) * 10).rounded() / 10
    ttsSpeedLabel.text = String(format: "%.1f×", speed * 2)
    onChange?("ttsSpeed", speed)
  }
  @objc private func ttsPitchChanged(_ slider: UISlider) {
    let pitch = (Double(slider.value) * 10).rounded() / 10
    ttsPitchLabel.text = String(format: "%.1f", pitch)
    onChange?("ttsPitch", pitch)
  }
  @objc private func backgroundColorTapped() { showColorPicker(target: "background", hex: backgroundHex) }
  @objc private func textColorTapped() { showColorPicker(target: "foreground", hex: foregroundHex) }
  private func showColorPicker(target: String, hex: String) {
    colorTarget = target
    let picker = UIColorPickerViewController()
    picker.delegate = self
    picker.supportsAlpha = false
    let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    if let n = UInt32(value, radix: 16) {
      picker.selectedColor = UIColor(
        red: CGFloat((n >> 16) & 255) / 255,
        green: CGFloat((n >> 8) & 255) / 255,
        blue: CGFloat(n & 255) / 255, alpha: 1)
    }
    present(picker, animated: true)
  }
  func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController, continuously: Bool) {
    if continuously { return }
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    viewController.selectedColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    let hex = String(format: "#%02X%02X%02X",
                     Int((red * 255).rounded()), Int((green * 255).rounded()),
                     Int((blue * 255).rounded()))
    if colorTarget == "background" { backgroundHex = hex }
    else { foregroundHex = hex }
    refreshColorLabels()
    onChange?(colorTarget, hex)
  }
  @objc private func speakTapped() { onSpeak?() }
  @objc private func done() { dismiss(animated: true) }
}

/// The UIKit reader is a full-screen modal, so the navigation controller
/// must forward home-indicator/status-bar preferences to its reader child.
final class NovayomiReaderNavigationController: UINavigationController {
  override var childForHomeIndicatorAutoHidden: UIViewController? { topViewController }
  override var childForStatusBarHidden: UIViewController? { topViewController }
  override var childForStatusBarStyle: UIViewController? { topViewController }
}
