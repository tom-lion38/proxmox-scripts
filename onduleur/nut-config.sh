#!/usr/bin/env bash
# nut-config.sh : branche Proxmox VE sur un onduleur avec NUT, pour s'éteindre proprement
# avant que la batterie soit vide. Option : délestage (arrêt de machines choisies après
# quelques minutes sur batterie, pour gagner de l'autonomie pour le reste).
set -euo pipefail
DOSSIER=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# shellcheck source=../lib/commun.sh
. "$DOSSIER/../lib/commun.sh"

aide() {
  cat <<'EOF'
Usage :
  nut-config.sh --mode local  [--nom onduleur] [--pilote usbhid-ups]
      l'onduleur est branché en USB sur cet hôte
  nut-config.sh --mode client --serveur HOTE [--nom ups] [--utilisateur monuser]
      l'onduleur est branché ailleurs (NAS, autre serveur) qui fait serveur NUT.
      Le mot de passe est demandé, ou lu dans la variable NUT_MOT_DE_PASSE.

Options communes :
  --delestage MIN      après MIN minutes sur batterie, arrête proprement les CT et VM
                       qui ont l'étiquette Proxmox « delestable » (0 = pas de délestage, par défaut)
  --etiquette E        autre étiquette que « delestable »
  --essai --oui -h|--aide

L'arrêt de l'hôte lui-même se fait quand l'onduleur annonce « batterie faible ».
Proxmox arrête alors proprement toutes les machines avant de s'éteindre.
EOF
}

MODE=""; NOM=""; PILOTE=usbhid-ups; SERVEUR=""; UTILISATEUR=monuser; DELESTAGE=0; ETIQUETTE=delestable
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE=${2:-}; shift ;;
    --nom) NOM=${2:-}; shift ;;
    --pilote) PILOTE=${2:-}; shift ;;
    --serveur) SERVEUR=${2:-}; shift ;;
    --utilisateur) UTILISATEUR=${2:-}; shift ;;
    --delestage) DELESTAGE=${2:-}; shift ;;
    --etiquette) ETIQUETTE=${2:-}; shift ;;
    --essai) ESSAI=1 ;;
    --oui) OUI=1 ;;
    -h|--aide) aide; exit 0 ;;
    *) erreur "option inconnue : $1 (voir --aide)" ;;
  esac
  shift
done

verifier_root
verifier_pve
verifier_entier "$DELESTAGE" "--delestage"
[[ "$ETIQUETTE" =~ ^[a-z0-9_-]+$ ]] || erreur "étiquette invalide : $ETIQUETTE"
case "$MODE" in
  local) NOM=${NOM:-onduleur}; PAQUETS="nut" ;;
  client)
    NOM=${NOM:-ups}; PAQUETS="nut-client"
    [ -n "$SERVEUR" ] || erreur "--serveur est obligatoire en mode client"
    ;;
  *) aide; exit 2 ;;
esac
[[ "$NOM" =~ ^[A-Za-z0-9_-]+$ ]] || erreur "nom d'onduleur invalide : $NOM"

MDP=""
if [ "$MODE" = client ]; then
  MDP=${NUT_MOT_DE_PASSE:-}
  if [ -z "$MDP" ] && [ "$ESSAI" = 0 ]; then
    [ -t 0 ] || erreur "mot de passe NUT absent : variable NUT_MOT_DE_PASSE ou lancement dans un terminal"
    read -r -s -p "Mot de passe NUT de $UTILISATEUR sur $SERVEUR : " MDP; echo
  fi
  if [ -z "$MDP" ]; then
    [ "$ESSAI" = 1 ] || erreur "mot de passe NUT vide"
  fi
else
  MDP=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-24)
fi
# En mode essai les fichiers sont affichés à l'écran : on n'y montre pas le vrai mot de passe.
[ "$ESSAI" = 1 ] && MDP="(mot-de-passe-masque)"

info "mode $MODE, onduleur « $NOM »$( [ "$MODE" = client ] && echo " sur $SERVEUR" ), délestage : $( [ "$DELESTAGE" -gt 0 ] && echo "$DELESTAGE min (étiquette $ETIQUETTE)" || echo non )"
confirmer "Configurer NUT ?" || erreur "annulé"

etape "Paquets"
faire env DEBIAN_FRONTEND=noninteractive apt-get install -y $PAQUETS
[ "$DELESTAGE" -gt 0 ] && faire env DEBIAN_FRONTEND=noninteractive apt-get install -y sudo

if [ "$MODE" = local ]; then
  etape "Détection de l'onduleur"
  if [ "$ESSAI" = 0 ]; then
    nut-scanner -U 2>/dev/null | sed 's/^/    /' >&2 || attention "nut-scanner ne voit rien en USB (câble ? onduleur allumé ?)"
  fi
fi

etape "Configuration"
if [ "$MODE" = local ]; then
  printf '# Posé par proxmox-scripts\nMODE=standalone\n' | ecrire_fichier /etc/nut/nut.conf 644
  ecrire_fichier /etc/nut/ups.conf 640 <<EOF
# Posé par proxmox-scripts. Si le pilote ne trouve pas l'onduleur, regarde « nut-scanner -U ».
[$NOM]
    driver = $PILOTE
    port = auto
    desc = "Onduleur de l'hôte"
EOF
  ecrire_fichier /etc/nut/upsd.users 640 <<EOF
# Posé par proxmox-scripts. Compte local utilisé par upsmon sur cet hôte.
[upsmon]
    password = $MDP
    upsmon primary
EOF
  MONITOR="MONITOR $NOM@localhost 1 upsmon $MDP primary"
else
  printf '# Posé par proxmox-scripts\nMODE=netclient\n' | ecrire_fichier /etc/nut/nut.conf 644
  MONITOR="MONITOR $NOM@$SERVEUR 1 $UTILISATEUR $MDP secondary"
fi

if [ "$DELESTAGE" -gt 0 ]; then
  NOTIF=$'NOTIFYCMD '"$(command -v upssched || echo /usr/sbin/upssched)"$'\nNOTIFYFLAG ONBATT SYSLOG+WALL+EXEC\nNOTIFYFLAG ONLINE SYSLOG+WALL+EXEC'
else
  NOTIF=$'NOTIFYFLAG ONBATT SYSLOG+WALL\nNOTIFYFLAG ONLINE SYSLOG+WALL'
fi
ecrire_fichier /etc/nut/upsmon.conf 640 <<EOF
# Posé par proxmox-scripts.
$MONITOR
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
FINALDELAY 5
$NOTIF
NOTIFYFLAG LOWBATT SYSLOG+WALL
NOTIFYFLAG COMMBAD SYSLOG+WALL
NOTIFYFLAG COMMOK SYSLOG+WALL
EOF

if [ "$DELESTAGE" -gt 0 ]; then
  etape "Délestage"
  ecrire_fichier /usr/local/sbin/delestage-onduleur 755 < "$DOSSIER/delestage-onduleur.sh"
  ecrire_fichier /usr/local/sbin/delestage-onduleur-nut 755 <<'EOF'
#!/bin/sh
# Lancé par upssched (compte nut). Passe la main à delestage-onduleur, en root via sudo.
exec sudo -n /usr/local/sbin/delestage-onduleur "$1"
EOF
  printf '# Posé par proxmox-scripts : NUT peut lancer le délestage, et rien d autre.\nnut ALL=(root) NOPASSWD: /usr/local/sbin/delestage-onduleur\n' \
    | ecrire_fichier /etc/sudoers.d/nut-delestage 440
  if [ "$ESSAI" = 0 ]; then
    visudo -cf /etc/sudoers.d/nut-delestage >/dev/null || { rm -f /etc/sudoers.d/nut-delestage; erreur "règle sudo refusée, retirée"; }
  fi
  ecrire_fichier /etc/nut/upssched.conf 640 <<EOF
# Posé par proxmox-scripts : délestage après $DELESTAGE min sur batterie, annulé au retour du courant.
CMDSCRIPT /usr/local/sbin/delestage-onduleur-nut
PIPEFN /run/nut/upssched.pipe
LOCKFN /run/nut/upssched.lock
AT ONBATT * START-TIMER delestage $((DELESTAGE * 60))
AT ONLINE * CANCEL-TIMER delestage
AT ONLINE * EXECUTE retour-secteur
EOF
  printf 'ETIQUETTE=%s\n' "$ETIQUETTE" | ecrire_fichier /etc/proxmox-scripts/delestage.conf 644
fi

if [ "$ESSAI" = 0 ]; then
  chown root:nut /etc/nut/*.conf /etc/nut/upsd.users 2>/dev/null || true
fi

etape "Démarrage"
if [ "$MODE" = local ]; then
  faire systemctl enable nut-server
  faire systemctl restart nut-driver.target nut-server || attention "le pilote ou le serveur NUT ne démarre pas (journalctl -u nut-driver@$NOM)"
fi
faire systemctl enable nut-monitor
faire systemctl restart nut-monitor
if [ "$ESSAI" = 0 ]; then
  sleep 3
  CIBLE=$( [ "$MODE" = local ] && echo "$NOM@localhost" || echo "$NOM@$SERVEUR" )
  if ETAT=$(upsc "$CIBLE" ups.status 2>/dev/null); then
    info "onduleur joignable, état : $ETAT (OL = sur secteur, OB = sur batterie, LB = batterie faible)"
    info "charge batterie : $(upsc "$CIBLE" battery.charge 2>/dev/null || echo ?) %"
  else
    attention "upsc ne joint pas $CIBLE : regarde journalctl -u nut-monitor"
  fi
fi
info "terminé. Pense à tester un jour : débranche l'onduleur du mur et regarde les journaux."
[ "$DELESTAGE" -gt 0 ] && info "pour suspendre le délestage : touch /etc/proxmox-scripts/delestage.off"
exit 0
