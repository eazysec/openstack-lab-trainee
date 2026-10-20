# TP 04 bis. Revenir en arrière : snapshots, revert, re-image

| | |
|---|---|
| Prérequis | TP 04 ; Cinder déployé (scénario 02) |
| À la fin du TP | Vous savez remettre un volume dans un état antérieur, reconstruire une VM qui démarre sur un volume sans perdre ses données, et vous connaissez les limites de chaque méthode |

## Objectifs

- Ramener un volume à son dernier snapshot (*revert*), et savoir quand c'est refusé.
- Comprendre qu'un snapshot n'est pas une image, et passer de l'un à l'autre.
- Réécrire un volume à partir d'une image (*re-image*).
- Reconstruire une VM qui démarre sur un volume en gardant son volume de données.

---

## Étape 0. Vérifier les conditions d'entrée

```bash
# [instance]
./openstack-lab-trainee/tps/tp04-bis/verifier-entree.sh    # dernière ligne : "Lab prêt pour le TP 04 bis."
```

Ce script ne modifie rien. Il vérifie que la plateforme répond, que Cinder est déployé, que les
ressources communes du déploiement sont là et qu'il ne reste rien d'un essai précédent (`tp04b-` :
VM, volumes, snapshots, images). Ne commencez pas tant que la dernière ligne n'est pas
`Lab prêt pour le TP 04 bis.`

## Étape 1. Un volume au contenu repérable

Pour voir à coup sûr dans quel état est un volume, on écrit une courte marque au tout début du
disque, sans système de fichiers, et on la relit sur l'hôte, là où Cinder stocke le volume.

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
openstack server create --image cirros --flavor m1.tiny --key-name mykey --network demo-net --wait tp04b-vm
FIP=$(openstack floating ip create public1 -f value -c floating_ip_address)
openstack server add floating ip tp04b-vm $FIP
ssh-keygen -R $FIP 2>/dev/null           # floating IP peut-être déjà vue (conventions)
openstack volume create --size 1 tp04b-vol-donnees
attendre() { until [ "$(openstack volume show $1 -f value -c status)" = "$2" ]; do sleep 3; done; }
ecrire() {   # ecrire <marque> : attache le volume, écrit la marque au début du disque, détache
  openstack server add volume tp04b-vm tp04b-vol-donnees; attendre tp04b-vol-donnees in-use
  until ssh cirros@$FIP true 2>/dev/null; do sleep 5; done
  ssh cirros@$FIP "echo $1 | sudo dd of=/dev/vdb conv=fsync 2>/dev/null"
  openstack server remove volume tp04b-vm tp04b-vol-donnees; attendre tp04b-vol-donnees available
}
lire() {     # lire <volume> : les 9 premiers octets du volume, lus sur l'hôte
  sudo head -c 9 /dev/cinder-volumes/volume-$(openstack volume show $1 -f value -c id); echo
}
attendre tp04b-vol-donnees available
ecrire version-A; lire tp04b-vol-donnees          # version-A
```

> Acceptez la clé d'hôte de la VM à la première connexion (`yes`). Gardez le même terminal jusqu'à
> la fin du TP : les fonctions et les variables n'existent que dans ce shell.

Deux snapshots, entre trois écritures :

```bash
# [instance]
openstack volume snapshot create --volume tp04b-vol-donnees tp04b-snap-a
until [ "$(openstack volume snapshot show tp04b-snap-a -f value -c status)" = available ]; do sleep 2; done
ecrire version-B
openstack volume snapshot create --volume tp04b-vol-donnees tp04b-snap-b
until [ "$(openstack volume snapshot show tp04b-snap-b -f value -c status)" = available ]; do sleep 2; done
ecrire version-C; lire tp04b-vol-donnees          # version-C
```

## Étape 2. Revenir au dernier snapshot

```bash
# [instance]
openstack volume revert tp04b-snap-a             # refusé : ce n'est pas le dernier snapshot
openstack volume revert tp04b-snap-b             # accepté
attendre tp04b-vol-donnees available
lire tp04b-vol-donnees                           # version-B
```

Le premier refus répond `Specified snapshot … is None or not the latest one of volume`. Le revert ne
ramène le volume qu'à **son dernier** snapshot, et seulement s'il n'est attaché à aucune VM :

```bash
# [instance]
openstack server add volume tp04b-vm tp04b-vol-donnees; attendre tp04b-vol-donnees in-use
openstack volume revert tp04b-snap-b             # refusé : volume attaché
openstack server remove volume tp04b-vm tp04b-vol-donnees; attendre tp04b-vol-donnees available
```

Réponse : `Invalid volume: Can't revert volume …` (409).

## Étape 3. Un snapshot n'est pas une image

Le *re-image* réécrit un volume à partir d'une **image** de Glance. Peut-on lui donner un snapshot ?

```bash
# [instance]
SA=$(openstack volume snapshot show tp04b-snap-a -f value -c id)
cinder --os-volume-api-version 3.68 reimage tp04b-vol-donnees $SA     # refusé
```

Réponse : `Image … could not be found` : Cinder cherche une image de ce nom dans Glance. Un snapshot
reste dans Cinder ; pour en faire une image, on passe par un volume :

```bash
# [instance]
openstack volume create --snapshot tp04b-snap-a --size 1 tp04b-vol-copie
attendre tp04b-vol-copie available; lire tp04b-vol-copie                  # version-A
openstack image create --volume tp04b-vol-copie tp04b-img-version-a
until [ "$(openstack image show tp04b-img-version-a -f value -c status)" = active ]; do sleep 3; done
attendre tp04b-vol-copie available
IMG=$(openstack image show tp04b-img-version-a -f value -c id)
cinder --os-volume-api-version 3.68 reimage tp04b-vol-donnees $IMG    # accepté
sleep 5; attendre tp04b-vol-donnees available
lire tp04b-vol-donnees                                               # version-A
```

`cinder reimage` n'a pas d'équivalent dans la commande `openstack` ; il demande l'**identifiant** de
l'image, pas son nom, et un volume détaché. Contrairement au revert, il peut ramener le volume à un
état plus ancien que le dernier snapshot, à condition d'en avoir fait une image.

## Étape 4. Reconstruire une VM qui démarre sur un volume

Une VM peut démarrer sur un volume (racine) plutôt que sur un disque éphémère. On lui attache aussi
le volume de données :

```bash
# [instance]
openstack volume create --image cirros --size 1 --bootable tp04b-vol-racine
attendre tp04b-vol-racine available
openstack server create --volume tp04b-vol-racine --flavor m1.tiny --key-name mykey \
  --network demo-net --wait tp04b-vm-volume
FIP2=$(openstack floating ip create public1 -f value -c floating_ip_address)
openstack server add floating ip tp04b-vm-volume $FIP2
ssh-keygen -R $FIP2 2>/dev/null
openstack server add volume tp04b-vm-volume tp04b-vol-donnees; attendre tp04b-vol-donnees in-use
until ssh cirros@$FIP2 true 2>/dev/null; do sleep 5; done
ssh cirros@$FIP2 "echo trace > /home/cirros/trace; sync; ls /home/cirros; sudo head -c 9 /dev/vdb; echo"
```

Le système de la VM a été modifié (le fichier `trace`). On le remet à neuf à partir de l'image, sans
toucher au volume de données :

```bash
# [instance]
openstack server rebuild --image cirros tp04b-vm-volume                         # refusé
openstack server rebuild --image cirros --reimage-boot-volume --wait tp04b-vm-volume
ssh-keygen -R $FIP2                       # la VM reconstruite a une nouvelle clé d'hôte
until ssh cirros@$FIP2 true 2>/dev/null; do sleep 5; done
ssh cirros@$FIP2 "ls /home/cirros; sudo head -c 9 /dev/vdb; echo"            # plus de trace ; version-A
```

Sans `--reimage-boot-volume`, la commande répond `--reimage-boot-volume is required to rebuild a
volume-backed server`. Avec, le volume racine est réécrit à partir de l'image ; le volume de données
reste attaché et intact.

Deux limites, à constater :

```bash
# [instance]
openstack volume snapshot create --volume tp04b-vol-racine --force tp04b-snap-racine
until [ "$(openstack volume snapshot show tp04b-snap-racine -f value -c status)" = available ]; do sleep 2; done
openstack volume revert tp04b-snap-racine       # refusé : le volume racine est attaché à la VM
openstack server remove volume tp04b-vm-volume tp04b-vol-donnees; attendre tp04b-vol-donnees available
openstack volume delete tp04b-vol-donnees       # refusé : le volume a des snapshots
```

## Étape 5. Nettoyage

Dans l'ordre des dépendances : les VM, l'image, les snapshots, puis les volumes.

```bash
# [instance]
openstack server delete --wait tp04b-vm tp04b-vm-volume
openstack floating ip delete $FIP $FIP2
openstack image delete tp04b-img-version-a
openstack volume snapshot delete tp04b-snap-a
openstack volume snapshot delete tp04b-snap-b
openstack volume snapshot delete tp04b-snap-racine
until [ -z "$(openstack volume snapshot list -f value -c Name | grep '^tp04b-')" ]; do sleep 3; done
openstack volume delete tp04b-vol-donnees tp04b-vol-copie tp04b-vol-racine
until [ -z "$(openstack volume list -f value -c Name | grep '^tp04b-')" ]; do sleep 3; done
unset -f attendre ecrire lire; unset FIP FIP2 SA IMG
./openstack-lab-trainee/tps/tp04-bis/verifier-entree.sh | tail -1    # "Lab prêt pour le TP 04 bis."
```

## Questions

1. Pourquoi un snapshot ne peut-il pas servir directement au re-image ? Par quelles étapes en fait-on
   une image ?
2. Le revert ne ramène qu'au dernier snapshot. Comment garder plusieurs points de retour utilisables ?
3. Que garde et que perd la reconstruction d'une VM qui démarre sur un volume ? Pourquoi séparer le
   système et les données sur deux volumes ?
4. Pourquoi le revert du volume racine est-il refusé, même VM arrêtée ? Comment ramener tout de même
   le système à un état antérieur ?
5. Un re-image avec une image plus grande que le volume : que se passe-t-il, à votre avis ?
6. `openstack server image create` sur une VM qui démarre sur un volume produit une image de 0 octet.
   Que contient-elle vraiment ?

## Validation

- [ ] Revert au dernier snapshot fait ; refus pour un snapshot plus ancien et pour un volume attaché.
- [ ] Refus du re-image avec un snapshot ; chaîne snapshot → volume → image → re-image faite.
- [ ] VM sur volume reconstruite : système remis à neuf, volume de données intact.
- [ ] Limites de l'étape 4 relevées ; questions 2 et 3 argumentées.
- [ ] Nettoyage fait.

## Sources

- Cinder : gérer les volumes et leurs snapshots en ligne de commande : <https://docs.openstack.org/cinder/2025.1/cli/cli-manage-volumes.html>
- API Block Storage v3 : revert au snapshot : <https://docs.openstack.org/api-ref/block-storage/v3/#revert-volume-to-snapshot> ; re-image : <https://docs.openstack.org/api-ref/block-storage/v3/>
- Images adossées à des volumes (question 6) : <https://docs.openstack.org/cinder/2025.1/admin/blockstorage-volume-backed-image.html>
- Nova : reconstruire une instance qui démarre sur un volume : <https://docs.openstack.org/api-ref/compute/#rebuild-server-rebuild-action>
- Toutes les sources du parcours : [sources.md](../sources.md)
