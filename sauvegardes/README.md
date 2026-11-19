# sauvegardes

Deux scripts pour savoir si les sauvegardes servent vraiment à quelque chose.

## age-sauvegardes.sh

Lecture seule. Pour chaque CT et chaque VM, cherche la sauvegarde la plus récente sur
tous les stockages de sauvegarde (PBS compris) et dit si elle a plus de 26 heures.

```bash
./age-sauvegardes.sh
./age-sauvegardes.sh --max-heures 170 --ignorer-arretes   # sauvegarde hebdomadaire
./age-sauvegardes.sh --exclure 9000,9001 --alerter
```

Exemple de sortie :

```
    ID     nom                      dernière     âge     état
CT  101    dns                      19/11 03:12  6 h     ok
CT  102    web                      12/11 03:15  174 h   TROP VIEILLE
VM  200    nas                      -            -       AUCUNE
```

Code de sortie 1 s'il y a un problème, ce qui permet de l'utiliser dans cron ou dans une
sonde de supervision. `--alerter` envoie la liste par ntfy (voir `alertes/`).

Sur un cluster : les stockages locaux des autres nœuds ne sont pas lus. Une machine
sauvegardée sur le disque local d'un autre nœud apparaîtra donc en « AUCUNE ». Avec un PBS
ou un stockage partagé, pas de souci.

## test-restauration.sh

Une sauvegarde qu'on n'a jamais restaurée, on ne sait pas si elle marche. Ce script :

1. prend la dernière sauvegarde du CT (ou celle donnée par `--sauvegarde`) ;
2. la restaure sur un ID libre entre 9900 et 9999 (ou `--id-test`). Si l'ID est pris, il
   s'arrête ;
3. retire de la copie toutes les cartes réseau, les points de montage liés à des dossiers
   de l'hôte, les périphériques, les lignes `lxc.mount.entry`, et le démarrage automatique.
   La copie ne peut ni parler au réseau ni écrire dans les dossiers de l'original ;
4. la démarre, attend systemd, liste les services en échec (souvent normal sans réseau),
   lance ta commande de contrôle si tu en as donné une ;
5. l'arrête et la supprime, même si quelque chose a raté en route. Il ne supprime que le
   CT qu'il a créé, repéré par sa description.

```bash
./test-restauration.sh --ct 101 --essai
./test-restauration.sh --ct 101
./test-restauration.sh --ct 102 --commande "test -s /var/lib/monappli/base.db" --alerter
./test-restauration.sh --ct 101 --garder        # pour aller voir dedans : pct enter <id>
```

Il faut de la place libre sur le stockage de destination, autant que le disque du CT.
Une restauration lit toute la sauvegarde : lance-le à une heure calme, pas pendant les
sauvegardes de la nuit.

Exemple de cron, le premier dimanche du mois à 10 h, un CT à la fois :

```
0 10 1-7 * * root [ "$(date +\%u)" = 7 ] && /opt/proxmox-scripts/sauvegardes/test-restauration.sh --ct 101 --oui --alerter
```

Les VM ne sont pas gérées : leur restauration demande des choix (disques, carte réseau,
démarrage) qu'un script ne peut pas faire à ta place sans risque.
