#!/usr/bin/env bash
# age-sauvegardes.sh : vérifie que chaque CT et chaque VM a une sauvegarde récente.
# Lecture seule : ne change rien, ne fait que regarder et prévenir.
set -euo pipefail
DOSSIER=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# shellcheck source=../lib/commun.sh
. "$DOSSIER/../lib/commun.sh"

aide() {
  cat <<'EOF'
Usage : age-sauvegardes.sh [options]

  --max-heures N       au-delà, la sauvegarde est jugée trop vieille (par défaut 26)
  --stockage S         ne regarde que ce stockage (par défaut tous ceux qui contiennent des sauvegardes)
  --exclure 101,102    ne vérifie pas ces machines
  --ignorer-arretes    ne vérifie pas les machines arrêtées
  --alerter            envoie un message ntfy s'il y a un problème (voir alertes/)
  -h, --aide

Code de sortie : 0 tout va bien, 1 au moins une sauvegarde manque ou est trop vieille.
Exemple pour cron, tous les matins à 9 h :
  0 9 * * * root /opt/proxmox-scripts/sauvegardes/age-sauvegardes.sh --alerter >/dev/null 2>&1
EOF
}

MAX_HEURES=26; STOCKAGE=""; EXCLURE=""; IGNORER_ARRETES=0; ALERTER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --max-heures) MAX_HEURES=${2:-}; shift ;;
    --stockage) STOCKAGE=${2:-}; shift ;;
    --exclure) EXCLURE=${2:-}; shift ;;
    --ignorer-arretes) IGNORER_ARRETES=1 ;;
    --alerter) ALERTER=1 ;;
    -h|--aide) aide; exit 0 ;;
    *) erreur "option inconnue : $1 (voir --aide)" ;;
  esac
  shift
done

verifier_root
verifier_pve
verifier_commande python3
verifier_entier "$MAX_HEURES" "--max-heures"

NOEUD=$(hostname)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pvesh get /cluster/resources --type vm --output-format json > "$TMP/machines.json"

if [ -n "$STOCKAGE" ]; then
  STOCKAGES=$STOCKAGE
else
  STOCKAGES=$(pvesm status --content backup 2>/dev/null | awk 'NR > 1 && $3 == "active" { print $1 }')
fi
[ -n "$STOCKAGES" ] || erreur "aucun stockage de sauvegarde actif trouvé"

for s in $STOCKAGES; do
  if ! pvesh get "/nodes/$NOEUD/storage/$s/content" --content backup --output-format json > "$TMP/sauv-$s.json" 2>/dev/null; then
    attention "stockage $s illisible, ignoré"
    rm -f "$TMP/sauv-$s.json"
  fi
done

set +e
RAPPORT=$(python3 - "$TMP" "$MAX_HEURES" "$EXCLURE" "$IGNORER_ARRETES" <<'EOF'
import glob, json, os, sys, time

dossier, max_heures, exclure, ignorer_arretes = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4] == "1"
exclus = {e.strip() for e in exclure.split(",") if e.strip()}

with open(os.path.join(dossier, "machines.json")) as f:
    machines = json.load(f)

derniere = {}
for chemin in glob.glob(os.path.join(dossier, "sauv-*.json")):
    with open(chemin) as f:
        for s in json.load(f):
            vmid = str(s.get("vmid", ""))
            ctime = int(s.get("ctime", 0))
            if vmid and ctime > derniere.get(vmid, 0):
                derniere[vmid] = ctime

maintenant = time.time()
probleme = 0
lignes = []
for m in sorted(machines, key=lambda x: int(x.get("vmid", 0))):
    vmid = str(m.get("vmid"))
    if m.get("template") or vmid in exclus:
        continue
    if ignorer_arretes and m.get("status") != "running":
        continue
    nom = m.get("name", "?")
    genre = "CT" if m.get("type") == "lxc" else "VM"
    t = derniere.get(vmid)
    if t is None:
        etat, quand, age = "AUCUNE", "-", "-"
        probleme = 1
    else:
        heures = (maintenant - t) / 3600
        quand = time.strftime("%d/%m %H:%M", time.localtime(t))
        age = "%.0f h" % heures
        if heures > max_heures:
            etat = "TROP VIEILLE"
            probleme = 1
        else:
            etat = "ok"
    lignes.append("%-3s %-6s %-24s %-12s %-7s %s" % (genre, vmid, nom[:24], quand, age, etat))

print("%-3s %-6s %-24s %-12s %-7s %s" % ("", "ID", "nom", "dernière", "âge", "état"))
print("\n".join(lignes))
sys.exit(probleme)
EOF
)
CODE=$?
set -e
[ "$CODE" -le 1 ] || erreur "lecture des sauvegardes impossible (python3 a renvoyé $CODE)"

printf '%s\n' "$RAPPORT"
if [ "$CODE" = 1 ]; then
  attention "au moins une machine n'a pas de sauvegarde de moins de $MAX_HEURES h"
  if [ "$ALERTER" = 1 ]; then
    MANQUES=$(printf '%s\n' "$RAPPORT" | grep -E 'AUCUNE|TROP VIEILLE' | tr -s ' ' | head -n 15)
    "$DOSSIER/../alertes/ntfy-envoyer.sh" --priorite 4 --tags sauvegardes \
      "Sauvegardes en retard sur $NOEUD" "$MANQUES" || attention "alerte ntfy non envoyée"
  fi
  exit 1
fi
info "toutes les machines vérifiées ont une sauvegarde de moins de $MAX_HEURES h"
