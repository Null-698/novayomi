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
  private let progressControl = UISlider()
  private let progressCaption = UILabel()
  private lazy var readerControls = NovayomiReaderControls(
    progress: progressControl, caption: progressCaption
  )
  private var lastDisplayedPercent = -1
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
  private var autoScrollLink: CADisplayLink?
  private var autoScrollEnabled = false
  private var autoScrollSpeed = 10.0
  private var tapZonesEnabled = false
  private var ttsSpeed = 0.5
  private var ttsPitch = 1.0
  private var ttsLanguage: String?
  private var previousIdleTimerDisabled = false
  private var previousBrightness: CGFloat?

  init(chapter: [String: Any]) {
    self.chapter = chapter
    fontSize = chapter["fontSize"] as? Int ?? 16
    lineHeight = chapter["lineHeight"] as? Double ?? 1.5
    readingMode = chapter["mode"] as? String ?? "scroll"
    currentProgress = min(max(chapter["progress"] as? Double ?? 0, 0), 1)
    isBookmarked = chapter["bookmarked"] as? Bool ?? false
    autoScrollEnabled = chapter["autoScroll"] as? Bool ?? false
    autoScrollSpeed = chapter["autoScrollSpeed"] as? Double ?? 10
    tapZonesEnabled = chapter["tapZones"] as? Bool ?? false
    ttsSpeed = chapter["ttsSpeed"] as? Double ?? 0.5
    ttsPitch = chapter["ttsPitch"] as? Double ?? 1
    ttsLanguage = chapter["ttsLanguage"] as? String
    let config = WKWebViewConfiguration()
    config.defaultWebpagePreferences.allowsContentJavaScript = false
    config.allowsInlineMediaPlayback = false
    webView = WKWebView(frame: .zero, configuration: config)
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

    let tap = UITapGestureRecognizer(target: self, action: #selector(toggleChrome(_:)))
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

    // Aidoku-style native reader chrome: compact progress glass at the bottom;
    // chapter list, typography and actions live in the navigation bar.
    // Novel controls retain their existing native actions and Dart settings.
    progressControl.minimumValue = 0
    progressControl.maximumValue = 1
    progressControl.value = Float(currentProgress)
    progressControl.accessibilityLabel = "Reading progress"
    progressControl.addTarget(self, action: #selector(progressChanged(_:)), for: .valueChanged)
    progressControl.addTarget(self, action: #selector(progressEnded(_:)),
                              for: [.touchUpInside, .touchUpOutside, .touchCancel])

    readerControls.onPrevious = { [weak self] in self?.previousChapter() }
    readerControls.onNext = { [weak self] in self?.nextChapter() }
    readerControls.onChapters = { [weak self] in self?.showChapters() }
    readerControls.onFont = { [weak self] in self?.showFontSizeSheet() }
    readerControls.onLayout = { [weak self] in self?.cycleReadingLayout() }
    readerControls.onSpeech = { [weak self] in self?.toggleSpeech() }
    readerControls.onSettings = { [weak self] in self?.showSettings() }
    readerControls.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(readerControls)
    NSLayoutConstraint.activate([
      readerControls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
      readerControls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
      readerControls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
      readerControls.heightAnchor.constraint(equalToConstant: 72)
    ])
    updatePercentLabel()

    previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
    UIApplication.shared.isIdleTimerDisabled = chapter["keepAwake"] as? Bool ?? false
    updateBars()
    renderChapter()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    overrideUserInterfaceStyle = isDarkBook ? .dark : .light
    navigationController?.overrideUserInterfaceStyle = isDarkBook ? .dark : .light
    navigationController?.setNavigationBarHidden(!chromeVisible, animated: false)
    // The reader's two-row control surface owns the bottom chrome.
    // UIToolbar is intentionally hidden so it cannot duplicate buttons.
    navigationController?.setToolbarHidden(true, animated: false)
    readerControls.isHidden = !chromeVisible
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
    // Reserve only the compact native progress bar and its safe-area space.
    let bottom = max(100, (view.window?.safeAreaInsets.bottom ?? 0) + 74)
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
    let padding = max(0, min(chapter["padding"] as? Int ?? 16, 50))
    let alignment = ["left", "right", "center", "justify"].contains(safeString("alignment", fallback: "left"))
      ? safeString("alignment", fallback: "left") : "left"
    // OpenDyslexic is embedded from Novayomi's existing local font asset.
    let familyName = safeString("fontFamily", fallback: "")
    let embeddedFont = safeString("fontData", fallback: "")
    let fontFace = embeddedFont.isEmpty ? "" :
      "@font-face{font-family:'NovayomiDyslexic';src:url(data:font/otf;base64,\(embeddedFont)) format('opentype');}"
    let font: String
    switch familyName {
    case "OpenDyslexic": font = "'NovayomiDyslexic', -apple-system, sans-serif"
    case "Lexend": font = "'Lexend', -apple-system, sans-serif"
    case "AtkinsonHyperlegible": font = "'Atkinson Hyperlegible', -apple-system, sans-serif"
    default: font = "-apple-system, BlinkMacSystemFont, serif"
    }
    let modeStyle: String
    if readingMode == "pages" {
      let layout = safeString("pageLayout", fallback: "single")
      let twoPages = layout == "double" || (layout == "auto" && view.bounds.width > view.bounds.height)
      let columnWidth = twoPages ? "50vw" : "100vw"
      modeStyle = "html,body{height:100%;overflow-x:visible;overflow-y:hidden} #book{height:100vh;width:100vw;column-width:\(columnWidth);column-gap:0;column-fill:auto;overflow:visible;box-sizing:border-box}"
    } else {
      modeStyle = "html,body{min-height:100%;overflow-x:hidden} #book{box-sizing:border-box;min-height:100%;}"
    }
    return """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
    <style>
    \(fontFace)
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
    configureAutoScroll()
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
    updatePercentLabel()
  }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    if chromeVisible { setChromeVisible(false) }
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                         shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    return true
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    // A tap on a native chapter, slider, or settings control must never
    // toggle immersive mode at the same time.
    if gestureRecognizer is UITapGestureRecognizer {
      if !readerControls.isHidden && readerControls.bounds.contains(touch.location(in: readerControls)) {
        return false
      }
      if touch.view is UIControl { return false }
    }
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
    updatePercentLabel()
    reportProgress(force: false)
  }

  private func updatePercentLabel() {
    let percentage = Int((currentProgress * 100).rounded())
    let showCaption = chapter["showPercent"] as? Bool ?? true
    let leading: String
    let trailing: String
    if readingMode == "pages", didInitialLoad {
      let width = max(1, webView.scrollView.bounds.width)
      let pages = max(1, Int(ceil(webView.scrollView.contentSize.width / width)))
      let current = min(pages, max(1, Int(round(currentProgress * Double(max(0, pages - 1)))) + 1))
      leading = "\(current)"
      trailing = "\(pages)"
    } else {
      leading = "\(percentage)%"
      trailing = "100%"
    }
    readerControls.updateProgress(
      value: currentProgress,
      leading: leading,
      trailing: trailing,
      caption: showCaption ? "\(percentage)%" : nil
    )
    lastDisplayedPercent = percentage
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

    let closeItem = UIBarButtonItem(
      image: UIImage(systemName: "xmark"),
      style: .plain, target: self, action: #selector(closeReader))
    closeItem.accessibilityLabel = "Return to novel details"
    let chaptersItem = UIBarButtonItem(
      image: UIImage(systemName: "list.bullet"),
      style: .plain, target: self, action: #selector(showChapters))
    chaptersItem.accessibilityLabel = "Chapter list"
    navigationItem.leftBarButtonItems = [closeItem, chaptersItem]

    let fontItem = UIBarButtonItem(title: "aA", style: .plain,
      target: self, action: #selector(showFontSizeSheet))
    fontItem.accessibilityLabel = "Font size"
    let options = UIBarButtonItem(
      image: UIImage(systemName: "ellipsis.circle"),
      menu: UIMenu(children: [
        UIAction(title: bookmarked ? "Remove bookmark" : "Bookmark chapter",
                 image: UIImage(systemName: bookmarked ? "bookmark.slash" : "bookmark")) {
          [weak self] _ in self?.toggleBookmark()
        },
        UIAction(title: "Reading settings", image: UIImage(systemName: "textformat.size")) {
          [weak self] _ in self?.showSettings()
        },
        UIAction(title: "Change reading layout", image: UIImage(systemName: "book")) {
          [weak self] _ in self?.cycleReadingLayout()
        },
        UIAction(title: speech.isSpeaking ? "Stop reading aloud" : "Read aloud",
                 image: UIImage(systemName: "waveform")) {
          [weak self] _ in self?.toggleSpeech()
        }
      ]))
    options.accessibilityLabel = "Reader actions"
    navigationItem.rightBarButtonItems = [options, fontItem]

    readerControls.configure(
      hasPrevious: chapter["hasPrevious"] as? Bool ?? false,
      hasNext: chapter["hasNext"] as? Bool ?? false,
      mode: readingMode,
      pageLayout: safeString("pageLayout", fallback: "single"),
      speaking: speech.isSpeaking
    )
    updatePercentLabel()
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

  @objc private func showFontSizeSheet() {
    let sheet = NovayomiFontSizeSheet(fontSize: fontSize)
    sheet.onSizeChanged = { [weak self] size in self?.setFontSize(size) }
    presentReaderSheet(sheet)
  }

  @objc private func cycleReadingLayout() {
    // Follows novel_bottom_bar.dart: continuous -> single-page ->
    // double-page -> continuous, keeping existing saved settings in sync.
    let layout = safeString("pageLayout", fallback: "single")
    if readingMode == "scroll" {
      chapter["pageLayout"] = "single"
      onEvent?(["type": "pageLayout", "value": "single"])
      switchMode()
    } else if layout == "single" {
      applyReaderSetting(key: "pageLayout", value: "double")
    } else {
      switchMode()
    }
  }

  @objc private func showSettings() {
    let settings = NovayomiReadingSettingsSheet(
      fontSize: fontSize,
      lineHeight: lineHeight,
      padding: chapter["padding"] as? Int ?? 16,
      mode: readingMode,
      background: safeString("background", fallback: "#292832"),
      foreground: safeString("foreground", fallback: "#CCCCCC"),
      alignment: safeString("alignment", fallback: "left"),
      fontKey: safeString("fontFamily", fallback: ""),
      pageLayout: safeString("pageLayout", fallback: "single"),
      keepAwake: chapter["keepAwake"] as? Bool ?? false,
      showPercent: chapter["showPercent"] as? Bool ?? true,
      compactParagraphs: chapter["compactParagraphs"] as? Bool ?? false,
      tapZones: tapZonesEnabled,
      volumeKeys: chapter["volumeKeys"] as? Bool ?? false,
      invertVolume: chapter["invertVolume"] as? Bool ?? false,
      orientation: chapter["orientation"] as? Int ?? 0,
      autoScroll: autoScrollEnabled,
      autoScrollSpeed: autoScrollSpeed,
      ttsSpeed: ttsSpeed,
      ttsPitch: ttsPitch,
      ttsLanguage: ttsLanguage
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
      if let size = value as? Int { setFontSize(size) }
    case "lineHeight":
      if let spacing = value as? Double { setLineHeight(spacing) }
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
      case "light": palette = ("#FFFFFF", "#000000")
      case "black": palette = ("#000000", "#FFFFFF")
      case "sepia": palette = ("#F5E6D3", "#5F4B32")
      default: palette = ("#292832", "#CCCCCC")
      }
      chapter["background"] = palette.0
      chapter["foreground"] = palette.1
      onEvent?(["type": "background", "value": palette.0])
      onEvent?(["type": "foreground", "value": palette.1])
      updateReaderPalette()
    case "background", "foreground":
      guard let hex = value as? String else { return }
      chapter[key] = hex
      onEvent?(["type": key, "value": hex])
      updateReaderPalette()
    case "fontFamily":
      guard let font = value as? String else { return }
      chapter["fontFamily"] = font
      onEvent?(["type": "fontFamily", "value": font])
      applyReaderFont()
    case "pageLayout":
      guard let layout = value as? String else { return }
      chapter["pageLayout"] = layout
      onEvent?(["type": "pageLayout", "value": layout])
      if readingMode == "pages" {
        currentProgress = progressFraction()
        renderChapter()
      }
    case "keepAwake":
      guard let enabled = value as? Bool else { return }
      chapter["keepAwake"] = enabled
      UIApplication.shared.isIdleTimerDisabled = enabled
      onEvent?(["type": "keepAwake", "value": enabled])
    case "showPercent":
      guard let enabled = value as? Bool else { return }
      chapter["showPercent"] = enabled
      updatePercentLabel()
      onEvent?(["type": "showPercent", "value": enabled])
    case "tapZones":
      guard let enabled = value as? Bool else { return }
      tapZonesEnabled = enabled
      chapter["tapZones"] = enabled
      onEvent?(["type": "tapZones", "value": enabled])
    case "volumeKeys", "invertVolume":
      guard let enabled = value as? Bool else { return }
      chapter[key] = enabled
      onEvent?(["type": key, "value": enabled])
    case "orientation":
      guard let orientation = value as? Int else { return }
      chapter["orientation"] = orientation
      onEvent?(["type": "orientation", "value": orientation])
      if #available(iOS 16.0, *),
         let scene = view.window?.windowScene {
        let mask: UIInterfaceOrientationMask = orientation == 1 ? .portrait :
          orientation == 2 ? .landscape : .allButUpsideDown
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
      }
    case "compactParagraphs":
      guard let enabled = value as? Bool else { return }
      chapter["compactParagraphs"] = enabled
      onEvent?(["type": "compactParagraphs", "value": enabled])
      applyReaderCSS("document.querySelectorAll('p').forEach(p => p.style.marginBottom = '\(enabled ? 4 : 8)px')")
    case "autoScroll":
      guard let enabled = value as? Bool else { return }
      autoScrollEnabled = enabled
      chapter["autoScroll"] = enabled
      onEvent?(["type": "autoScroll", "value": enabled])
      configureAutoScroll()
    case "autoScrollSpeed":
      guard let speed = value as? Double else { return }
      autoScrollSpeed = speed
      chapter["autoScrollSpeed"] = speed
      onEvent?(["type": "autoScrollSpeed", "value": speed])
    case "brightness":
      guard let brightness = value as? Double else { return }
      if previousBrightness == nil { previousBrightness = UIScreen.main.brightness }
      UIScreen.main.brightness = CGFloat(brightness)
    case "ttsSpeed":
      guard let speed = value as? Double else { return }
      ttsSpeed = speed
      chapter["ttsSpeed"] = speed
      onEvent?(["type": "ttsSpeed", "value": speed])
    case "ttsPitch":
      guard let pitch = value as? Double else { return }
      ttsPitch = pitch
      chapter["ttsPitch"] = pitch
      onEvent?(["type": "ttsPitch", "value": pitch])
    case "ttsLanguage":
      guard let language = value as? String else { return }
      ttsLanguage = language.isEmpty ? nil : language
      chapter["ttsLanguage"] = ttsLanguage
      onEvent?(["type": "ttsLanguage", "value": language])
    case "alignment":
      guard let align = value as? String,
            ["left", "center", "right", "justify"].contains(align) else { return }
      chapter["alignment"] = align
      onEvent?(["type": "alignment", "value": align])
      applyReaderCSS("document.getElementById('book').style.textAlign = '\(align)'")
    default: break
    }
  }

  private func updateReaderPalette() {
    let background = cssColor("background", fallback: "#292832")
    let foreground = cssColor("foreground", fallback: "#CCCCCC")
    view.backgroundColor = readerBackground()
    webView.backgroundColor = readerBackground()
    overrideUserInterfaceStyle = isDarkBook ? .dark : .light
    navigationController?.overrideUserInterfaceStyle = isDarkBook ? .dark : .light
    setNeedsStatusBarAppearanceUpdate()
    applyReaderCSS("document.documentElement.style.backgroundColor = '\(background)'; document.body.style.backgroundColor = '\(background)'; document.body.style.color = '\(foreground)'")
  }

  private func applyReaderFont() {
    let key = safeString("fontFamily", fallback: "")
    let family: String
    switch key {
    case "OpenDyslexic": family = "NovayomiDyslexic"
    case "Lexend": family = "Lexend"
    case "AtkinsonHyperlegible": family = "Atkinson Hyperlegible"
    default: family = "-apple-system"
    }
    // Family names come from a fixed local list, never from chapter HTML.
    applyReaderCSS("document.body.style.fontFamily = '\(family)'")
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
    fontSize = min(40, max(8, newSize))
    chapter["fontSize"] = fontSize
    onEvent?(["type": "fontSize", "value": fontSize])
    applyReaderCSS("document.documentElement.style.setProperty('--reader-size', '\(fontSize)px')")
  }

  private func setLineHeight(_ newHeight: Double) {
    lineHeight = min(3, max(1.0, (newHeight * 10).rounded() / 10))
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
      utterance.rate = Float(min(max(self.ttsSpeed, 0.1), 1))
      utterance.pitchMultiplier = Float(min(max(self.ttsPitch, 0.5), 2))
      if let language = self.ttsLanguage {
        utterance.voice = AVSpeechSynthesisVoice(language: language)
      }
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
    readerControls.isHidden = !visible
    navigationController?.setToolbarHidden(true, animated: false)
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

  private func configureAutoScroll() {
    autoScrollLink?.invalidate()
    autoScrollLink = nil
    guard autoScrollEnabled, readingMode == "scroll", didInitialLoad else { return }
    let link = CADisplayLink(target: self, selector: #selector(autoScrollFrame(_:)))
    link.add(to: .main, forMode: .common)
    autoScrollLink = link
  }

  @objc private func autoScrollFrame(_ link: CADisplayLink) {
    let scroll = webView.scrollView
    guard !scroll.isDragging, !scroll.isDecelerating, didInitialLoad else { return }
    let limit = max(-contentInsets.top,
      scroll.contentSize.height - scroll.bounds.height + contentInsets.bottom)
    guard scroll.contentOffset.y < limit else {
      autoScrollEnabled = false
      configureAutoScroll()
      return
    }
    let delta = CGFloat(min(link.targetTimestamp - link.timestamp, 1.0 / 30.0) * autoScrollSpeed * 5)
    scroll.contentOffset.y = min(scroll.contentOffset.y + delta, limit)
  }

  @objc private func toggleChrome(_ gesture: UITapGestureRecognizer) {
    if tapZonesEnabled && !chromeVisible {
      let point = gesture.location(in: view)
      let width = view.bounds.width
      if point.x < width * 0.25 || point.x > width * 0.75 {
        let scroll = webView.scrollView
        if readingMode == "pages" {
          let direction: CGFloat = point.x < width * 0.25 ? -1 : 1
          scroll.setContentOffset(
            CGPoint(x: scroll.contentOffset.x + direction * scroll.bounds.width,
                    y: scroll.contentOffset.y), animated: true)
        } else {
          let direction: CGFloat = point.x < width * 0.25 ? -1 : 1
          scroll.setContentOffset(
            CGPoint(x: scroll.contentOffset.x,
                    y: scroll.contentOffset.y + direction * scroll.bounds.height * 0.83),
            animated: true)
        }
        return
      }
    }
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

  func handleVolumePage(forward: Bool) {
    let scroll = webView.scrollView
    if readingMode == "pages" {
      let delta: CGFloat = forward ? scroll.bounds.width : -scroll.bounds.width
      scroll.setContentOffset(
        CGPoint(x: scroll.contentOffset.x + delta, y: scroll.contentOffset.y),
        animated: true)
    } else {
      let delta: CGFloat = (forward ? 1 : -1) * scroll.bounds.height * 0.83
      scroll.setContentOffset(
        CGPoint(x: scroll.contentOffset.x, y: scroll.contentOffset.y + delta),
        animated: true)
    }
  }

  @objc private func closeReader() {
    guard !didReportClose else { return }
    didReportClose = true
    reportProgress(force: true)
    speech.stopSpeaking(at: .immediate)
    autoScrollLink?.invalidate()
    autoScrollLink = nil
    UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
    if let brightness = previousBrightness { UIScreen.main.brightness = brightness }
    // Keep native content visible while Flutter persists progress and
    // restores the previous details route. Dismissing here exposed Flutter's
    // reader-loading placeholder between screens.
    onEvent?(["type":"closeRequested"])
  }

  func finishClose() {
    guard didReportClose else { return }
    dismiss(animated: true) { [weak self] in
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
    ttsSpeed = data["ttsSpeed"] as? Double ?? ttsSpeed
    ttsPitch = data["ttsPitch"] as? Double ?? ttsPitch
    ttsLanguage = data["ttsLanguage"] as? String
    tapZonesEnabled = data["tapZones"] as? Bool ?? tapZonesEnabled
    autoScrollEnabled = data["autoScroll"] as? Bool ?? autoScrollEnabled
    autoScrollSpeed = data["autoScrollSpeed"] as? Double ?? autoScrollSpeed
    progressControl.value = Float(currentProgress)
    updatePercentLabel()
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
  private var fontChips: [UIButton] = []
  private var themeCards: [UIButton] = []
  private let keepAwake = UISwitch()
  private let showPercent = UISwitch()
  private let compactParagraphs = UISwitch()
  private let tapZones = UISwitch()
  private let autoScroll = UISwitch()
  private let volumeKeys = UISwitch()
  private let invertVolume = UISwitch()
  private let orientationControl = UISegmentedControl(items: ["Auto", "Portrait", "Landscape"])
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
  private let initialVolumeKeys: Bool
  private let initialInvertVolume: Bool
  private let initialOrientation: Int
  private let initialAutoScroll: Bool
  private let initialAutoScrollSpeed: Double
  private let initialTtsSpeed: Double
  private let initialTtsPitch: Double
  private var ttsLanguage: String?

  init(fontSize: Int, lineHeight: Double, padding: Int, mode: String,
       background: String, foreground: String, alignment: String,
       fontKey: String, pageLayout: String, keepAwake: Bool,
       showPercent: Bool, compactParagraphs: Bool, tapZones: Bool,
       volumeKeys: Bool, invertVolume: Bool, orientation: Int,
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
    initialVolumeKeys = volumeKeys
    initialInvertVolume = invertVolume
    initialOrientation = orientation
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
    volumeKeys.isOn = initialVolumeKeys
    invertVolume.isOn = initialInvertVolume
    orientationControl.selectedSegmentIndex = max(0, min(2, initialOrientation))
    orientationControl.addTarget(self, action: #selector(orientationChanged), for: .valueChanged)
    for control in [keepAwake, showPercent, compactParagraphs, tapZones, autoScroll, volumeKeys, invertVolume] {
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
      makeThemeCards(),
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
    form.addArrangedSubview(section("Font", children: [makeFontChips()]))
    form.addArrangedSubview(section("Reading mode", children: [modeControl]))
    if modeControl.selectedSegmentIndex == 1 {
      form.addArrangedSubview(section("Page mode", children: [pageControl]))
    }
  }

  private func makeThemeCards() -> UIView {
    let titles = ["Aa\nDark", "Aa\nLight", "Aa\nBlack", "Aa\nSepia"]
    let backgrounds: [UIColor] = [
      UIColor(red: 41 / 255, green: 40 / 255, blue: 50 / 255, alpha: 1),
      .white, .black,
      UIColor(red: 245 / 255, green: 230 / 255, blue: 211 / 255, alpha: 1)
    ]
    let foregrounds: [UIColor] = [
      .white, .black, .white,
      UIColor(red: 95 / 255, green: 75 / 255, blue: 50 / 255, alpha: 1)
    ]
    themeCards = titles.enumerated().map { index, title in
      let button = UIButton(type: .system)
      button.tag = index
      button.setTitle(title, for: .normal)
      button.titleLabel?.numberOfLines = 2
      button.titleLabel?.textAlignment = .center
      button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
      button.setTitleColor(foregrounds[index], for: .normal)
      button.backgroundColor = backgrounds[index]
      button.layer.cornerRadius = 16
      button.heightAnchor.constraint(equalToConstant: 56).isActive = true
      button.addTarget(self, action: #selector(themeCardTapped(_:)), for: .touchUpInside)
      return button
    }
    updateThemeSelection()
    return horizontalRow(themeCards)
  }

  private func updateThemeSelection() {
    for (index, button) in themeCards.enumerated() {
      button.layer.borderWidth = index == themeControl.selectedSegmentIndex ? 3 : 1
      button.layer.borderColor = index == themeControl.selectedSegmentIndex
        ? UIColor.systemBlue.cgColor : UIColor.separator.cgColor
    }
  }

  private func makeFontChips() -> UIView {
    let fonts = [
      ("Default", ""), ("OpenDyslexic", "OpenDyslexic"),
      ("Lexend", "Lexend"), ("Atkinson Hyperlegible", "AtkinsonHyperlegible")
    ]
    fontChips = fonts.enumerated().map { index, entry in
      let button = UIButton(type: .system)
      button.tag = index
      button.configuration = .tinted()
      button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
      button.setTitle(entry.0, for: .normal)
      button.addTarget(self, action: #selector(fontChipTapped(_:)), for: .touchUpInside)
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
      return button
    }
    updateFontChipSelection()
    let rows = UIStackView(arrangedSubviews: [
      horizontalRow(Array(fontChips[0...1])),
      horizontalRow(Array(fontChips[2...3]))
    ])
    rows.axis = .vertical
    rows.spacing = 8
    return rows
  }

  private func updateFontChipSelection() {
    let keys = ["", "OpenDyslexic", "Lexend", "AtkinsonHyperlegible"]
    for (index, button) in fontChips.enumerated() {
      let selected = keys[index] == fontKey
      button.layer.cornerRadius = 14
      button.layer.borderWidth = selected ? 2 : 1
      button.layer.borderColor = selected
        ? UIColor.systemBlue.cgColor : UIColor.separator.cgColor
    }
  }

  @objc private func themeCardTapped(_ button: UIButton) {
    themeControl.selectedSegmentIndex = button.tag
    updateThemeSelection()
    themeChanged()
  }

  @objc private func fontChipTapped(_ button: UIButton) {
    let keys = ["", "OpenDyslexic", "Lexend", "AtkinsonHyperlegible"]
    guard keys.indices.contains(button.tag) else { return }
    fontKey = keys[button.tag]
    updateFontChipSelection()
    updateFontMenu()
    onChange?("fontFamily", fontKey)
  }

  private func showGeneralSettings() {
    form.addArrangedSubview(section("Display", children: [
      switchRow("Keep screen on", control: keepAwake),
      switchRow("Show reading percentage", control: showPercent),
      switchRow("Remove extra paragraph spacing", control: compactParagraphs),
      switchRow("Use tap zones for paging", control: tapZones),
      switchRow("Volume buttons turn pages", control: volumeKeys),
      switchRow("Reverse volume page direction", control: invertVolume)
    ]))
    form.addArrangedSubview(section("Screen orientation", children: [
      orientationControl
    ]))
    form.addArrangedSubview(section("Auto-scroll", children: [
      switchRow("Auto-scroll while reading", control: autoScroll),
      sectionHint("Auto-scroll speed (2–30)"),
      sliderRow(autoScrollSpeed, value: nil)
    ]))
    form.addArrangedSubview(section("Screen brightness", children: [
      sliderRow(brightness, value: nil)
    ]))
  }

  private func showSpeechSettings() {
    form.addArrangedSubview(section("Speech rate", children: [
      sliderRow(ttsSpeed, value: ttsSpeedLabel)
    ]))
    form.addArrangedSubview(section("Speech pitch", children: [
      sliderRow(ttsPitch, value: ttsPitchLabel)
    ]))
    form.addArrangedSubview(section("Voice language", children: [
      languageButton
    ]))
    let play = UIButton(type: .system)
    play.configuration = .filled()
    play.setTitle("Read aloud / Stop", for: .normal)
    play.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    play.addTarget(self, action: #selector(speakTapped), for: .touchUpInside)
    form.addArrangedSubview(section("Playback", children: [play]))
  }

  private func sectionHint(_ content: String) -> UILabel {
    let label = UILabel()
    label.text = content
    label.font = .preferredFont(forTextStyle: .footnote)
    label.textColor = .secondaryLabel
    return label
  }

  private func section(_ title: String, children: [UIView]) -> UIView {
    // Mirrors NovelSettingSection: the heading is ABOVE its group, not
    // buried in the card. All controls remain native UIKit elements.
    let section = UIStackView()
    section.axis = .vertical
    section.spacing = 8

    let heading = UILabel()
    heading.text = title
    heading.font = .preferredFont(forTextStyle: .subheadline)
    heading.textColor = .label
    let accent = UIView()
    accent.backgroundColor = view.tintColor
    accent.layer.cornerRadius = 2
    accent.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      accent.widthAnchor.constraint(equalToConstant: 3),
      accent.heightAnchor.constraint(equalToConstant: 15)
    ])
    let header = UIStackView(arrangedSubviews: [accent, heading])
    header.axis = .horizontal
    header.alignment = .center
    header.spacing = 8
    header.isLayoutMarginsRelativeArrangement = true
    header.layoutMargins = UIEdgeInsets(top: 4, left: 3, bottom: 0, right: 3)
    section.addArrangedSubview(header)

    let card = UIStackView()
    card.axis = .vertical
    card.spacing = 12
    card.isLayoutMarginsRelativeArrangement = true
    card.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    card.backgroundColor = .secondarySystemGroupedBackground
    card.layer.cornerRadius = 16
    children.forEach(card.addArrangedSubview)
    section.addArrangedSubview(card)
    return section
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
    guard let value else { return slider }
    let row = UIStackView(arrangedSubviews: [slider, value])
    row.axis = .horizontal
    row.alignment = .center
    row.distribution = .fill
    row.spacing = 14
    value.widthAnchor.constraint(equalToConstant: 56).isActive = true
    return row
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
    updateFontChipSelection()
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
    let index = themeControl.selectedSegmentIndex
    guard (0...3).contains(index) else { return }
    let backgrounds = ["#292832", "#FFFFFF", "#000000", "#F5E6D3"]
    let foregrounds = ["#CCCCCC", "#000000", "#FFFFFF", "#5F4B32"]
    backgroundHex = backgrounds[index]
    foregroundHex = foregrounds[index]
    refreshColorLabels()
    onChange?("appearance", ["dark", "light", "black", "sepia"][index])
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
    else if control === volumeKeys { key = "volumeKeys" }
    else if control === invertVolume { key = "invertVolume" }
    else { key = "autoScroll" }
    onChange?(key, control.isOn)
  }
  @objc private func orientationChanged() {
    onChange?("orientation", orientationControl.selectedSegmentIndex)
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
    themeControl.selectedSegmentIndex = UISegmentedControl.noSegment
    updateThemeSelection()
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


/// UIKit implementation of lib/modules/novel/widgets/novel_bottom_bar.dart.
/// Both rows share one system-controlled glass material. The slider takes all
/// remaining width rather than being constrained by a UIBarButtonItem.
private final class NovayomiReaderControls: UIView {
  var onPrevious: (() -> Void)?
  var onNext: (() -> Void)?
  var onChapters: (() -> Void)?
  var onFont: (() -> Void)?
  var onLayout: (() -> Void)?
  var onSpeech: (() -> Void)?
  var onSettings: (() -> Void)?

  private let material: UIVisualEffectView
  private let slider: UISlider
  private let caption: UILabel
  private let currentLabel = UILabel()
  private let endLabel = UILabel()
  private let previous = UIButton(type: .system)
  private let nextChapterButton = UIButton(type: .system)
  private let chapterButton = UIButton(type: .system)
  private let fontButton = UIButton(type: .system)
  private let layoutButton = UIButton(type: .system)
  private let speechButton = UIButton(type: .system)
  private let settingsButton = UIButton(type: .system)

  init(progress: UISlider, caption: UILabel) {
    slider = progress
    self.caption = caption
    if #available(iOS 26.0, *) {
      material = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
      material.cornerConfiguration = .corners(radius: 24)
    } else {
      material = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
      material.layer.cornerRadius = 24
      material.clipsToBounds = true
    }
    super.init(frame: .zero)
    backgroundColor = .clear
    material.translatesAutoresizingMaskIntoConstraints = false
    addSubview(material)
    NSLayoutConstraint.activate([
      material.leadingAnchor.constraint(equalTo: leadingAnchor),
      material.trailingAnchor.constraint(equalTo: trailingAnchor),
      material.topAnchor.constraint(equalTo: topAnchor),
      material.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])

    configureButton(previous, symbol: "backward.end.fill", label: "Previous chapter", selector: #selector(previousTapped))
    configureButton(nextChapterButton, symbol: "forward.end.fill", label: "Next chapter", selector: #selector(nextTapped))
    previous.widthAnchor.constraint(equalToConstant: 40).isActive = true
    nextChapterButton.widthAnchor.constraint(equalToConstant: 40).isActive = true

    for label in [currentLabel, endLabel] {
      label.textColor = .label
      label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
      label.textAlignment = .center
      label.setContentCompressionResistancePriority(.required, for: .horizontal)
      label.widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
    }
    slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
    slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let progressRow = UIStackView(arrangedSubviews: [
      previous, currentLabel, slider, endLabel, nextChapterButton
    ])
    progressRow.axis = .horizontal
    progressRow.alignment = .center
    progressRow.spacing = 6
    progressRow.translatesAutoresizingMaskIntoConstraints = false
    material.contentView.addSubview(progressRow)

    caption.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    caption.textColor = .secondaryLabel
    caption.textAlignment = .center
    caption.translatesAutoresizingMaskIntoConstraints = false
    material.contentView.addSubview(caption)

    NSLayoutConstraint.activate([
      progressRow.topAnchor.constraint(equalTo: material.contentView.topAnchor, constant: 4),
      progressRow.leadingAnchor.constraint(equalTo: material.contentView.leadingAnchor, constant: 10),
      progressRow.trailingAnchor.constraint(equalTo: material.contentView.trailingAnchor, constant: -10),
      progressRow.heightAnchor.constraint(equalToConstant: 42),
      caption.topAnchor.constraint(equalTo: progressRow.bottomAnchor, constant: 1),
      caption.centerXAnchor.constraint(equalTo: material.contentView.centerXAnchor),
      caption.bottomAnchor.constraint(lessThanOrEqualTo: material.contentView.bottomAnchor, constant: -3)
    ])
  }

  required init?(coder: NSCoder) { fatalError("Storyboard init unsupported") }

  private func configureButton(_ button: UIButton, symbol: String, label: String, selector: Selector) {
    let configuration = UIImage.SymbolConfiguration(pointSize: 21, weight: .medium)
    button.setImage(UIImage(systemName: symbol, withConfiguration: configuration), for: .normal)
    button.tintColor = .label
    button.accessibilityLabel = label
    button.addTarget(self, action: selector, for: .touchUpInside)
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
  }

  func configure(hasPrevious: Bool, hasNext: Bool, mode: String, pageLayout: String, speaking: Bool) {
    previous.isEnabled = hasPrevious
    nextChapterButton.isEnabled = hasNext
    let symbol = mode == "scroll" ? "arrow.up.arrow.down" :
      pageLayout == "double" ? "book.closed" : "doc.text"
    layoutButton.setImage(UIImage(systemName: symbol), for: .normal)
    layoutButton.accessibilityValue = mode == "scroll" ? "Continuous scrolling" :
      pageLayout == "double" ? "Double-page" : "Single-page"
    speechButton.tintColor = speaking ? .systemBlue : .label
    speechButton.accessibilityLabel = speaking ? "Stop reading aloud" : "Read aloud"
  }

  func updateProgress(value: Double, leading: String, trailing: String, caption: String?) {
    if !slider.isTracking { slider.value = Float(min(max(value, 0), 1)) }
    currentLabel.text = leading
    endLabel.text = trailing
    self.caption.text = caption
    self.caption.isHidden = caption == nil
  }

  @objc private func previousTapped() { onPrevious?() }
  @objc private func nextTapped() { onNext?() }
  @objc private func chaptersTapped() { onChapters?() }
  @objc private func fontTapped() { onFont?() }
  @objc private func layoutTapped() { onLayout?() }
  @objc private func speechTapped() { onSpeech?() }
  @objc private func settingsTapped() { onSettings?() }
}

/// Font-size quick sheet from showNovelFontSizeBottomSheet: slider 8–40,
/// preset choices 12/14/16/18/20/24/28 and reset to the original 14 px.
private final class NovayomiFontSizeSheet: UIViewController {
  var onSizeChanged: ((Int) -> Void)?
  private let slider = UISlider()
  private let valueLabel = UILabel()
  private let sizes = [12, 14, 16, 18, 20, 24, 28]

  init(fontSize: Int) {
    super.init(nibName: nil, bundle: nil)
    slider.minimumValue = 8
    slider.maximumValue = 40
    slider.value = Float(fontSize)
  }

  required init?(coder: NSCoder) { fatalError("Storyboard init unsupported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Font size"
    view.backgroundColor = .systemGroupedBackground
    navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
      target: self, action: #selector(done))
    slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
    valueLabel.text = "\(Int(slider.value.rounded())) px"
    valueLabel.textAlignment = .center
    valueLabel.font = .preferredFont(forTextStyle: .headline)

    let column = UIStackView()
    column.axis = .vertical
    column.spacing = 18
    column.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(column)
    let row = UIStackView(arrangedSubviews: [slider, valueLabel])
    row.spacing = 12
    row.alignment = .center
    valueLabel.widthAnchor.constraint(equalToConstant: 62).isActive = true
    column.addArrangedSubview(row)
    // Flutter used a Wrap for its seven presets, not a cramped seven-item
    // horizontal toolbar. Use two equally-sized native rows on iPhone.
    let presets = UIStackView()
    presets.axis = .vertical
    presets.spacing = 8
    for group in [Array(sizes.prefix(4)), Array(sizes.suffix(3))] {
      let row = UIStackView()
      row.axis = .horizontal
      row.alignment = .fill
      row.distribution = .fillEqually
      row.spacing = 8
      for size in group {
        let button = UIButton(type: .system)
        button.configuration = .tinted()
        button.setTitle("\(size)", for: .normal)
        button.tag = size
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        button.addTarget(self, action: #selector(presetTapped(_:)), for: .touchUpInside)
        row.addArrangedSubview(button)
      }
      presets.addArrangedSubview(row)
    }
    column.addArrangedSubview(presets)
    let reset = UIButton(type: .system)
    reset.setTitle("Reset to 14 px", for: .normal)
    reset.addTarget(self, action: #selector(resetTapped), for: .touchUpInside)
    column.addArrangedSubview(reset)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18),
      column.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18),
      column.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 22)
    ])
  }

  private func setSize(_ size: Int) {
    slider.value = Float(size)
    valueLabel.text = "\(size) px"
    onSizeChanged?(size)
  }

  @objc private func sliderChanged() { setSize(Int(slider.value.rounded())) }
  @objc private func presetTapped(_ sender: UIButton) { setSize(sender.tag) }
  @objc private func resetTapped() { setSize(14) }
  @objc private func done() { dismiss(animated: true) }
}
