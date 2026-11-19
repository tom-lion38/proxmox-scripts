#!/usr/bin/env bash
# ntfy-envoyer.sh : envoie une notification sur un serveur ntfy (ntfy.sh ou le tien).
# Autonome : il peut être copié seul, par exemple dans /usr/local/sbin/ntfy-envoyer.
#
#   ntfy-envoyer.sh [--priorite 1-5] [--tags a,b] [--essai] "Titre" "Message"
#
# Réglages lus dans /etc/proxmox-scripts/alertes.conf (ou le fichier donné par ALERTES_CONF) :
#   NTFY_URL=https://ntfy.exemple.fr   adresse du serveur, sans le sujet
#   NTFY_SUJET=homelab                 sujet (topic) auquel ton téléphone est abonné
#   NTFY_JETON=                        jeton d'accès si ton serveur en demande un (facultatif)
set -euo pipefail

CONF=${ALERTES_CONF:-/etc/proxmox-scripts/alertes.conf}
if [ -r "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
fi
NTFY_URL=${NTFY_URL:-}
NTFY_SUJET=${NTFY_SUJET:-}
NTFY_JETON=${NTFY_JETON:-}

PRIORITE=3; TAGS=""; ESSAI=${ESSAI:-0}
while [ $# -gt 0 ]; do
  case "$1" in
    --priorite) PRIORITE=${2:-3}; shift ;;
    --tags) TAGS=${2:-}; shift ;;
    --essai) ESSAI=1 ;;
    -h|--aide) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; break ;;
    -*) echo "ntfy-envoyer : option inconnue : $1" >&2; exit 2 ;;
    *) break ;;
  esac
  shift
done
TITRE=${1:-Message de $(hostname)}
MESSAGE=${2:-(vide)}

[[ "$PRIORITE" =~ ^[1-5]$ ]] || { echo "ntfy-envoyer : priorité de 1 à 5" >&2; exit 2; }
if [ -z "$NTFY_URL" ] || [ -z "$NTFY_SUJET" ]; then
  echo "ntfy-envoyer : NTFY_URL et NTFY_SUJET à régler dans $CONF" >&2
  exit 2
fi

json_texte() {
  local s
  s=$(printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037')
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/}
  s=${s//$'\t'/ }
  printf '"%s"' "$s"
}

LISTE_TAGS="[]"
if [ -n "$TAGS" ]; then
  LISTE_TAGS="["
  IFS=',' read -r -a T <<< "$TAGS"
  for t in "${T[@]}"; do LISTE_TAGS+="$(json_texte "$t"),"; done
  LISTE_TAGS="${LISTE_TAGS%,}]"
fi

CORPS="{\"topic\":$(json_texte "$NTFY_SUJET"),\"title\":$(json_texte "$TITRE"),\"message\":$(json_texte "$MESSAGE"),\"priority\":$PRIORITE,\"tags\":$LISTE_TAGS}"

if [ "$ESSAI" = 1 ]; then
  echo "(essai) POST $NTFY_URL"
  echo "$CORPS"
  exit 0
fi

ENTETES=(-H "Content-Type: application/json")
[ -n "$NTFY_JETON" ] && ENTETES+=(-H "Authorization: Bearer $NTFY_JETON")

for essai in 1 2 3; do
  if curl -fsS --max-time 10 "${ENTETES[@]}" -d "$CORPS" "${NTFY_URL%/}/" >/dev/null; then
    exit 0
  fi
  [ "$essai" -lt 3 ] && sleep 5
done
echo "ntfy-envoyer : envoi impossible vers $NTFY_URL" >&2
exit 1
