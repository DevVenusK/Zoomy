import UIKit

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

extension GridViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        // M3에서 zoom present 연결
    }
}
