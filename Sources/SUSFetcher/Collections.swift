import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - Élément de collection

/// Un élément rangé dans une collection. Les produits du catalogue sont mémorisés par **titre**
/// (le Product ID change à chaque nouvelle version), les appareils IPSW par **identifiant** (stable).
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

// MARK: - Collection

struct ItemCollection: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var items: [Favorite] = []

    func contains(_ favorite: Favorite) -> Bool { items.contains { $0.id == favorite.id } }
}

@Observable
@MainActor
final class CollectionsStore {
    static let shared = CollectionsStore()
    private static let key = "collections"
    private static let legacyFavoritesKey = "favorites"

    private(set) var collections: [ItemCollection]

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([ItemCollection].self, from: data) {
            collections = decoded
        } else if let data = d.data(forKey: Self.legacyFavoritesKey),
                  let favorites = try? JSONDecoder().decode([Favorite].self, from: data), !favorites.isEmpty {
            // Ancien système « Favoris » : converti en une première collection.
            collections = [ItemCollection(name: "Favoris", items: favorites)]
        } else {
            collections = []
        }
    }

    // MARK: Lecture

    func collection(_ id: UUID) -> ItemCollection? { collections.first { $0.id == id } }

    /// Retrouve un élément (même s'il est dans plusieurs collections, c'est le même).
    func favorite(_ favoriteID: String) -> Favorite? {
        for c in collections { if let f = c.items.first(where: { $0.id == favoriteID }) { return f } }
        return nil
    }

    func isInAnyCollection(_ favorite: Favorite) -> Bool { collections.contains { $0.contains(favorite) } }

    // MARK: Collections

    @discardableResult
    func create(named name: String) -> UUID {
        let c = ItemCollection(name: name)
        collections.append(c)
        save()
        return c.id
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = index(id) else { return }
        collections[i].name = name
        save()
    }

    func delete(_ id: UUID) {
        collections.removeAll { $0.id == id }
        save()
        if case .collectionItem(let cid, _)? = ViewState.shared.sidebar, cid == id {
            ViewState.shared.sidebar = .installers
        }
    }

    func moveCollection(_ id: UUID, by offset: Int) {
        guard let i = index(id) else { return }
        let j = i + offset
        guard collections.indices.contains(j) else { return }
        collections.swapAt(i, j)
        save()
    }

    // MARK: Éléments

    func toggle(_ favorite: Favorite, in id: UUID) {
        guard let i = index(id) else { return }
        if collections[i].contains(favorite) {
            remove(favorite.id, from: id)
        } else {
            collections[i].items.append(favorite)
            save()
        }
    }

    func remove(_ favoriteID: String, from id: UUID) {
        guard let i = index(id) else { return }
        collections[i].items.removeAll { $0.id == favoriteID }
        save()
        if ViewState.shared.sidebar == .collectionItem(id, favoriteID) {
            ViewState.shared.sidebar = .installers
        }
    }

    func moveItems(in id: UUID, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let i = index(id) else { return }
        collections[i].items.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: Interactions (boîtes de dialogue)

    /// Demande un nom puis crée la collection (en y ajoutant éventuellement un élément).
    func createInteractively(adding favorite: Favorite? = nil) {
        // Différé : on sort d'abord du menu contextuel qui a déclenché l'action.
        Task { @MainActor in
            guard let name = promptForName(title: tr("Nouvelle collection", "New Collection"),
                                           initial: "",
                                           confirm: tr("Créer", "Create")) else { return }
            let id = create(named: name)
            if let favorite { toggle(favorite, in: id) }
        }
    }

    func renameInteractively(_ id: UUID) {
        guard let current = collection(id) else { return }
        Task { @MainActor in
            guard let name = promptForName(title: tr("Renommer la collection", "Rename Collection"),
                                           initial: current.name,
                                           confirm: tr("Renommer", "Rename")) else { return }
            rename(id, to: name)
        }
    }

    func deleteInteractively(_ id: UUID) {
        guard let c = collection(id) else { return }
        if c.items.isEmpty { delete(id); return }
        Task { @MainActor in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = tr("Supprimer la collection « \(c.name) » ?", "Delete the “\(c.name)” collection?")
            alert.informativeText = tr("Les \(c.items.count) éléments qu'elle contient en seront retirés. Rien n'est supprimé sur le disque.",
                                       "Its \(c.items.count) items will be removed from it. Nothing is deleted from disk.")
            alert.addButton(withTitle: tr("Supprimer", "Delete")).hasDestructiveAction = true
            alert.addButton(withTitle: tr("Annuler", "Cancel"))
            if alert.runModal() == .alertFirstButtonReturn { delete(id) }
        }
    }

    // MARK: Interne

    private func index(_ id: UUID) -> Int? { collections.firstIndex { $0.id == id } }

    private func save() {
        if let data = try? JSONEncoder().encode(collections) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// Petite boîte de dialogue « nom » (AppKit, pas besoin de @State).
@MainActor
func promptForName(title: String, initial: String, confirm: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    field.stringValue = initial
    field.placeholderString = tr("Nom de la collection", "Collection name")
    alert.accessoryView = field
    alert.addButton(withTitle: confirm)
    alert.addButton(withTitle: tr("Annuler", "Cancel"))
    alert.window.initialFirstResponder = field
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

// MARK: - Vues réutilisables

/// Sous-menu « Ajouter à une collection › » : une coche par collection, plus « Nouvelle collection… ».
struct AddToCollectionMenu: View {
    let favorite: Favorite

    var body: some View {
        Menu(tr("Ajouter à une collection", "Add to Collection")) {
            AddToCollectionItems(favorite: favorite)
        }
    }
}

/// Contenu du menu (utilisable directement dans un bouton-menu).
struct AddToCollectionItems: View {
    let favorite: Favorite

    var body: some View {
        let store = CollectionsStore.shared
        ForEach(store.collections) { c in
            Toggle(c.name, isOn: Binding(get: { c.contains(favorite) },
                                         set: { _ in store.toggle(favorite, in: c.id) }))
        }
        if !store.collections.isEmpty { Divider() }
        Button(tr("Nouvelle collection…", "New Collection…")) {
            store.createInteractively(adding: favorite)
        }
    }
}

/// Petite icône affichée à côté d'un élément rangé dans au moins une collection.
struct CollectionMark: View {
    var body: some View {
        Image(systemName: "folder.fill")
            .font(.caption2)
            .foregroundStyle(.tint)
            .help(tr("Dans une collection", "In a collection"))
    }
}

/// Section de sidebar d'une collection : en-tête (menu de gestion) + éléments réordonnables.
struct CollectionSection: View {
    let collection: ItemCollection
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        let store = CollectionsStore.shared
        Section {
            if collection.items.isEmpty {
                Text(tr("Vide — clic droit sur un élément › Ajouter à une collection",
                        "Empty — right-click an item › Add to Collection"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            ForEach(collection.items) { fav in
                Label(fav.label, systemImage: fav.icon)
                    .lineLimit(1)
                    .tag(SidebarItem.collectionItem(collection.id, fav.id))
                    .contextMenu {
                        Button(tr("Retirer de « \(collection.name) »", "Remove from “\(collection.name)”")) {
                            store.remove(fav.id, from: collection.id)
                        }
                    }
            }
            .onMove { store.moveItems(in: collection.id, fromOffsets: $0, toOffset: $1) }
        } header: {
            HStack {
                Text(collection.name)
                Spacer()
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button(tr("Renommer…", "Rename…")) { store.renameInteractively(collection.id) }
                Divider()
                Button(tr("Monter", "Move Up")) { store.moveCollection(collection.id, by: -1) }
                    .disabled(isFirst)
                Button(tr("Descendre", "Move Down")) { store.moveCollection(collection.id, by: 1) }
                    .disabled(isLast)
                Divider()
                Button(tr("Supprimer la collection…", "Delete Collection…")) { store.deleteInteractively(collection.id) }
            }
        }
    }
}
