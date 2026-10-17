# TP 04. Stockage persistant : volumes, montage, snapshots

| | |
|---|---|
| Durée | 1 h 30 (+ ~15 min si Cinder n'est pas encore déployé) |
| Prérequis | TP 02 ; Cinder déployé (scénario 02) |
| À la fin du TP | Vous savez donner à une VM un disque qui survit à la VM |

## Objectifs

- Comprendre la différence entre le disque éphémère d'une VM et un volume Cinder.
- Créer, attacher, formater, monter, détacher un volume ; le déplacer vers une autre VM.
- Faire un snapshot de volume et en restaurer une copie.
- Voir où Cinder range les volumes sur l'hôte.

---

## Étape 0. Ajouter Cinder (si ce n'est pas déjà fait)

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
openstack volume service list       # si la commande échoue ou ne liste rien : Cinder n'est pas déployé
```

Si besoin, ajoutez Cinder au déploiement existant (les VM existantes sont conservées) :

```bash
# [instance] : dans tmux, ~15 min
./openstack-lab-trainee/deploy.sh openstack-lab-trainee/scenarios/02-aio-cinder.env
./openstack-lab-trainee/verify.sh        # attendu : « 0 échoués » sur la dernière ligne
```

## Étape 1. Une VM et un volume

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
openstack server create --image cirros --flavor m1.tiny --key-name mykey \
  --network demo-net --wait tp04-vm1
FIP1=$(openstack floating ip create public1 -f value -c floating_ip_address)
openstack server add floating ip tp04-vm1 $FIP1

openstack volume create --size 1 tp04-vol
openstack volume list                     # attendre le statut "available"
openstack server add volume tp04-vm1 tp04-vol
openstack volume list                     # statut "in-use", attaché à tp04-vm1
```

## Étape 2. Formater, monter, écrire

```bash
# [instance]
ssh cirros@$FIP1
```

```bash
# [VM] (tp04-vm1)
lsblk                                     # vda = disque système (éphémère), vdb = le volume
sudo mkfs.ext4 /dev/vdb                   # formater : UNE SEULE FOIS, cela efface le volume
sudo mkdir -p /mnt/data
sudo mount /dev/vdb /mnt/data
echo "écrit par tp04-vm1 le $(date)" | sudo tee /mnt/data/preuve.txt
df -h /mnt/data
sudo umount /mnt/data                     # toujours démonter avant de détacher
exit
```

## Étape 3. Le volume survit à la VM

```bash
# [instance]
openstack server remove volume tp04-vm1 tp04-vol
openstack server delete --wait tp04-vm1
openstack volume list                     # le volume existe toujours, "available"

openstack server create --image cirros --flavor m1.tiny --key-name mykey \
  --network demo-net --wait tp04-vm2
openstack server add floating ip tp04-vm2 $FIP1
openstack server add volume tp04-vm2 tp04-vol
ssh-keygen -R $FIP1                       # nouvelle VM sur la même floating IP (voir conventions)
ssh cirros@$FIP1                          # attendre ~1 min le démarrage
```

```bash
# [VM] (tp04-vm2)
sudo mkdir -p /mnt/data
sudo mount /dev/vdb /mnt/data             # sans mkfs : il effacerait les données
sudo cat /mnt/data/preuve.txt             # le fichier appartient à root (créé avec sudo tee)
sudo umount /mnt/data
exit
```

## Étape 4. Snapshot et restauration

```bash
# [instance]
openstack volume snapshot create --volume tp04-vol tp04-snap
```

Cette commande échoue : on ne fait pas de snapshot d'un volume en cours d'utilisation sans le dire
explicitement, car les données en cours d'écriture pourraient être incohérentes. Deux options :
détacher le volume, ou forcer. Ici, le système de fichiers est démonté, on peut forcer :

```bash
# [instance]
openstack volume snapshot create --volume tp04-vol --force tp04-snap
openstack volume snapshot list            # attendre "available"
openstack volume create --snapshot tp04-snap --size 1 tp04-vol-copie
openstack volume list
```

`tp04-vol-copie` est un nouveau volume contenant les données du snapshot. Pour vérifier, attachez-le
à `tp04-vm2` à la place de `tp04-vol` et lisez `preuve.txt`.

## Étape 5. Où sont les volumes sur l'hôte ?

```bash
# [instance]
sudo vgs cinder-volumes                   # le groupe de volumes LVM de Cinder
sudo lvs cinder-volumes                   # un volume logique par volume Cinder
ls -lh /var/lib/cinder-volumes.img        # le fichier qui contient tout le groupe LVM (scénario 02)
```

## Étape 6. Nettoyage

```bash
# [instance]
openstack server remove volume tp04-vm2 tp04-vol 2>/dev/null
openstack server remove volume tp04-vm2 tp04-vol-copie 2>/dev/null
openstack volume delete tp04-vol-copie
openstack volume snapshot delete tp04-snap
openstack volume delete tp04-vol          # un volume avec des snapshots ne peut pas être supprimé
openstack server delete --wait tp04-vm2
openstack floating ip delete $FIP1
```

Si `volume delete` répond que le volume a des snapshots, attendez quelques secondes que la suppression
du snapshot se termine, puis relancez.

## Questions

1. Qu'est-ce qui distingue `vda` de `vdb` dans la VM ? Que devient chacun quand on supprime la VM ?
2. Pourquoi faut-il démonter (`umount`) avant de détacher un volume ?
3. Pourquoi Cinder refuse-t-il par défaut un snapshot de volume attaché ?
4. Le stockage du lab est un fichier sur le disque de l'instance. Quelles limites cela pose-t-il ?
   Quelle alternative AWS existe ? (voir [../aws/aws-setup.md §3.3](../aws/aws-setup.md))

## Validation

- [ ] `preuve.txt` lu depuis `tp04-vm2` après suppression de `tp04-vm1`.
- [ ] Snapshot créé et volume restauré à partir du snapshot.
- [ ] Nettoyage fait (aucun volume ni snapshot `tp04-…`).

## Sources

- Cinder (stockage bloc) : <https://docs.openstack.org/cinder/2025.1/>
- Cinder dans Kolla-Ansible (LVM) : <https://docs.openstack.org/kolla-ansible/2025.1/reference/storage/cinder-guide.html>
- `lvcreate` (LVM) : <https://man7.org/linux/man-pages/man8/lvcreate.8.html>
- `losetup` : <https://man7.org/linux/man-pages/man8/losetup.8.html>
- Toutes les sources du parcours : [sources.md](sources.md)
