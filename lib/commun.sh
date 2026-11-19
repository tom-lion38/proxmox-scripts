#!/usr/bin/env bash
# lib/commun.sh : fonctions partagées par les scripts du dépôt.
# Ce fichier se charge avec « . lib/commun.sh », il ne se lance pas tout seul.
#
# Variables reconnues (les scripts les règlent aussi avec leurs options) :
#   ESSAI=1      affiche ce qui serait fait, sans rien modifier (--essai)
#   OUI=1        ne pose aucune question, pour cron ou un lancement automatique (--oui)
#   JOURNAL=...  fichier où recopier les messages (facultatif)
#   CIBLE_CT=ID  vide = on travaille sur l'hôte, sinon dans le CT indiqué

ESSAI=${ESSAI:-0}
OUI=${OUI:-0}
JOURNAL=${JOURNAL:-}
CIBLE_CT=${CIBLE_CT:-}
HORODATAGE=${HORODATAGE:-$(date +%Y%m%d-%H%M%S)}
# Les copies de sécurité vont ici (sur l'hôte, ou au même endroit dans le CT visé).
# On ne les laisse jamais à côté du fichier : apt lit tous les fichiers de apt.conf.d,
# une copie « .bak » posée là-dedans resterait active.
SAUVEGARDES=${SAUVEGARDES:-/root/proxmox-scripts-sauvegardes/$HORODATAGE}

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  _VERT=$'\033[32m'; _JAUNE=$'\033[33m'; _ROUGE=$'\033[31m'; _GRIS=$'\033[90m'; _RAZ=$'\033[0m'
else
  _VERT=""; _JAUNE=""; _ROUGE=""; _GRIS=""; _RAZ=""
fi

_ecrire_journal() {
  [ -n "$JOURNAL" ] || return 0
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$JOURNAL" 2>/dev/null || true
}

# Messages. Tout part sur la sortie d'erreur, pour ne pas se mélanger aux résultats.
info()      { printf '%s[info]%s %s\n' "$_VERT" "$_RAZ" "$*" >&2; _ecrire_journal "[info] $*"; }
attention() { printf '%s[attention]%s %s\n' "$_JAUNE" "$_RAZ" "$*" >&2; _ecrire_journal "[attention] $*"; }
erreur()    { printf '%s[erreur]%s %s\n' "$_ROUGE" "$_RAZ" "$*" >&2; _ecrire_journal "[erreur] $*"; exit 1; }
etape()     { printf '\n== %s\n' "$*" >&2; _ecrire_journal "== $*"; }

# faire <commande...> : lance la commande, ou l'affiche seulement en mode essai.
faire() {
  if [ "$ESSAI" = 1 ]; then
    printf '%s[essai]%s %s\n' "$_GRIS" "$_RAZ" "$(printf '%q ' "$@")" >&2
    return 0
  fi
  _ecrire_journal "[commande] $*"
  "$@"
}

# confirmer "question" : renvoie 0 si la réponse est oui.
# Avec --oui la réponse est oui d'office. En mode essai on ne demande rien.
confirmer() {
  local question=${1:-Continuer ?} reponse
  [ "$ESSAI" = 1 ] && return 0
  [ "$OUI" = 1 ] && return 0
  [ -t 0 ] || erreur "pas de terminal pour répondre à « $question » (relance avec --oui si c'est voulu)"
  read -r -p "$question [o/N] " reponse || true
  case "${reponse,,}" in
    o|oui|y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

verifier_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || erreur "il faut lancer ce script en root"
}

verifier_pve() {
  command -v pveversion >/dev/null 2>&1 && command -v pct >/dev/null 2>&1 \
    || erreur "Proxmox VE introuvable : ce script se lance sur l'hôte Proxmox"
}

verifier_pbs() {
  command -v proxmox-backup-manager >/dev/null 2>&1 \
    || erreur "Proxmox Backup Server introuvable : ce script se lance sur le PBS"
}

verifier_commande() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || erreur "commande manquante : $c"
  done
}

# Nom de code Debian de l'hôte (bookworm, trixie...).
codename_debian() {
  ( . /etc/os-release && printf '%s\n' "${VERSION_CODENAME:-}" )
}

# charger_conf <fichier> : lit un fichier de réglages s'il existe (variables shell).
charger_conf() {
  if [ -r "$1" ]; then
    # shellcheck disable=SC1090
    . "$1"
  fi
  return 0
}

# --- Hôte ou CT ---------------------------------------------------------------

nom_cible() {
  if [ -n "$CIBLE_CT" ]; then printf 'CT %s : ' "$CIBLE_CT"; fi
  return 0
}

# dans_cible "commande" : lance une commande shell sur l'hôte ou dans le CT visé.
# Sert aussi aux lectures, donc elle tourne même en mode essai.
dans_cible() {
  if [ -z "$CIBLE_CT" ]; then
    bash -c "$1"
  else
    pct exec "$CIBLE_CT" -- bash -c "$1"
  fi
}

# faire_cible "commande" : comme dans_cible, mais affichée seulement en mode essai.
faire_cible() {
  if [ "$ESSAI" = 1 ]; then
    printf '%s[essai]%s %s%s\n' "$_GRIS" "$_RAZ" "$(nom_cible)" "$1" >&2
    return 0
  fi
  _ecrire_journal "[commande] $(nom_cible)$1"
  dans_cible "$1"
}

# sauvegarder_cible <chemin> : copie le fichier dans $SAUVEGARDES avant de le changer.
sauvegarder_cible() {
  local f=$1
  [ "$ESSAI" = 1 ] && return 0
  dans_cible "[ -e '$f' ] || exit 0; mkdir -p '$SAUVEGARDES' && cp -a --parents '$f' '$SAUVEGARDES/'" \
    || erreur "$(nom_cible)impossible de copier $f avant modification"
  if dans_cible "[ -e '$f' ]"; then
    info "$(nom_cible)copie de sécurité : $SAUVEGARDES$f"
  fi
  return 0
}

# ecrire_cible <chemin> [droits] : écrit l'entrée standard dans <chemin>, sur l'hôte
# ou dans le CT visé. Ne fait rien si le contenu est déjà le même.
# Met FICHIER_CHANGE à 1 quand le fichier a vraiment été écrit.
# Attention : dans un tube (« printf ... | ecrire_cible ») la fonction tourne dans un
# sous-shell et FICHIER_CHANGE ne remonte pas. Pour s'en servir, passer par un heredoc
# (<<EOF) ou par « < <(commande) ».
FICHIER_CHANGE=0
ecrire_cible() {
  local cible=$1 droits=${2:-644} tmp avant apres
  FICHIER_CHANGE=0
  tmp=$(mktemp)
  cat > "$tmp"
  avant=$(dans_cible "cat '$cible' 2>/dev/null || true" | md5sum | cut -d' ' -f1)
  apres=$(md5sum < "$tmp" | cut -d' ' -f1)
  if [ "$avant" = "$apres" ] && dans_cible "[ -e '$cible' ]"; then
    rm -f "$tmp"
    info "$(nom_cible)déjà à jour : $cible"
    return 0
  fi
  if [ "$ESSAI" = 1 ]; then
    info "(essai) $(nom_cible)$cible serait écrit avec :"
    sed 's/^/    | /' "$tmp" >&2
    rm -f "$tmp"
    return 0
  fi
  sauvegarder_cible "$cible"
  if [ -z "$CIBLE_CT" ]; then
    install -D -m "$droits" "$tmp" "$cible"
  else
    pct exec "$CIBLE_CT" -- mkdir -p "$(dirname "$cible")"
    pct push "$CIBLE_CT" "$tmp" "$cible" --perms "$droits"
  fi
  rm -f "$tmp"
  FICHIER_CHANGE=1
  info "$(nom_cible)écrit : $cible"
}

# ecrire_fichier : ecrire_cible, toujours sur l'hôte.
ecrire_fichier() {
  local CIBLE_CT=""
  ecrire_cible "$@"
}

# supprimer_cible <chemin> : retire un fichier posé par un script (avec copie avant).
supprimer_cible() {
  local f=$1
  dans_cible "[ -e '$f' ]" || { info "$(nom_cible)déjà absent : $f"; return 0; }
  sauvegarder_cible "$f"
  faire_cible "rm -f '$f'"
  info "$(nom_cible)retiré : $f"
}

# --- Proxmox VE ---------------------------------------------------------------

# id_libre <id> : vrai si aucun CT ni VM n'utilise cet ID dans le cluster.
id_libre() {
  pvesh get /cluster/nextid --vmid "$1" >/dev/null 2>&1
}

ct_existe() {
  pct config "$1" >/dev/null 2>&1
}

ct_en_marche() {
  [ "$(pct status "$1" 2>/dev/null | awk '{print $2}')" = running ]
}

# attendre_ct <id> [secondes] : attend que le CT réponde à pct exec.
attendre_ct() {
  local id=$1 max=${2:-60} i=0
  while [ "$i" -lt "$max" ]; do
    if pct exec "$id" -- true >/dev/null 2>&1; then return 0; fi
    sleep 2
    i=$((i + 2))
  done
  return 1
}

# premier_stockage <contenu> : premier stockage actif qui accepte ce type de contenu
# (rootdir pour les disques de CT, backup pour les sauvegardes, vztmpl pour les modèles).
premier_stockage() {
  pvesm status --content "$1" 2>/dev/null | awk 'NR > 1 && $3 == "active" { print $1; exit }'
}

verifier_entier() { # verifier_entier <valeur> <nom>
  [[ "$1" =~ ^[0-9]+$ ]] || erreur "$2 doit être un nombre (reçu : « $1 »)"
}
