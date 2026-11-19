#!/usr/bin/env bash
# pbs-post-install.sh : réglages de base après l'installation de Proxmox Backup Server (3 ou 4).
set -euo pipefail
DOSSIER=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# shellcheck source=../lib/commun.sh
. "$DOSSIER/../lib/commun.sh"
# shellcheck source=../lib/depots.sh
. "$DOSSIER/../lib/depots.sh"

aide() {
  cat <<'EOF'
Usage : pbs-post-install.sh [options]

Par défaut :
  - coupe le dépôt enterprise et ajoute pbs-no-subscription
  - apt update + full-upgrade
  - installe quelques outils (htop, tmux, smartmontools...)
  - vérifie l'heure
  - affiche les datastores et les tâches d'élagage, de nettoyage et de vérification

Options :
  --essai              montre ce qui serait fait, sans rien changer
  --oui                ne pose pas de question
  --sans-maj           ne lance pas le full-upgrade
  --sans-paquets       n'installe pas les outils
  --retirer-message    retire la fenêtre « No valid subscription »
  --remettre-message   annule l'option précédente
  -h, --aide           cette aide
EOF
}

MAJ=1; PAQUETS=1; MESSAGE=0; REMETTRE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --essai) ESSAI=1 ;;
    --oui) OUI=1 ;;
    --sans-maj) MAJ=0 ;;
    --sans-paquets) PAQUETS=0 ;;
    --retirer-message) MESSAGE=1 ;;
    --remettre-message) REMETTRE=1 ;;
    -h|--aide) aide; exit 0 ;;
    *) erreur "option inconnue : $1 (voir --aide)" ;;
  esac
  shift
done

verifier_root
verifier_pbs
[ "$MESSAGE" = 1 ] && [ "$REMETTRE" = 1 ] && erreur "--retirer-message et --remettre-message en même temps ?"

CODE=$(codename_debian)
info "hôte : $(hostname), $(proxmox-backup-manager versions 2>/dev/null | head -n1), Debian $CODE"
[ "$ESSAI" = 1 ] && info "mode essai : rien ne sera modifié"
confirmer "Régler les dépôts et mettre ce PBS à jour ?" || erreur "annulé"

etape "Dépôts"
desactiver_depots_entreprise
ajouter_depot_sans_abonnement pbs
faire apt-get update || erreur "apt-get update a échoué, regarde /etc/apt/sources.list.d/"

if [ "$MAJ" = 1 ]; then
  etape "Mises à jour"
  faire env DEBIAN_FRONTEND=noninteractive apt-get -y \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
fi

if [ "$PAQUETS" = 1 ]; then
  etape "Outils"
  faire env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    curl ca-certificates htop iotop tmux rsync bind9-dnsutils smartmontools nvme-cli lm-sensors sysstat ncdu
fi

if [ "$MESSAGE" = 1 ]; then etape "Message d'abonnement"; retirer_message_abonnement; fi
if [ "$REMETTRE" = 1 ]; then etape "Message d'abonnement"; remettre_message_abonnement; fi

etape "Heure"
SYNCHRO=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo inconnu)
info "synchronisée : $SYNCHRO"
[ "$SYNCHRO" = yes ] || attention "heure non synchronisée : les sauvegardes et les certificats en dépendent, vérifie chrony"

etape "Datastores et tâches"
proxmox-backup-manager datastore list 2>/dev/null | sed 's/^/    /' >&2 || attention "aucun datastore lisible"
echo "  Élagage (prune) :" >&2
proxmox-backup-manager prune-job list 2>/dev/null | sed 's/^/    /' >&2 || true
echo "  Vérification :" >&2
proxmox-backup-manager verify-job list 2>/dev/null | sed 's/^/    /' >&2 || true
info "chaque datastore devrait avoir : un élagage (sinon il grossit sans fin), un nettoyage (garbage collection)"
info "programmé dans ses options, et une vérification de temps en temps (les données pourries se voient là)"

etape "Bilan"
info "terminé. Copies des fichiers modifiés : $SAUVEGARDES (s'il y en a eu)"
