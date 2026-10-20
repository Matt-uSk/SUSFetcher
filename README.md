<p align="center"><img src="Resources/AppIcon.svg" width="128" alt="SUS Fetcher"></p>

# SUS Fetcher

App macOS native (Swift/SwiftUI, Apple Silicon, macOS 14+, sans aucune dépendance) qui lit le catalogue Apple Software Update et télécharge `InstallAssistant.pkg` **en un clic**, sans passer par clic droit → Packages → InstallAssistant.pkg.

## Origine et crédits

- **Inspiré de [SUS Inspector](https://github.com/hjuutilainen/sus-inspector)** de Hannes Juutilainen. Le concept (parcourir le catalogue Apple Software Update et en extraire les paquets) vient de là. SUS Inspector reposant sur Python 2 / PyObjC, SUS Fetcher en est une réécriture complète et moderne, centrée sur le téléchargement des installers macOS. Aucun code de SUS Inspector n'a été repris.
- **La majorité du code a été écrite par [Claude](https://claude.ai) (Anthropic)**, à partir des besoins, des tests et des retours de [Matt-uSk](https://github.com/Matt-uSk) sur une flotte de Mac gérée avec Jamf Pro.

## Fonctions

- Sidebar **Installers macOS** / **Autres** / **Téléchargements** (⌘1 / ⌘2 / ⌘3)
- Bouton « InstallAssistant.pkg » par ligne, double-clic, multi-sélection (clic droit)
- Page Téléchargements + mini-moniteur en bas de la sidebar : progression, vitesse, temps restant, **pause / reprise**, annulation, réessai
- Confirmation avant de quitter si des téléchargements sont en cours
- Produits « Autres » : menu des paquets, rangés dans `<Titre> <version> [<Product ID>]/`
- Canaux : Public, Bêta publique, Bêta développeur, AppleSeed — produits bêta marqués BÊTA, filtre « Bêtas uniquement »
- Recherche par titre / version / build / Product ID
- Métadonnées (.dist) mises en cache dans `~/Library/Application Support/SUSFetcher/`

## Réglages (⌘,)

- **Langue** : système / français / English (changement immédiat)
- **Apparence** : système / clair / sombre
- **Dossier de téléchargement** par défaut
- **Nommage des installers** : préréglages ou modèle personnalisé, avec aperçu

| Préréglage | Exemple |
|---|---|
| Nom Apple d'origine | `InstallAssistant.pkg` |
| InstallAssistant + version + build | `InstallAssistant-26.7.1-25H123.pkg` |
| Lisible (défaut) | `InstallermacOSTahoe-26.7.1.pkg` |
| Lisible + build | `InstallermacOSTahoe-26.7.1-25H123.pkg` |

Jetons du modèle personnalisé : `{name}` (titre sans espaces), `{title}`, `{version}`, `{build}`, `{id}`.
Un jeton vide est supprimé avec son séparateur.

## Build

```bash
chmod +x build-app.sh
./build-app.sh            # → build/SUS Fetcher.app
```

Ou pour tester rapidement : `swift run`. Ou `open Package.swift` pour l'ouvrir dans Xcode.

## Nouvelle version majeure de macOS

Dans `Sources/SUSFetcher/Models.swift`, ajouter le numéro en tête de `CatalogChannel.versions` (ex. `28-27-26-…`) et mettre à jour `latestMajor`.
