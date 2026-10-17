# OpenStack sur AWS EC2 : contraintes de l'infrastructure et alternatives

> Ce document traite uniquement de ce qui est propre à AWS : le réseau virtuel (VPC), les types
> d'instance, le stockage, les coûts. Le fonctionnement d'OpenStack lui-même est décrit dans le
> [README principal](../README.md).

**Règle du lab : aucune ressource payante ne doit être créée dans AWS sans l'accord explicite du
responsable du compte.** Les scripts qui touchent à AWS (`aws-public-fip.sh`) fonctionnent en mode
simulation par défaut et affichent le coût avant toute action.

---

## 1. L'environnement de référence

| Élément | Valeur | Remarque |
|---|---|---|
| Type d'instance | `t2.xlarge` (4 vCPU, 16 Go) | Virtualisation Xen (interface `enX0`) ; instance *burstable* |
| Région | `us-east-1` | |
| OS | Ubuntu 24.04 LTS | |
| Réseau | 1 ENI, IP privée 172.31.x.x/20, IP publique auto-attribuée, MTU 9001 | VPC par défaut |
| Disque | 1 volume EBS racine de 58 Go | |

---

## 2. Les contraintes AWS et leurs conséquences

### 2.1 Pas de virtualisation matérielle (instance non *metal*)

Une instance EC2 classique est elle-même une VM. Le processeur n'expose pas les extensions
Intel VT-x / AMD-V à l'intérieur : il n'y a pas de `/dev/kvm`.

- **Conséquence** : Nova ne peut pas utiliser KVM. Les VM OpenStack tournent en émulation QEMU (TCG),
  10 à 50 fois plus lente. Une CirrOS démarre en ~1 min ; une Ubuntu complète peut prendre 5 à 10 min.
- **Ce que fait `deploy.sh`** : il détecte l'absence de `/dev/kvm` et configure `virt_type = qemu`.

### 2.2 Instance *burstable* (familles t2, t3, t4g)

L'émulation QEMU sollicite le CPU en continu et épuise les crédits CPU des instances `t*` :
en mode standard (`t2`), le CPU est ensuite bridé (VM très lentes) ; en mode unlimited (`t3`/`t4g`),
le dépassement est facturé. Détails et surveillance : [finops.md §2](finops.md).

### 2.3 Le VPC n'est pas un réseau Ethernet

C'est la contrainte la plus importante, et la plus déroutante quand on connaît OpenStack.

| Règle AWS | Conséquence pour OpenStack |
|---|---|
| **AWS associe les adresses IP à l'ENI** (déclarées dans la console/API), pas à ce qui se trouve derrière. Une IP n'est routée vers l'instance que si elle est déclarée sur l'ENI. | Les floating IP que Neutron annonce par ARP sur `br-ex` sont ignorées : AWS ne connaît pas le bridge OVS. |
| **Pas de vrai niveau 2** : ni broadcast, ni ARP gratuit, ni apprentissage MAC. | Impossible d'« annoncer » une adresse ; une VIP keepalived ne fonctionne pas. |
| **Les MAC sont imposées** : le trafic émis avec une autre MAC que celle de l'ENI est ignoré. | Le routeur Neutron (qui a sa propre MAC) ne peut pas parler directement au VPC. |
| **Contrôle source/destination** activé par défaut : l'ENI rejette les paquets dont l'IP source ou destination n'est pas une des siennes. | Le trafic des VM (IP Neutron) serait jeté s'il sortait tel quel. |
| **L'IP publique n'est pas sur l'instance** : la passerelle Internet fait un NAT 1:1 entre l'IP publique et l'IP privée de l'ENI. | `ip a` ne montre que l'IP privée. Les services OpenStack écoutent sur l'IP privée. |
| **L'IP publique auto-attribuée change** à chaque arrêt/démarrage de l'instance (pas au reboot). | L'URL d'Horizon change. Pour une IP fixe, il faut une Elastic IP (payante). |
| **Security Group = pare-feu attaché à l'ENI**, appliqué par AWS avant que le paquet n'atteigne l'instance. | À ne pas confondre avec les security groups OpenStack, qui filtrent le trafic des VM à l'intérieur de l'hôte. Il faut ouvrir les deux. |
| **Une seule ENI** sur l'instance. | Pas de 2ᵉ carte pour `br-ex` (une interface donnée à `br-ex` ne doit pas porter d'IP, sinon on perd l'accès à l'instance). |

Ce que fait `deploy.sh` : le réseau externe Neutron est entièrement interne à l'hôte (paire veth),
et l'hôte fait du NAT vers l'ENI. Tout le trafic qui sort de l'instance porte l'IP et la MAC de l'ENI :
le VPC l'accepte. Le *source/dest check* peut rester activé.

Limite qui en découle : les floating IP ne sont joignables que depuis l'hôte, pas depuis Internet.

### 2.4 Stockage

Le seul disque est le volume EBS racine. Cinder (stockage bloc) a besoin d'un groupe de volumes LVM.

- **Scénario 02** : le groupe LVM est créé dans un fichier sur le disque racine (« loop »). Gratuit,
  mais la capacité est prise sur le disque racine et les performances sont modestes.
- **Alternative AWS** : attacher un 2ᵉ volume EBS dédié à Cinder (payant).

### 2.5 MTU

L'ENI a un MTU de 9001 (jumbo frames) dans le VPC, mais le trafic vers Internet est limité à 1500.
Aucun problème pour le lab : Neutron ne lit pas le MTU de l'ENI, il part de sa valeur par défaut
`global_physnet_mtu = 1500`. Constaté sur le lab : `public1` (flat) a un MTU de 1500 et `demo-net`
(VXLAN) de 1450 (1500 moins les 50 octets d'en-tête VXLAN) ; les VM reçoivent 1450 par DHCP.

---

## 3. Alternatives disponibles dans AWS

Les coûts indiqués sont des ordres de grandeur ; le détail est dans [finops.md](finops.md).

### 3.1 Avoir de vraies performances (KVM)

| Option | Principe | Coût indicatif |
|---|---|---|
| Rester en QEMU (actuel) | Suffisant pour CirrOS et la découverte d'OpenStack | Prix de l'instance actuelle |
| **Instance `*.metal` (ex. `c5.metal`, `m5.metal`) | Serveur physique entier : `/dev/kvm` disponible. `deploy.sh` passe automatiquement en `kvm`, sans modification. | ~4 à 5 USD/heure. À arrêter dès la fin du TP.** |
| Virtualisation imbriquée | Certaines familles d'instances récentes peuvent proposer la virtualisation imbriquée selon les régions : vérifier la documentation AWS du moment. | Variable |
| Instance non *burstable* (`m5.xlarge`, `m6i.xlarge`…) | Pas de KVM, mais pas de bridage CPU non plus | Comparable à la `t2.xlarge` |

### 3.2 Rendre les floating IP joignables depuis Internet

| Option | Principe | Coût AWS | Statut |
|---|---|---|---|
| Rebond SSH par l'instance (`ProxyJump`, `ProxyCommand`, `~/.ssh/config`) | SSH relaie la connexion vers la VM à travers l'instance ; la VM doit utiliser votre keypair | Aucun | Recommandé ; testé depuis un poste ([../tps/tp02-instances-ssh.md](../tps/tp02-instances-ssh.md), étape 6) |
| Transfert d'agent SSH (`ssh -A`) | Votre clé reste sur le poste, l'instance l'utilise à distance | Aucun | Testé ; à réserver aux hôtes de confiance (root sur l'instance peut utiliser votre agent) |
| Tunnel de port (`ssh -L`) | Un port local du poste mène au port d'une VM (SSH, web…) | Aucun | Testé |
| `sshuttle` | `sshuttle -r ubuntu@<IP_PUBLIQUE> 10.0.2.0/24` : votre poste route le réseau externe Neutron via SSH | Aucun | Non testé (nécessite les droits root sur le poste) |
| Redirection de ports sur l'hôte | DNAT d'un port de l'ENI (ex. 2201) vers `<floating_ip>:22` | Aucun | Non testé : exige d'ouvrir un port dans le Security Group ; un port par service |
| **IP secondaires + Elastic IP** (scénario 03) | Une IP privée secondaire est déclarée côté AWS sur l'ENI ; l'hôte la porte et fait un NAT 1:1 vers une floating IP ; une Elastic IP est associée à l'IP secondaire | IP secondaire : gratuite. Elastic IP : ~0,005 USD/h (~3,6 USD/mois) chacune | Partie hôte vérifiée (`tests/test-public-fip.sh`, 28/28) ; partie AWS non exécutée (voir §4) |
| 2ᵉ ENI dédiée à `br-ex` | Même principe, sur une interface séparée | Elastic IP payantes, ENI gratuite | Non implémenté |
| *Prefix delegation* (/28 sur l'ENI) | Attribue 16 IP privées d'un coup à l'ENI | Chaque IP publique reste payante | Non implémenté |
| IPv6 | Le VPC peut fournir des IPv6 publiques sans surcoût ; Neutron route nativement l'IPv6 | Aucun (hors configuration du VPC) | Non implémenté ; nécessite un VPC et un sous-réseau avec IPv6 |

Le nombre d'IP par ENI est limité selon le type d'instance (15 pour une `t2.xlarge`, IP primaire comprise).

### 3.3 Stockage pour Cinder

| Option | Coût | Statut |
|---|---|---|
| Fichier loop sur le disque racine (scénario 02) | Aucun | Vérifié |
| Volume EBS gp3 dédié (`CINDER_DEVICE=/dev/xvdf` ou `/dev/nvme1n1`) | ~0,08 USD/Go-mois | Script prêt (garde-fou anti-écrasement), non testé sur un vrai volume EBS |

### 3.4 Accès à Horizon

| Option | Principe | Coût |
|---|---|---|
| Security Group limité à votre IP | Source `<VOTRE_IP>/32` sur le port 80 | Aucun |
| Tunnel SSH | `ssh -i ec2_key -L 8080:<IP_PRIVEE>:80 ubuntu@<IP_PUBLIQUE>` puis `http://localhost:8080` ; le port 80 peut rester fermé | Aucun |
| AWS Systems Manager (Session Manager) | Redirection de port sans ouvrir le port 22 ; nécessite l'agent SSM et un rôle IAM | Aucun pour l'usage de base |
| Load balancer AWS (ALB) + certificat ACM | HTTPS public propre | Payant (~16 USD/mois minimum) |

---

## 4. Scénario 03 : floating IP publiques, pas à pas

> Prérequis : OpenStack déployé (scénario 01 ou 02), AWS CLI configurée sur votre poste, et
> **accord explicite** pour créer une Elastic IP payante.

```
Internet ──> Elastic IP ──(NAT AWS)──> IP secondaire de l'ENI (ex. 172.31.27.140)
         ──(DNAT par l'hôte)──> floating IP (ex. 10.0.2.150)
         ──(routeur Neutron)──> IP privée de la VM (ex. 10.0.0.12)
```

1. **Simuler** la partie AWS (aucune modification) :
   ```bash
   ./aws/aws-public-fip.sh create <INSTANCE_ID>
   ```
   Le script affiche l'ENI, les commandes qu'il va lancer et le coût.
2. **Exécuter** après accord :
   ```bash
   ./aws/aws-public-fip.sh create <INSTANCE_ID> --apply
   ```
   Il affiche l'IP privée secondaire et l'Elastic IP créées.
3. **Créer une VM avec VOTRE clé SSH.** La keypair de démo `mykey` a sa clé privée sur l'instance
   (`~/.ssh/id_ecdsa`) : depuis votre poste, une VM créée avec `mykey` refuserait la connexion
   (`Permission denied (publickey)`). On enregistre donc votre clé publique dans OpenStack ; la clé
   privée ne quitte pas votre poste.
   ```bash
   # Sur votre poste : copier votre clé publique sur l'instance
   scp -i ec2_key ~/.ssh/id_ed25519.pub ubuntu@<IP_PUBLIQUE>:ma-cle.pub

   # Sur l'instance
   source ~/kolla/venv/bin/activate
   source /etc/kolla/admin-openrc.sh
   openstack keypair create --public-key ~/ma-cle.pub ma-cle
   openstack server create --image cirros --flavor m1.tiny --key-name ma-cle --network demo-net --wait vm-pub
   openstack floating ip create public1 --floating-ip-address 10.0.2.150
   openstack server add floating ip vm-pub 10.0.2.150
   ```
   Pas de clé sur votre poste ? `ssh-keygen -t ed25519` en crée une.
4. **Sur l'instance**, publier la floating IP. Un retour arrière automatique est programmé pendant
   l'opération : si l'hôte n'émet plus avec son IP principale, la publication est annulée.
   ```bash
   sudo ~/openstack-lab-trainee/tools/public-fip.sh add <IP_SECONDAIRE> 10.0.2.150
   ```
5. **Ouvrir les ports** dans le Security Group AWS (ex. 22 depuis votre IP) et dans le security
   group OpenStack de la VM (le groupe `default` autorise déjà SSH et ICMP après `init-runonce`).
6. Tester depuis votre poste, avec la clé privée correspondant à `ma-cle` :
   `ssh -i ~/.ssh/id_ed25519 cirros@<ELASTIC_IP>`.
7. **Nettoyer** (arrête la facturation) :
   ```bash
   sudo ~/openstack-lab-trainee/tools/public-fip.sh del <IP_SECONDAIRE>     # sur l'instance
   ./aws/aws-public-fip.sh delete <ALLOCATION_ID> --apply                # sur votre poste
   ./aws/aws-public-fip.sh list                                          # vérifier qu'il ne reste rien
   # sur l'instance : supprimer la VM, sa floating IP et la keypair
   openstack server delete --wait vm-pub && openstack floating ip delete 10.0.2.150 && openstack keypair delete ma-cle
   ```

Pourquoi ce montage respecte les règles AWS : l'IP secondaire est déclarée sur l'ENI (AWS la route
vers l'instance), et c'est l'hôte qui la porte, avec la MAC de l'ENI. Neutron n'a pas à être modifié :
pour lui, la floating IP reste une adresse de son réseau externe.

---

## 5. Coûts

Coûts par scénario, crédits CPU et bonnes pratiques : voir [finops.md](finops.md).

---

## 6. Incident : instance injoignable après publication d'une IP secondaire

Constaté le 17/10/2026 pendant les tests du scénario 03 (version précédente de `openstack-lab-net.sh`).

| | |
|---|---|
| Symptôme | Plus aucun accès SSH, y compris après un reboot |
| Cause | Pour qu'elle survive aux reconfigurations, l'IP secondaire avait été déclarée comme adresse statique dans la configuration systemd-networkd de l'interface (drop-in). networkd vérifie qu'une adresse statique n'est pas déjà utilisée (détection de conflit ARP) ; or le VPC répond lui-même aux requêtes ARP. networkd a conclu à un conflit et mis l'interface en échec : **plus de DHCP, plus aucune adresse** (tableau des routes vide dans la console au démarrage). Le fichier étant dans `/etc`, la panne revenait à chaque démarrage. |
| Correctif | On ne touche plus à la configuration réseau de l'interface d'administration. Les IP secondaires sont ajoutées avec `ip addr`, en /32 et dépréciées (jamais utilisées comme source). Un hook networkd-dispatcher les remet si networkd reconfigure l'interface. `public-fip.sh` programme en plus un retour arrière automatique (120 s, indépendant de la session SSH), annulé seulement si l'hôte émet toujours avec son IP principale. |
| Diagnostic sans SSH | `aws ec2 get-console-output --instance-id <ID> --output text` : tableau `ci-info` de cloud-init (adresses, routes) et journal de `recover-network.sh` (lignes `openstack-lab-recover:`). |
| Leçon | Ne jamais modifier le réseau de l'interface par laquelle on administre une instance sans retour arrière automatique. Sur une instance Xen (`t2`), la console série EC2 n'existe pas : une erreur réseau se paie par une intervention AWS. |

### Procédure de récupération (instance injoignable)

Toutes ces étapes modifient l'instance : **accord du responsable du compte requis**.

1. **Méthode gratuite (recommandée)** : arrêter l'instance, lui donner un *user-data* qui supprime la
   configuration fautive au démarrage, puis la redémarrer (méthode documentée par AWS pour récupérer
   un accès perdu ; l'instance doit être arrêtée). Le *user-data* ne s'exécute qu'une fois : il peut
   être retiré au prochain arrêt planifié.
   Le script exécuté au démarrage :
   ```sh
   rm -f /etc/systemd/network/*.network.d/openstack-lab-fip.conf   # après avoir retiré ses IP
   : > /etc/openstack-lab/public-fip.map
   networkctl reload && networkctl reconfigure <interface>        # "reload" seul ne relance pas une interface en échec
   ```
   C'est ce que fait `aws/recover-network.sh <INSTANCE_ID> --apply`.
   L'IP publique auto-attribuée change au redémarrage. Aucun coût, hors temps d'arrêt.
2. **Méthode avec instance de secours** (payante, quelques centimes) : arrêter l'instance, détacher son
   volume racine, l'attacher à une petite instance de secours, corriger les fichiers, le rattacher.
3. La console série EC2 n'est pas disponible sur les instances Xen (`t2`) ; elle l'est sur les
   instances Nitro (`t3`, `m5`…), ce qui est un argument pour ces familles.
