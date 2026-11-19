#!/usr/bin/env bash
# pve-post-install.sh : réglages de base juste après l'installation de Proxmox VE (8 ou 9).
# Dépôts gratuits, mises à jour, outils utiles, contrôle de l'heure, et quelques options.
set -euo pipefail
DOSSIER=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# shellcheck source=../lib/commun.sh
. "$DOSSIER/../lib/commun.sh"
# shellcheck source=../lib/depots.sh
. "$DOSSIER/../lib/depots.sh"

aide() {
  cat <<'EOF'
Usage : pve-post-install.sh [options]

Par défaut :
  - coupe les dépôts enterprise (payants) de Proxmox et de Ceph
  - ajoute le dépôt gratuit pve-no-subscription (et Ceph no-subscription si Ceph était là)
  - apt update + full-upgrade
  - installe quelques outils (htop, tmux, tcpdump, smartmontools...)
  - vérifie que l'heure est synchronisée

Options :
  --essai              montre ce qui serait fait, sans rien changer
  --oui                ne pose pas de question
  --sans-maj           ne lance pas le full-upgrade
  --sans-paquets       n'installe pas les outils
  --sans-ceph          ne remplace pas le dépôt Ceph enterprise par le gratuit
  --retirer-message    retire la fenêtre « No valid subscription » (refait après chaque mise à jour)
  --remettre-message   annule l'option précédente
  --noeud-seul         coupe les services de haute disponibilité (inutiles sans cluster)
  --fail2ban           installe fail2ban pour SSH et l'interface web (port 8006)
  --reseau-confiance R réseau jamais bloqué par fail2ban, ex. 192.168.10.0/24
  -h, --aide           cette aide
EOF
}

MAJ=1; PAQUETS=1; CEPH=1; MESSAGE=0; REMETTRE=0; NOEUD_SEUL=0; FAIL2BAN=0; RESEAU_CONFIANCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --essai) ESSAI=1 ;;
    --oui) OUI=1 ;;
    --sans-maj) MAJ=0 ;;
    --sans-paquets) PAQUETS=0 ;;
    --sans-ceph) CEPH=0 ;;
    --retirer-message) MESSAGE=1 ;;
    --remettre-message) REMETTRE=1 ;;
    --noeud-seul) NOEUD_SEUL=1 ;;
    --fail2ban) FAIL2BAN=1 ;;
    --reseau-confiance) RESEAU_CONFIANCE=${2:-}; shift ;;
    -h|--aide) aide; exit 0 ;;
    *) erreur "option inconnue : $1 (voir --aide)" ;;
  esac
  shift
done

verifier_root
verifier_pve
[ "$MESSAGE" = 1 ] && [ "$REMETTRE" = 1 ] && erreur "--retirer-message et --remettre-message en même temps ?"

VERSION=$(pveversion | head -n1)
CODE=$(codename_debian)
info "hôte : $(hostname), $VERSION, Debian $CODE"
[ "$ESSAI" = 1 ] && info "mode essai : rien ne sera modifié"

echo
echo "Ce script va :"
echo "  - couper les dépôts enterprise et ajouter les dépôts gratuits"
[ "$MAJ" = 1 ] && echo "  - mettre le système à jour (full-upgrade)"
[ "$PAQUETS" = 1 ] && echo "  - installer des outils d'administration"
[ "$MESSAGE" = 1 ] && echo "  - retirer le message d'abonnement de l'interface web"
[ "$REMETTRE" = 1 ] && echo "  - remettre le message d'abonnement d'origine"
[ "$NOEUD_SEUL" = 1 ] && echo "  - couper les services de haute disponibilité"
[ "$FAIL2BAN" = 1 ] && echo "  - installer fail2ban (SSH + interface web)"
echo
confirmer "On y va ?" || erreur "annulé"

etape "Dépôts"
desactiver_depots_entreprise
ajouter_depot_sans_abonnement pve
if [ "$CEPH" = 1 ]; then ajouter_depot_ceph; fi
faire apt-get update || erreur "apt-get update a échoué, regarde les dépôts dans /etc/apt/sources.list.d/"

if [ "$MAJ" = 1 ]; then
  etape "Mises à jour"
  faire env DEBIAN_FRONTEND=noninteractive apt-get -y \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
fi

if [ "$PAQUETS" = 1 ]; then
  etape "Outils"
  OUTILS=(curl wget ca-certificates htop iotop iftop tmux jq rsync git unzip
          bind9-dnsutils mtr-tiny tcpdump ethtool smartmontools nvme-cli lm-sensors sysstat ncdu)
  faire env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${OUTILS[@]}"
fi

if [ "$MESSAGE" = 1 ]; then
  etape "Message d'abonnement"
  retirer_message_abonnement
fi
if [ "$REMETTRE" = 1 ]; then
  etape "Message d'abonnement"
  remettre_message_abonnement
fi

etape "Heure"
if command -v timedatectl >/dev/null 2>&1; then
  SYNCHRO=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo inconnu)
  info "fuseau : $(timedatectl show -p Timezone --value 2>/dev/null || echo inconnu), synchronisée : $SYNCHRO"
  if [ "$SYNCHRO" != yes ]; then
    attention "l'heure n'est pas synchronisée. Vérifie chrony (chronyc sources) et que le port UDP 123 sort bien."
    attention "Une horloge fausse casse les certificats, les sauvegardes et les graphiques."
  fi
fi

if [ "$NOEUD_SEUL" = 1 ]; then
  etape "Nœud seul"
  if [ -f /etc/pve/corosync.conf ]; then
    attention "cet hôte fait partie d'un cluster : je laisse la haute disponibilité tranquille"
  else
    faire systemctl disable --now pve-ha-lrm pve-ha-crm
    info "haute disponibilité coupée. Pour la remettre : systemctl enable --now pve-ha-crm pve-ha-lrm"
  fi
fi

if [ "$FAIL2BAN" = 1 ]; then
  etape "fail2ban"
  faire env DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban python3-systemd
  ecrire_fichier /etc/fail2ban/filter.d/proxmox.conf <<'EOF'
# Échecs de connexion à l'interface web de Proxmox VE (posé par proxmox-scripts)
[Definition]
failregex = pvedaemon\[.*authentication (verification )?failure; rhost=<HOST> user=.* msg=.*
ignoreregex =
journalmatch = _SYSTEMD_UNIT=pvedaemon.service
EOF
  ecrire_fichier /etc/fail2ban/jail.d/proxmox-scripts.conf <<EOF
# Posé par proxmox-scripts. Les journaux sont lus dans journald (pas de /var/log/auth.log sur Debian 13).
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 $RESEAU_CONFIANCE
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
backend = systemd

[proxmox]
enabled = true
port = https,http,8006
filter = proxmox
backend = systemd
EOF
  if [ "$ESSAI" = 0 ]; then
    fail2ban-client -t >/dev/null || erreur "configuration fail2ban refusée (fail2ban-client -t)"
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban
    sleep 2
    fail2ban-client status | sed 's/^/    /' >&2 || true
  fi
  [ -n "$RESEAU_CONFIANCE" ] || attention "aucun --reseau-confiance : un mot de passe mal tapé 5 fois depuis chez toi bloque aussi ton IP pendant 1 h"
fi

etape "Bilan"
NOYAU_ACTUEL=$(uname -r)
NOYAU_RECENT=$(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null | sed 's/^vmlinuz-//' | sort -V | tail -n1)
if [ -n "$NOYAU_RECENT" ] && [ "$NOYAU_RECENT" != "$NOYAU_ACTUEL" ]; then
  attention "noyau $NOYAU_RECENT installé, $NOYAU_ACTUEL en marche : redémarre l'hôte quand tu peux"
fi
info "terminé. Copies des fichiers modifiés : $SAUVEGARDES (s'il y en a eu)"
info "à vérifier : pveversion -v | head, apt policy | head -n 20, pvesm status"
