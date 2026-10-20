# Sources et références

> Tous les liens ont été vérifiés le 17/10/2026 (ils répondaient). Les versions citées (`2025.1`)
> correspondent au déploiement du lab ; pour une autre version, remplacer `2025.1` dans l'adresse.

## Ce qui a réellement servi à construire le lab

Pour être transparent sur l'origine des informations :

| Source | Ce qu'on y a trouvé |
|---|---|
| Le code de Kolla-Ansible 2025.1 installé sur l'instance (`~/kolla/venv/share/kolla-ansible/ansible/`) : `group_vars/all.yml`, `roles/*/defaults/main.yml`, `roles/*/templates/` | Les variables réelles de la release : `enable_loadbalancer`, `enable_barbican`, `enable_designate`, `designate_backend`, `neutron_dns_integration`, l'absence de rôle Swift… Plus fiable que toute documentation, car c'est ce qui s'exécute |
| Les observations faites sur le lab | MTU des réseaux, comportement de `losetup` au boot, réponses du VPC, messages d'erreur exacts cités dans les TP |
| Les journaux de l'instance (`/var/log/kolla/`, `journalctl`, console AWS) | Le diagnostic de chaque incident (voir [../aws/aws-setup.md §6](../aws/aws-setup.md)) |

Les références ci-dessous sont les documentations officielles qui couvrent ces sujets : à consulter
pour comprendre, approfondir, ou vérifier une évolution de version.

---

## OpenStack et Kolla-Ansible

| Sujet | Référence |
|---|---|
| Kolla-Ansible 2025.1 (documentation) | <https://docs.openstack.org/kolla-ansible/2025.1/> |
| Installation rapide (*quickstart*) | <https://docs.openstack.org/kolla-ansible/2025.1/user/quickstart.html> |
| Configuration avancée (surcharges dans `/etc/kolla/config/`) | <https://docs.openstack.org/kolla-ansible/2025.1/admin/advanced-configuration.html> |
| Dépannage Kolla-Ansible | <https://docs.openstack.org/kolla-ansible/2025.1/user/troubleshooting.html> |
| Neutron dans Kolla-Ansible | <https://docs.openstack.org/kolla-ansible/2025.1/reference/networking/neutron.html> |
| Cinder dans Kolla-Ansible (LVM) | <https://docs.openstack.org/kolla-ansible/2025.1/reference/storage/cinder-guide.html> |
| Keystone dans Kolla-Ansible | <https://docs.openstack.org/kolla-ansible/2025.1/reference/shared-services/keystone-guide.html> |
| Designate dans Kolla-Ansible | <https://docs.openstack.org/kolla-ansible/2025.1/reference/networking/designate-guide.html> |
| Calendrier des versions OpenStack | <https://releases.openstack.org/> |
| Versions figées des dépendances (*upper-constraints*) | <https://releases.openstack.org/constraints/upper/2025.1> |
| Client `openstack` | <https://docs.openstack.org/python-openstackclient/latest/> |
| Liste des commandes du client | <https://docs.openstack.org/python-openstackclient/latest/cli/command-list.html> |
| Keystone (identité, projets, rôles) | <https://docs.openstack.org/keystone/2025.1/> |
| Keystone : identifiants d'application et règles d'accès (TP 06 bis) | <https://docs.openstack.org/keystone/2025.1/user/application_credentials.html> |
| Keystone : jetons Fernet (TP 06 bis) | <https://docs.openstack.org/keystone/2025.1/admin/fernet-token-faq.html> |
| keystonemiddleware : validation et cache des jetons dans les services (TP 06 bis) | <https://docs.openstack.org/keystonemiddleware/latest/middlewarearchitecture.html> |
| Identifiant de requête global, transmis d'un service à l'autre (TP 05 bis) | <https://specs.openstack.org/openstack/oslo-specs/specs/pike/global-req-id.html> |
| Nova : actions et événements d'une instance (TP 05 bis) | <https://docs.openstack.org/api-ref/compute/#servers-actions-servers-os-instance-actions> |
| Nova (calcul) | <https://docs.openstack.org/nova/2025.1/> |
| Nova : planificateur (*scheduler*) | <https://docs.openstack.org/nova/2025.1/admin/configuration/schedulers.html> |
| Neutron (réseau) | <https://docs.openstack.org/neutron/2025.1/> |
| Neutron : réseaux *self-service* avec Open vSwitch | <https://docs.openstack.org/neutron/2025.1/admin/deploy-ovs-selfservice.html> |
| Neutron : MTU | <https://docs.openstack.org/neutron/2025.1/admin/config-mtu.html> |
| Neutron : intégration DNS avec Designate | <https://docs.openstack.org/neutron/2025.1/admin/config-dns-int-ext-serv.html> |
| Cinder (stockage bloc) | <https://docs.openstack.org/cinder/2025.1/> |
| Cinder : chiffrement des volumes | <https://docs.openstack.org/cinder/2025.1/configuration/block-storage/volume-encryption.html> |
| Glance (images) | <https://docs.openstack.org/glance/2025.1/> |
| Horizon (interface web) | <https://docs.openstack.org/horizon/2025.1/> |
| Designate (DNS) | <https://docs.openstack.org/designate/2025.1/> |
| Barbican (secrets) | <https://docs.openstack.org/barbican/2025.1/> |
| Barbican : guide de l'API (secrets, conteneurs, ACL, *consumers*) | <https://docs.openstack.org/api-guide/key-manager/> |
| CirrOS (image de test) | <https://github.com/cirros-dev/cirros> |
| Open vSwitch | <https://docs.openvswitch.org/en/latest/> |

## Sécurité

| Sujet | Référence |
|---|---|
| Guide de sécurité OpenStack | <https://docs.openstack.org/security-guide/> |
| Avis de sécurité OpenStack (OSSA) | <https://security.openstack.org/> |
| Notes de sécurité OpenStack (OSSN) | <https://wiki.openstack.org/wiki/Security_Notes> |
| CIS Benchmark Ubuntu Linux | <https://www.cisecurity.org/benchmark/ubuntu_linux> |
| ANSSI (guides et recommandations de sécurité) | <https://cyber.gouv.fr/> |
| Security Groups AWS | <https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html> |

## AWS

| Sujet | Référence |
|---|---|
| Instances *burstable* et crédits CPU | <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances.html> |
| Adresses IP multiples (IP secondaires) | <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/MultipleIP.html> |
| Elastic IP | <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/elastic-ip-addresses-eip.html> |
| User-data EC2 | <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html> |
| Exécuter un user-data à chaque démarrage (récupération) | <https://repost.aws/knowledge-center/execute-user-data-ec2> |
| Tarifs EC2 à la demande | <https://aws.amazon.com/ec2/pricing/on-demand/> |
| Tarifs VPC (dont IPv4 publiques) | <https://aws.amazon.com/vpc/pricing/> |

## Système Linux

| Sujet | Référence |
|---|---|
| cloud-init | <https://cloudinit.readthedocs.io/en/latest/> |
| netplan | <https://netplan.readthedocs.io/en/stable/> |
| systemd-networkd : fichiers `.network` | <https://man7.org/linux/man-pages/man5/systemd.network.5.html> |
| `networkctl` | <https://man7.org/linux/man-pages/man1/networkctl.1.html> |
| networkd-dispatcher | <https://gitlab.com/craftyguy/networkd-dispatcher> |
| Unités systemd (dépendances, `RequiresMountsFor`) | <https://man7.org/linux/man-pages/man5/systemd.unit.5.html> |
| `ip address` (dont `preferred_lft`) | <https://man7.org/linux/man-pages/man8/ip-address.8.html> |
| `ip netns` (namespaces réseau) | <https://man7.org/linux/man-pages/man8/ip-netns.8.html> |
| `losetup` | <https://man7.org/linux/man-pages/man8/losetup.8.html> |
| `lvcreate` (LVM) | <https://man7.org/linux/man-pages/man8/lvcreate.8.html> |
| `tcpdump` | <https://www.tcpdump.org/manpages/tcpdump.1.html> |
| Configuration du client SSH (`ProxyCommand`, `ProxyJump`) | <https://man.openbsd.org/ssh_config> |
| Client SSH (options `-A`, `-J`, `-L`, `-W`) | <https://man.openbsd.org/ssh> |
| Agent SSH | <https://man.openbsd.org/ssh-agent> |
| sshuttle | <https://sshuttle.readthedocs.io/en/stable/> |
| Bash | <https://man7.org/linux/man-pages/man1/bash.1.html> |
| ShellCheck | <https://www.shellcheck.net/> |

## Sauvegarde et stockage objet (TP 10), autres hébergeurs

| Sujet | Référence |
|---|---|
| restic (sauvegardes chiffrées) | <https://restic.readthedocs.io/en/stable/> |
| restic : créer un dépôt (dont S3) | <https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html> |
| restic : copier entre dépôts | <https://restic.readthedocs.io/en/stable/045_working_with_repos.html> |
| restic : rétention et purge | <https://restic.readthedocs.io/en/stable/060_forget.html> |
| restic : versions et empreintes | <https://github.com/restic/restic/releases> |
| Garage (serveur S3) | <https://garagehq.deuxfleurs.fr/documentation/> |
| s3cmd | <https://s3tools.org/s3cmd> |
| AWS S3 : verrouillage d'objets | <https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html> |
| AWS S3 : cycle de vie | <https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html> |
| AWS S3 : tarifs | <https://aws.amazon.com/s3/pricing/> |
| OVHcloud Public Cloud | <https://www.ovhcloud.com/fr/public-cloud/> |
| Documentation OVHcloud | <https://help.ovhcloud.com/csm/fr-documentation> |

## Configuration des VM au démarrage (TP 12)

| Sujet | Référence |
|---|---|
| cloud-init | <https://cloudinit.readthedocs.io/en/latest/> |
| cloud-init : modules (users, mounts, fs_setup, bootcmd, runcmd…) | <https://cloudinit.readthedocs.io/en/latest/reference/modules.html> |
| cloud-init : phases du démarrage | <https://cloudinit.readthedocs.io/en/latest/explanation/boot.html> |
| cloud-init : données d'instance et gabarits Jinja | <https://cloudinit.readthedocs.io/en/latest/explanation/instancedata.html> |
| cloud-init : commandes (`status`, `query`, `schema`) | <https://cloudinit.readthedocs.io/en/latest/reference/cli.html> |
| Nova : service de métadonnées | <https://docs.openstack.org/nova/2025.1/user/metadata.html> |
| Images cloud de Debian | <https://cloud.debian.org/images/cloud/> |
| GTFOBins : `systemctl` et les échappements par `sudo` | <https://gtfobins.github.io/gtfobins/systemctl/> |
| NFS : `exports(5)` | <https://man7.org/linux/man-pages/man5/exports.5.html> |
| NFS : `nfs.conf(5)` | <https://man7.org/linux/man-pages/man5/nfs.conf.5.html> |
| systemd : automontage | <https://man7.org/linux/man-pages/man5/systemd.automount.5.html> |

## Architecture de déploiement (TP 13)

| Sujet | Référence |
|---|---|
| Neutron : routeurs, SNAT, security groups | <https://docs.openstack.org/neutron/2025.1/admin/intro-os-networking.html> |
| Client `openstack` : règles de security group | <https://docs.openstack.org/python-openstackclient/latest/cli/command-objects/security-group-rule.html> |
| Barbican : client en ligne de commande | <https://docs.openstack.org/python-barbicanclient/latest/cli/usage.html> |
| Netplan : routes et routage par source (`routing-policy`) | <https://netplan.readthedocs.io/en/stable/netplan-yaml/> |
| Squid : contrôle d'accès | <https://wiki.squid-cache.org/SquidFaq/SquidAcl> |
| chrony : `allow` et `bindaddress` | <https://chrony-project.org/doc/4.5/chrony.conf.html> |
| PostgreSQL 17 : `pg_hba.conf` | <https://www.postgresql.org/docs/17/auth-pg-hba-conf.html> |
| PostgreSQL 17 : authentification *peer* et correspondances `pg_ident.conf` (TP 13 bis) | <https://www.postgresql.org/docs/17/auth-peer.html>, <https://www.postgresql.org/docs/17/auth-username-maps.html> |
| PostgreSQL 17 : droits (`GRANT`, propriétaire) et journalisation (TP 13 bis) | <https://www.postgresql.org/docs/17/ddl-priv.html>, <https://www.postgresql.org/docs/17/runtime-config-logging.html> |
| systemd : durcissement d'un service | <https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html> |
| HAProxy 3.0 : configuration (`option forwardfor`) | <https://docs.haproxy.org/3.0/configuration.html> |
| GitHub : empreintes des clés d'hôte SSH | <https://docs.github.com/fr/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints> |
| AWS : adresses IP Elastic | <https://docs.aws.amazon.com/fr_fr/AWSEC2/latest/UserGuide/elastic-ip-addresses-eip.html> |
