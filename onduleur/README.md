# onduleur

Un onduleur sans logiciel tient le serveur allumé jusqu'à ce que la batterie soit vide,
puis tout s'arrête net. Avec NUT, l'hôte sait qu'il est sur batterie et s'éteint
proprement à temps. Proxmox arrête alors chaque CT et chaque VM avant de s'éteindre.

## nut-config.sh

Deux cas :

```bash
# L'onduleur est branché en USB sur l'hôte Proxmox
./nut-config.sh --mode local --essai
./nut-config.sh --mode local

# L'onduleur est branché sur une autre machine qui fait serveur NUT (NAS, autre serveur)
NUT_MOT_DE_PASSE='...' ./nut-config.sh --mode client --serveur nas.lan --nom ups --utilisateur monuser
```

En mode local, le pilote `usbhid-ups` convient à la plupart des onduleurs USB récents.
`nut-scanner -U` est lancé pour montrer ce qui est détecté. Si ton onduleur demande un
autre pilote, passe-le avec `--pilote`. Le mot de passe du compte local de NUT est tiré
au hasard et ne sert qu'à l'hôte lui-même.

En mode client, beaucoup de NAS (Synology par exemple) exposent leur onduleur sous le nom
`ups`, avec un compte et un mot de passe fixés par le fabricant : regarde la doc de ton NAS,
et autorise l'adresse de l'hôte Proxmox dans ses réglages UPS.

L'hôte s'éteint quand l'onduleur annonce « batterie faible ». Vérifie à quel pourcentage
ton onduleur le fait (`upsc <nom>@localhost battery.charge.low`) : trop bas, et il ne
restera pas assez de temps pour arrêter toutes les machines.

## Délestage

```bash
./nut-config.sh --mode local --delestage 2
```

Après 2 minutes sur batterie, les CT et VM qui ont l'étiquette Proxmox `delestable` sont
arrêtés proprement. Le reste (routeur virtuel, DNS, NAS...) garde plus longtemps la
batterie pour lui. Si le courant revient avant les 2 minutes, rien ne se passe.

- Les machines délestées ne redémarrent pas toutes seules au retour du courant. C'est
  voulu : après une coupure, mieux vaut regarder avant de tout relancer.
- `touch /etc/proxmox-scripts/delestage.off` suspend le délestage, `rm` le remet.
- `ESSAI=1 /usr/local/sbin/delestage-onduleur delestage` montre ce qui serait arrêté.
- NUT tourne sous son propre compte. Une règle sudo l'autorise à lancer le script de
  délestage et rien d'autre (`/etc/sudoers.d/nut-delestage`).

## Tester

Le seul vrai test : débrancher l'onduleur du mur, à un moment où une coupure ne gêne
personne, et suivre `journalctl -f -u nut-monitor`. Rebranche avant d'arriver à
« batterie faible » si tu ne veux pas aller jusqu'à l'arrêt.
