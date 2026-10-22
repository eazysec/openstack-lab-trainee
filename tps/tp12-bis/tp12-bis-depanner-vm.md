# TP 12 bis. Dépanner une VM : le mode rescue, puis cloud-init

| | |
|---|---|
| Prérequis | TP 12 (image `debian13`, gabarit `m1.1g`) ; tunnel SSH du TP 02 (étape 5) pour la console d'Horizon ; scénario 02 ou 04 (Cinder, pour l'étape 5) |
| À la fin du TP | Vous savez reprendre la main sur une VM dont l'accès administrateur est perdu, par le mode rescue, et dire pourquoi la méthode « console et GRUB » ne s'applique pas ici ; vous savez trouver pourquoi une personnalisation cloud-init a échoué, la reprendre sans recréer la VM, et dire ce que cette reprise change |

## Objectifs

- Provoquer une panne qui retire tout droit d'administration dans une VM, et en comprendre la cause.
- Démarrer la VM en mode rescue, réparer son disque depuis un autre système, puis la rendre.
- Reconnaître un rescue qui démarre sur le mauvais disque.
- Dire ce que la console d'une VM permet, ce qu'elle ne permet pas sur cette image, et ce qu'elle
  exposerait.
- Trouver dans les journaux de cloud-init la cause d'une personnalisation en échec, la corriger, puis
  relancer un module ou tout cloud-init, et relever ce que la relance change.

---

## Étape 0. Vérifier les conditions d'entrée

```bash
# [instance]
./openstack-lab-trainee/tps/tp12-bis/verifier-entree.sh    # dernière ligne : "Lab prêt pour le TP 12 bis."
```

Ce script ne modifie rien. Il vérifie que la plateforme répond, que les ressources communes du
déploiement sont là, que l'image `debian13` et le gabarit `m1.1g` du TP 12 existent, et qu'il ne
reste rien d'un essai précédent (`tp12b-`) ; il vérifie aussi que Cinder répond, pour l'étape 5. Chaque écart est affiché avec ce qu'il faut faire.

## Étape 1. Une VM, puis une panne

Une VM `debian13`, joignable en SSH depuis l'hôte seulement :

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
openstack security group create tp12b-sg-admin-demo --description "SSH depuis l'hôte seulement" -f value -c id
openstack security group rule create --ingress --protocol tcp --dst-port 22 --remote-ip 10.0.2.1/32 \
  tp12b-sg-admin-demo -f value -c id
openstack server create --image debian13 --flavor m1.1g --key-name mykey --network demo-net \
  --security-group tp12b-sg-admin-demo --wait tp12b-vm-demo -f value -c status   # ACTIVE
FIP=$(openstack floating ip create public1 -f value -c floating_ip_address)
openstack server add floating ip tp12b-vm-demo "$FIP"
ssh-keygen -R "$FIP"
until ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new debian@"$FIP" true 2>/dev/null; do sleep 5; done
ssh debian@"$FIP" 'sudo -n true && echo "sudo : OK"'
```

Les droits de `debian` viennent d'une règle écrite par cloud-init dans `/etc/sudoers.d/`. Une faute de
frappe dans un **autre** fichier de ce dossier :

```bash
# [instance]
ssh debian@"$FIP" 'echo "debian ALL=(ALL) NOPASSWD ALL" | sudo tee /etc/sudoers.d/99-essai > /dev/null; sudo -n true; echo "code $?"'
ssh debian@"$FIP" 'sudo rm /etc/sudoers.d/99-essai; sudo -n true && echo "sudo : OK"'
```

`sudo` signale l'erreur, mais répond quand même (code 0) : il ignore la ligne fausse et applique les
autres. La même faute dans la règle de `debian` elle-même :

```bash
# [instance]
ssh debian@"$FIP" 'sudo sed -i "s/NOPASSWD:ALL/NOPASSWD ALL/" /etc/sudoers.d/90-cloud-init-users'
ssh debian@"$FIP" 'sudo -n true; echo "code $?"'      # a password is required, code 1
```

Cette fois, la seule règle de `debian` est ignorée : il n'a plus aucun droit, et il n'a pas de mot de
passe à donner. Plus personne ne peut administrer la VM de l'intérieur. La connexion SSH, elle,
fonctionne toujours.

## Étape 2. Et la console ?

Sur un serveur physique, la méthode classique est la suivante : redémarrer, arrêter le chargeur de
démarrage GRUB, ajouter `init=/bin/bash` à la ligne du noyau, et l'on obtient un shell root sans mot de
passe, d'où l'on répare. Sur une VM, l'écran et le clavier sont ceux de la console d'Horizon. Voyez ce
qu'elle permet ici.

**Le clavier de la console.** Ouvrez le tunnel du TP 02 (étape 5), avec ses deux redirections :
Horizon (port 8080) et la console des VM (port 6080). Sans la seconde, la console reste vide. Dans
Horizon, ouvrez **Projet > Calcul > Instances > `tp12b-vm-demo` > Console**. Attendez l'invite
`tp12b-vm-demo login:`, cliquez une fois dans l'écran, puis tapez quelques lettres, sans appuyer sur
Entrée : elles s'affichent. Relevez les périphériques d'entrée de la VM, redémarrez-la « en
matériel », puis relevez-les de nouveau :

```bash
# [instance]
D=$(openstack server show tp12b-vm-demo -f value -c OS-EXT-SRV-ATTR:instance_name)
sudo docker exec nova_libvirt virsh dumpxml "$D" | grep "<input"   # tablette USB, souris PS/2, clavier PS/2
openstack server reboot --hard --wait tp12b-vm-demo
sudo docker exec nova_libvirt virsh dumpxml "$D" | grep "<input"   # un clavier USB en plus
until ssh -o BatchMode=yes debian@"$FIP" true 2>/dev/null; do sleep 5; done
```

« Matériel » désigne ici le matériel virtuel de la VM : Nova arrête le processus QEMU qui l'émule,
reconstruit sa définition, puis le relance ; l'instance AWS, elle, ne redémarre pas. Un redémarrage
logiciel (`openstack server reboot` sans `--hard`) demande seulement au système de la VM de
redémarrer, sans toucher à son matériel virtuel.

Rechargez la page de la console, attendez l'invite, cliquez dans l'écran et tapez de nouveau quelques
lettres : cette fois, rien ne s'affiche. Deux constats encore, lus dans la VM sans `sudo` :

```bash
# [instance]
ssh debian@"$FIP" 'cat /etc/default/grub.d/15_timeout.cfg'                  # délai du menu de GRUB
ssh debian@"$FIP" 'grep "CONFIG_USB_SUPPORT" /boot/config-$(uname -r)'      # le noyau et l'USB
```

Notez ces constats : la question 3 vous demande de les expliquer.

## Étape 3. Le mode rescue, avec la même image

Le mode rescue redémarre la VM sur un disque de secours, neuf, créé depuis une image ; le disque de la
VM y est ajouté comme second disque, pour qu'on le répare. Par défaut, le disque de secours vient de la
même image que la VM :

```bash
# [instance]
openstack server rescue tp12b-vm-demo
until [ "$(openstack server show tp12b-vm-demo -f value -c status)" = RESCUE ]; do sleep 3; done
ssh-keygen -R "$FIP"
until ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new debian@"$FIP" true 2>/dev/null; do sleep 5; done
ssh debian@"$FIP" 'lsblk -o NAME,SIZE,PARTUUID,MOUNTPOINTS'
ssh debian@"$FIP" 'sudo -n true; echo "code $?"'      # toujours : a password is required
openstack server stop tp12b-vm-demo                   # refusé : 409, la VM est en rescue
```

`vda` est le disque de secours (3 Go, la taille de l'image), `vdb` le disque de la VM (8 Go, celle du
gabarit). Mais la racine `/` est montée depuis `vdb1` : c'est le système en panne qui a démarré. Les
deux disques viennent de la même image, et leurs partitions portent le même identifiant (`PARTUUID`) ;
le noyau monte la partition qui porte cet identifiant, et il a pris celle de la VM. Ce rescue ne sert à
rien. Rendez la VM :

```bash
# [instance]
openstack server unrescue tp12b-vm-demo
until [ "$(openstack server show tp12b-vm-demo -f value -c status)" = ACTIVE ]; do sleep 3; done
```

## Étape 4. Le mode rescue, avec une autre image

On démarre cette fois sur l'image CirrOS, dont les identifiants de disque sont différents :

```bash
# [instance]
openstack server rescue --image cirros tp12b-vm-demo
until [ "$(openstack server show tp12b-vm-demo -f value -c status)" = RESCUE ]; do sleep 3; done
ssh-keygen -R "$FIP"                                  # autre système, autre clé d'hôte
until ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new cirros@"$FIP" true 2>/dev/null; do sleep 5; done
ssh cirros@"$FIP" 'grep " / " /proc/mounts; sudo blkid /dev/vdb1'
```

La racine est `vda1`, le disque de CirrOS ; le disque de la VM, `vdb1`, est libre. On le monte, on
corrige la règle, on le démonte :

```bash
# [instance]
ssh cirros@"$FIP" 'sudo mkdir -p /mnt/origine && sudo mount /dev/vdb1 /mnt/origine'
ssh cirros@"$FIP" 'sudo sed -i "s/NOPASSWD ALL/NOPASSWD:ALL/" /mnt/origine/etc/sudoers.d/90-cloud-init-users'
ssh cirros@"$FIP" 'sudo grep debian /mnt/origine/etc/sudoers.d/90-cloud-init-users; sudo umount /mnt/origine'
```

Rendez la VM, et vérifiez :

```bash
# [instance]
openstack server unrescue tp12b-vm-demo
until [ "$(openstack server show tp12b-vm-demo -f value -c status)" = ACTIVE ]; do sleep 3; done
ssh-keygen -R "$FIP"                                  # de nouveau le système de la VM
until ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new debian@"$FIP" true 2>/dev/null; do sleep 5; done
ssh debian@"$FIP" 'sudo -n true && echo "sudo : OK"; sudo visudo -c | tail -1'
```

La VM a retrouvé son disque, réparé, et ses droits d'administration. Rien d'autre n'a changé : même
identifiant, même adresse, même FIP.

## Étape 5. Une personnalisation qui échoue

Jusqu'ici, le système était cassé. Voici le cas inverse : la VM démarre, SSH répond, mais sa
personnalisation par cloud-init (TP 12) a échoué en partie. Le user-data ci-dessous formate et monte
un volume de données, puis vérifie le montage. Le volume est créé, mais on oublie de l'attacher à la
création de la VM (l'option `--block-device` du TP 12, étape 9) :

```bash
# [instance]
openstack volume create --size 1 tp12b-vol-donnees-demo -f value -c status
VOL=$(openstack volume show tp12b-vol-donnees-demo -f value -c id)
mkdir -p ~/tp12b
cat > ~/tp12b/user-data-donnees.yaml <<EOF
#cloud-config
fs_setup:
  - label: donnees
    filesystem: ext4
    device: /dev/disk/by-id/virtio-${VOL:0:20}
    overwrite: false
mounts:
  - [ LABEL=donnees, /srv/donnees, ext4, "defaults,nofail", "0", "2" ]
runcmd:
  - echo "runcmd \$(date +%T)" >> /var/log/tp12b-runcmd.log
  - findmnt /srv/donnees
EOF
cloud-init schema -c ~/tp12b/user-data-donnees.yaml 2>/dev/null | tail -1   # Valid schema …
openstack server create --image debian13 --flavor m1.1g --key-name mykey --network demo-net \
  --security-group tp12b-sg-admin-demo --user-data ~/tp12b/user-data-donnees.yaml \
  --wait tp12b-vm-donnees-demo -f value -c status                         # ACTIVE
FIP2=$(openstack floating ip create public1 -f value -c floating_ip_address)
openstack server add floating ip tp12b-vm-donnees-demo "$FIP2"
ssh-keygen -R "$FIP2"
until ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new debian@"$FIP2" true 2>/dev/null; do sleep 5; done
ssh debian@"$FIP2" 'cloud-init status --wait --long'                     # status: error
```

**Trouver la cause.** Le statut donne deux listes : `errors`, ce qui a échoué, et
`recoverable_errors`, les avertissements. Les journaux de cloud-init sont lisibles par le groupe
`adm`, dont `debian` fait partie :

```bash
# [instance]
ssh debian@"$FIP2" 'grep -A1 "Failed during filesystem" /var/log/cloud-init.log | head -2'
ssh debian@"$FIP2" 'cat /var/log/tp12b-runcmd.log; grep donnees /etc/fstab'
ssh debian@"$FIP2" 'ls /dev/disk/by-id/; lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS'
```

L'erreur porte sur `scripts-user`, c'est-à-dire le `runcmd` : `findmnt` n'a rien trouvé. Ce n'est
que le dernier symptôme. La cause est dans les avertissements : le disque attendu n'existait pas.
Entre les deux, `fs_setup` n'a rien formaté, mais `mounts` a quand même écrit sa ligne dans
`/etc/fstab` ; l'option `nofail` laisse la VM démarrer sans le disque.

**Corriger, puis relancer les seuls modules en cause.** On attache le volume, puis on relance les
deux modules qui en dépendent :

```bash
# [instance]
openstack server add volume tp12b-vm-donnees-demo tp12b-vol-donnees-demo
until ssh debian@"$FIP2" "test -e /dev/disk/by-id/virtio-${VOL:0:20}"; do sleep 3; done
ssh debian@"$FIP2" 'sudo cloud-init single --name disk_setup --frequency always; lsblk -o NAME,FSTYPE,LABEL,MOUNTPOINTS /dev/vdb'
ssh debian@"$FIP2" 'sudo cloud-init single --name mounts --frequency always; findmnt /srv/donnees'
ssh debian@"$FIP2" 'cloud-init status | head -1'
ssh debian@"$FIP2" 'echo "écrit avant la relance" | sudo tee /srv/donnees/temoin.txt'
```

Le volume est formaté, puis monté : la VM est réparée sans redémarrer. Le statut, lui, reste
`error` : il décrit le dernier démarrage, et `single` ne le refait pas.

**Relancer tout cloud-init.** `cloud-init clean` efface ce que cloud-init a retenu de la VM
(fichiers témoins, `/var/lib/cloud/instance`), et `--reboot` redémarre : au démarrage suivant,
cloud-init croit voir une nouvelle VM et rejoue toute la configuration. Relevez l'empreinte de la clé
d'hôte avant et après :

```bash
# [instance]
ssh-keyscan -t ed25519 "$FIP2" 2>/dev/null | ssh-keygen -lf -
ssh debian@"$FIP2" 'sudo cloud-init clean --logs --reboot'
sleep 30
until ssh-keyscan -T 5 -t ed25519 "$FIP2" 2>/dev/null | grep -q ed25519; do sleep 5; done
ssh-keyscan -t ed25519 "$FIP2" 2>/dev/null | ssh-keygen -lf -
ssh -o BatchMode=yes debian@"$FIP2" true                                 # refusé : la clé d'hôte a changé
```

La clé d'hôte a changé. Avant d'accepter la nouvelle, comparez-la à celle que cloud-init a affichée
dans la console, comme au TP 13 (étape 8) : la dernière empreinte affichée est celle du démarrage
qui vient d'avoir lieu.

```bash
# [instance]
openstack console log show tp12b-vm-donnees-demo | sed -n '/BEGIN SSH HOST KEY FINGERPRINTS/,/END/p' | grep ED25519 | tail -1
ssh-keyscan -t ed25519 "$FIP2" 2>/dev/null | ssh-keygen -lf -
```

Si les deux empreintes `SHA256:…` sont identiques, retirez l'ancienne clé et reconnectez-vous :

```bash
# [instance]
ssh-keygen -R "$FIP2"
until ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new debian@"$FIP2" true 2>/dev/null; do sleep 5; done
ssh debian@"$FIP2" 'cloud-init status --wait --long | head -1; cat /var/log/tp12b-runcmd.log; cat /srv/donnees/temoin.txt'
```

Le statut est `done`. Le `runcmd` a été rejoué : deux lignes dans son journal. Le fichier témoin est
toujours là : `overwrite: false` a empêché de reformater un disque qui avait déjà un système de
fichiers. Le user-data, lui, n'a pas changé : la relance rejoue la même configuration. Elle répare une
cause extérieure à la VM (un disque oublié, un réseau coupé), pas une erreur du user-data.

## Étape 6. Nettoyage

```bash
# [instance]
openstack server delete --wait tp12b-vm-demo tp12b-vm-donnees-demo
openstack floating ip delete "$FIP" "$FIP2"
openstack volume delete tp12b-vol-donnees-demo
openstack security group delete tp12b-sg-admin-demo
ssh-keygen -R "$FIP"; ssh-keygen -R "$FIP2"
rm -r ~/tp12b
```

## Questions

1. Pourquoi une faute dans un autre fichier de `/etc/sudoers.d/` n'a-t-elle rien bloqué, alors que la
   même faute dans la règle de `debian` lui a tout retiré ? Comment vérifier une règle avant qu'elle
   ne s'applique ?
2. À l'étape 3, pourquoi le rescue a-t-il démarré le système en panne ? À quoi le reconnaît-on ?
3. À l'étape 2, pourquoi les lettres ne s'affichent-elles plus après le redémarrage matériel ? Pourquoi
   la méthode « console, GRUB, `init=/bin/bash` » n'est-elle pas utilisable sur cette VM ? Que
   faudrait-il avoir prévu avant la panne ?
4. Si cette méthode fonctionnait, qu'obtiendrait-on, et avec quel mot de passe ? Qui peut ouvrir la
   console d'une VM, et quelles protections faudrait-il ?
5. Le TP 12 conseille de reconstruire plutôt que de modifier une VM (immutabilité). Quand réparer
   par le rescue, et quand reconstruire ? Que perd-on dans chaque cas ?
6. À l'étape 5, le statut signale une erreur dans le `runcmd`, alors que la cause est ailleurs.
   Pourquoi ? Dans quel ordre lire le statut et les journaux pour remonter à la cause ?
7. Trois façons de reprendre une personnalisation : relancer un module (`cloud-init single`), relancer
   tout cloud-init (`cloud-init clean --reboot`), reconstruire la VM (`server rebuild`, TP 12,
   étape 6). Que rejoue chacune, et que change-t-elle : statut, `runcmd`, clés d'hôte, données,
   user-data ? Pourquoi faut-il vérifier la nouvelle clé d'hôte avant de l'accepter ?

## Validation

- [ ] Panne provoquée : `sudo` refusé, et la différence avec une faute dans un autre fichier expliquée.
- [ ] Console : lettres affichées sur la VM neuve, plus rien après le redémarrage matériel ; clavier USB
  relevé dans la définition de la VM ; délai de GRUB relevé.
- [ ] Rescue avec la même image : disque monté en racine relevé, échec expliqué.
- [ ] Rescue avec CirrOS : règle réparée depuis le disque de la VM, `sudo` de nouveau accepté.
- [ ] Personnalisation en échec : cause trouvée dans les avertissements ; volume monté par
  `cloud-init single` ; après `clean --reboot` : statut `done`, `runcmd` rejoué, nouvelle clé d'hôte
  comparée à la console, fichier témoin conservé.
- [ ] Questions 2 à 4 et 7 argumentées.
- [ ] Nettoyage fait.

## Sources

- Nova, mode rescue : <https://docs.openstack.org/nova/2025.1/user/rescue.html>
- sudoers, format des règles et traitement des erreurs : <https://www.sudo.ws/docs/man/sudoers.man/>
- GRUB, configuration et édition au démarrage : <https://www.gnu.org/software/grub/manual/grub/grub.html>
- cloud-init, commandes `status`, `single`, `clean` : <https://cloudinit.readthedocs.io/en/latest/reference/cli.html>
- cloud-init, relancer : <https://cloudinit.readthedocs.io/en/latest/howto/rerun_cloud_init.html>
- cloud-init, déboguer : <https://cloudinit.readthedocs.io/en/latest/howto/debugging.html>
- Toutes les sources du parcours : [sources.md](../sources.md)
