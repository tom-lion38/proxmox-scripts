#!/usr/bin/env bash
# creer-ct.sh : crée un conteneur LXC (Debian par défaut) à partir d'un préréglage.
set -euo pipefail
DOSSIER=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# shellcheck source=../lib/commun.sh
. "$DOSSIER/../lib/commun.sh"

aide() {
  cat <<'EOF'
Usage : creer-ct.sh --nom <nom> [options]

  --nom NOM            nom d'hôte du CT (obligatoire), ex. web-01
  --id ID              numéro du CT (par défaut : le prochain libre)
  --preset P           petit (1 cœur, 512 Mo, 4 Go), moyen (2, 1 Go, 8 Go), grand (4, 4 Go, 16 Go)
  --cpu N --ram MO --disque GO   pour changer une valeur du préréglage
  --ip dhcp|CIDR       dhcp (par défaut) ou une adresse fixe, ex. 192.168.10.50/24
  --passerelle IP      obligatoire avec une adresse fixe, ex. 192.168.10.1
  --pont vmbr0         pont réseau (par défaut vmbr0)
  --vlan N             étiquette VLAN sur l'interface
  --dns IP             serveur DNS du CT (sinon celui de l'hôte)
  --domaine D          domaine de recherche, ex. maison.lan
  --stockage S         stockage du disque (par défaut le premier qui accepte les CT)
  --modele M           debian-13 (par défaut), debian-12, ubuntu-24.04...
  --cle FICHIER        clé SSH publique à mettre pour root
  --tags a,b           étiquettes Proxmox
  --docker             active keyctl en plus de nesting (pour Docker dans un CT non privilégié)
  --privilegie         CT privilégié (à éviter, seulement si tu sais pourquoi)
  --sans-demarrage-auto  ne démarre pas le CT avec l'hôte
  --demarrer           démarre le CT après la création
  --preparer           démarre le CT puis lance preparer-ct.sh dessus
  --essai --oui -h|--aide
EOF
}

ID=""; NOM=""; PRESET=petit; CPU=""; RAM=""; DISQUE=""; IP=dhcp; PASSERELLE=""; PONT=vmbr0; VLAN=""
DNS=""; DOMAINE=""; STOCKAGE=""; MODELE=debian-13; STOCKAGE_MODELES=${STOCKAGE_MODELES:-local}
CLE=""; TAGS=""; DOCKER=0; PRIVILEGIE=0; ONBOOT=1; DEMARRER=0; PREPARER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --id) ID=${2:-}; shift ;;
    --nom) NOM=${2:-}; shift ;;
    --preset) PRESET=${2:-}; shift ;;
    --cpu) CPU=${2:-}; shift ;;
    --ram) RAM=${2:-}; shift ;;
    --disque) DISQUE=${2:-}; shift ;;
    --ip) IP=${2:-}; shift ;;
    --passerelle) PASSERELLE=${2:-}; shift ;;
    --pont) PONT=${2:-}; shift ;;
    --vlan) VLAN=${2:-}; shift ;;
    --dns) DNS=${2:-}; shift ;;
    --domaine) DOMAINE=${2:-}; shift ;;
    --stockage) STOCKAGE=${2:-}; shift ;;
    --modele) MODELE=${2:-}; shift ;;
    --cle) CLE=${2:-}; shift ;;
    --tags) TAGS=${2:-}; shift ;;
    --docker) DOCKER=1 ;;
    --privilegie) PRIVILEGIE=1 ;;
    --sans-demarrage-auto) ONBOOT=0 ;;
    --demarrer) DEMARRER=1 ;;
    --preparer) PREPARER=1; DEMARRER=1 ;;
    --essai) ESSAI=1 ;;
    --oui) OUI=1 ;;
    -h|--aide) aide; exit 0 ;;
    *) erreur "option inconnue : $1 (voir --aide)" ;;
  esac
  shift
done

verifier_root
verifier_pve

# --- Contrôles ----------------------------------------------------------------
[ -n "$NOM" ] || erreur "--nom est obligatoire (voir --aide)"
[[ "$NOM" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,61}[a-zA-Z0-9])?$ ]] || erreur "nom d'hôte invalide : $NOM"

case "$PRESET" in
  petit) d_cpu=1; d_ram=512;  d_disque=4 ;;
  moyen) d_cpu=2; d_ram=1024; d_disque=8 ;;
  grand) d_cpu=4; d_ram=4096; d_disque=16 ;;
  *) erreur "préréglage inconnu : $PRESET (petit, moyen ou grand)" ;;
esac
CPU=${CPU:-$d_cpu}; RAM=${RAM:-$d_ram}; DISQUE=${DISQUE:-$d_disque}
verifier_entier "$CPU" "--cpu"; verifier_entier "$RAM" "--ram"; verifier_entier "$DISQUE" "--disque"
SWAP=512

if [ -z "$ID" ]; then
  ID=$(pvesh get /cluster/nextid)
else
  verifier_entier "$ID" "--id"
  [ "$ID" -ge 100 ] || erreur "les ID sous 100 sont réservés par Proxmox"
  id_libre "$ID" || erreur "l'ID $ID est déjà utilisé"
fi

if [ "$IP" = dhcp ]; then
  NET0="name=eth0,bridge=$PONT,firewall=1,ip=dhcp"
else
  [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || erreur "adresse invalide : $IP (attendu : 192.168.10.50/24)"
  [ -n "$PASSERELLE" ] || erreur "--passerelle est obligatoire avec une adresse fixe"
  NET0="name=eth0,bridge=$PONT,firewall=1,ip=$IP,gw=$PASSERELLE"
fi
if [ -n "$VLAN" ]; then verifier_entier "$VLAN" "--vlan"; NET0="$NET0,tag=$VLAN"; fi
ip link show "$PONT" >/dev/null 2>&1 || erreur "le pont $PONT n'existe pas sur cet hôte"

STOCKAGE=${STOCKAGE:-$(premier_stockage rootdir)}
[ -n "$STOCKAGE" ] || erreur "aucun stockage actif n'accepte les CT, précise --stockage"
pvesm status --content rootdir 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -qx "$STOCKAGE" \
  || erreur "le stockage $STOCKAGE n'accepte pas les disques de CT (contenu rootdir)"

if [ -n "$CLE" ]; then
  [ -r "$CLE" ] || erreur "clé introuvable : $CLE"
  grep -qE '^(ssh-|ecdsa-)' "$CLE" || erreur "$CLE ne ressemble pas à une clé publique SSH"
fi

# --- Modèle -------------------------------------------------------------------
MOTIF="^$MODELE-standard_"
trouver_modele_local() {
  pveam list "$STOCKAGE_MODELES" 2>/dev/null | awk 'NR > 1 { print $1 }' \
    | sed 's#.*/##' | grep -E "$MOTIF" | sort -V | tail -n1 || true
}
FICHIER_MODELE=$(trouver_modele_local)
if [ -z "$FICHIER_MODELE" ]; then
  info "modèle $MODELE absent de $STOCKAGE_MODELES, je cherche le plus récent"
  pveam update >/dev/null 2>&1 || attention "pveam update a échoué, la liste peut être ancienne"
  FICHIER_MODELE=$(pveam available --section system | awk '{ print $2 }' | grep -E "$MOTIF" | sort -V | tail -n1 || true)
  [ -n "$FICHIER_MODELE" ] || erreur "aucun modèle « $MODELE » chez Proxmox (pveam available --section system)"
  faire pveam download "$STOCKAGE_MODELES" "$FICHIER_MODELE"
fi
VOLID_MODELE="$STOCKAGE_MODELES:vztmpl/$FICHIER_MODELE"

# --- Création -----------------------------------------------------------------
if [ "$PRIVILEGIE" = 1 ]; then
  NON_PRIVILEGIE=0; FEATURES=""
  attention "CT privilégié : root dans le CT est root sur l'hôte en cas d'évasion"
else
  NON_PRIVILEGIE=1; FEATURES="nesting=1"
  [ "$DOCKER" = 1 ] && FEATURES="nesting=1,keyctl=1"
fi

ARGS=(create "$ID" "$VOLID_MODELE"
  --hostname "$NOM" --cores "$CPU" --memory "$RAM" --swap "$SWAP"
  --rootfs "$STOCKAGE:$DISQUE" --net0 "$NET0"
  --unprivileged "$NON_PRIVILEGIE" --onboot "$ONBOOT" --timezone host
  --description "Créé par creer-ct.sh le $(date +%d/%m/%Y), préréglage $PRESET")
[ -n "$FEATURES" ] && ARGS+=(--features "$FEATURES")
[ -n "$TAGS" ] && ARGS+=(--tags "$TAGS")
[ -n "$DNS" ] && ARGS+=(--nameserver "$DNS")
[ -n "$DOMAINE" ] && ARGS+=(--searchdomain "$DOMAINE")
[ -n "$CLE" ] && ARGS+=(--ssh-public-keys "$CLE")

echo
echo "CT $ID « $NOM » : $CPU cœur(s), $RAM Mo, $DISQUE Go sur $STOCKAGE"
echo "  réseau : $NET0"
echo "  modèle : $FICHIER_MODELE, $( [ "$NON_PRIVILEGIE" = 1 ] && echo 'non privilégié' || echo 'PRIVILÉGIÉ' ), démarrage auto : $ONBOOT"
echo
confirmer "Créer ce CT ?" || erreur "annulé"

faire pct "${ARGS[@]}"
info "CT $ID créé. Root n'a pas de mot de passe : on entre avec « pct enter $ID »."

if [ "$DEMARRER" = 1 ]; then
  faire pct start "$ID"
  if [ "$ESSAI" = 0 ]; then
    attendre_ct "$ID" 60 || erreur "le CT $ID ne répond pas après 60 s"
    info "CT $ID démarré"
  fi
fi

if [ "$PREPARER" = 1 ]; then
  OPTS=()
  [ "$ESSAI" = 1 ] && OPTS+=(--essai)
  [ "$OUI" = 1 ] && OPTS+=(--oui)
  "$DOSSIER/preparer-ct.sh" "$ID" "${OPTS[@]}"
fi
