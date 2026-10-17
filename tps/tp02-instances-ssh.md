# TP 02. Lancer des instances depuis l'hôte et s'y connecter en SSH

| | |
|---|---|
| Durée | 1 h 30 |
| Prérequis | TP 01 (OpenStack déployé, `verify.sh` OK) |
| À la fin du TP | Vous savez créer une VM, la rendre joignable et vous y connecter |

## Objectifs

- Connaître les briques nécessaires pour lancer une VM : image, gabarit (*flavor*), réseau, keypair.
- Lancer une VM, suivre son démarrage, lui attribuer une floating IP.
- Se connecter en SSH à la VM, et comprendre pourquoi cela se fait depuis l'hôte.
- Faire la même chose dans Horizon.

---

## Étape 1. Charger l'environnement et faire l'inventaire

```bash
# [instance]
source ~/kolla/venv/bin/activate
source /etc/kolla/admin-openrc.sh

openstack image list            # les images disponibles (systèmes à démarrer)
openstack flavor list           # les gabarits : vCPU, RAM, disque
openstack network list          # les réseaux
openstack keypair list          # les clés SSH enregistrées
```

La keypair `mykey` a été créée au déploiement à partir de la clé publique `~/.ssh/id_ecdsa.pub` de
l'instance. La clé privée correspondante est sur l'instance : c'est pour cela qu'on se connecte
aux VM depuis l'instance.

## Étape 2. Lancer une VM

```bash
# [instance]
openstack server create --image cirros --flavor m1.tiny --key-name mykey \
  --network demo-net --wait tp02-vm1
openstack server show tp02-vm1 -c status -c addresses
```

`--wait` attend que la VM soit `ACTIVE`. Elle a une adresse en `10.0.0.x` sur `demo-net`, un réseau
privé : il n'est pas joignable directement depuis l'instance.

Le système de la VM met encore environ une minute à démarrer (émulation QEMU, voir TP 00). On suit
son démarrage dans sa console :

```bash
# [instance]
openstack console log show tp02-vm1 | tail -20
```

Attendez la ligne `login:`.

## Étape 3. Floating IP et connexion SSH

```bash
# [instance]
FIP=$(openstack floating ip create public1 -f value -c floating_ip_address)
openstack server add floating ip tp02-vm1 $FIP
echo $FIP
ping -c3 $FIP
ssh cirros@$FIP
```

À la première connexion, SSH demande de confirmer l'empreinte de la VM : répondez `yes`.

```bash
# [VM]
hostname
ip addr                  # la VM ne voit que son adresse privée 10.0.0.x
ip route
ping -c2 8.8.8.8         # accès à Internet
exit
```

## Étape 4. Une deuxième VM, et la communication entre VM

```bash
# [instance]
openstack server create --image cirros --flavor m1.tiny --key-name mykey \
  --network demo-net --wait tp02-vm2
openstack server show tp02-vm2 -f value -c addresses       # notez son IP 10.0.0.y
ssh cirros@$FIP
```

```bash
# [VM] (tp02-vm1)
ping -c2 <IP_PRIVEE_DE_TP02_VM2>
exit
```

## Étape 5. Horizon, par un tunnel SSH

Horizon est servi en HTTP, sans chiffrement : le mot de passe saisi dans le formulaire circule en clair.
Si le port 80 de l'instance était ouvert sur Internet, n'importe quel équipement sur le chemin pourrait
le lire. On le laisse donc fermé, et on passe par un tunnel SSH : le trafic d'Horizon voyage à
l'intérieur de la connexion SSH, chiffrée, et ne sort en clair qu'à l'intérieur de l'instance.

Ouvrez le tunnel depuis votre poste :

```bash
# [poste]
ssh -i ec2_key -L 8080:<IP_PRIVEE_INSTANCE>:80 ubuntu@<IP_PUBLIQUE>
```

`<IP_PRIVEE_INSTANCE>` est l'adresse de `enX0` notée au TP 00. Ouvrez ensuite <http://localhost:8080>.
Le formulaire demande seulement l'utilisateur (`admin`) et le mot de passe, qui s'obtient avec :

```bash
# [instance]
grep keystone_admin_password /etc/kolla/passwords.yml
```

Dans Horizon : *Projet → Compute → Instances*. Retrouvez vos deux VM, ouvrez la console de
`tp02-vm2`, puis lancez une troisième VM `tp02-vm3` depuis l'interface (image `cirros`, gabarit
`m1.tiny`, réseau `demo-net`, keypair `mykey`).

**Constater ce que protège le tunnel.** Déconnectez-vous d'Horizon, puis lancez deux captures sur
l'instance (2 minutes) : le trafic SSH qui arrive par Internet, et le trafic HTTP à la sortie du tunnel.

```bash
# [instance]
sudo timeout 120 tcpdump -i enX0 -w /tmp/tunnel.pcap 'tcp port 22' &
sudo timeout 120 tcpdump -i lo -w /tmp/horizon.pcap 'tcp port 80' &
```

Reconnectez-vous à Horizon par le tunnel, dans les 2 minutes, puis comptez les champs `password=` :

```bash
# [instance], après la connexion
sudo tcpdump -r /tmp/tunnel.pcap -A 2>/dev/null | grep -c 'password='      # 0 : chiffré
sudo tcpdump -r /tmp/horizon.pcap -A 2>/dev/null | grep -c 'password='     # 1 : en clair
sudo tcpdump -r /tmp/horizon.pcap -A 2>/dev/null | grep -oE 'POST /auth/login/ HTTP/1.1|username=admin' | sort -u
sudo rm -f /tmp/tunnel.pcap /tmp/horizon.pcap
```

La requête de connexion, identifiant et mot de passe compris, est lisible à la sortie du tunnel (`lo`),
mais invisible dans le trafic SSH (`enX0`). La solution durable est de chiffrer Horizon lui-même
(HTTPS, `kolla_enable_tls_external`, voir le README du lab).

## Étape 6. Se connecter depuis votre poste : les différentes façons

Depuis votre poste, deux obstacles :
- **la clé** : la clé privée de `mykey` est sur l'instance ;
- **le réseau** : la floating IP (10.0.2.x) n'existe que dans l'instance (voir TP 03 et 07).

Pour la clé, on enregistre dans OpenStack la clé publique de votre poste. Pour le réseau, il existe
plusieurs méthodes, résumées ici puis détaillées.

| Méthode | Principe | Coût | Testée sur le lab |
|---|---|---|---|
| A. Depuis l'instance | On se connecte à l'instance, puis à la VM avec `mykey` | 0 | Oui (étape 3) |
| B. `ProxyCommand` | SSH ouvre un canal vers la VM à travers l'instance | 0 | Oui |
| C. `ProxyJump` (`-J`) | Même principe, syntaxe courte | 0 | Oui |
| D. `~/.ssh/config` | B ou C enregistré une fois pour toutes : `ssh 10.0.2.x` suffit | 0 | Oui |
| E. Transfert d'agent (`-A`, *ForwardAgent*) | Votre clé reste sur le poste, l'instance l'utilise à distance pour joindre la VM | 0 | Oui |
| F. Tunnel de port (`-L`) | Un port local de votre poste est relié au port 22 de la VM | 0 | Oui |
| G. `sshuttle` | Tout le réseau 10.0.2.0/24 devient joignable depuis le poste, comme un VPN | 0 | Non : exige les droits root sur le poste |
| H. Redirection de port sur l'instance (DNAT) | Un port de l'instance (ex. 2201) renvoie vers la VM | 0 | Non : exige d'ouvrir un port dans le Security Group AWS (accord du tuteur) |
| I. IP publique dédiée (scénario 03) | Une Elastic IP est associée à la VM | **Payant** | Non : partie hôte testée sans AWS, voir TP 07 |

Préparation (commune à B–I) : enregistrer votre clé publique et créer une VM qui l'utilise.

```bash
# [poste] : si vous n'avez pas de clé : ssh-keygen -t ed25519
scp -i ec2_key ~/.ssh/id_ed25519.pub ubuntu@<IP_PUBLIQUE>:ma-cle.pub
```

```bash
# [instance]
openstack keypair create --public-key ~/ma-cle.pub tp02-cle
openstack server create --image cirros --flavor m1.tiny --key-name tp02-cle \
  --network demo-net --wait tp02-poste
FIP2=$(openstack floating ip create public1 -f value -c floating_ip_address)
openstack server add floating ip tp02-poste $FIP2
echo $FIP2
```

Attendez environ une minute le démarrage de la VM. Dans les commandes ci-dessous, `<FIP2>` est la
valeur affichée.

### B. `ProxyCommand`

```bash
# [poste]
ssh -i ~/.ssh/id_ed25519 -o ProxyCommand="ssh -i ec2_key -W %h:%p ubuntu@<IP_PUBLIQUE>" cirros@<FIP2>
```

`-i ~/.ssh/id_ed25519` est la clé de la VM ; `-i ec2_key`, dans `ProxyCommand`, celle de l'instance.
`-W %h:%p` demande à l'instance de relayer la connexion vers la VM.

### C. `ProxyJump` (`-J`)

`-J` n'accepte pas d'option `-i` pour l'instance : on met la clé de l'instance dans l'agent SSH
(un programme du poste qui garde les clés en mémoire).

```bash
# [poste]
eval "$(ssh-agent -s)"            # démarre un agent (inutile si votre poste en a déjà un)
ssh-add ec2_key
ssh -J ubuntu@<IP_PUBLIQUE> -i ~/.ssh/id_ed25519 cirros@<FIP2>
```

### D. Fichier `~/.ssh/config`

On décrit une fois l'instance et le rebond ; ensuite, `ssh <FIP2>` suffit.

```bash
# [poste] : ajouter à la fin de ~/.ssh/config (chemins absolus vers vos clés)
Host lab
    HostName <IP_PUBLIQUE>
    User ubuntu
    IdentityFile ~/chemin/vers/ec2_key

Host 10.0.2.*
    User cirros
    IdentityFile ~/.ssh/id_ed25519
    ProxyJump lab
```

```bash
# [poste]
ssh lab                 # l'instance
ssh <FIP2>              # la VM, par rebond automatique
```

### E. Transfert d'agent (`-A`, *ForwardAgent*)

La clé privée reste sur le poste ; l'instance demande à votre agent de signer la connexion à la VM.

```bash
# [poste]
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
ssh -A -i ec2_key ubuntu@<IP_PUBLIQUE>
```

```bash
# [instance] : session ouverte avec -A
ssh-add -l                        # votre clé du poste apparaît
ssh cirros@<FIP2>
```

Sans `-A`, `ssh-add -l` sur l'instance répond qu'il n'y a pas d'agent : la clé n'est pas transmise.

> Sécurité : pendant la session, toute personne root sur l'instance peut utiliser votre agent pour
> se connecter en votre nom partout où votre clé est acceptée. À réserver aux machines de
> confiance ; préférer `ProxyJump` (C, D), où l'instance ne voit jamais votre clé.

### F. Tunnel de port (`-L`)

```bash
# [poste] : session 1 : le tunnel (laisser ouverte)
ssh -i ec2_key -N -L 2222:<FIP2>:22 ubuntu@<IP_PUBLIQUE>
```

```bash
# [poste] : session 2
ssh -p 2222 -i ~/.ssh/id_ed25519 cirros@localhost
```

Le port 2222 de votre poste mène au port 22 de la VM. Le même principe ouvre Horizon (étape 5) ou
n'importe quel service web d'une VM. Si vous changez de VM derrière le même port local, SSH signalera un
changement d'empreinte : `ssh-keygen -R "[localhost]:2222"`.

### G. `sshuttle` (non testé : droits root sur le poste)

```bash
# [poste] : nécessite sshuttle installé et sudo sur le poste
sshuttle -r ubuntu@<IP_PUBLIQUE> --ssh-cmd "ssh -i ec2_key" 10.0.2.0/24
# dans un autre terminal :
ssh -i ~/.ssh/id_ed25519 cirros@<FIP2>
```

### H. Redirection de port sur l'instance (non testé : modification du Security Group AWS)

Principe : une règle DNAT sur l'instance envoie le port 2201 vers le port 22 de la VM. Cela exige
d'ouvrir le port 2201 dans le Security Group AWS (gratuit, mais à valider avec le tuteur). Ne pas
toucher au port 22 de l'instance. Ce montage n'a pas été testé sur le lab.

### I. IP publique dédiée (payant)

Scénario 03 : voir le TP 07 et [../aws/aws-setup.md §4](../aws/aws-setup.md).

## Étape 7. Nettoyage

```bash
# [instance]
openstack server delete --wait tp02-vm1 tp02-vm2 tp02-vm3 tp02-poste
openstack floating ip delete $FIP $FIP2
openstack keypair delete tp02-cle
rm ~/ma-cle.pub
openstack server list
```

## Questions

1. Quelles sont les quatre ressources indispensables pour lancer une VM ici ?
2. Pourquoi `ssh cirros@<FLOATING_IP>` fonctionne-t-il depuis l'instance mais pas depuis votre poste ?
   (deux raisons : l'une liée à la clé, l'autre au réseau) Comment l'étape 6 répond-elle à chacune ?
5. `ProxyJump` et transfert d'agent permettent tous deux de joindre la VM. Lequel préférer, et pourquoi ?
6. Horizon reste en HTTP. Pourquoi le tunnel protège-t-il quand même le mot de passe ? Qu'est-ce qu'il ne
   protège pas ?
3. La VM ne connaît que son IP privée. Qui fait la traduction entre floating IP et IP privée ?
4. Que se passe-t-il pour le disque de la VM quand on la supprime ?

## Validation

- [ ] Connexion SSH à `tp02-vm1` réussie, ping vers Internet et vers `tp02-vm2` réussis.
- [ ] VM créée depuis Horizon, par le tunnel SSH.
- [ ] Captures faites : `password=` absent du trafic SSH, présent à la sortie du tunnel.
- [ ] Connexion à `tp02-poste` depuis votre poste par au moins trois méthodes parmi B à F.
- [ ] Le risque du transfert d'agent (E) expliqué.
- [ ] Nettoyage fait (`openstack server list` ne montre plus de `tp02-…`).

## Sources

- Commandes du client `openstack` : <https://docs.openstack.org/python-openstackclient/latest/cli/command-list.html>
- Nova (calcul) : <https://docs.openstack.org/nova/2025.1/>
- Glance (images) : <https://docs.openstack.org/glance/2025.1/>
- Horizon : <https://docs.openstack.org/horizon/2025.1/>
- CirrOS : <https://github.com/cirros-dev/cirros>
- SSH : `ProxyCommand`, `ProxyJump` : <https://man.openbsd.org/ssh_config>
- SSH (options `-A`, `-J`, `-L`, `-W`) : <https://man.openbsd.org/ssh>
- Agent SSH : <https://man.openbsd.org/ssh-agent>
- sshuttle : <https://sshuttle.readthedocs.io/en/stable/>
- Toutes les sources du parcours : [sources.md](sources.md)
