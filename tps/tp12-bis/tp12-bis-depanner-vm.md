# TP 12 bis. Dépanner une VM : le mode rescue

| | |
|---|---|
| Prérequis | TP 12 (image `debian13`, gabarit `m1.1g`) ; tunnel SSH du TP 02 (étape 5) pour la console d'Horizon ; scénario 02 ou 04 |
| À la fin du TP | Vous savez reprendre la main sur une VM dont l'accès administrateur est perdu, par le mode rescue, et dire pourquoi la méthode « console et GRUB » ne s'applique pas ici |

## Objectifs

- Provoquer une panne qui retire tout droit d'administration dans une VM, et en comprendre la cause.
- Démarrer la VM en mode rescue, réparer son disque depuis un autre système, puis la rendre.
- Reconnaître un rescue qui démarre sur le mauvais disque.
- Dire ce que la console d'une VM permet, ce qu'elle ne permet pas sur cette image, et ce qu'elle
  exposerait.

---

## Étape 0. Vérifier les conditions d'entrée

```bash
# [instance]
./openstack-lab-trainee/tps/tp12-bis/verifier-entree.sh    # dernière ligne : "Lab prêt pour le TP 12 bis."
```

Ce script ne modifie rien. Il vérifie que la plateforme répond, que les ressources communes du
déploiement sont là, que l'image `debian13` et le gabarit `m1.1g` du TP 12 existent, et qu'il ne
reste rien d'un essai précédent (`tp12b-`). Chaque écart est affiché avec ce qu'il faut faire.

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

## Étape 5. Nettoyage

```bash
# [instance]
openstack server delete --wait tp12b-vm-demo
openstack floating ip delete "$FIP"
openstack security group delete tp12b-sg-admin-demo
ssh-keygen -R "$FIP"
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

## Validation

- [ ] Panne provoquée : `sudo` refusé, et la différence avec une faute dans un autre fichier expliquée.
- [ ] Console : lettres affichées sur la VM neuve, plus rien après le redémarrage matériel ; clavier USB
  relevé dans la définition de la VM ; délai de GRUB relevé.
- [ ] Rescue avec la même image : disque monté en racine relevé, échec expliqué.
- [ ] Rescue avec CirrOS : règle réparée depuis le disque de la VM, `sudo` de nouveau accepté.
- [ ] Questions 2 à 4 argumentées.
- [ ] Nettoyage fait.

## Sources

- Nova, mode rescue : <https://docs.openstack.org/nova/2025.1/user/rescue.html>
- sudoers, format des règles et traitement des erreurs : <https://www.sudo.ws/docs/man/sudoers.man/>
- GRUB, configuration et édition au démarrage : <https://www.gnu.org/software/grub/manual/grub/grub.html>
- Toutes les sources du parcours : [sources.md](../sources.md)
