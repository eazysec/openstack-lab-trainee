# TP 12. Configurer les VM au démarrage avec cloud-init

| | |
|---|---|
| Prérequis | TP 03 et TP 04 ; scénario 02 ou 04 (Cinder) ; accès Internet depuis l'instance |
| À la fin du TP | Vous savez décrire la configuration d'une VM dans un user-data, la vérifier, et dire ce qu'il ne faut jamais y mettre |

> **Instance ou VM ?** Dans tout le parcours, l'*instance* est la machine louée chez AWS, qui
> héberge OpenStack, et les *VM* sont les machines créées par OpenStack.
>
> ```
> Votre poste
>    │  ssh -i ec2_key ubuntu@<IP_PUBLIQUE>
>    ▼
> ┌─────────────────────────────────────────────────────────┐
> │ L'« instance » : une machine virtuelle louée chez AWS   │
> │ (t2.xlarge). OpenStack est installé dessus.             │
> │                                                         │
> │   ┌──────────────┐  ┌──────────────┐                    │
> │   │ VM tp12-vm-1 │  │ VM tp12-vm-2 │  ← les « VM » :    │
> │   │ (Debian)     │  │ (Debian)     │    créées PAR      │
> │   └──────────────┘  └──────────────┘    OpenStack       │
> └─────────────────────────────────────────────────────────┘
> ```
>
> Attention : AWS comme OpenStack appellent « instance » leurs machines virtuelles. Quand cloud-init
> parle d'`instance_id` ou d'exécution « une fois par instance », il s'agit donc de la **VM**.

## Objectifs

- Comprendre le rôle de cloud-init : configurer une VM à son premier démarrage, sans agent ni
  connexion manuelle, à partir d'un *user-data*.
- Distinguer le *user-data* (fourni par vous) des *métadonnées* (fournies par le cloud).
- Créer un compte d'exploitation sûr : clé SSH seulement, mot de passe verrouillé, `sudo` limité.
- Constater qu'un secret placé dans un user-data est lisible par n'importe quel processus de la VM.
- Appliquer le principe d'immutabilité : on ne modifie pas une VM, on la reconstruit.
- Monter un partage NFS entre deux VM entièrement par cloud-init, filtré par security groups.

### Repères

cloud-init est installé dans les images cloud de la plupart des distributions (Debian, Ubuntu, Red
Hat, etc.) et fonctionne sur AWS comme sur OpenStack : le même user-data sert partout. Il lit sa
configuration au démarrage, l'applique, puis ne la rejoue plus : changer de configuration, c'est
remplacer la VM. C'est le principe d'**infrastructure immuable**.

| Terme | Fourni par | Exemple | Modifiable par vous |
|---|---|---|---|
| user-data | vous, à la création de la VM | comptes, paquets, fichiers, commandes | oui, en recréant ou reconstruisant la VM |
| métadonnées | le cloud | identifiant, nom, zone, clés SSH | non |

cloud-init applique sa configuration en trois phases successives : `init` (réseau, disques,
montages), `config` (comptes, fichiers…), `final` (paquets, commandes `runcmd`). L'ordre compte : à
l'étape 9, un montage échouerait parce qu'il a lieu avant l'installation des paquets.

---

## Étape 0. Préparer l'image, le gabarit et la clé

L'image CirrOS des TP précédents n'embarque pas cloud-init. On utilise l'image cloud officielle de
Debian 13, légère et rapide à démarrer en émulation. Si l'image et le gabarit existent déjà (lab
préparé par le formateur), passez directement à la création de la clé.

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
mkdir -p ~/tp12 && cd ~/tp12
U=https://cloud.debian.org/images/cloud/trixie/latest
curl -fLO $U/debian-13-genericcloud-amd64.qcow2                           # ~330 Mo
curl -fsSL $U/SHA512SUMS | grep " debian-13-genericcloud-amd64.qcow2$" | sha512sum -c   # "OK"
openstack image create --disk-format qcow2 --container-format bare \
  --file debian-13-genericcloud-amd64.qcow2 tp12-img-debian13
openstack flavor create --vcpus 1 --ram 1024 --disk 8 tp12-flv-1g        # 1 Go suffit
ssh-keygen -q -t ed25519 -N "" -C tp12-key -f ~/.ssh/tp12-key
openstack keypair create --public-key ~/.ssh/tp12-key.pub tp12-key
```

Vérifier l'empreinte avant d'importer une image est une règle de base : une image modifiée serait
recopiée dans chaque VM.

## Étape 1. Un compte d'exploitation décrit dans un user-data

```bash
# [instance]
cat > user-data-stack.yaml <<EOF
#cloud-config
# Un compte d'exploitation "stack", accès par clé uniquement
users:
  - name: stack
    gecos: Compte d'exploitation du TP 12
    shell: /bin/bash
    lock_passwd: true
    groups: [systemd-journal, adm]
    sudo: "ALL=(root) NOPASSWD: /usr/bin/systemctl --no-pager status *"
    ssh_authorized_keys:
      - $(cat ~/.ssh/tp12-key.pub)
ssh_pwauth: false
disable_root: true
EOF
cloud-init schema -c user-data-stack.yaml        # dernière ligne : "Valid schema user-data-stack.yaml"
```

L'instance AWS fait elle-même tourner cloud-init : on s'en sert pour valider le fichier avant de
créer la VM. Les lignes `WARNING` sur les permissions sont normales (commande lancée sans `sudo`).

| Ligne | Effet |
|---|---|
| `lock_passwd: true` | aucun mot de passe : connexion par clé seulement |
| `groups` | lecture des journaux système sans `sudo` |
| `sudo` | une seule commande autorisée en root, sans mot de passe |
| `ssh_pwauth: false` | le serveur SSH refuse toute authentification par mot de passe |
| `disable_root: true` | connexion directe en root refusée |

## Étape 2. Lancer la VM

Le security group n'autorise SSH que depuis l'instance (le bastion), dont l'adresse sur `public1` est
`10.0.2.1`.

```bash
# [instance]
openstack security group create --description "TP 12 : SSH depuis le bastion" tp12-sg-ssh
openstack security group rule create --ingress --protocol tcp --dst-port 22 \
  --remote-ip 10.0.2.1/32 tp12-sg-ssh
openstack server create --image tp12-img-debian13 --flavor tp12-flv-1g --key-name tp12-key \
  --network demo-net --security-group tp12-sg-ssh --user-data user-data-stack.yaml --wait tp12-vm-1
FIP=$(openstack floating ip create public1 --description tp12-fip-vm-1 -f value -c floating_ip_address)
openstack server add floating ip tp12-vm-1 $FIP
echo "FIP=$FIP" > ~/tp12/env                     # pour retrouver l'adresse dans une autre session
ssh -i ~/.ssh/tp12-key stack@$FIP cloud-init status --wait     # 2 à 3 min : "status: done"
```

Tant que la VM démarre, `ssh` répond `Connection refused` ou ne répond pas : relancez la commande.

## Étape 3. Métadonnées et user-data, vus de la VM

```bash
# [instance]
ssh -i ~/.ssh/tp12-key stack@$FIP
```

```bash
# [VM] (tp12-vm-1, en tant que stack)
cloud-init status --long                         # status: done ; erreurs éventuelles
cloud-init query v1.instance_id                  # l'identifiant de la VM
cloud-init query v1.local_hostname
cloud-init query userdata                        # "redacted for non-root user"
ls -l /var/lib/cloud/instance/user-data.txt     # lisible par root seulement
ip route get 169.254.169.254                    # le service de métadonnées d'OpenStack
curl -s http://169.254.169.254/openstack/latest/             # ce que le cloud expose
curl -s http://169.254.169.254/openstack/latest/meta_data.json; echo
```

`meta_data.json` contient ce que le cloud sait de la VM : identifiant, nom, zone, clés SSH publiques.
La VM le lit par une adresse spéciale, `169.254.169.254`, que Neutron intercepte.

## Étape 4. Ce qu'il ne faut jamais mettre dans un user-data

cloud-init protège sa copie locale du user-data (étape 3). Mais le service de métadonnées, lui, le
sert à quiconque le demande depuis la VM :

```bash
# [VM] (tp12-vm-1, en tant que stack, compte sans privilège)
curl -s http://169.254.169.254/openstack/latest/user_data
```

Le user-data complet s'affiche. N'importe quel processus de la VM, y compris un service compromis,
peut faire de même. Un mot de passe, une clé privée ou un jeton placé dans un user-data est donc
exposé. Les secrets se récupèrent au démarrage depuis un gestionnaire de secrets comme Barbican
(TP 08), avec des droits limités.

## Étape 5. Le compte stack : ce qu'il peut faire, et ce qu'il ne peut pas faire

```bash
# [VM] (tp12-vm-1, en tant que stack)
id                                               # groupes systemd-journal et adm
grep -E "sh$" /etc/passwd | cut -d: -f1          # root et stack seulement
sudo -l                                          # la seule commande autorisée
sudo systemctl --no-pager status ssh             # autorisé
sudo systemctl status ssh                        # refusé : "a password is required"
sudo cat /etc/shadow                             # refusé
journalctl -u ssh -n 3 --no-pager                # journaux lisibles sans sudo
exit
```

Pourquoi `--no-pager` dans la règle `sudo` ? Sans cette option, `systemctl status` affiche sa sortie
dans `less`, et `less` permet de lancer un shell avec `!sh`. Lancé par `sudo`, ce shell serait root :
une règle d'apparence anodine donnerait tous les droits. C'est une erreur fréquente : avant d'autoriser
une commande par `sudo`, vérifiez qu'elle ne permet pas d'en exécuter une autre.

Depuis l'instance, vérifiez les refus :

```bash
# [instance]
ssh -o PubkeyAuthentication=no stack@$FIP        # "Permission denied (publickey)" : pas de mot de passe
ssh -i ~/.ssh/tp12-key debian@$FIP               # refusé : le compte n'existe pas
ssh -i ~/.ssh/tp12-key root@$FIP                 # refusé
```

Le compte `debian`, créé d'habitude par l'image, n'existe pas : la liste `users` du user-data
remplace le compte par défaut. Pour le garder, il faudrait ajouter `- default` en tête de la liste.
La clé `tp12-key` donnée à `server create` était destinée à ce compte : elle n'est donc utilisée
nulle part, seule celle du user-data compte.

## Étape 6. Immutabilité : on reconstruit, on ne modifie pas

On ne peut pas changer le user-data d'une VM existante. Pour changer sa configuration, on la
*reconstruit* (`rebuild`) : même identifiant, même adresse, mais un disque neuf et un nouveau
user-data. cloud-init voit un disque vierge et rejoue tout.

```bash
# [instance]
sed '/^ssh_pwauth/i bootcmd:\n  - echo "bootcmd   $(date +%T)" >> /var/log/tp12-frequences.log\nruncmd:\n  - echo "runcmd    $(date +%T)" >> /var/log/tp12-frequences.log\n  - chmod 644 /var/log/tp12-frequences.log' \
  user-data-stack.yaml > user-data-v2.yaml
cloud-init schema -c user-data-v2.yaml
openstack server rebuild --image tp12-img-debian13 --user-data user-data-v2.yaml --wait tp12-vm-1
ssh-keygen -R $FIP                               # disque neuf : nouvelle clé d'hôte SSH
ssh -i ~/.ssh/tp12-key stack@$FIP 'cloud-init status --wait; cat /var/log/tp12-frequences.log'
openstack server reboot --wait tp12-vm-1
ssh -i ~/.ssh/tp12-key stack@$FIP 'cloud-init status --wait; cat /var/log/tp12-frequences.log'
```

Après la reconstruction : une ligne `bootcmd`, une ligne `runcmd`. Après le redémarrage : une ligne
`bootcmd` de plus, et toujours une seule ligne `runcmd`.

| Module | Fréquence | Usage |
|---|---|---|
| `bootcmd` | à chaque démarrage, très tôt | réglages à refaire à chaque fois |
| `runcmd`, `users`, `packages`… | une fois par instance, c'est-à-dire par VM | configuration initiale |

cloud-init retient ce qu'il a déjà fait dans des fichiers témoins :

```bash
# [instance]
ssh -i ~/.ssh/tp12-key stack@$FIP 'ls -l /var/lib/cloud/instance/sem/ | head'
```

## Étape 7. Un user-data, une configuration propre à chaque VM

Un user-data peut être un gabarit Jinja : cloud-init remplace les variables par les métadonnées de
la VM. La première ligne doit être `## template: jinja`.

```bash
# [instance]
{ echo '## template: jinja'
  sed '/^ssh_pwauth/i write_files:\n  - path: /etc/motd\n    content: |\n      VM {{ v1.local_hostname }}, identifiant {{ v1.instance_id }}, zone {{ v1.availability_zone }}' \
    user-data-stack.yaml; } > user-data-jinja.yaml
cloud-init schema -c user-data-jinja.yaml
openstack server rebuild --image tp12-img-debian13 --user-data user-data-jinja.yaml --wait tp12-vm-1
openstack server create --image tp12-img-debian13 --flavor tp12-flv-1g --key-name tp12-key \
  --network demo-net --security-group tp12-sg-ssh --user-data user-data-jinja.yaml --wait tp12-vm-2
FIP2=$(openstack floating ip create public1 --description tp12-fip-vm-2 -f value -c floating_ip_address)
openstack server add floating ip tp12-vm-2 $FIP2; echo "FIP2=$FIP2" >> ~/tp12/env
ssh-keygen -R $FIP
for f in $FIP $FIP2; do ssh -i ~/.ssh/tp12-key stack@$f 'cloud-init status --wait >/dev/null; cat /etc/motd'; done
```

Le même fichier produit un message différent sur chaque VM. Supprimez ensuite `tp12-vm-2`, pour
libérer la mémoire de l'hôte :

```bash
# [instance]
openstack server delete --wait tp12-vm-2
openstack floating ip delete $FIP2
```

## Étape 8. Un partage NFS : volume, groupes et ports

On monte un partage NFS entre un serveur et un client, configurés uniquement par cloud-init. Les
bonnes pratiques appliquées :

- NFS version 4.2 seulement : un seul port (TCP 2049), sans `rpcbind` (port 111) ;
- un security group qui n'ouvre 2049 qu'aux membres du groupe client (`remote_group`) ;
- un export limité à l'adresse du client, avec `root_squash` : root sur le client n'est pas root sur
  le partage ;
- le même UID pour `stack` sur les deux VM, car NFS identifie les propriétaires par leur numéro.

On crée d'abord les ports des deux VM, pour connaître leurs adresses avant d'écrire les user-data.

```bash
# [instance]
openstack volume create --size 1 tp12-vol-nfs
openstack security group create --description "TP 12 : serveur NFS" tp12-sg-nfs-srv
openstack security group create --description "TP 12 : clients NFS" tp12-sg-nfs-cli
openstack security group rule create --ingress --protocol tcp --dst-port 2049 \
  --remote-group tp12-sg-nfs-cli tp12-sg-nfs-srv
openstack port create --network demo-net --security-group tp12-sg-ssh \
  --security-group tp12-sg-nfs-srv tp12-port-vm-nfs
openstack port create --network demo-net --security-group tp12-sg-ssh \
  --security-group tp12-sg-nfs-cli tp12-port-vm-client
IPS=$(openstack port show tp12-port-vm-nfs -f value -c fixed_ips | grep -oP "ip_address': '\K[^']+")
IPC=$(openstack port show tp12-port-vm-client -f value -c fixed_ips | grep -oP "ip_address': '\K[^']+")
VOL=$(openstack volume show tp12-vol-nfs -f value -c id)
echo "serveur $IPS, client $IPC, volume $VOL"
echo "IPS=$IPS IPC=$IPC VOL=$VOL" >> ~/tp12/env
```

## Étape 9. Le serveur NFS, entièrement par cloud-init

Le volume est désigné par son identifiant stable, `/dev/disk/by-id/virtio-<20 premiers caractères de
l'ID du volume>`, plutôt que par `/dev/vdb`, dont le nom peut changer. `overwrite: false` interdit à
cloud-init de reformater un disque qui contient déjà un système de fichiers.

```bash
# [instance]
cat > compte-stack.yaml <<EOF
users:
  - name: stack
    uid: 2001
    gecos: Compte d'exploitation du TP 12
    shell: /bin/bash
    lock_passwd: true
    groups: [systemd-journal, adm]
    sudo: "ALL=(root) NOPASSWD: /usr/bin/systemctl --no-pager status *"
    ssh_authorized_keys:
      - $(cat ~/.ssh/tp12-key.pub)
ssh_pwauth: false
disable_root: true
EOF
{ echo "#cloud-config"; cat compte-stack.yaml; cat <<EOF
fs_setup:
  - label: tp12-nfs
    filesystem: ext4
    device: /dev/disk/by-id/virtio-${VOL:0:20}
    overwrite: false
mounts:
  - [ LABEL=tp12-nfs, /srv/nfs, ext4, "defaults,nofail", "0", "2" ]
packages: [nfs-kernel-server]
write_files:
  - path: /etc/nfs.conf.d/tp12.conf
    content: |
      [nfsd]
      vers3=n
      vers4.0=n
      vers4.1=n
      vers4.2=y
  - path: /etc/exports.d/tp12.exports
    content: |
      /srv/nfs/partage $IPC(rw,sync,root_squash,no_subtree_check)
runcmd:
  - mkdir -p /srv/nfs/partage
  - chown 2001:2001 /srv/nfs/partage
  - systemctl mask --now rpcbind.socket rpcbind.service
  - systemctl restart nfs-server
  - exportfs -ra
EOF
} > user-data-nfs-srv.yaml
cloud-init schema -c user-data-nfs-srv.yaml
openstack server create --image tp12-img-debian13 --flavor tp12-flv-1g --key-name tp12-key \
  --port tp12-port-vm-nfs --user-data user-data-nfs-srv.yaml \
  --block-device uuid=$VOL,source_type=volume,destination_type=volume,boot_index=-1,delete_on_termination=false \
  --wait tp12-vm-nfs
FIPS=$(openstack floating ip create public1 --description tp12-fip-vm-nfs -f value -c floating_ip_address)
openstack server add floating ip tp12-vm-nfs $FIPS; echo "FIPS=$FIPS" >> ~/tp12/env
ssh -i ~/.ssh/tp12-key stack@$FIPS 'cloud-init status --wait; findmnt /srv/nfs; ls -ln /srv/nfs; ss -ltn'
```

Le partage appartient à l'UID 2001. Le serveur écoute sur 2049, mais aussi sur quelques ports
aléatoires (services RPC annexes de NFS) : le security group ne les ouvre à personne. C'est la
défense en profondeur : chaque couche filtre, même si la précédente laisse passer.

## Étape 10. Le client NFS : attention à l'ordre des phases

```bash
# [instance]
{ echo "#cloud-config"; cat compte-stack.yaml; cat <<EOF
packages: [nfs-common]
mounts:
  - [ "$IPS:/srv/nfs/partage", /mnt/partage, nfs4, "vers=4.2,_netdev,nofail,noauto,x-systemd.automount", "0", "0" ]
runcmd:
  - [ systemctl, start, mnt-partage.automount ]
  - [ sh, -c, 'touch /mnt/partage/essai-root 2> /var/log/tp12-root-squash.log; chmod 644 /var/log/tp12-root-squash.log' ]
EOF
} > user-data-nfs-cli.yaml
cloud-init schema -c user-data-nfs-cli.yaml
openstack server create --image tp12-img-debian13 --flavor tp12-flv-1g --key-name tp12-key \
  --port tp12-port-vm-client --user-data user-data-nfs-cli.yaml --wait tp12-vm-client
FIPC=$(openstack floating ip create public1 --description tp12-fip-vm-client -f value -c floating_ip_address)
openstack server add floating ip tp12-vm-client $FIPC; echo "FIPC=$FIPC" >> ~/tp12/env
ssh -i ~/.ssh/tp12-key stack@$FIPC 'cloud-init status --wait'
ssh -i ~/.ssh/tp12-key stack@$FIPC 'cat /var/log/tp12-root-squash.log; echo bonjour > /mnt/partage/de-stack.txt; ls -l /mnt/partage; findmnt -t nfs4 /mnt/partage'
ssh -i ~/.ssh/tp12-key stack@$FIPS 'ls -ln /srv/nfs/partage'
```

Résultats attendus :

- `cloud-init status` : `done`, sans erreur ;
- l'écriture tentée par root au démarrage est refusée (`Permission denied`) : c'est `root_squash` ;
- le fichier écrit par `stack` appartient à `stack` côté client et à l'UID 2001 côté serveur.

Pourquoi `noauto,x-systemd.automount` ? Le module `mounts` s'exécute dans la phase `init`, avant la
phase `final` qui installe les paquets. Un montage NFS immédiat échouerait (« mount program didn't
pass remote address » : `nfs-common` n'est pas encore là). Avec ces options, systemd monte le partage
au premier accès, une fois les paquets installés ; le `runcmd`, qui s'exécute en phase `final`, active
cet automontage dès le premier démarrage.

## Étape 11. Contre-tests

```bash
# [instance]
ssh -i ~/.ssh/tp12-key stack@$FIP "timeout 5 bash -c '</dev/tcp/$IPS/2049' && echo OUVERT || echo FILTRÉ"
ssh -i ~/.ssh/tp12-key stack@$FIPC "timeout 5 bash -c '</dev/tcp/$IPS/2049' && echo OUVERT || echo FILTRÉ"
ssh -i ~/.ssh/tp12-key stack@$FIPC "timeout 5 bash -c '</dev/tcp/$IPS/111' && echo OUVERT || echo FILTRÉ"
```

Attendu : `FILTRÉ` depuis `tp12-vm-1` (hors du groupe client), `OUVERT` depuis le client sur 2049,
`FILTRÉ` sur 111.

Limite à connaître : sans Kerberos (`sec=krb5`), le serveur fait confiance aux UID annoncés par le
client. Quiconque est root sur une machine autorisée peut se faire passer pour n'importe quel
utilisateur (sauf root, grâce à `root_squash`). Le filtrage par security group et par adresse est donc
indispensable. Kerberos est hors du périmètre de ce lab.

## Étape 12. Nettoyage

L'image et le gabarit servent au TP 13 : on les garde.

```bash
# [instance]
source ~/tp12/env
openstack server delete --wait tp12-vm-1 tp12-vm-nfs tp12-vm-client
openstack floating ip delete $FIP $FIPS $FIPC
openstack port delete tp12-port-vm-nfs tp12-port-vm-client
openstack volume delete tp12-vol-nfs
openstack security group delete tp12-sg-nfs-srv tp12-sg-nfs-cli tp12-sg-ssh
openstack keypair delete tp12-key
for ip in $FIP $FIPS $FIPC; do ssh-keygen -R $ip; done
```

## Questions

1. Quelle différence entre le user-data et les métadonnées ? Lequel pouvez-vous modifier, et comment ?
2. Pourquoi un mot de passe ne doit-il jamais figurer dans un user-data, alors que cloud-init protège
   sa copie locale ?
3. Pourquoi la règle `sudo` autorise-t-elle `systemctl --no-pager status` et non `systemctl status` ?
4. Pourquoi le compte `debian` n'existe-t-il pas, et pourquoi la connexion en root affiche-t-elle
   « login as the user "NONE" » ?
5. Après un `rebuild`, la VM garde son identifiant, mais cloud-init rejoue toute la configuration.
   Pourquoi ?
6. Pourquoi le client monte-t-il le partage par automontage, et non par un montage immédiat ?
7. Pourquoi faut-il le même UID pour `stack` sur les deux VM ? Que se passerait-il sinon ?
8. Quels mécanismes empêchent une autre VM du projet d'accéder au partage ? Lequel resterait si l'un
   d'eux était mal configuré ?

## Validation

- [ ] Image vérifiée par son empreinte avant import.
- [ ] user-data validé par `cloud-init schema` avant chaque création.
- [ ] user-data lu en clair par un compte sans privilège, via le service de métadonnées.
- [ ] Refus constatés : mot de passe, compte `debian`, root, `sudo` hors de la règle.
- [ ] Fréquences `bootcmd` et `runcmd` constatées après `rebuild` et redémarrage.
- [ ] Partage NFS monté par cloud-init, sans erreur ; `root_squash` et UID constatés.
- [ ] Contre-tests : 2049 filtré hors du groupe client, 111 filtré.
- [ ] Questions 2, 3 et 8 argumentées.
- [ ] Nettoyage fait, image et gabarit conservés.

## Sources

- Documentation de cloud-init : <https://cloudinit.readthedocs.io/en/latest/>
- Modules de cloud-init (users, mounts, fs_setup, runcmd, bootcmd) : <https://cloudinit.readthedocs.io/en/latest/reference/modules.html>
- Phases du démarrage de cloud-init : <https://cloudinit.readthedocs.io/en/latest/explanation/boot.html>
- Gabarits Jinja dans un user-data : <https://cloudinit.readthedocs.io/en/latest/explanation/instancedata.html>
- Service de métadonnées de Nova : <https://docs.openstack.org/nova/2025.1/user/metadata.html>
- Images cloud de Debian : <https://cloud.debian.org/images/cloud/>
- GTFOBins, `systemctl` : <https://gtfobins.github.io/gtfobins/systemctl/>
- NFS et automontage : <https://man7.org/linux/man-pages/man5/exports.5.html>,
  <https://man7.org/linux/man-pages/man5/nfs.conf.5.html>,
  <https://man7.org/linux/man-pages/man5/systemd.automount.5.html>
- Toutes les sources du parcours : [sources.md](sources.md)
