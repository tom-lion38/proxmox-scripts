# alertes

Notifications sur le téléphone avec [ntfy](https://ntfy.sh). Tu peux utiliser le serveur
public ntfy.sh ou héberger le tien (il tient dans un petit CT).

## Mise en place

```bash
mkdir -p /etc/proxmox-scripts
cp alertes.conf.exemple /etc/proxmox-scripts/alertes.conf
chmod 600 /etc/proxmox-scripts/alertes.conf
nano /etc/proxmox-scripts/alertes.conf          # NTFY_URL, NTFY_SUJET, NTFY_JETON
```

Sur le téléphone : application ntfy, abonnement au même sujet.

Sur ntfy.sh n'importe qui peut lire un sujet s'il connaît son nom. Choisis un nom long
et difficile à deviner, ou utilise ton propre serveur avec un jeton d'accès.

## ntfy-envoyer.sh

```bash
./ntfy-envoyer.sh "Titre" "Le message"
./ntfy-envoyer.sh --priorite 5 --tags disque "Disque plein" "/var est à 98 %"
./ntfy-envoyer.sh --essai "Titre" "Message"       # affiche la requête sans l'envoyer
```

Le message part en JSON, les accents et les retours à la ligne passent sans souci.
Trois essais espacés de 5 secondes si le serveur ne répond pas. Le script est autonome :
il peut être copié seul, par exemple dans `/usr/local/sbin/ntfy-envoyer`, et appelé par
tes propres scripts ou par cron.

## alerte-connexion.sh

Prévient quand root ouvre une session en SSH ou sur la console.

```bash
./alerte-connexion.sh --installer
./alerte-connexion.sh --tester
./alerte-connexion.sh --retirer
```

L'installation pose `ntfy-envoyer` et `alerte-connexion` dans `/usr/local/sbin`, puis
ajoute une ligne `pam_exec` en `optional` dans `/etc/pam.d/sshd` et `/etc/pam.d/login`.
`optional` veut dire que si l'alerte ne part pas, la connexion se fait quand même :
le script ne peut pas te bloquer dehors. L'envoi se fait en arrière-plan pour ne pas
ralentir la connexion.

Réglages dans `alertes.conf` :

- `ALERTE_COMPTES` : comptes surveillés (`root` par défaut) ;
- `ALERTE_IGNORER_SOURCES` : début des adresses qui ne déclenchent rien, par exemple
  `"192.168.10.5 "` pour ton PC fixe. Laisse vide pour être prévenu à chaque fois.

Les connexions à l'interface web de Proxmox (port 8006) ne passent pas par une session
PAM et ne sont donc pas couvertes. Pour elles, regarde l'option `--fail2ban` de
`post-install/pve-post-install.sh`.
