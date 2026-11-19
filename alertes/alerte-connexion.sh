#!/usr/bin/env bash
# alerte-connexion.sh : prévient sur ton téléphone (ntfy) quand root ouvre une session
# en SSH ou sur la console. Passe par pam_exec, en « optional » : si l'alerte ne part pas,
# la connexion n'est jamais bloquée.
#
#   alerte-connexion.sh --installer [--services sshd,login]
#   alerte-connexion.sh --tester
#   alerte-connexion.sh --retirer
set -euo pipefail
DOSSIER=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# shellcheck source=../lib/commun.sh
. "$DOSSIER/../lib/commun.sh"

ENVOYEUR=/usr/local/sbin/ntfy-envoyer
CROCHET=/usr/local/sbin/alerte-connexion
LIGNE_PAM="session optional pam_exec.so quiet $CROCHET"
CONF=/etc/proxmox-scripts/alertes.conf

aide() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  echo
  echo "Options : --services LISTE (par défaut sshd,login), --essai, --oui"
  echo "Réglages : $CONF (voir alertes.conf.exemple)"
}

ACTION=""; SERVICES="sshd,login"
while [ $# -gt 0 ]; do
  case "$1" in
    --installer) ACTION=installer ;;
    --retirer) ACTION=retirer ;;
    --tester) ACTION=tester ;;
    --services) SERVICES=${2:-}; shift ;;
    --essai) ESSAI=1 ;;
    --oui) OUI=1 ;;
    -h|--aide) aide; exit 0 ;;
    *) erreur "option inconnue : $1 (voir --aide)" ;;
  esac
  shift
done
[ -n "$ACTION" ] || { aide; exit 2; }
verifier_root

installer() {
  [ -r "$CONF" ] || erreur "copie d'abord alertes.conf.exemple dans $CONF et règle NTFY_URL et NTFY_SUJET"
  ecrire_fichier "$ENVOYEUR" 755 < "$DOSSIER/ntfy-envoyer.sh"
  ecrire_fichier "$CROCHET" 755 <<'EOF'
#!/bin/sh
# Appelé par pam_exec à l'ouverture et à la fermeture d'une session (posé par proxmox-scripts).
# Prévient par ntfy quand un compte surveillé ouvre une session. Ne bloque jamais la connexion.
[ "${PAM_TYPE:-}" = open_session ] || exit 0
CONF=/etc/proxmox-scripts/alertes.conf
[ -r "$CONF" ] && . "$CONF"
case " ${ALERTE_COMPTES:-root} " in
  *" ${PAM_USER:-} "*) ;;
  *) exit 0 ;;
esac
SOURCE=${PAM_RHOST:-console}
for p in ${ALERTE_IGNORER_SOURCES:-}; do
  case "$SOURCE" in "$p"*) exit 0 ;; esac
done
MACHINE=$(hostname)
QUAND=$(date '+%d/%m/%Y %H:%M')
( timeout 20 /usr/local/sbin/ntfy-envoyer --priorite 4 --tags connexion \
    "Connexion $PAM_USER sur $MACHINE" \
    "Service : ${PAM_SERVICE:-?}, depuis : $SOURCE, le $QUAND" >/dev/null 2>&1 & ) || true
exit 0
EOF
  IFS=',' read -r -a LISTE <<< "$SERVICES"
  for s in "${LISTE[@]}"; do
    f=/etc/pam.d/$s
    [ -f "$f" ] || { attention "$f absent, sauté"; continue; }
    if grep -qF "$CROCHET" "$f"; then
      info "déjà branché : $f"
      continue
    fi
    if [ "$ESSAI" = 1 ]; then
      info "(essai) ajout dans $f : $LIGNE_PAM"
      continue
    fi
    sauvegarder_cible "$f"
    printf '\n# Alerte de connexion (proxmox-scripts)\n%s\n' "$LIGNE_PAM" >> "$f"
    info "branché : $f"
  done
  if [[ ",$SERVICES," == *",sshd,"* ]] && ! sshd -T 2>/dev/null | grep -qi '^usepam yes'; then
    attention "UsePAM n'est pas à yes dans sshd : les connexions SSH ne déclencheront rien"
  fi
  info "installé. Essaie : $0 --tester, puis une connexion SSH en root"
}

retirer() {
  local f
  for f in /etc/pam.d/*; do
    [ -f "$f" ] && grep -qF "$CROCHET" "$f" || continue
    if [ "$ESSAI" = 1 ]; then info "(essai) $f serait nettoyé"; continue; fi
    sauvegarder_cible "$f"
    sed -i "\#$CROCHET#d; /^# Alerte de connexion (proxmox-scripts)$/d" "$f"
    info "débranché : $f"
  done
  supprimer_cible "$CROCHET"
  info "$ENVOYEUR est laissé en place (d'autres scripts peuvent s'en servir)"
}

tester() {
  [ -x "$ENVOYEUR" ] || erreur "$ENVOYEUR absent : lance d'abord --installer"
  faire "$ENVOYEUR" --priorite 3 --tags test "Test depuis $(hostname)" "Si tu lis ça, les alertes marchent."
  info "message de test envoyé"
}

"$ACTION"
