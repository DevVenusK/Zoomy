import UIKit
import Zoomy

/// Grid item with a stable identity so diffable snapshots stay consistent.
struct PhotoItem: Hashable {
    let id: UUID
    let color: UIColor

    static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

final class PhotoCell: UICollectionViewCell {

    static let reuseIdentifier = "PhotoCell"

    /// The view a zoom transition will animate from/to (wired up in M3).
    let photoView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        photoView.layer.cornerRadius = 12
        photoView.clipsToBounds = true
        photoView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(photoView)
        NSLayoutConstraint.activate([
            photoView.topAnchor.constraint(equalTo: contentView.topAnchor),
            photoView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            photoView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            photoView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with item: PhotoItem) {
        photoView.backgroundColor = item.color
    }
}

final class GridViewController: UIViewController {

    /// Which navigation style a tap triggers. Tab 1 pushes (M4 — not yet wired); tab 2 presents
    /// a modal zoom (M3b).
    enum Mode {
        case push
        case modal
    }

    var mode: Mode = .push

    private enum Section {
        case main
    }

    private let items: [PhotoItem] = (0..<60).map { _ in
        PhotoItem(
            id: UUID(),
            color: UIColor(
                hue: .random(in: 0...1),
                saturation: .random(in: 0.25...0.4),
                brightness: .random(in: 0.9...1.0),
                alpha: 1
            )
        )
    }

    private lazy var collectionView = UICollectionView(
        frame: .zero,
        collectionViewLayout: makeLayout()
    )

    private var dataSource: UICollectionViewDiffableDataSource<Section, PhotoItem>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureCollectionView()
        configureDataSource()
        applyInitialSnapshot()
    }

    private func makeLayout() -> UICollectionViewLayout {
        let spacing: CGFloat = 8
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / 3.0),
            heightDimension: .fractionalHeight(1.0)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalWidth(1.0 / 3.0)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        group.interItemSpacing = .fixed(spacing)

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = spacing
        section.contentInsets = NSDirectionalEdgeInsets(
            top: spacing, leading: spacing, bottom: spacing, trailing: spacing
        )
        return UICollectionViewCompositionalLayout(section: section)
    }

    private func configureCollectionView() {
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.register(PhotoCell.self, forCellWithReuseIdentifier: PhotoCell.reuseIdentifier)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Section, PhotoItem>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PhotoCell.reuseIdentifier,
                for: indexPath
            ) as? PhotoCell else {
                return UICollectionViewCell()
            }
            cell.configure(with: item)
            return cell
        }
    }

    private func applyInitialSnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, PhotoItem>()
        snapshot.appendSections([.main])
        snapshot.appendItems(items)
        dataSource?.apply(snapshot, animatingDifferences: false)
    }
}

extension GridViewController {

    /// Presents `item`'s detail with a Zoomy modal zoom. The source-view provider re-resolves the
    /// live cell by *stable ID* (not index path) at animation time — the consumer pattern from
    /// brief §3a — so a reload or scroll between tap and dismiss still finds the right source view
    /// (or cleanly falls back when the cell is off-screen).
    func presentZoomDetail(for item: PhotoItem) {
        let detail = PhotoDetailViewController(item: item)

        let capturedID = item.id
        detail.zoomTransition = ZoomTransition { [weak self] _ in
            guard let self,
                  let index = self.items.firstIndex(where: { $0.id == capturedID }) else {
                return nil
            }
            let path = IndexPath(item: index, section: 0)
            guard let cell = self.collectionView.cellForItem(at: path) as? PhotoCell else {
                return nil
            }
            return cell.photoView
        }

        present(detail, animated: true)
    }

    /// Pushes `item`'s detail with a Zoomy push zoom. Uses the same stable-ID re-resolution pattern
    /// as `presentZoomDetail`, so a scroll/reload between push and pop still finds the source cell.
    /// The navigation controller's `ZoomNavigationDelegate` (installed in `SceneDelegate`) vends the
    /// zoom driver for the push and the adjacent pop.
    func pushZoomDetail(for item: PhotoItem) {
        let detail = PhotoDetailViewController(item: item, presentationContext: .push)

        let capturedID = item.id
        detail.zoomTransition = ZoomTransition { [weak self] _ in
            guard let self,
                  let index = self.items.firstIndex(where: { $0.id == capturedID }) else {
                return nil
            }
            let path = IndexPath(item: index, section: 0)
            guard let cell = self.collectionView.cellForItem(at: path) as? PhotoCell else {
                return nil
            }
            return cell.photoView
        }

        navigationController?.pushViewController(detail, animated: true)
    }

    /// Screenshot / UI-test affordance: present the first item's detail without a tap. Inert
    /// unless invoked from `SceneDelegate` under the `-zoomyDemoPresent` launch argument.
    func presentFirstItemForDemo() {
        guard mode == .modal, let first = items.first else { return }
        presentZoomDetail(for: first)
    }

    /// Screenshot / UI-test affordance: push the first item's detail without a tap. Inert unless
    /// invoked from `SceneDelegate` under the `-zoomyDemoPush` launch argument.
    func pushFirstItemForDemo() {
        guard mode == .push, let first = items.first else { return }
        pushZoomDetail(for: first)
    }
}

extension GridViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)

        switch mode {
        case .push:
            pushZoomDetail(for: items[indexPath.item])
        case .modal:
            presentZoomDetail(for: items[indexPath.item])
        }
    }
}
