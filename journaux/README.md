# journaux

## rsyslog-envoi.sh

Quand un CT plante, ses journaux partent souvent avec lui. Avec un serveur de journaux
central (Loki avec Alloy, Graylog, un simple rsyslog), tout reste lisible au même endroit.
Ce script règle rsyslog sur l'hôte et dans les CT pour qu'ils envoient une copie de tous
leurs journaux à ce serveur.

```bash
./rsyslog-envoi.sh --serveur journaux.lan --port 1514 --essai
./rsyslog-envoi.sh --serveur journaux.lan --port 1514 --hote --tous-les-ct
./rsyslog-envoi.sh --serveur 192.168.10.40 --ct 101,102 --envoi-seul
./rsyslog-envoi.sh --retirer --hote --tous-les-ct
```

Ce qui est posé, sur chaque machine :

- rsyslog, s'il n'est pas installé (Debian 13 ne l'installe plus d'office) ;
- `/etc/systemd/journald.conf.d/50-vers-rsyslog.conf` : journald passe les messages à rsyslog ;
- `/etc/rsyslog.d/10-envoi-central.conf` : envoi en syslog RFC 5424, en TCP par défaut,
  avec une file d'attente sur disque (100 Mo au plus) qui garde les messages pendant une
  coupure du serveur et les renvoie ensuite.

Dans les CT, le module `imklog` est mis en commentaire : un CT non privilégié ne peut
pas lire les messages du noyau, et rsyslog afficherait une erreur à chaque démarrage.

`--envoi-seul` arrête l'écriture des fichiers dans `/var/log` (syslog, auth.log...) :
les journaux restent dans journald en local et partent vers le serveur, sans être écrits
une troisième fois sur le disque.

À la fin, un message de test est envoyé (« test d envoi des journaux depuis ... ») et le
script vérifie que la connexion TCP vers le serveur est bien ouverte.

### Côté serveur

Le serveur doit écouter en syslog. Avec Grafana Alloy devant Loki, par exemple :

```
loki.source.syslog "lan" {
  listener {
    address  = "0.0.0.0:1514"
    protocol = "tcp"
    labels   = { job = "syslog" }
  }
  forward_to = [loki.write.local.receiver]
}
```

N'ouvre ce port qu'à ton réseau local : un serveur de journaux ouvert sur internet se
remplit vite de n'importe quoi.
