# post-install

À lancer une fois, juste après l'installation de Proxmox VE ou de Proxmox Backup Server.
Les deux scripts peuvent être relancés plus tard sans risque : ce qui est déjà en place
n'est pas réécrit.

## pve-post-install.sh

```bash
./pve-post-install.sh --essai                  # voir ce qui serait fait
./pve-post-install.sh                          # le minimum : dépôts, mises à jour, outils
./pve-post-install.sh --retirer-message --noeud-seul --fail2ban --reseau-confiance 192.168.10.0/24
```

Ce qu'il fait :

1. Coupe les dépôts « enterprise » de Proxmox et de Ceph. Sans abonnement payant ils
   renvoient une erreur 401 à chaque `apt update`. Sur PVE 9 la ligne `Enabled: no` est
   ajoutée dans le fichier `.sources`, sur PVE 8 la ligne est mise en commentaire.
2. Ajoute le dépôt gratuit `pve-no-subscription` (format deb822 sur PVE 9). Si un dépôt
   Ceph enterprise existait, il est remplacé par le dépôt Ceph `no-subscription` de la
   même version, pour que les paquets clients de Ceph continuent d'être mis à jour.
3. `apt update` puis `full-upgrade` (jamais `upgrade` seul sur Proxmox).
4. Installe des outils : htop, iotop, iftop, tmux, jq, rsync, git, dig, mtr, tcpdump,
   ethtool, smartmontools, nvme-cli, lm-sensors, sysstat, ncdu.
5. Vérifie que l'heure est synchronisée. Une horloge fausse casse les certificats, les
   sauvegardes et les graphiques de supervision.
6. Prévient s'il faut redémarrer pour un nouveau noyau.

Options :

- `--retirer-message` : retire la fenêtre « No valid subscription » à la connexion.
  Un petit script est posé dans `/usr/local/sbin/retirer-message-abonnement` et APT le
  relance après chaque mise à jour, sinon la fenêtre reviendrait. `--remettre-message`
  annule tout et réinstalle le fichier d'origine.
- `--noeud-seul` : coupe `pve-ha-lrm` et `pve-ha-crm`. Ils ne servent qu'en cluster et
  écrivent régulièrement sur le disque. Refusé si l'hôte est dans un cluster.
- `--fail2ban` : bloque une adresse après 5 échecs en 10 minutes, sur SSH et sur
  l'interface web (port 8006). Les journaux sont lus dans journald. Donne ton réseau
  avec `--reseau-confiance` pour ne pas te bloquer toi-même.
- `--sans-maj`, `--sans-paquets`, `--sans-ceph` : sautent l'étape correspondante.

## pbs-post-install.sh

```bash
./pbs-post-install.sh --essai
./pbs-post-install.sh --retirer-message
```

Mêmes étapes pour les dépôts, les mises à jour, les outils et l'heure. À la fin il
affiche les datastores et les tâches d'élagage et de vérification. Un datastore sans
élagage grossit jusqu'à remplir le disque, et le nettoyage (garbage collection) doit être
programmé pour libérer vraiment la place.

## Ce que ces scripts ne font pas

- Ils ne touchent pas au réseau (`/etc/network/interfaces`). Une erreur là-dedans coupe
  l'accès à la machine.
- Ils ne créent pas de compte et ne changent aucun mot de passe.
- Ils n'activent pas l'IOMMU ni le passthrough : ça dépend trop du matériel.
