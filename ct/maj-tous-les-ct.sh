#!/usr/bin/env bash
# maj-tous-les-ct.sh : met à jour les paquets de tous les CT démarrés de cet hôte.
# Debian, Ubuntu (apt) et Alpine (apk). Les autres sont sautés avec un message.
set -euo pipefail
DOSSIER=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# shellcheck source=../lib/commun.sh
. "$DOSSIER/../lib/commun.sh"

aide() {
  cat <<'EOF'
Usage : maj-tous-les-ct.sh [options]

  --instantane         prend un instantané « maj-AAAAMMJJ-HHMM » avant chaque mise à jour
                       (un CT dont le stockage ne sait pas faire d'instantané est alors sauté)
  --garder N           nombre d'instantanés « maj-... » gardés par CT (par défaut 3)
  --seulement 101,102  ne traite que ces CT
  --exclure 103,104    saute ces CT
  --redemarrer         redémarre les CT qui le demandent après la mise à jour
  --essai --oui -h|--aide

Un CT avec l'étiquette Proxmox « sans-maj-auto » est toujours sauté.
Journal : /var/log/maj-tous-les-ct.log
EOF
}

INSTANTANE=0; GARDER=3; SEULEMENT=""; EXCLURE=""; REDEMARRER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --instantane) INSTANTANE=1 ;;
    --garder) GARDER=${2:-}; shift ;;
    --seulement) SEULEMENT=${2:-}; shift ;;
    --exclure) EXCLURE=${2:-}; shift ;;
    --redemarrer) REDEMARRER=1 ;;
    --essai) ESSAI=1 ;;
    --oui) OUI=1 ;;
    -h|--aide) aide; exit 0 ;;
    *) erreur "option inconnue : $1 (voir --aide)" ;;
  esac
  shift
done

verifier_root
verifier_pve
verifier_entier "$GARDER" "--garder"
[ "$ESSAI" = 1 ] || JOURNAL=/var/log/maj-tous-les-ct.log

exec 9>/run/lock/maj-tous-les-ct.lock
flock -n 9 || erreur "une autre mise à jour des CT tourne déjà"

dans_liste() { # dans_liste <id> <liste séparée par des virgules>
  case ",$2," in *",$1,"*) return 0 ;; esac
  return 1
}

LISTE=$(pct list | awk 'NR > 1 && $2 == "running" { print $1 }')
[ -n "$LISTE" ] || { info "aucun CT démarré"; exit 0; }

A_TRAITER=()
for id in $LISTE; do
  if [ -n "$SEULEMENT" ] && ! dans_liste "$id" "$SEULEMENT"; then continue; fi
  if [ -n "$EXCLURE" ] && dans_liste "$id" "$EXCLURE"; then info "CT $id exclu"; continue; fi
  if pct config "$id" | awk '/^tags:/ { print $2 }' | tr ';,' '\n\n' | grep -qx 'sans-maj-auto'; then
    info "CT $id sauté (étiquette sans-maj-auto)"; continue
  fi
  A_TRAITER+=("$id")
done
[ "${#A_TRAITER[@]}" -gt 0 ] || { info "rien à mettre à jour"; exit 0; }

info "CT à mettre à jour : ${A_TRAITER[*]}"
[ "$INSTANTANE" = 1 ] && info "un instantané sera pris avant chaque CT ($GARDER gardés)"
confirmer "On lance ?" || erreur "annulé"

nettoyer_instantanes() { # garde les $GARDER plus récents « maj-... »
  local id=$1 noms nb
  noms=$(pct listsnapshot "$id" 2>/dev/null | grep -oE 'maj-[0-9]{8}-[0-9]{4}' | sort -u || true)
  nb=$(printf '%s\n' "$noms" | grep -c . || true)
  [ "$nb" -gt "$GARDER" ] || return 0
  printf '%s\n' "$noms" | head -n "$((nb - GARDER))" | while read -r n; do
    faire pct delsnapshot "$id" "$n" && info "CT $id : ancien instantané $n supprimé"
  done
}

declare -A RESULTAT
for id in "${A_TRAITER[@]}"; do
  etape "CT $id ($(pct config "$id" | awk '/^hostname:/ { print $2 }'))"
  SYSTEME=$(pct exec "$id" -- sh -c '. /etc/os-release 2>/dev/null; echo "${ID:-inconnu}"' 2>/dev/null || echo inconnu)
  case "$SYSTEME" in
    debian|ubuntu) COMMANDE='export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade && apt-get -y -qq autoremove' ;;
    alpine) COMMANDE='apk update -q && apk upgrade -q' ;;
    *) attention "CT $id : système « $SYSTEME » non géré, sauté"; RESULTAT[$id]="sauté ($SYSTEME)"; continue ;;
  esac

  if [ "$INSTANTANE" = 1 ]; then
    NOM_INST="maj-$(date +%Y%m%d-%H%M)"
    if ! faire pct snapshot "$id" "$NOM_INST" --description "avant mise à jour par maj-tous-les-ct.sh"; then
      attention "CT $id : instantané impossible (stockage sans instantanés ?), CT sauté"
      RESULTAT[$id]="sauté (pas d'instantané)"
      continue
    fi
    info "CT $id : instantané $NOM_INST"
  fi

  if [ "$ESSAI" = 1 ]; then
    faire pct exec "$id" -- sh -c "$COMMANDE"
    RESULTAT[$id]="essai"
    continue
  fi
  if pct exec "$id" -- sh -c "$COMMANDE" >>"${JOURNAL:-/dev/null}" 2>&1; then
    RESULTAT[$id]="à jour"
    info "CT $id : à jour"
  else
    RESULTAT[$id]="ÉCHEC (voir $JOURNAL)"
    attention "CT $id : la mise à jour a échoué"
    [ "$INSTANTANE" = 1 ] && attention "retour arrière possible : pct rollback $id $NOM_INST"
    continue
  fi

  if pct exec "$id" -- test -f /var/run/reboot-required 2>/dev/null; then
    if [ "$REDEMARRER" = 1 ]; then
      pct reboot "$id" && RESULTAT[$id]="à jour, redémarré"
    else
      RESULTAT[$id]="à jour, redémarrage demandé"
    fi
  fi
  [ "$INSTANTANE" = 1 ] && nettoyer_instantanes "$id"
done

etape "Bilan"
for id in "${A_TRAITER[@]}"; do
  printf '  CT %-6s %s\n' "$id" "${RESULTAT[$id]:-?}" >&2
done
for id in "${A_TRAITER[@]}"; do
  case "${RESULTAT[$id]:-}" in ÉCHEC*) exit 1 ;; esac
done
exit 0
