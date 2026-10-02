# Revelio Noël — banc d'essai des gestes de révélation

Date : 2026-10-02 · Statut : décidé en autonomie à la demande de Kélian (« fonce jusqu'à ce que tous les effets soient finis »), à recadrer après coup.

## Intention

Proto iOS pour **sentir sur iPhone** plusieurs façons de révéler une photo cachée, dans un habillage de Noël, et choisir laquelle retenir pour Revelio. Ce n'est pas une app produit : on privilégie la sensation et la comparaison rapide, avec des réglages exposés.

Ce que Kélian a dit :
- trois gestes : **souffler**, **gratter**, **secouer** ;
- usage : proto Revelio (tester les sensations, montrer à l'équipe) ;
- thème Noël, **plusieurs masques** : givre sur une vitre, neige accumulée, papier cadeau, ticket à gratter doré ;
- un **panneau de réglages** (sensibilités, taille du doigt, seuil d'auto-fin, haptique/son, mode debug) ;
- rendu en **SwiftUI pur + shaders Metal + Canvas** (approche B).

Hypothèses prises :
- geste et masque se choisissent **indépendamment** (4 × 3 = 12 combinaisons) ;
- une photo de Noël d'exemple embarquée + choix dans la photothèque (`PhotosPicker`) ;
- portrait uniquement (sinon secouer fait tourner l'écran) ; iPhone, iOS 26+.

## Écran

Un seul écran, fond nuit de Noël (dégradé bleu nuit → vert sapin, neige ambiante légère).

- **Au centre** : la photo façon tirage (bord blanc, coins arrondis, ombre), ratio 3:4. La révélation se passe dans la zone photo.
- **En haut** : titre discret « Revelio · Noël », bouton photothèque, bouton réglages.
- **En bas** : rangée « Geste » (Gratter / Souffler / Secouer), rangée « Masque » (Givre / Neige / Papier / Doré), phrase d'aide contextuelle (« Gratte la photo du bout du doigt », « Souffle sur le bas de l'iPhone », « Secoue ton iPhone »), bouton Recommencer. Contrôles en Liquid Glass.
- Changer de geste ou de masque **recouvre la photo à neuf**.
- **Mode debug** (réglages) : % révélé, vumètre micro avec la ligne de seuil, intensité de secousse, et un bouton à maintenir « Simuler » qui injecte le geste courant (souffle ou secousse) — indispensable en simulateur.

## Modèle commun : la carte de couverture

`CoverageField` : grille `cols × rows` de `Float` (1 = couvert, 0 = révélé), en coordonnées normalisées de la carte (0…1). Résolution ≈ 90 × 120. Les valeurs ne font que **descendre** (érosion monotone), ce qui permet de composer les gestes par `min`.

Les **gestes écrivent dans la carte**, de façon indépendante du masque :
- **Gratter** : pinceau doux le long du trait (interpolation entre deux échantillons tactiles), rayon et force réglables.
- **Souffler** : un front qui part du **bas-centre** (là où est le micro) et monte, bord bruité. Une progression `P` avance avec l'intensité du souffle ; chaque cellule a un seuil `d(cellule) = distance au bas-centre × (1 + bruit)`. `coverage = min(coverage, clamp((d − P) / bande))`.
- **Secouer** : chaque secousse fait avancer une progression `P` sur une carte de seuils **en gros morceaux** (bruit cellulaire), donc la couverture tombe par plaques.

Les **masques lisent la carte** et décident du rendu, des bords et des particules. Chaque frame, la carte rapporte les cellules érodées (position + quantité) pour que le masque émette des particules au bon endroit.

**Pourcentage révélé** = moyenne de `1 − coverage` (le papier calcule plutôt l'aire des morceaux détachés).

**Auto-fin** : à `revealed ≥ seuil` (réglable, 70 % par défaut, 100 % = désactivé), le reste se dissout en ~0,8 s, les morceaux restants tombent, puis célébration (paillettes dorées + rafale de neige, haptique de succès, carillon).

## Masques

| Masque | Rendu | Bord | Particules |
|---|---|---|---|
| **Givre** | photo floutée + voile blanc + cristaux (shader, plus épais sur les bords de la vitre) | liseré humide (ménisque clair/sombre) | éclats de glace (secouer), gouttelettes qui coulent (souffler), poudre de givre (gratter) |
| **Neige** | neige procédurale : bosses éclairées, reflets bleutés, paillettes qui scintillent | épaisseur visible + ombre portée sur la photo | flocons qui s'envolent (souffler), mottes qui tombent (secouer), poudre (gratter) |
| **Papier cadeau** | papier rouge à motifs + ruban doré en croix et nœud, découpé en ~50 morceaux (Voronoï) | déchirure blanche fibreuse le long des bords exposés | les morceaux eux-mêmes : ils se détachent quand la carte sous eux est assez érodée, tournoient, montrent leur verso blanc, tombent |
| **Doré** | feuille métallisée à motifs (étoiles, houx), texte « Gratte-moi », reflet qui suit l'inclinaison | net, légèrement dentelé, liseré sombre | copeaux dorés qui tombent |

Gravité des particules = gravité réelle du téléphone (Core Motion), (0, 1) par défaut.

## Entrées

- **Micro** (`AVAudioEngine`, tap sur l'entrée, mode `.measurement`) → RMS → dBFS → intensité 0…1 au-dessus d'un seuil réglable, lissée (attaque rapide, relâche plus lente). Permission micro demandée au passage sur « Souffler ».
- **Mouvement** (`CMMotionManager.deviceMotion`, 60 Hz) → accélération utilisateur → impulsion de secousse au-dessus d'un seuil réglable, avec direction ; gravité pour les particules ; attitude pour le reflet doré.
- **Toucher** : `DragGesture(minimumDistance: 0)` sur la carte.
- **Haptique** (Core Haptics) : texture continue modulée par la vitesse du doigt en grattant, grondement léger en soufflant, impulsions en secouant, motif de succès à la fin.
- **Son** (procédural, `AVAudioEngine`) : grattement (bruit filtré modulé par la vitesse), carillon de fin. Interrupteur dans les réglages.

## Réglages (persistés)

Gratter : taille du doigt, force · Souffler : sensibilité (seuil dB), vitesse · Secouer : seuil (g), vitesse · Fin : seuil d'auto-fin · Retours : haptique, son · Debug : overlay.

## Architecture

- `RevealEngine` (@Observable, MainActor) : tient la carte, les particules, l'état de session ; avancé par un `CADisplayLink`. Un compteur `frame` observé déclenche le rendu ; la carte elle-même n'est pas observée (évite le coût par mutation).
- Logique pure et testée : `CoverageField`, motifs d'érosion, `BlowAnalyzer`, `ShakeAnalyzer`, `ParticleSystem`, pièces Voronoï du papier, règles d'auto-fin.
- Vues : `RevealCardView` (photo + couche masque + Canvas particules), une vue par masque, shaders Metal `[[stitchable]]` recevant la carte en `floatArray`.
- Lancement de démo pour vérifier sans gestes : arguments `-RNMask`, `-RNGesture`, `-RNDemo` (érosion scriptée qui montre les bords).

## Tests

Swift Testing sur la logique pure ; rendu vérifié par captures simulateur ; sensations micro/mouvement/haptique à valider sur iPhone par Kélian.

## Hors périmètre

Vidéo révélée, partage, sauvegarde, iPad/paysage, sons enregistrés.
