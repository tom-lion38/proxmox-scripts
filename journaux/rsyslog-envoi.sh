#!/usr/bin/env bash
# rsyslog-envoi.sh : envoie les journaux de l'hôte et/ou de CT vers un serveur central
# (Loki avec Alloy, Graylog, un autre rsyslog...), en syslog RFC 5424.
# Une file d'attente sur disque garde les messages si le serveur est injoignable un moment.
set -euo pipefail
DOSSIER=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# shellcheck source=../lib/commun.sh
. "$DOSSIER/../lib/commun.sh"

aide() {
  cat <<'EOF'
Usage : rsyslog-envoi.sh --serveur HOTE [options]

  --serveur HOTE       nom ou adresse du serveur de journaux (obligatoire sauf --retirer)
  --port N             port d'écoute du serveur (par défaut 514)
  --udp                UDP au lieu de TCP (TCP conseillé : rien ne se perd en route)
  --hote               règle l'hôte Proxmox (par défaut si aucun --ct)
  --ct 101,102         règle ces CT (démarrés, Debian ou Ubuntu)
  --tous-les-ct        règle tous les CT démarrés Debian ou Ubuntu
  --envoi-seul         n'écrit plus les journaux dans /var/log (journald les garde quand même)
  --retirer            enlève la configuration posée par ce script
  --essai --oui -h|--aide

Exemple : rsyslog-envoi.sh --serveur journaux.lan --port 1514 --hote --tous-les-ct
EOF
}

SERVEUR=""; PORT=514; PROTO=tcp; HOTE=0; CTS=""; TOUS=0; ENVOI_SEUL=0; RETIRER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --serveur) SERVEUR=${2:-}; shift ;;
    --port) PORT=${2:-}; shift ;;
    --udp) PROTO=udp ;;
    --hote) HOTE=1 ;;
    --ct) CTS=${2:-}; shift ;;
    --tous-les-ct) TOUS=1 ;;
    --envoi-seul) ENVOI_SEUL=1 ;;
    --retirer) RETIRER=1 ;;
    --essai) ESSAI=1 ;;
    --oui) OUI=1 ;;
    -h|--aide) aide; exit 0 ;;
    *) erreur "option inconnue : $1 (voir --aide)" ;;
  esac
  shift
done

verifier_root
verifier_entier "$PORT" "--port"
if [ "$RETIRER" = 0 ]; then
  [ -n "$SERVEUR" ] || erreur "--serveur est obligatoire (voir --aide)"
  [[ "$SERVEUR" =~ ^[A-Za-z0-9.:-]+$ ]] || erreur "nom de serveur invalide : $SERVEUR"
fi

CIBLES=()
if [ "$TOUS" = 1 ] || [ -n "$CTS" ]; then verifier_pve; fi
if [ "$TOUS" = 1 ]; then
  for id in $(pct list | awk 'NR > 1 && $2 == "running" { print $1 }'); do CIBLES+=("$id"); done
elif [ -n "$CTS" ]; then
  IFS=',' read -r -a CIBLES <<< "$CTS"
fi
if [ "$HOTE" = 1 ] || [ "${#CIBLES[@]}" -eq 0 ]; then CIBLES=(hote "${CIBLES[@]}"); fi

CONF_RSYSLOG=/etc/rsyslog.d/10-envoi-central.conf
CONF_JOURNALD=/etc/systemd/journald.conf.d/50-vers-rsyslog.conf

if [ "$RETIRER" = 1 ]; then
  info "configuration à retirer sur : ${CIBLES[*]}"
else
  info "envoi vers $SERVEUR:$PORT en $PROTO depuis : ${CIBLES[*]}"
fi
confirmer "Continuer ?" || erreur "annulé"

contenu_rsyslog() {
  local cadre=""
  [ "$PROTO" = tcp ] && cadre=' TCP_Framing="octet-counted"'
  cat <<EOF
# Posé par proxmox-scripts (rsyslog-envoi.sh) : copie de tous les journaux vers le serveur central.
# La file sur disque (100 Mo max) garde les messages pendant une coupure du serveur.
*.* action(type="omfwd" target="$SERVEUR" port="$PORT" protocol="$PROTO"$cadre
       template="RSYSLOG_SyslogProtocol23Format"
       queue.type="LinkedList" queue.size="10000" queue.filename="envoi_central"
       queue.maxDiskSpace="100m" queue.saveOnShutdown="on"
       action.resumeRetryCount="-1" action.resumeInterval="30")
EOF
  # Ce fichier est lu avant les règles de /etc/rsyslog.conf : « stop » empêche l'écriture locale.
  if [ "$ENVOI_SEUL" = 1 ]; then echo "& stop"; fi
}

traiter() { # traiter <hote|id>
  local c=$1
  if [ "$c" = hote ]; then CIBLE_CT=""; else
    verifier_entier "$c" "l'ID du CT"
    CIBLE_CT=$c
    if ! ct_en_marche "$c"; then attention "CT $c arrêté, sauté"; return 0; fi
    if ! dans_cible '[ -f /etc/debian_version ]'; then attention "CT $c : ni Debian ni Ubuntu, sauté"; return 0; fi
  fi
  etape "$( [ -z "$CIBLE_CT" ] && echo "Hôte $(hostname)" || echo "CT $CIBLE_CT" )"

  if [ "$RETIRER" = 1 ]; then
    supprimer_cible "$CONF_RSYSLOG"
    supprimer_cible "$CONF_JOURNALD"
    faire_cible 'systemctl restart systemd-journald; systemctl restart rsyslog 2>/dev/null || true'
    return 0
  fi

  if ! dans_cible 'command -v rsyslogd >/dev/null 2>&1'; then
    faire_cible 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq rsyslog'
  fi
  # Dans un CT non privilégié, rsyslog ne peut pas lire les messages du noyau : on coupe imklog
  # pour éviter une erreur à chaque démarrage.
  if [ -n "$CIBLE_CT" ] && dans_cible 'grep -qE "^module\(load=\"imklog\"" /etc/rsyslog.conf 2>/dev/null'; then
    sauvegarder_cible /etc/rsyslog.conf
    faire_cible 'sed -i -E "s/^(module\(load=\"imklog\".*)/# \1   # coupé par proxmox-scripts (CT)/" /etc/rsyslog.conf'
  fi

  ecrire_cible "$CONF_JOURNALD" <<'EOF'
# Posé par proxmox-scripts : journald passe aussi les messages à rsyslog.
[Journal]
ForwardToSyslog=yes
EOF
  ecrire_cible "$CONF_RSYSLOG" < <(contenu_rsyslog)

  [ "$ESSAI" = 1 ] && return 0
  if ! dans_cible 'rsyslogd -N1 >/dev/null 2>&1'; then
    dans_cible "rm -f '$CONF_RSYSLOG'"
    attention "$(nom_cible)rsyslog refuse la configuration, fichier retiré"
    return 1
  fi
  dans_cible 'systemctl restart systemd-journald && systemctl enable --now rsyslog >/dev/null 2>&1 && systemctl restart rsyslog'
  dans_cible "logger -t proxmox-scripts 'test d envoi des journaux depuis \$(hostname)'"
  sleep 2
  if [ "$PROTO" = tcp ]; then
    if dans_cible "ss -Htn state established '( dport = :$PORT )' 2>/dev/null | grep -q ."; then
      info "$(nom_cible)connexion au serveur établie, message de test envoyé"
    else
      attention "$(nom_cible)pas de connexion TCP vers $SERVEUR:$PORT pour l'instant (pare-feu ? nom introuvable ?)"
    fi
  else
    info "$(nom_cible)message de test envoyé en UDP (pas d'accusé de réception possible)"
  fi
}

ECHECS=0
for c in "${CIBLES[@]}"; do
  traiter "$c" || ECHECS=$((ECHECS + 1))
done
etape "Bilan"
if [ "$ECHECS" -gt 0 ]; then attention "$ECHECS machine(s) en échec"; exit 1; fi
info "terminé. Cherche « test d envoi des journaux » sur ton serveur central."
