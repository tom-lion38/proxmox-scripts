#!/usr/bin/env bash
# delestage-onduleur.sh : arrête proprement les CT et VM marqués « à délester » quand le
# courant est coupé depuis un moment. Installé par nut-config.sh dans /usr/local/sbin,
# lancé par NUT (upssched). Peut aussi se lancer à la main :
#
#   delestage-onduleur delestage        arrête les machines marquées
#   delestage-onduleur retour-secteur   note le retour du courant (ne redémarre rien)
#   ESSAI=1 delestage-onduleur delestage  montre ce qui serait arrêté, sans rien arrêter
#
# Garde-fous : rien n'est fait si /etc/proxmox-scripts/delestage.off existe ;
# seules les machines démarrées qui portent l'étiquette sont touchées.
set -uo pipefail

ETIQUETTE=delestable
[ -r /etc/proxmox-scripts/delestage.conf ] && . /etc/proxmox-scripts/delestage.conf
ESSAI=${ESSAI:-0}
COUPURE=/etc/proxmox-scripts/delestage.off

journal() { logger -t delestage-onduleur "$*"; echo "$*"; }

a_etiquette() { # a_etiquette <pct|qm> <id>
  "$1" config "$2" 2>/dev/null | awk '/^tags:/ { print $2 }' | tr ';,' '\n\n' | grep -qx "$ETIQUETTE"
}

case "${1:-}" in
  delestage)
    if [ -e "$COUPURE" ]; then journal "délestage demandé mais suspendu ($COUPURE existe)"; exit 0; fi
    journal "courant coupé depuis un moment : délestage des machines « $ETIQUETTE »"
    for id in $(pct list 2>/dev/null | awk 'NR > 1 && $2 == "running" { print $1 }'); do
      a_etiquette pct "$id" || continue
      if [ "$ESSAI" = 1 ]; then journal "(essai) CT $id serait arrêté"; continue; fi
      journal "arrêt du CT $id"
      ( pct shutdown "$id" --timeout 120 --forceStop 1 >/dev/null 2>&1 || journal "arrêt du CT $id raté" ) &
    done
    for id in $(qm list 2>/dev/null | awk 'NR > 1 && $3 == "running" { print $1 }'); do
      a_etiquette qm "$id" || continue
      if [ "$ESSAI" = 1 ]; then journal "(essai) VM $id serait arrêtée"; continue; fi
      journal "arrêt de la VM $id"
      ( qm shutdown "$id" --timeout 180 --forceStop 1 >/dev/null 2>&1 || journal "arrêt de la VM $id raté" ) &
    done
    wait
    journal "délestage terminé"
    ;;
  retour-secteur)
    journal "courant revenu. Les machines délestées restent arrêtées : à redémarrer à la main."
    ;;
  *)
    echo "usage : $0 delestage|retour-secteur" >&2
    exit 2
    ;;
esac
exit 0
