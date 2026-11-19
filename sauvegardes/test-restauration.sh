#!/usr/bin/env bash
# test-restauration.sh : restaure la dernière sauvegarde d'un CT sur un ID jetable, sans réseau,
# vérifie qu'il démarre, puis le supprime. Une sauvegarde qu'on n'a jamais restaurée n'est qu'un espoir.
#
# Garde-fous :
#   - refuse de travailler sur un ID déjà pris, et ne supprime que le CT qu'il vient de créer
#     (repéré par sa description) ;
#   - la copie n'a aucune carte réseau, aucun point de montage lié à l'hôte, aucun périphérique,
#     aucune ligne lxc.mount.entry : elle ne peut ni parler au réseau ni écrire dans les dossiers
#     de l'original ;
#   - elle ne démarre pas avec l'hôte et n'est pas protégée contre la suppression.
set -euo pipefail
DOSSIER=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# shellcheck source=../lib/commun.sh
. "$DOSSIER/../lib/commun.sh"

aide() {
  cat <<'EOF'
Usage : test-restauration.sh --ct <id> [options]

  --ct ID              CT dont on teste la sauvegarde (obligatoire)
  --sauvegarde VOLID   sauvegarde précise à tester (par défaut la plus récente)
  --id-test ID         ID de la copie jetable (par défaut le premier libre entre 9900 et 9999)
  --stockage S         où restaurer (par défaut le même stockage que le CT d'origine)
  --commande "CMD"     commande lancée dans la copie pour vérifier l'application,
                       ex. "test -s /var/lib/monappli/base.db"
  --attente N          secondes laissées au démarrage (par défaut 90)
  --garder             ne supprime pas la copie à la fin (pour aller voir dedans)
  --alerter            message ntfy si le test échoue
  --essai --oui -h|--aide

Il faut de la place sur le stockage de destination : autant que le disque du CT.
EOF
}

SOURCE=""; VOLID=""; ID_TEST=""; STOCKAGE=""; COMMANDE=""; ATTENTE=90; GARDER=0; ALERTER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ct) SOURCE=${2:-}; shift ;;
    --sauvegarde) VOLID=${2:-}; shift ;;
    --id-test) ID_TEST=${2:-}; shift ;;
    --stockage) STOCKAGE=${2:-}; shift ;;
    --commande) COMMANDE=${2:-}; shift ;;
    --attente) ATTENTE=${2:-}; shift ;;
    --garder) GARDER=1 ;;
    --alerter) ALERTER=1 ;;
    --essai) ESSAI=1 ;;
    --oui) OUI=1 ;;
    -h|--aide) aide; exit 0 ;;
    *) erreur "option inconnue : $1 (voir --aide)" ;;
  esac
  shift
done

verifier_root
verifier_pve
verifier_commande python3
[ -n "$SOURCE" ] || { aide; exit 2; }
verifier_entier "$SOURCE" "--ct"
verifier_entier "$ATTENTE" "--attente"
NOEUD=$(hostname)
# Sans espace ni accent : Proxmox peut encoder la description, le repère doit rester lisible tel quel.
MARQUEUR="test-restauration-jetable"

# --- Quelle sauvegarde ? --------------------------------------------------------
derniere_sauvegarde() {
  local s tmp
  tmp=$(mktemp -d)
  for s in $(pvesm status --content backup 2>/dev/null | awk 'NR > 1 && $3 == "active" { print $1 }'); do
    pvesh get "/nodes/$NOEUD/storage/$s/content" --content backup --vmid "$SOURCE" --output-format json \
      > "$tmp/$s.json" 2>/dev/null || rm -f "$tmp/$s.json"
  done
  python3 - "$tmp" "$SOURCE" <<'EOF'
import glob, json, os, sys
dossier, vmid = sys.argv[1], sys.argv[2]
meilleure = None
for chemin in glob.glob(os.path.join(dossier, "*.json")):
    with open(chemin) as f:
        for s in json.load(f):
            volid = s.get("volid", "")
            est_ct = s.get("subtype") == "lxc" or s.get("format") == "pbs-ct" or "vzdump-lxc-" in volid
            if str(s.get("vmid")) == vmid and est_ct:
                if meilleure is None or s.get("ctime", 0) > meilleure.get("ctime", 0):
                    meilleure = s
if meilleure:
    print(meilleure["volid"])
EOF
  rm -rf "$tmp"
}

if [ -z "$VOLID" ]; then
  VOLID=$(derniere_sauvegarde)
  [ -n "$VOLID" ] || erreur "aucune sauvegarde de CT trouvée pour $SOURCE"
fi
case "$VOLID" in
  *vzdump-lxc-*|*backup/ct/*) ;;
  *) erreur "$VOLID ne ressemble pas à une sauvegarde de CT" ;;
esac

# --- Où et sous quel numéro ------------------------------------------------------
if [ -z "$ID_TEST" ]; then
  for i in $(seq 9900 9999); do
    if id_libre "$i"; then ID_TEST=$i; break; fi
  done
  [ -n "$ID_TEST" ] || erreur "aucun ID libre entre 9900 et 9999, précise --id-test"
else
  verifier_entier "$ID_TEST" "--id-test"
fi
id_libre "$ID_TEST" || erreur "l'ID $ID_TEST est déjà pris : je refuse de continuer"
[ "$ID_TEST" != "$SOURCE" ] || erreur "l'ID de test ne peut pas être celui du CT d'origine"

if [ -z "$STOCKAGE" ]; then
  STOCKAGE=$(pct config "$SOURCE" 2>/dev/null | sed -n 's/^rootfs: \([^:]*\):.*/\1/p')
  STOCKAGE=${STOCKAGE:-$(premier_stockage rootdir)}
fi
[ -n "$STOCKAGE" ] || erreur "impossible de choisir un stockage, précise --stockage"

info "sauvegarde testée : $VOLID"
info "copie jetable : CT $ID_TEST sur $STOCKAGE, sans réseau"
confirmer "Lancer le test de restauration ?" || erreur "annulé"

# --- Nettoyage, même en cas d'erreur ou d'interruption ----------------------------
CREE=0
nettoyer() {
  [ "$CREE" = 1 ] || return 0
  if [ "$GARDER" = 1 ]; then
    info "copie gardée : CT $ID_TEST (à supprimer à la main : pct destroy $ID_TEST --purge)"
    return 0
  fi
  if ! pct config "$ID_TEST" 2>/dev/null | grep -q "$MARQUEUR"; then
    attention "le CT $ID_TEST n'a pas la description attendue : je ne le supprime pas"
    return 0
  fi
  pct stop "$ID_TEST" >/dev/null 2>&1 || true
  pct destroy "$ID_TEST" --purge 1 >/dev/null 2>&1 \
    && info "copie $ID_TEST supprimée" \
    || attention "suppression de $ID_TEST ratée, à faire à la main"
}
trap nettoyer EXIT
trap 'exit 130' INT TERM

echec() {
  attention "ÉCHEC : $*"
  if [ "$ALERTER" = 1 ] && [ "$ESSAI" = 0 ]; then
    "$DOSSIER/../alertes/ntfy-envoyer.sh" --priorite 4 --tags sauvegardes \
      "Test de restauration raté ($NOEUD)" "CT $SOURCE, $VOLID : $*" || true
  fi
  exit 1
}

if [ "$ESSAI" = 1 ]; then
  faire pct restore "$ID_TEST" "$VOLID" --storage "$STOCKAGE" --unique 1
  info "(essai) ensuite : réseau, montages liés et périphériques retirés, démarrage, contrôles, suppression"
  exit 0
fi

# --- Restauration -----------------------------------------------------------------
etape "Restauration"
DEBUT=$(date +%s)
pct restore "$ID_TEST" "$VOLID" --storage "$STOCKAGE" --unique 1 || echec "pct restore a échoué"
CREE=1
info "restauré en $(( $(date +%s) - DEBUT )) s"

etape "Isolement de la copie"
pct set "$ID_TEST" --onboot 0 --protection 0 --hostname "test-restauration-$SOURCE" \
  --description "$MARQUEUR (CT $SOURCE, $(date '+%d/%m/%Y %H:%M'))" || echec "pct set a échoué"
for cle in $(pct config "$ID_TEST" | awk -F: '/^(net[0-9]+|dev[0-9]+|hookscript):/ { print $1 }'); do
  pct set "$ID_TEST" --delete "$cle"
  info "retiré : $cle"
done
for cle in $(pct config "$ID_TEST" | awk '/^mp[0-9]+: \// { sub(":", "", $1); print $1 }'); do
  pct set "$ID_TEST" --delete "$cle"
  info "retiré : $cle (montage lié à un dossier de l'hôte)"
done
CONF=/etc/pve/lxc/$ID_TEST.conf
# Montages et accès aux périphériques ajoutés à la main. lxc.idmap et les autres réglages restent :
# sans eux, un CT avec une table d'ID sur mesure ne démarrerait plus.
LXC_RISQUE='^lxc\.(mount\.entry|cgroup2?\.devices\.allow|hook\.)'
if grep -qE "$LXC_RISQUE" "$CONF"; then
  sed -i -E "1,/^\[/{/$LXC_RISQUE/d}" "$CONF"
  info "lignes lxc.mount.entry, accès aux périphériques et hooks retirés"
fi
pct config "$ID_TEST" | grep -qE '^net[0-9]+:' && echec "la copie a encore une carte réseau, arrêt par prudence"

# --- Démarrage et contrôles -------------------------------------------------------
etape "Démarrage"
pct start "$ID_TEST" || echec "la copie ne démarre pas"
attendre_ct "$ID_TEST" "$ATTENTE" || echec "la copie ne répond pas après $ATTENTE s"
ETAT=$(pct exec "$ID_TEST" -- timeout "$ATTENTE" systemctl is-system-running --wait 2>/dev/null || true)
info "état de systemd : ${ETAT:-inconnu}"
EN_ECHEC=$(pct exec "$ID_TEST" -- systemctl --failed --no-legend --plain 2>/dev/null | awk '{ print $1 }' | tr '\n' ' ' || true)
[ -n "$EN_ECHEC" ] && attention "services en échec (souvent normal sans réseau) : $EN_ECHEC"
pct exec "$ID_TEST" -- df -h / 2>/dev/null | tail -n1 | sed 's/^/    /' >&2 || true

case "$ETAT" in
  running|degraded) ;;
  *) echec "systemd n'a pas fini de démarrer (état : ${ETAT:-inconnu})" ;;
esac

if [ -n "$COMMANDE" ]; then
  if pct exec "$ID_TEST" -- sh -c "$COMMANDE"; then
    info "commande de contrôle : ok"
  else
    echec "la commande de contrôle a échoué : $COMMANDE"
  fi
fi

etape "Bilan"
info "RÉUSSI : la sauvegarde $VOLID du CT $SOURCE se restaure et démarre"
exit 0
