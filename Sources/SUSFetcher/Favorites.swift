import Foundation
import Observation
import SwiftUI

/// Un favori. Les produits du catalogue sont mémorisés par **titre** (le Product ID change à chaque
/// nouvelle version), les appareils IPSW par **identifiant** (stable).
enum Favorite: Hashable, Codable, Identifiable, Sendable {
    case catalog(title: String, installer: Bool)
    case device(identifier: String, name: String)

    var id: String {
        switch self {
        case .catalog(let title, _): "catalog:\(title)"
        case .device(let identifier, _): "device:\(identifier)"
        }
    }

    var label: String {
        switch self {
        case .catalog(let title, _): title
        case .device(_, let name): name
        }
    }

    var icon: String {
        switch self {
        case .catalog(_, let installer): installer ? "laptopcomputer.and.arrow.down" : "shippingbox"
        case .device(let identifier, _):
            if IPSWFamily.iPhone.matches(identifier) { "iphone" }
            else if IPSWFamily.iPad.matches(identifier) { "ipad" }
            else { "laptopcomputer" }
        }
    }

    static func of(_ product: SUProduct) -> Favorite {
        .catalog(title: product.displayTitle, installer: product.isInstaller)
    }

    static func of(_ device: IPSWDevice) -> Favorite {
        .device(identifier: device.identifier, name: device.name)
    }
}

@Observable
@MainActor
final class FavoritesStore {
    static let shared = FavoritesStore()
    private static let key = "favorites"

    private(set) var items: [Favorite]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([Favorite].self, from: data) {
            items = decoded
        } else {
            items = []
        }
    }

    func item(_ id: String) -> Favorite? { items.first { $0.id == id } }
    func contains(_ favorite: Favorite) -> Bool { items.contains { $0.id == favorite.id } }

    func toggle(_ favorite: Favorite) {
        if contains(favorite) { remove(favorite.id) } else { items.append(favorite); save() }
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        save()
        // La page du favori retiré était affichée : on revient au catalogue.
        if ViewState.shared.sidebar == .favorite(id) { ViewState.shared.sidebar = .installers }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// Petite étoile affichée à côté d'un élément en favori.
struct FavoriteStar: View {
    var body: some View {
        Image(systemName: "star.fill")
            .font(.caption2)
            .foregroundStyle(.yellow)
            .help(tr("Dans les favoris", "In favorites"))
    }
}

/// Libellé du menu contextuel « Ajouter / Retirer des favoris ».
@MainActor
func favoriteMenuTitle(_ favorite: Favorite) -> String {
    FavoritesStore.shared.contains(favorite)
        ? tr("Retirer des favoris", "Remove from Favorites")
        : tr("Ajouter aux favoris", "Add to Favorites")
}
