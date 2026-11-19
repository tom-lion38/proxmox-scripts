#!/usr/bin/env bash
# preparer-ct.sh : premiers réglages d'un CT Debian ou Ubuntu neuf, lancé depuis l'hôte.
# Rejouable : un deuxième passage ne réécrit que ce qui a changé.
set -euo pipefail
DOSSIER=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# shellcheck source=../lib/commun.sh
. "$DOSSIER/../lib/commun.sh"

aide() {
  cat <<'EOF'
Usage : preparer-ct.sh <id> [options]

Fait dans le CT (qui doit être démarré) :
  - fuseau horaire (celui de l'hôte par défaut)
  - mise à jour + paquets de base (unattended-upgrades, needrestart, curl)
  - mises à jour de sécurité automatiques
  - limite de taille des journaux

Options :
  --fuseau Z           ex. Europe/Paris (par défaut : celui de l'hôte)
  --locale L           ex. fr_FR.UTF-8 (par défaut : on ne touche pas)
  --maj-auto M         securite (par défaut), tout (sécurité + mises à jour courantes) ou non
  --utilisateur U      crée un compte U avec sudo
  --cle FICHIER        clé SSH publique pour ce compte (ou pour root s'il n'y a pas de compte)
  --ssh-durci          SSH par clé seulement, root interdit si un compte avec clé existe
  --journald TAILLE    taille max des journaux (par défaut 200M)
  --sans-postfix       retire Postfix (installé d'office dans les modèles Debian)
  --essai --oui -h|--aide
EOF
}

ID=""; FUSEAU=""; LOCALE=""; MAJ_AUTO=securite; UTILISATEUR=""; CLE=""; SSH_DURCI=0
JOURNALD=200M; SANS_POSTFIX=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fuseau) FUSEAU=${2:-}; shift ;;
    --locale) LOCALE=${2:-}; shift ;;
    --maj-auto) MAJ_AUTO=${2:-}; shift ;;
    --utilisateur) UTILISATEUR=${2:-}; shift ;;
    --cle) CLE=${2:-}; shift ;;
    --ssh-durci) SSH_DURCI=1 ;;
    --journald) JOURNALD=${2:-}; shift ;;
    --sans-postfix) SANS_POSTFIX=1 ;;
    --essai) ESSAI=1 ;;
    --oui) OUI=1 ;;
    -h|--aide) aide; exit 0 ;;
    -*) erreur "option inconnue : $1 (voir --aide)" ;;
    *) [ -z "$ID" ] || erreur "un seul CT à la fois"; ID=$1 ;;
  esac
  shift
done

verifier_root
verifier_pve
[ -n "$ID" ] || { aide; exit 2; }
verifier_entier "$ID" "l'ID du CT"
ct_existe "$ID" || erreur "le CT $ID n'existe pas"
ct_en_marche "$ID" || erreur "le CT $ID est arrêté (pct start $ID)"
case "$MAJ_AUTO" in securite|tout|non) ;; *) erreur "--maj-auto securite, tout ou non" ;; esac
[[ "$JOURNALD" =~ ^[0-9]+[KMG]$ ]] || erreur "--journald attend une taille comme 200M ou 1G"
if [ -n "$UTILISATEUR" ]; then
  [[ "$UTILISATEUR" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || erreur "nom de compte invalide : $UTILISATEUR"
fi
if [ -n "$CLE" ]; then
  [ -r "$CLE" ] || erreur "clé introuvable : $CLE"
  grep -qE '^(ssh-|ecdsa-)' "$CLE" || erreur "$CLE ne ressemble pas à une clé publique SSH"
fi

CIBLE_CT=$ID
dans_cible '[ -f /etc/debian_version ]' || erreur "le CT $ID n'est ni Debian ni Ubuntu, ce script ne sait pas faire"
DISTRO=$(dans_cible '. /etc/os-release; echo "$ID"')
info "CT $ID : $(dans_cible '. /etc/os-release; echo "$PRETTY_NAME"')"
[ "$ESSAI" = 1 ] && info "mode essai : rien ne sera modifié"
confirmer "Préparer le CT $ID ?" || erreur "annulé"

etape "Fuseau horaire"
if [ -z "$FUSEAU" ]; then
  FUSEAU=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  FUSEAU=${FUSEAU:-Etc/UTC}
fi
dans_cible "[ -e /usr/share/zoneinfo/$FUSEAU ]" || erreur "fuseau inconnu dans le CT : $FUSEAU"
if [ "$(dans_cible 'readlink -f /etc/localtime')" = "/usr/share/zoneinfo/$FUSEAU" ]; then
  info "déjà sur $FUSEAU"
else
  faire_cible "ln -sf /usr/share/zoneinfo/$FUSEAU /etc/localtime && echo $FUSEAU > /etc/timezone"
  info "fuseau : $FUSEAU"
fi

etape "Paquets"
PAQUETS="unattended-upgrades needrestart curl ca-certificates"
[ -n "$UTILISATEUR" ] && PAQUETS="$PAQUETS sudo"
[ -n "$LOCALE" ] && PAQUETS="$PAQUETS locales"
faire_cible "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get -y -qq -o Dpkg::Options::=--force-confold full-upgrade && apt-get install -y -qq --no-install-recommends $PAQUETS"
if [ "$SANS_POSTFIX" = 1 ] && dans_cible 'dpkg -s postfix >/dev/null 2>&1'; then
  faire_cible "DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq postfix && apt-get autoremove -y -qq"
  info "Postfix retiré"
fi

if [ -n "$LOCALE" ]; then
  etape "Langue"
  dans_cible "grep -q '^$LOCALE ' /usr/share/i18n/SUPPORTED 2>/dev/null" || erreur "locale inconnue : $LOCALE"
  faire_cible "sed -i 's/^# *\\($LOCALE \\)/\\1/' /etc/locale.gen && locale-gen >/dev/null && update-locale LANG=$LOCALE"
  info "langue : $LOCALE (active à la prochaine connexion)"
fi

etape "Mises à jour automatiques ($MAJ_AUTO)"
if [ "$MAJ_AUTO" = non ]; then
  info "laissé tel quel"
else
  ecrire_cible /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  if [ "$MAJ_AUTO" = tout ]; then
    case "$DISTRO" in
      ubuntu) MOTIF='"origin=Ubuntu,archive=${distro_codename}-updates";' ;;
      *)      MOTIF='"origin=Debian,codename=${distro_codename}-updates";' ;;
    esac
    ecrire_cible /etc/apt/apt.conf.d/52proxmox-scripts-tout <<EOF
// Posé par proxmox-scripts : mises à jour courantes en plus de la sécurité.
Unattended-Upgrade::Origins-Pattern {
        $MOTIF
};
EOF
  else
    supprimer_cible /etc/apt/apt.conf.d/52proxmox-scripts-tout
  fi
  ecrire_cible /etc/needrestart/conf.d/50-proxmox-scripts.conf <<'EOF'
# Posé par proxmox-scripts : les services touchés par une mise à jour sont relancés tout seuls.
$nrconf{restart} = 'a';
EOF
  if [ "$ESSAI" = 0 ]; then
    if dans_cible 'unattended-upgrade --dry-run >/dev/null 2>&1'; then
      info "unattended-upgrades répond correctement"
    else
      attention "unattended-upgrade --dry-run a échoué, regarde /var/log/unattended-upgrades/ dans le CT"
    fi
  fi
fi

etape "Journaux"
ecrire_cible /etc/systemd/journald.conf.d/50-taille.conf <<EOF
# Posé par proxmox-scripts : les journaux ne dépassent pas cette taille.
[Journal]
SystemMaxUse=$JOURNALD
EOF
[ "$FICHIER_CHANGE" = 1 ] && faire_cible "systemctl restart systemd-journald"

if [ -n "$UTILISATEUR" ]; then
  etape "Compte $UTILISATEUR"
  if dans_cible "id '$UTILISATEUR' >/dev/null 2>&1"; then
    info "le compte existe déjà"
  else
    faire_cible "useradd -m -s /bin/bash -G sudo '$UTILISATEUR'"
    info "compte créé (membre de sudo)"
  fi
  if [ -n "$CLE" ]; then
    ecrire_cible "/home/$UTILISATEUR/.ssh/authorized_keys" 600 < "$CLE"
    faire_cible "chown -R '$UTILISATEUR:$UTILISATEUR' '/home/$UTILISATEUR/.ssh' && chmod 700 '/home/$UTILISATEUR/.ssh'"
  fi
  if [ "$ESSAI" = 0 ] && [ "$OUI" = 0 ] && [ -t 0 ]; then
    info "mot de passe du compte (il sert pour sudo) :"
    pct exec "$ID" -- passwd "$UTILISATEUR" || attention "mot de passe non posé : pct exec $ID -- passwd $UTILISATEUR"
  else
    info "pense à poser le mot de passe (pour sudo) : pct exec $ID -- passwd $UTILISATEUR"
  fi
elif [ -n "$CLE" ]; then
  etape "Clé SSH de root"
  ecrire_cible /root/.ssh/authorized_keys 600 < "$CLE"
  faire_cible "chmod 700 /root/.ssh"
fi

if [ "$SSH_DURCI" = 1 ]; then
  etape "SSH"
  if ! dans_cible 'command -v sshd >/dev/null 2>&1'; then
    info "pas de serveur SSH dans ce CT, rien à faire"
  else
    CLE_ROOT=0; CLE_COMPTE=0
    dans_cible '[ -s /root/.ssh/authorized_keys ]' && CLE_ROOT=1
    [ -n "$UTILISATEUR" ] && dans_cible "[ -s /home/$UTILISATEUR/.ssh/authorized_keys ]" && CLE_COMPTE=1
    if [ "$ESSAI" = 1 ] && [ -n "$CLE" ]; then
      if [ -n "$UTILISATEUR" ]; then CLE_COMPTE=1; else CLE_ROOT=1; fi
    fi
    if [ "$CLE_ROOT" = 0 ] && [ "$CLE_COMPTE" = 0 ]; then
      attention "aucune clé SSH dans le CT : je ne coupe pas les mots de passe, tu te fermerais la porte"
    else
      if [ "$CLE_COMPTE" = 1 ]; then ROOT_SSH=no; else ROOT_SSH=prohibit-password; fi
      # 10- pour passer avant les autres fichiers : sshd garde la première valeur lue.
      ecrire_cible /etc/ssh/sshd_config.d/10-proxmox-scripts.conf <<EOF
# Posé par proxmox-scripts : connexion par clé seulement. « pct enter » reste possible depuis l'hôte.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin $ROOT_SSH
X11Forwarding no
MaxAuthTries 4
EOF
      if [ "$FICHIER_CHANGE" = 1 ]; then
        if dans_cible 'sshd -t'; then
          faire_cible 'systemctl reload ssh 2>/dev/null || systemctl reload sshd'
          info "SSH durci (root : $ROOT_SSH)"
        else
          dans_cible 'rm -f /etc/ssh/sshd_config.d/10-proxmox-scripts.conf'
          erreur "sshd refuse la nouvelle configuration, fichier retiré"
        fi
      fi
    fi
  fi
fi

etape "Bilan"
info "CT $ID prêt. Copies des fichiers modifiés dans le CT : $SAUVEGARDES (s'il y en a eu)"
dans_cible '[ -f /var/run/reboot-required ]' && attention "le CT demande un redémarrage : pct reboot $ID"
exit 0
