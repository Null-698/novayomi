import UIKit

/// Native cover and source grid shared by Browse and novel discovery.
/// Mirrors Aidoku's adaptive UICollectionView grid/list presentation while
/// preserving Novayomi's existing Dart source, search and download logic.
final class NovayomiPosterGrid: UIView, UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout {
  enum Style { case sources, novels }

  private let style: Style
  private let collection: UICollectionView
  private var items: [[String: Any]] = []
  var onSelect: ((Int) -> Void)?
  var menuFor: ((Int) -> UIMenu?)?
  var onRefresh: (() -> Void)?
  private let refresh = UIRefreshControl()
  private let spacing: CGFloat = 12
  private let sideInset: CGFloat = 16

  init(style: Style) {
    self.style = style
    let layout = UICollectionViewFlowLayout()
    layout.minimumInteritemSpacing = spacing
    layout.minimumLineSpacing = 20
    collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    super.init(frame: .zero)
    collection.backgroundColor = .clear
    collection.dataSource = self
    collection.delegate = self
    collection.contentInset = UIEdgeInsets(top: 14, left: sideInset, bottom: 26, right: sideInset)
    collection.alwaysBounceVertical = true
    collection.keyboardDismissMode = .onDrag
    collection.refreshControl = refresh
    refresh.addTarget(self, action: #selector(refreshRequested), for: .valueChanged)
    collection.register(NovayomiPosterCell.self, forCellWithReuseIdentifier: "poster")
    collection.translatesAutoresizingMaskIntoConstraints = false
    addSubview(collection)
    NSLayoutConstraint.activate([
      collection.topAnchor.constraint(equalTo: topAnchor),
      collection.leadingAnchor.constraint(equalTo: leadingAnchor),
      collection.trailingAnchor.constraint(equalTo: trailingAnchor),
      collection.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
    isHidden = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func display(_ entries: [[String: Any]]) {
    items = entries
    collection.reloadData()
  }
  func finishRefresh() { refresh.endRefreshing() }
  @objc private func refreshRequested() { onRefresh?() }

  func numberOfSections(in collectionView: UICollectionView) -> Int { 1 }
  func collectionView(_ collectionView: UICollectionView,
                      numberOfItemsInSection section: Int) -> Int { items.count }

  func collectionView(_ collectionView: UICollectionView,
    cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "poster", for: indexPath)
      as! NovayomiPosterCell
    cell.configure(items[indexPath.item], style: style)
    return cell
  }

  func collectionView(_ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    sizeForItemAt indexPath: IndexPath) -> CGSize {
    let width = max(1, collectionView.bounds.width - sideInset * 2)
    // Aidoku's two-column manga covers have room to breathe on an iPhone.
    // Sources use three compact icon columns; both adapt to iPad widths.
    let columns: CGFloat = style == .novels
      ? (width >= 700 ? 5 : width >= 430 ? 3 : 2)
      : (width >= 700 ? 6 : width >= 430 ? 4 : 3)
    let itemWidth = floor((width - (columns - 1) * spacing) / columns)
    let imageHeight = style == .novels ? itemWidth * 1.43 : itemWidth
    return CGSize(width: itemWidth, height: imageHeight + (style == .novels ? 57 : 60))
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    onSelect?(indexPath.item)
  }

  func collectionView(_ collectionView: UICollectionView,
    contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint)
    -> UIContextMenuConfiguration? {
    guard let menu = menuFor?(indexPath.item) else { return nil }
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
  }
}

private final class NovayomiPosterCell: UICollectionViewCell {
  private let cover = UIImageView()
  private let title = UILabel()
  private let detail = UILabel()
  private var representedURL: String?
  private static let images = NSCache<NSString, UIImage>()

  override init(frame: CGRect) {
    super.init(frame: frame)
    cover.layer.cornerRadius = 9
    cover.clipsToBounds = true
    cover.backgroundColor = .tertiarySystemFill
    cover.contentMode = .scaleAspectFill
    cover.translatesAutoresizingMaskIntoConstraints = false
    title.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
      for: .systemFont(ofSize: 14, weight: .medium))
    title.adjustsFontForContentSizeCategory = true
    title.numberOfLines = 2
    title.textAlignment = .left
    title.translatesAutoresizingMaskIntoConstraints = false
    detail.font = .preferredFont(forTextStyle: .caption2)
    detail.textColor = .secondaryLabel
    detail.numberOfLines = 1
    detail.translatesAutoresizingMaskIntoConstraints = false
    for subview in [cover, title, detail] { contentView.addSubview(subview) }
    NSLayoutConstraint.activate([
      cover.topAnchor.constraint(equalTo: contentView.topAnchor),
      cover.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      cover.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      title.topAnchor.constraint(equalTo: cover.bottomAnchor, constant: 6),
      title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      title.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
      detail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      detail.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      detail.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor)
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func prepareForReuse() {
    super.prepareForReuse()
    representedURL = nil
    cover.image = nil
    title.text = nil
    detail.text = nil
  }

  func configure(_ data: [String: Any], style: NovayomiPosterGrid.Style) {
    let source = style == .sources
    let heading = data[source ? "name" : "title"] as? String ?? (source ? "Source" : "Novel")
    title.text = heading
    detail.text = source ? (data["lang"] as? String ?? "")
      : (data["description"] as? String ?? "")
    accessibilityLabel = [heading, detail.text ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
    isAccessibilityElement = true
    cover.contentMode = source ? .scaleAspectFit : .scaleAspectFill
    cover.image = UIImage(systemName: source ? "books.vertical" : "book.closed")
    cover.tintColor = .secondaryLabel
    let imageRatio: CGFloat = source ? 1 : 1.43
    // A new reuse cycle must not carry the previous aspect ratio constraint.
    for constraint in cover.constraints where constraint.identifier == "poster-aspect" {
      constraint.isActive = false
      cover.removeConstraint(constraint)
    }
    let ratio = cover.heightAnchor.constraint(equalTo: cover.widthAnchor, multiplier: imageRatio)
    ratio.identifier = "poster-aspect"
    ratio.isActive = true

    guard let path = data[source ? "icon" : "cover"] as? String,
          let url = URL(string: path), ["https", "http"].contains(url.scheme?.lowercased() ?? "")
    else {
      representedURL = nil
      return
    }
    representedURL = path
    if let cached = Self.images.object(forKey: path as NSString) {
      cover.image = cached
      return
    }
    var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
    for (key, value) in data["headers"] as? [String: String] ?? [:] {
      request.setValue(value, forHTTPHeaderField: key)
    }
    URLSession.shared.dataTask(with: request) { [weak self] bytes, _, _ in
      guard let bytes, let image = UIImage(data: bytes) else { return }
      Self.images.setObject(image, forKey: path as NSString)
      DispatchQueue.main.async {
        guard let self, self.representedURL == path else { return }
        self.cover.image = image
      }
    }.resume()
  }
}
