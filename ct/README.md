# ct

Créer, préparer et mettre à jour des conteneurs LXC. Tout se lance sur l'hôte Proxmox.

## creer-ct.sh

```bash
# CT Debian 13 en DHCP, préréglage petit, numéro choisi par Proxmox
./creer-ct.sh --nom test-01

# Adresse fixe, préréglage moyen, démarré et préparé dans la foulée
./creer-ct.sh --nom web-01 --id 120 --preset moyen \
  --ip 192.168.10.50/24 --passerelle 192.168.10.1 --dns 192.168.10.1 --domaine maison.lan \
  --tags web --preparer
```

| Préréglage | Cœurs | RAM | Disque |
| :-- | :-- | :-- | :-- |
| petit | 1 | 512 Mo | 4 Go |
| moyen | 2 | 1 Go | 8 Go |
| grand | 4 | 4 Go | 16 Go |

`--cpu`, `--ram` et `--disque` changent une valeur sans changer de préréglage.

Choix par défaut :

- CT non privilégié avec `nesting=1` (systemd s'en sert dans Debian 13). `--docker` ajoute
  `keyctl=1`. `--privilegie` existe, mais un CT privilégié qui se fait prendre donne
  la main sur l'hôte.
- Le pare-feu de Proxmox est activé sur la carte réseau (`firewall=1`). Il ne bloque rien
  tant que tu n'as pas mis de règles.
- Démarrage avec l'hôte, fuseau de l'hôte.
- Root n'a pas de mot de passe : on entre avec `pct enter <id>`. `--cle` ajoute une clé SSH.
- Le modèle Debian le plus récent est téléchargé s'il n'est pas déjà là (`--modele` pour
  en prendre un autre, par exemple `ubuntu-24.04`).

## preparer-ct.sh

```bash
./preparer-ct.sh 120
./preparer-ct.sh 120 --utilisateur admin --cle ~/.ssh/id_ed25519.pub --ssh-durci \
  --locale fr_FR.UTF-8 --maj-auto tout --sans-postfix
```

Le CT doit être démarré. Ce qui est fait :

- fuseau horaire (celui de l'hôte par défaut) et langue si `--locale` ;
- mise à jour complète, puis `unattended-upgrades`, `needrestart`, `curl` ;
- mises à jour automatiques : sécurité seulement (par défaut) ou `--maj-auto tout` pour
  les mises à jour courantes en plus. `needrestart` relance les services touchés ;
- taille des journaux limitée (200 Mo par défaut, `--journald 500M` pour changer) ;
- `--utilisateur` crée un compte avec sudo et demande son mot de passe ;
- `--ssh-durci` coupe la connexion par mot de passe. Le script refuse s'il n'y a aucune
  clé dans le CT, pour ne pas te fermer la porte. Root est interdit en SSH si un compte
  avec clé existe, sinon il reste autorisé par clé seulement ;
- `--sans-postfix` retire Postfix, installé d'office dans les modèles Debian et rarement utile.

## maj-tous-les-ct.sh

```bash
./maj-tous-les-ct.sh --essai
./maj-tous-les-ct.sh --instantane --garder 3
./maj-tous-les-ct.sh --oui --instantane --redemarrer   # pour cron
```

Met à jour tous les CT démarrés de l'hôte (apt pour Debian et Ubuntu, apk pour Alpine).
Avec `--instantane`, un instantané `maj-AAAAMMJJ-HHMM` est pris avant, et seuls les 3 plus
récents sont gardés. Si la mise à jour casse quelque chose : `pct rollback <id> <instantané>`.
Un CT dont le stockage ne sait pas faire d'instantané (stockage « dir » en raw par exemple)
est sauté plutôt que mis à jour sans filet.

Pour qu'un CT ne soit jamais touché, ajoute-lui l'étiquette `sans-maj-auto` dans Proxmox.

Exemple de cron, le dimanche à 4 h :

```
0 4 * * 0 root /opt/proxmox-scripts/ct/maj-tous-les-ct.sh --oui --instantane >/dev/null 2>&1
```

## Et Home Assistant ?

Mon ancien dépôt `homelab-proxmox-docs` avait un script qui installait Home Assistant
« Supervised » dans un CT. Je ne l'ai pas repris : Home Assistant a abandonné cette
méthode d'installation, et elle n'a jamais été prévue pour un conteneur LXC. Le plus simple et le plus solide est une VM avec
l'image officielle Home Assistant OS (fichier `.qcow2` à importer avec `qm importdisk`).
La documentation de Home Assistant explique la marche à suivre pour Proxmox.
