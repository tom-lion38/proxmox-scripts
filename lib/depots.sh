#!/usr/bin/env bash
# lib/depots.sh : dépôts APT de Proxmox (PVE et PBS), à charger après lib/commun.sh.
#
#   desactiver_depots_entreprise          coupe les dépôts « enterprise » (payants)
#   ajouter_depot_sans_abonnement pve|pbs  ajoute le dépôt gratuit « no-subscription »
#   ajouter_depot_ceph                     remplace le dépôt Ceph enterprise par sa version gratuite
#   retirer_message_abonnement / remettre_message_abonnement
#
# Proxmox 9 et PBS 4 (Debian 13) utilisent le format deb822 (.sources).
# Proxmox 8 et PBS 3 (Debian 12) utilisent encore les fichiers .list.

CLE_PROXMOX=/usr/share/keyrings/proxmox-archive-keyring.gpg
CEPH_DEPOT=""   # rempli par desactiver_depots_entreprise si un dépôt Ceph enterprise existait (ex. ceph-squid)

_noter_depot_ceph() { # repère le nom du dépôt Ceph dans une URL enterprise
  local d
  d=$(grep -oE 'enterprise\.proxmox\.com/debian/ceph-[a-z]+' "$1" | head -n1 | sed 's#.*/##')
  if [ -n "$d" ]; then CEPH_DEPOT=$d; fi
  return 0
}

desactiver_depots_entreprise() {
  local f trouve=0
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*.sources; do
    grep -q 'enterprise\.proxmox\.com' "$f" || continue
    trouve=1
    _noter_depot_ceph "$f"
    if grep -qiE '^Enabled:[[:space:]]*no' "$f" && ! grep -qiE '^Enabled:[[:space:]]*yes' "$f"; then
      info "déjà désactivé : $f"
      continue
    fi
    if [ "$ESSAI" = 1 ]; then
      info "(essai) $f serait désactivé (ligne « Enabled: no »)"
      continue
    fi
    sauvegarder_cible "$f"
    if grep -qiE '^Enabled:' "$f"; then
      sed -i -E 's/^Enabled:.*/Enabled: no/I' "$f"
    else
      sed -i -E '/^Types:/I a Enabled: no' "$f"
    fi
    info "désactivé : $f"
  done
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] || continue
    grep -qE '^[[:space:]]*deb[[:space:]].*enterprise\.proxmox\.com' "$f" || continue
    trouve=1
    _noter_depot_ceph "$f"
    if [ "$ESSAI" = 1 ]; then
      info "(essai) les lignes enterprise de $f seraient mises en commentaire"
      continue
    fi
    sauvegarder_cible "$f"
    sed -i -E 's|^([[:space:]]*deb[[:space:]].*enterprise\.proxmox\.com.*)$|# \1|' "$f"
    info "lignes enterprise mises en commentaire : $f"
  done
  shopt -u nullglob
  if [ "$trouve" = 0 ]; then info "aucun dépôt enterprise actif"; fi
  return 0
}

# _depot_present <composant> : vrai si un fichier actif déclare déjà ce composant.
_depot_present() {
  local composant=$1 f
  shopt -s nullglob
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] || continue
    if grep -qE "^[[:space:]]*deb[[:space:]].*[[:space:]]$composant([[:space:]]|$)" "$f"; then
      shopt -u nullglob; return 0
    fi
  done
  for f in /etc/apt/sources.list.d/*.sources; do
    if grep -qE "^Components:.*(^|[[:space:]])$composant([[:space:]]|$)" "$f" \
       && ! grep -qiE '^Enabled:[[:space:]]*no' "$f"; then
      shopt -u nullglob; return 0
    fi
  done
  shopt -u nullglob
  return 1
}

ajouter_depot_sans_abonnement() { # ajouter_depot_sans_abonnement pve|pbs
  local produit=$1 code composant
  code=$(codename_debian)
  case "$produit" in
    pve) composant=pve-no-subscription ;;
    pbs) composant=pbs-no-subscription ;;
    *) erreur "produit inconnu : $produit" ;;
  esac
  if _depot_present "$composant"; then
    info "dépôt $composant déjà présent"
    return 0
  fi
  case "$code" in
    bookworm)
      printf 'deb http://download.proxmox.com/debian/%s %s %s\n' "$produit" "$code" "$composant" \
        | ecrire_fichier "/etc/apt/sources.list.d/$composant.list"
      ;;
    trixie)
      [ -f "$CLE_PROXMOX" ] || attention "clé $CLE_PROXMOX absente, apt risque de refuser le dépôt"
      ecrire_fichier /etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/$produit
Suites: $code
Components: $composant
Signed-By: $CLE_PROXMOX
EOF
      ;;
    *)
      erreur "version de Debian non prévue : « $code » (prévu : bookworm, trixie)"
      ;;
  esac
}

ajouter_depot_ceph() {
  local code
  code=$(codename_debian)
  if [ -z "$CEPH_DEPOT" ]; then
    info "pas de dépôt Ceph enterprise trouvé, rien à remplacer"
    return 0
  fi
  if _depot_present no-subscription && grep -rqs "debian/$CEPH_DEPOT" /etc/apt/sources.list.d/ --include='ceph-no-subscription.*'; then
    info "dépôt $CEPH_DEPOT no-subscription déjà présent"
    return 0
  fi
  case "$code" in
    bookworm)
      printf 'deb http://download.proxmox.com/debian/%s %s no-subscription\n' "$CEPH_DEPOT" "$code" \
        | ecrire_fichier /etc/apt/sources.list.d/ceph-no-subscription.list
      ;;
    trixie)
      ecrire_fichier /etc/apt/sources.list.d/ceph-no-subscription.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/$CEPH_DEPOT
Suites: $code
Components: no-subscription
Signed-By: $CLE_PROXMOX
EOF
      ;;
    *) erreur "version de Debian non prévue : « $code »" ;;
  esac
}

# --- Message « No valid subscription » -----------------------------------------
# On ne modifie pas le code de Proxmox à la main une fois pour toutes : un petit script
# est posé, et APT le relance après chaque mise à jour du paquet concerné.

SCRIPT_MESSAGE=/usr/local/sbin/retirer-message-abonnement
HOOK_MESSAGE=/etc/apt/apt.conf.d/99retirer-message-abonnement

retirer_message_abonnement() {
  ecrire_fichier "$SCRIPT_MESSAGE" 755 <<'EOF'
#!/bin/sh
# Retire la fenêtre « No valid subscription » de l'interface web de Proxmox (PVE et PBS).
# Posé par proxmox-scripts. APT le relance après chaque installation de paquets.
JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
[ -f "$JS" ] || exit 0
grep -q "void({ //Ext.Msg.show({" "$JS" && exit 0
if ! grep -q "title: gettext('No valid sub" "$JS"; then
  echo "retirer-message-abonnement : texte attendu introuvable dans $JS, rien modifié" >&2
  exit 0
fi
sed -Ezi "s/(Ext\.Msg\.show\(\{\s+title: gettext\('No valid sub)/void({ \/\/\1/g" "$JS"
exit 0
EOF
  ecrire_fichier "$HOOK_MESSAGE" 644 <<EOF
// Posé par proxmox-scripts : retire de nouveau le message d'abonnement après une mise à jour.
DPkg::Post-Invoke { "if [ -x $SCRIPT_MESSAGE ]; then $SCRIPT_MESSAGE; fi"; };
EOF
  faire "$SCRIPT_MESSAGE"
  info "message d'abonnement retiré (vide le cache du navigateur pour le voir)"
}

remettre_message_abonnement() {
  supprimer_cible "$HOOK_MESSAGE"
  supprimer_cible "$SCRIPT_MESSAGE"
  faire apt-get install -y --reinstall proxmox-widget-toolkit
  info "fichier d'origine de Proxmox remis"
}
