# proxmox-scripts

Des scripts pour Proxmox, tirés de ce que j'ai mis en place sur mon homelab et
réécrits de façon générique pour servir à d'autres. Ils visent Proxmox VE 9 et Proxmox Backup Server 4 (Debian 13). La plupart marchent
aussi sur PVE 8 et PBS 3 (Debian 12).

Ils tournent en root et touchent au système. Avant de lancer quoi que ce soit, lis le
script, puis lance-le une première fois avec `--essai` : il affiche ce qu'il ferait,
sans rien changer.

## Ce qu'il y a dedans

| Dossier | Script | À quoi ça sert |
| :-- | :-- | :-- |
| `post-install/` | `pve-post-install.sh` | dépôts gratuits, mises à jour, outils, heure, fail2ban en option |
| | `pbs-post-install.sh` | pareil pour Proxmox Backup Server, plus un coup d'œil aux tâches |
| `ct/` | `creer-ct.sh` | créer un CT Debian à partir d'un préréglage (petit, moyen, grand) |
| | `preparer-ct.sh` | premiers réglages d'un CT neuf : fuseau, mises à jour auto, compte, SSH |
| | `maj-tous-les-ct.sh` | mettre à jour tous les CT, avec un instantané avant si on veut |
| `sauvegardes/` | `age-sauvegardes.sh` | vérifier que chaque machine a une sauvegarde récente |
| | `test-restauration.sh` | restaurer un CT sur un ID jetable sans réseau, le démarrer, le supprimer |
| `alertes/` | `ntfy-envoyer.sh` | envoyer une notification sur le téléphone avec ntfy |
| | `alerte-connexion.sh` | être prévenu quand root se connecte |
| `journaux/` | `rsyslog-envoi.sh` | envoyer les journaux de l'hôte et des CT vers un serveur central |
| `onduleur/` | `nut-config.sh` | brancher l'hôte sur un onduleur avec NUT, délestage en option |

Chaque dossier a son README avec des exemples.

## Installation

```bash
apt install -y git
git clone https://github.com/tom-lion38/proxmox-scripts.git /opt/proxmox-scripts
cd /opt/proxmox-scripts
./post-install/pve-post-install.sh --essai
```

Les scripts chargent `lib/commun.sh`, il faut donc garder l'arborescence telle quelle.
Seul `alertes/ntfy-envoyer.sh` est autonome et peut être copié ailleurs.

## Options communes

| Option | Effet |
| :-- | :-- |
| `--essai` | affiche ce qui serait fait, ne modifie rien |
| `--oui` | ne pose aucune question (cron, lancement automatique) |
| `-h`, `--aide` | aide du script |

## Ce que les scripts font pour ne rien casser

- Un fichier modifié est d'abord copié dans `/root/proxmox-scripts-sauvegardes/<date>/`,
  avec son chemin complet (dans le CT quand le fichier est dans un CT). Les copies ne sont
  jamais posées à côté du fichier : apt lit tout ce qui se trouve dans `apt.conf.d`, une
  copie `.bak` laissée là resterait active.
- Un fichier qui a déjà le bon contenu n'est pas réécrit, on peut relancer un script
  autant de fois qu'on veut.
- Les configurations sont testées avant d'être appliquées quand l'outil le permet
  (`sshd -t`, `rsyslogd -N1`, `fail2ban-client -t`, `visudo -c`), et retirées si le
  test échoue.
- Les scripts qui suppriment quelque chose vérifient d'abord que c'est bien ce qu'ils
  ont créé eux-mêmes.

## Réglages

Les alertes lisent `/etc/proxmox-scripts/alertes.conf`. Un exemple commenté se trouve
dans `alertes/alertes.conf.exemple`.

## Compatibilité

| Système | Scripts prévus pour | Remarques |
| :-- | :-- | :-- |
| Proxmox VE 9 (Debian 13) | tous | cible principale |
| Proxmox VE 8 (Debian 12) | tous | les dépôts sont alors écrits en `.list` |
| Proxmox Backup Server 4 et 3 | `pbs-post-install.sh` | |
| CT Debian 12 et 13, Ubuntu 22.04 et 24.04 | `preparer-ct.sh`, `maj-tous-les-ct.sh`, `rsyslog-envoi.sh` | |
| CT Alpine | `maj-tous-les-ct.sh` seulement | |

Les scripts sont faits pour un nœud seul ou un petit cluster. Sur un cluster, lance-les
sur chaque nœud et lis les remarques de chaque README.

Ces versions génériques sont récentes et n'ont pas encore été essayées sur chaque
version : passe-les d'abord sur un nœud de test, avec `--essai` puis pour de vrai. Si
quelque chose ne marche pas chez toi, ouvre une issue avec la sortie du script et la
version (`pveversion`).

## Licence

MIT, voir `LICENSE`. Utilise, modifie, partage. Aucune garantie : c'est ton serveur.
