# OpenStack All-in-One sur une instance cloud (Kolla-Ansible)

Ce dépôt déploie un lab OpenStack mono-nœud sur une instance qui n'a qu'une interface réseau (cas
typique : AWS EC2), et fournit un parcours de TP.

| Vous êtes | Commencez par |
|---|---|
| Stagiaire ou alternant | [tps/README.md](tps/README.md) : parcours de TP |
| Administrateur du lab | Ce document : déploiement, architecture, exploitation |

Ce document décrit OpenStack et le déploiement. Ce qui est propre à AWS (réseau VPC, types d'instance,
alternatives) est dans [aws/aws-setup.md](aws/aws-setup.md), les coûts dans [aws/finops.md](aws/finops.md).

---

## 1. Contenu du dépôt

```
openstack-lab-trainee/
├── README.md                  ce document
├── deploy.sh                  déploiement (prend un fichier de scénario en paramètre)
├── verify.sh                  test de bout en bout du déploiement (critère d'acceptation)
├── destroy.sh                 suppression du déploiement (--purge : remise à zéro de l'hôte)
├── scenarios/
│   ├── 01-aio-base.env        All-in-One de base
│   ├── 02-aio-cinder.env      + stockage bloc Cinder (LVM)
│   ├── 03-aio-public-fip.env  + floating IP joignables depuis Internet
│   └── 04-aio-complet.env     02 + Barbican + Designate + stockage objet S3 (Garage) et restic
├── tools/
│   ├── openstack-lab-net.sh   réseau de l'hôte (veth, NAT, IP publiées), lancé au boot par systemd
│   ├── openstack-lab-cinder-loop.sh   rattache le stockage Cinder (fichier loop) au boot
│   ├── lab-s3.sh              stockage objet S3 du lab (Garage) et restic statique (TP 10)
│   └── public-fip.sh          publication d'une floating IP via une IP secondaire (scénario 03)
├── tests/
│   └── test-public-fip.sh     test du scénario 03 côté hôte, sans ressource AWS (TP 07)
├── tps/                       parcours de TP : énoncés, conventions, grille de suivi, sources ;
│                              un dossier tpNN/ par TP (verifier-entree.sh, fichiers fournis)
├── VERSION                    version du dépôt
├── LICENSE                    licence des scripts (MIT)
├── LICENSE-CONTENU.md         licence des contenus pédagogiques (CC BY-SA 4.0)
├── NOTICE.md                  logiciels tiers utilisés
└── aws/
    ├── aws-setup.md           contraintes AWS et alternatives
    ├── finops.md              coûts, crédits CPU, bonnes pratiques
    ├── check-cpu-credits.sh   garantit le mode de crédits "standard" (aucun surcoût)
    ├── aws-public-fip.sh      partie AWS du scénario 03 (simulation par défaut)
    └── recover-network.sh     récupère une instance devenue injoignable (voir aws-setup.md §6)
```

---

## 2. Les scénarios

| Scénario | Contenu | Ressources AWS en plus |
|---|---|---|
| **01 (base)** | Keystone, Glance, Nova, Neutron, Placement, Horizon. Disques des VM éphémères. | Aucune |
| **02 (Cinder)** | 01 + volumes persistants (Cinder, LVM sur fichier loop) | Aucune (option : volume EBS dédié, payant) |
| **03 (floating IP publiques)** | 01 + accès à des VM depuis Internet | IP secondaires (gratuites) + Elastic IP (**payantes**, accord requis) |
| **04 (complet)** | 02 + Barbican (secrets, volumes chiffrés) + Designate (DNS, intégration Neutron) + stockage objet S3 (Garage) | Aucune (16 Go de RAM recommandés) |

Les scénarios sont cumulables : on peut déployer 01, puis relancer `deploy.sh` avec 02 (ou 04) pour
ajouter des services sans perdre les VM existantes.

---

## 3. Démarrage rapide

Prérequis : instance Ubuntu 24.04 neuve, ≥ 8 Go RAM (16 recommandés), ≥ 2 vCPU (4 recommandés),
≥ 40 Go de disque (60 recommandés : ~30 Go occupés en scénario 04), utilisateur avec `sudo` sans mot
de passe (`ubuntu` sur EC2), accès Internet.

```bash
# Depuis votre poste : vérifier qu'aucun frais de crédits CPU n'est possible (voir aws/finops.md)
./openstack-lab-trainee/aws/check-cpu-credits.sh <INSTANCE_ID>

# Copier le dépôt sur l'instance
scp -r -i ec2_key openstack-lab-trainee ubuntu@<IP_PUBLIQUE>:
ssh -i ec2_key ubuntu@<IP_PUBLIQUE>

# Sur l'instance (tmux conseillé : le déploiement est long)
tmux new -s deploy
./openstack-lab-trainee/deploy.sh openstack-lab-trainee/scenarios/01-aio-base.env
./openstack-lab-trainee/verify.sh
```

Pour suivre tous les TP ([tps/README.md](tps/README.md)), déployez plutôt le scénario 04 :
`./openstack-lab-trainee/deploy.sh openstack-lab-trainee/scenarios/04-aio-complet.env`.

`verify.sh` crée une VM de test, vérifie le réseau, et selon les services présents Cinder, Barbican,
le chiffrement des volumes et Designate, puis nettoie.
Il se termine par `Résultat : N réussis, 0 échoués` et renvoie un code d'erreur si un test échoue.

### Paramètres

Les paramètres se règlent dans le fichier de scénario, ou en variable d'environnement :

| Variable | Défaut | Rôle |
|---|---|---|
| `OPENSTACK_RELEASE` | `2025.1` | Branche Kolla-Ansible / version des images |
| `WORKDIR` | `~/kolla` | venv, inventaire, logs |
| `MGMT_IF` / `MGMT_IP` | détectés via la route par défaut | Interface/IP des API |
| `EXT_CIDR` / `EXT_GW` | `10.0.2.0/24` / `10.0.2.1` | Réseau externe Neutron |
| `EXT_POOL_START` / `EXT_POOL_END` | `10.0.2.100` / `10.0.2.200` | Plage de floating IP |
| `ENABLE_CINDER` | `no` | Active Cinder (backend LVM) |
| `CINDER_DEVICE` | vide | Disque vide dédié à Cinder ; vide = fichier loop |
| `CINDER_LOOP_SIZE_GB` | `20` | Taille du fichier loop |
| `ENABLE_HEAT` | `no` | Orchestration Heat (environ 1 Go de mémoire en plus, mesuré) ; le TP 14 l'active |
| `ENABLE_BARBICAN` | `no` | Gestion des secrets ; nécessaire pour chiffrer les volumes Cinder |
| `ENABLE_DESIGNATE` | `no` | DNS (backend bind9 sur l'hôte, port 53) |
| `ENABLE_LAB_BACKUP` | `no` | Stockage objet S3 (Garage, hors Kolla), restic et s3cmd, pour le TP 10 |
| `DESIGNATE_NS_RECORD` | `ns1.lab.example` | Serveur de noms des zones, sans point final (Kolla l'ajoute) |
| `NEUTRON_DNS_DOMAIN` | `lab.example.` | Domaine DNS des ports Neutron, avec point final ; jamais `openstacklocal.` (Neutron ignorerait alors le nom des ports) |

### En cas d'échec

Lire le log indiqué (`~/kolla/deploy-*.log`), corriger, puis relancer `deploy.sh` : il est idempotent.
Une relance sur un déploiement existant revérifie tous les services et prend plus longtemps que le premier
déploiement : ce n'est pas un blocage (suivre le log avec `tail -f ~/kolla/deploy-*.log`).

Pour tout supprimer :
```bash
./openstack-lab-trainee/destroy.sh            # conteneurs et données OpenStack
./openstack-lab-trainee/destroy.sh --purge    # + config, venv, réseau hôte, stockage Cinder ; puis sudo reboot
```

---

## 4. Ce que fait `deploy.sh`

1. **Pré-checks** : pas root, sudo OK, OS, RAM, CPU, détection interface/IP et KVM, garde-fou sur `CINDER_DEVICE` ;
   avec Barbican/Designate : alerte si moins de 16 Go de RAM, refus si le port 53 est déjà pris.
2. **Paquets système** (non interactif, dont `lvm2` et `dig`), swap de 8 Go, hostname dans `/etc/hosts` (requis par RabbitMQ).
3. **Réseau de l'hôte** : `tools/openstack-lab-net.sh`, installé comme service systemd `openstack-lab-net`.
4. **(Cinder)** fichier loop (service `openstack-lab-cinder-loop`) ou disque, puis groupe LVM `cinder-volumes`.
5. **Kolla-Ansible** dans un venv + `python-openstackclient`, `python-barbicanclient`, `python-designateclient`,
   versions figées par les *upper-constraints*.
6. `install-deps`, puis `kolla-genpwd`, qui complète les mots de passe manquants sans modifier les existants.
7. **Configuration** : `/etc/kolla/globals.yml` réécrit entièrement + fichiers dans `/etc/kolla/config/`.
8. `bootstrap-servers` → `prechecks` → `pull` → `deploy` → `post-deploy`.
9. **Ressources de démo** (`init-runonce`), seulement au premier déploiement.

---

## 5. Architecture réseau

### 5.1 Le fonctionnement standard d'OpenStack (Neutron)

Ce qui suit est vrai pour n'importe quel déploiement OpenStack avec ML2/Open vSwitch :

| Élément Neutron | Rôle |
|---|---|
| **Réseau tenant** (`demo-net`, 10.0.0.0/24, VXLAN) | Réseau privé des VM d'un projet, isolé des autres projets |
| **`br-int`** (pont OVS d'intégration) | Les VM y sont branchées ; OVS y applique l'isolation |
| **Routeur Neutron** (`demo-router`, namespace `qrouter-…`) | Relie le réseau tenant au réseau externe ; fait le NAT (SNAT en sortie, DNAT pour les floating IP) |
| **Réseau externe** (`public1`, flat, `physnet1`) | Réseau d'où viennent les floating IP ; Neutron suppose qu'il est raccordé à un vrai réseau |
| **`br-ex`** (pont OVS externe) | Relie le routeur au réseau externe, via l'interface `neutron_external_interface` |
| **Floating IP** | Adresse du réseau externe que le routeur traduit vers l'IP privée d'une VM |

Sur un serveur physique classique, une 2ᵉ carte réseau branchée sur un switch est donnée à `br-ex`, et les
floating IP sont de vraies adresses du LAN : Neutron répond lui-même aux requêtes ARP pour ces adresses.

### 5.2 L'adaptation pour une instance cloud à une seule interface

Le réseau d'un cloud comme AWS n'est pas un switch : il n'accepte que les adresses qu'il a lui-même
attribuées à l'interface de l'instance (détails dans [aws/aws-setup.md §2.3](aws/aws-setup.md)).
On crée donc un réseau externe interne à l'hôte, et l'hôte fait le pont par NAT :

```
                     Internet
                        │
              ┌─────────┴──────────┐  pare-feu du cloud (Security Group AWS)
              │  enX0 172.31.x.x   │  IP publique traduite par le cloud
              │                    │
   API OpenStack, Horizon :80      │  iptables MASQUERADE 10.0.2.0/24 -> enX0
              │                    │
              │  veth-ext 10.0.2.1/24   passerelle du réseau externe
              │      ║ paire veth (câble virtuel)
              │  veth-neutron ── br-ex (OVS) ── routeur Neutron ── br-int ── VM
              └────────────────────┘
   public1  : 10.0.2.0/24 (flat), floating IP de 10.0.2.100 à 10.0.2.200
   demo-net : 10.0.0.0/24 (VXLAN), routeur demo-router
```

| Réseau | Plage | Usage des adresses |
|---|---|---|
| `public1` (externe) | 10.0.2.0/24 | 10.0.2.1 : `veth-ext`, la passerelle sur l'hôte ; 10.0.2.100 à 10.0.2.200 : la réserve où Neutron puise les floating IP (101 adresses, `EXT_POOL_START` et `EXT_POOL_END`, §3) et les passerelles des routeurs ; le reste est inutilisé |
| `demo-net` (projet) | 10.0.0.0/24 | Adresses privées des VM, attribuées par DHCP |

Le chemin d'un paquet sortant d'une VM :

| Étape | Couche | Ce qui se passe |
|---|---|---|
| VM → `br-int` → routeur Neutron | OpenStack | Le routeur traduit 10.0.0.x en floating IP 10.0.2.x |
| Routeur → `br-ex` → `veth-neutron` | OpenStack | Fonctionnement standard ; `veth-neutron` joue le rôle de la « 2ᵉ carte réseau » |
| `veth-ext` → `enX0` | Hôte Linux | `veth-ext` (10.0.2.1) est la passerelle ; iptables remplace la source par l'IP de l'interface |
| `enX0` → Internet | Cloud (AWS) | Le paquet porte l'IP et la MAC de l'interface : le cloud l'accepte et le traduit vers l'IP publique |

Conséquences :
- **côté OpenStack, rien n'est modifié** : Neutron, `br-ex` et les floating IP fonctionnent comme d'habitude ;
- **l'adaptation est sur l'hôte** (veth + NAT, service `openstack-lab-net`) ;
- les floating IP ne sont joignables que depuis l'hôte (ou via tunnel SSH). Pour les rendre publiques :
  scénario 03, détaillé dans [aws/aws-setup.md §4](aws/aws-setup.md).

Pas de VIP non plus : HAProxy/keepalived/ProxySQL sont désactivés et `kolla_internal_vip_address` = IP de l'hôte.

---

## 6. Services déployés

| Service | Rôle | Conteneur(s) | Port(s) sur l'IP de l'hôte |
|---|---|---|---|
| Keystone | Identité | `keystone`, `keystone_fernet`, `keystone_ssh` | 5000 |
| Glance | Images | `glance_api` | 9292 |
| Nova | Calcul (libvirt) | `nova_api`, `nova_scheduler`, `nova_conductor`, `nova_novncproxy`, `nova_compute`, `nova_libvirt`, `nova_ssh` | 8774, 6080 (console VNC) |
| Placement | Inventaire des ressources | `placement_api` | 8780 |
| Neutron (ML2/OVS) | Réseau | `neutron_server`, `neutron_openvswitch_agent`, `neutron_l3_agent`, `neutron_dhcp_agent`, `neutron_metadata_agent` | 9696 |
| Open vSwitch | Commutateur virtuel | `openvswitch_db`, `openvswitch_vswitchd` | aucun |
| Horizon | Dashboard web | `horizon` | 80 |
| Cinder *(scénarios 02, 04)* | Stockage bloc | `cinder_api`, `cinder_scheduler`, `cinder_volume`, `tgtd`, `iscsid` | 8776 |
| Barbican *(scénario 04)* | Secrets, clés des volumes chiffrés | `barbican_api`, `barbican_worker`, `barbican_keystone_listener` | 9311 |
| Designate *(scénario 04)* | DNS as a Service | `designate_api`, `designate_central`, `designate_worker`, `designate_producer`, `designate_mdns`, `designate_backend_bind9` | 9001 (API), 53 (DNS, bind9), 5354 (mdns), 953 (rndc) |
| Stockage objet du lab *(scénario 04, hors Kolla)* | S3 pour les sauvegardes (TP 10) | `lab-s3` (Garage v2.4.1), données dans `/srv/lab-s3` | 3900 (S3), 3901 et 3903 sur 127.0.0.1 |
| MariaDB (Galera mono-nœud) | Base de données | `mariadb` | 3306 |
| RabbitMQ | Bus de messages | `rabbitmq` | 5672 |
| Memcached | Cache | `memcached` | 11211 |
| Fluentd, cron, kolla_toolbox | Logs, rotation, outils | `fluentd`, `cron`, `kolla_toolbox` | aucun |

Non déployés :
- Heat (orchestration) : désactivé pour économiser la mémoire ; le TP 14 l'ajoute (`ENABLE_HEAT=yes`
  dans le scénario 04), puis le retire ;
- Barbican et Designate : seulement dans le scénario 04 ;
- **Swift (stockage objet) : n'existe plus dans Kolla-Ansible 2025.1** (aucun rôle ni variable `enable_swift`).
  L'alternative Kolla, `ceph-rgw` (API compatible Swift), exige un cluster Ceph externe. Pour le TP 10,
  le lab fournit à la place un serveur S3 léger (Garage), hors Kolla ;
- Cinder backup : nécessiterait Swift, Ceph ou NFS ;
- HAProxy, keepalived, ProxySQL : inutiles sur un seul nœud (voir §5.2).

### Fichiers de configuration

| Fichier | Contenu |
|---|---|
| `/etc/kolla/globals.yml` | Configuration principale (généré par `deploy.sh`) |
| `/etc/kolla/passwords.yml` | Tous les secrets (ne jamais committer) |
| `/etc/kolla/config/galera.cnf` | `innodb_buffer_pool_size = 1G` |
| `/etc/kolla/config/nova/nova-compute.conf` | `resume_guests_state_on_host_boot`, et en QEMU `virt_type`, `cpu_mode` |
| `/etc/kolla/<service>/` | Config rendue de chaque service (écrasée à chaque déploiement : ne pas éditer) |
| `/etc/kolla/admin-openrc.sh`, `/etc/kolla/clouds.yaml` | Identifiants CLI admin |
| `/etc/openstack-lab/network.env` | Paramètres du réseau hôte (lus au boot) |
| `/etc/openstack-lab/public-fip.map` | Floating IP publiées (scénario 03) |
| `~/kolla/all-in-one` | Inventaire Ansible |
| `/var/log/kolla/<service>/` | Logs des services |

Pour modifier une option : éditer `globals.yml` ou ajouter un fichier dans `/etc/kolla/config/<service>/`, puis
`kolla-ansible reconfigure -i ~/kolla/all-in-one --tags <service>`.
Attention : `deploy.sh` réécrit `globals.yml` ; une modification durable se fait dans le script ou le scénario.

---

## 7. Accès

| Accès | Comment |
|---|---|
| SSH hôte | `ssh -i ec2_key ubuntu@<IP_PUBLIQUE>` |
| Horizon | `http://<IP_PUBLIQUE>/` si le Security Group ouvre le port 80 à votre IP, sinon par tunnel SSH (§9). La console des VM passe toujours par le tunnel (port 6080, §9). Formulaire : utilisateur `admin` et son mot de passe (ni domaine ni région à choisir) |
| Mot de passe admin | `grep keystone_admin_password /etc/kolla/passwords.yml` |
| CLI | `source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh`, puis `openstack ...` (à refaire dans chaque nouvelle session SSH) |
| VM depuis l'instance | Clé `mykey` (= `~/.ssh/id_ecdsa` de l'instance) : `ssh cirros@<FLOATING_IP>` |
| VM depuis votre poste | Créer la VM avec votre keypair, puis rebondir par l'instance (gratuit) : voir « Se connecter à une VM depuis son poste » ci-dessous |

Ressources créées au premier déploiement : image `cirros`, flavors `m1.tiny` → `m1.xlarge`, réseaux `public1`
et `demo-net`, routeur `demo-router`, keypair `mykey`, règles ICMP + SSH dans le groupe `default`.

### Exemples
```bash
# Sur l'instance. Charger le client OpenStack et les identifiants admin
# (à refaire dans chaque nouvelle session SSH, sinon : "Command 'openstack' not found")
source ~/kolla/venv/bin/activate
source /etc/kolla/admin-openrc.sh

# Lancer une VM et la rendre joignable depuis l'hôte
openstack server create --image cirros --flavor m1.tiny --key-name mykey --network demo-net --wait vm1
FIP=$(openstack floating ip create public1 -f value -c floating_ip_address)
openstack server add floating ip vm1 $FIP
ssh cirros@$FIP

# Scénario 02 : ajouter un disque persistant
openstack volume create --size 1 vol1
openstack server add volume vm1 vol1        # visible dans la VM en /dev/vdb
```

### Se connecter à une VM depuis son poste

La clé privée de `mykey` est sur l'instance et la floating IP n'existe que dans l'instance. Il faut
donc créer la VM avec sa propre keypair et rebondir par l'instance. Les méthodes possibles (ProxyJump,
ProxyCommand, `~/.ssh/config`, transfert d'agent, tunnel de port…) sont décrites et testées dans le
[TP 02, étape 6](tps/tp02-instances-ssh.md). La connexion directe depuis Internet passe par le
scénario 03 ([aws/aws-setup.md §4](aws/aws-setup.md)).

---

## 8. Choix techniques

| Choix | Pourquoi |
|---|---|
| Kolla-Ansible `stable/2025.1` + upper-constraints | Versions figées : déploiement reproductible |
| `set -Eeuo pipefail` + trap affichant la ligne en erreur | Arrêt à la première erreur, avec le log |
| Un script + des fichiers de scénario | Une seule logique à maintenir ; les variantes ne diffèrent que par leurs paramètres |
| `enable_loadbalancer: "no"` (+ haproxy/keepalived/proxysql à `no`) | Depuis 2024.2 c'est cette variable qui désactive le load balancer. Sinon ProxySQL prend le port 3306 et MariaDB ne démarre pas |
| Paire veth persistante + NAT | Une seule interface réseau (voir §5) |
| Interface et IP détectées via `ip route` | Fonctionne quel que soit le nom de l'interface |
| `globals.yml` réécrit à chaque exécution | Pas de doublons ; le scénario fait foi |
| Détection de `/dev/kvm`, sinon `qemu` + `cpu_mode=none` | Instances sans virtualisation matérielle |
| InnoDB limité à 1 Go | Par défaut MariaDB réserve ~40 % de la RAM |
| `resume_guests_state_on_host_boot = true` | Les VM redémarrent après un reboot de l'hôte |
| Cinder sur fichier loop par défaut | Aucun disque supplémentaire à acheter |
| Refus d'utiliser un `CINDER_DEVICE` contenant des données | Évite d'effacer un disque par erreur |
| `destroy.sh` supprime les volumes Docker oubliés par `kolla-ansible destroy` | Un redéploiement repart réellement de zéro |
| `destroy.sh` arrête les VM avant `kolla-ansible destroy` | `destroy` refuse de s'exécuter tant que des processus qemu tournent |
| `kolla-genpwd` à chaque exécution | Il ne remplit que les mots de passe vides : les services ajoutés ont leurs secrets, les existants ne changent pas |

---

## 9. Sécurité

1. **Horizon est en HTTP clair** : si le pare-feu du cloud ouvre le port 80 à tous (`0.0.0.0/0`), le mot de
   passe admin circule en clair sur Internet. Deux options :
   - **limiter le port 80 du Security Group à votre IP** (source `<VOTRE_IP>/32`) ;
   - **ou fermer le port 80 et passer par un tunnel SSH** :
     ```bash
     ssh -i ec2_key -N -L 8080:<IP_PRIVEE>:80 -L 6080:<IP_PRIVEE>:6080 ubuntu@<IP_PUBLIQUE>
     ```
     dans un terminal dédié (`-N` : pas de shell ; `Ctrl+C` ferme le tunnel), puis ouvrir
     `http://localhost:8080`. La redirection du port 6080 sert à la console des VM dans
     Horizon : elle n'est jamais ouverte dans le Security Group, même quand le port 80 l'est.
   → À terme, activer TLS : `kolla_enable_tls_external: "yes"` + certificat (`kolla-ansible certificates` pour un lab).
2. Les API (5000, 8774, 9696…) ne doivent pas être ouvertes dans le pare-feu du cloud.
3. `passwords.yml` contient tous les secrets : sauvegarder hors de l'instance, ne pas committer.
4. Clés SSH et identifiants AWS : jamais en clair dans un chat, un mail ou un dépôt Git
   (le `.gitignore` du dépôt exclut les clés et les secrets générés).

---

## 10. Limites et améliorations possibles

Limites liées à l'infrastructure (performances QEMU, floating IP publiques, stockage) :
voir [aws/aws-setup.md](aws/aws-setup.md). Coûts : [aws/finops.md](aws/finops.md).

Limites et pistes côté OpenStack :
- **Mono-nœud, sans haute disponibilité** : tout s'arrête avec l'instance. Étape suivante : un inventaire
  `multinode` (contrôleur + compute) sur plusieurs instances.
- **RAM** : ~7 Go utilisés à vide sur 16 ; peu de marge pour les VM.
- Supervision (`enable_prometheus`, `enable_grafana`) et logs centralisés (`enable_central_logging`) si ≥ 32 Go.
- Sauvegarde de MariaDB : `enable_mariabackup: "yes"`, puis `kolla-ansible mariadb_backup`.
- Images plus utiles (image cloud Ubuntu) et quotas adaptés.
- Mise à jour : changer `OPENSTACK_RELEASE` et suivre `kolla-ansible upgrade` (une version à la fois).
- Déploiement automatisé à la création de l'instance (*user-data* cloud-init, Terraform).

---

## 11. Dépannage

| Symptôme | Piste |
|---|---|
| `Timeout when waiting for search string MariaDB` | `sudo ss -ltnp \| grep 3306` : ProxySQL occupe le port ? Vérifier `enable_loadbalancer: "no"` |
| Un `fatal:` dans le log mais le déploiement continue | Normal : certaines sondes Kolla sont en `ignore_errors` ; seul le `PLAY RECAP` (`failed=0`) compte |
| Conteneur en redémarrage | `sudo docker ps -a`, `sudo docker logs <nom>`, `sudo ls /var/log/kolla/<service>/` (dossier réservé à root) |
| Arrêter / relancer un service | Chaque conteneur est piloté par l'unité systemd `kolla-<conteneur>-container.service` (`Restart=always`) : `sudo systemctl stop\|start\|restart kolla-<conteneur>-container.service`. Un `docker stop` est annulé par systemd |
| `Command 'openstack' not found` | Charger l'environnement dans la session : `source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh`. Ne pas installer le client `snap`/`apt` d'Ubuntu (version trop ancienne) |
| `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!` en SSH vers une VM | La floating IP a été réutilisée par une nouvelle VM : `ssh-keygen -R <FLOATING_IP>` |
| `Permission denied (publickey)` en SSH vers une VM | La VM a été créée avec `mykey`, dont la clé privée est sur l'instance : se connecter depuis l'instance, ou recréer la VM avec votre keypair (§7, « Se connecter à une VM depuis son poste ») |
| SSH vers une VM qui ne répond pas juste après sa création | Le système démarre en ~1 min (émulation QEMU) : suivre `openstack console log show <vm>` jusqu'à `login:` |
| VM en ERROR | `openstack server show <vm> -c fault`, `/var/log/kolla/nova/nova-compute.log` |
| Floating IP injoignable | `ip a show veth-ext`, `systemctl status openstack-lab-net`, `sudo iptables -t nat -S POSTROUTING`, security group OpenStack de la VM (`openstack security group rule list default`) |
| Volume Cinder en `error` | `sudo vgs cinder-volumes`, `systemctl status openstack-lab-cinder-loop`, `/var/log/kolla/cinder/cinder-volume.log` |
| `kolla-ansible destroy` échoue : « Some qemu processes were detected » | Des VM tournent encore : `destroy.sh` les arrête (`virsh destroy`) avant de lancer `destroy`. En manuel : `sudo docker exec nova_libvirt virsh list`, puis `virsh destroy <nom>` |
| Horizon : erreur 500 sur la page de connexion | `sudo grep OfflineGenerationError /var/log/kolla/horizon/horizon-error.log` : compression des fichiers statiques périmée (vu après l'ajout du scénario 04 sur un déploiement existant ; `deploy.sh` la répare désormais). À la main : `sudo docker exec horizon rm -f /var/lib/kolla/.settings.md5sum.txt && sudo systemctl restart kolla-horizon-container.service` |
| Plus d'espace disque | `sudo docker system df`, `df -h` |
