# TP 11. DNS as a Service avec Designate

| | |
|---|---|
| Prérequis | TP 03 et TP 06 ; Designate déployé (scénario 04) |
| À la fin du TP | Vous savez publier des noms DNS pour vos VM, à la main ou automatiquement |

## Objectifs

- Créer une zone DNS et des enregistrements, les résoudre depuis l'hôte et depuis une VM.
- Faire publier automatiquement le nom d'une VM par Neutron quand elle reçoit une floating IP.
- Constater l'isolation des zones entre projets.

Sur ce lab, Designate s'appuie sur un serveur bind9 qui tourne sur l'instance et répond sur son
IP privée, port 53. Les zones (`lab.example.`, réservé aux exemples) ne sont pas publiées sur
Internet : on interroge directement ce serveur.

---

## Étape 0. Vérifier que Designate est déployé

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
openstack service list | grep dns
IPH=$(ip -o -4 route get 1.1.1.1 | grep -o 'src [0-9.]*' | cut -d' ' -f2)   # IP privée de l'instance
echo $IPH
```

Sinon, déployez le scénario 04 (voir TP 08, étape 0).

## Étape 1. Une zone et des enregistrements

```bash
# [instance]
openstack zone create --email admin@lab.example tp11.lab.example.     # le point final est obligatoire
openstack zone show tp11.lab.example. -c status                       # PENDING, puis ACTIVE
openstack recordset list tp11.lab.example.                            # NS et SOA créés automatiquement

openstack recordset create --type A --record 192.0.2.10 tp11.lab.example. www
openstack recordset create --type CNAME --record www.tp11.lab.example. tp11.lab.example. intranet
openstack recordset list tp11.lab.example. -c name -c type -c records -c status
```

Un enregistrement est d'abord `PENDING`, le temps que Designate le pousse vers bind9 (quelques
secondes), puis `ACTIVE`. Avant `ACTIVE`, `dig` ne trouve rien : relancez `recordset list` jusqu'à ce
que tout soit `ACTIVE`.

## Étape 2. Résoudre les noms

Depuis l'instance, avec `dig` :

```bash
# [instance]
dig +short @$IPH www.tp11.lab.example.
dig +short @$IPH intranet.tp11.lab.example.      # deux lignes : l'alias (www…), puis son adresse
dig @$IPH tp11.lab.example. NS +short
```

Depuis une VM, avec `nslookup` (CirrOS n'a pas `dig`) :

```bash
# [instance]
openstack server create --image cirros --flavor m1.tiny --key-name mykey \
  --network demo-net --wait tp11-vm-client
FIP0=$(openstack floating ip create public1 -f value -c floating_ip_address)
openstack server add floating ip tp11-vm-client $FIP0
ssh cirros@$FIP0 "nslookup www.tp11.lab.example. $IPH"        # attendre ~1 min le démarrage
```

La réponse donne `Address: 192.0.2.10`, suivie de `*** Can't find www.tp11.lab.example.: No answer` :
c'est la réponse à la question IPv6 (enregistrement AAAA), qui n'existe pas. C'est normal.

## Étape 3. Publication automatique par Neutron

Si un réseau a un domaine DNS, Nova donne à chaque port le nom de la VM (`dns_name`). Quand une
floating IP est associée à ce port, Neutron demande à Designate de publier `<vm>.<domaine>`.

```bash
# [instance]
openstack network create --dns-domain tp11.lab.example. tp11-net
openstack subnet create --network tp11-net --subnet-range 192.168.110.0/24 tp11-subnet
openstack router create tp11-rtr
openstack router set --external-gateway public1 tp11-rtr
openstack router add subnet tp11-rtr tp11-subnet

openstack server create --image cirros --flavor m1.tiny --key-name mykey --network tp11-net --wait tp11-vm-web
PORT=$(openstack port list --server tp11-vm-web -f value -c ID)
openstack port show $PORT -c dns_name -c dns_assignment       # dns_name = tp11-vm-web

FIP=$(openstack floating ip create public1 -f value -c floating_ip_address)
openstack server add floating ip tp11-vm-web $FIP
sleep 10
openstack recordset list tp11.lab.example. -c name -c type -c records
dig +short @$IPH tp11-vm-web.tp11.lab.example.                      # la floating IP de tp11-vm-web
```

Retirez la floating IP : l'enregistrement disparaît.

```bash
# [instance]
openstack server remove floating ip tp11-vm-web $FIP
sleep 10
dig +short @$IPH tp11-vm-web.tp11.lab.example.                      # plus de réponse
openstack server add floating ip tp11-vm-web $FIP                    # on la remet pour la suite
```

Autre méthode : nommer la floating IP elle-même, sans dépendre d'une VM.

```bash
# [instance]
FIP2=$(openstack floating ip create public1 --dns-name api --dns-domain tp11.lab.example. \
  -f value -c floating_ip_address)
sleep 10
dig +short @$IPH api.tp11.lab.example.
```

Observez enfin la zone inverse (adresse → nom) que Designate a créée tout seul, dans le projet
`service`, pour les floating IP :

```bash
# [instance]
openstack zone list --all-projects -c name -c project_id
```

## Étape 4. Isolation entre projets

```bash
# [instance]
openstack project create tp11-proj-autre
openstack user create --project tp11-proj-autre --password-prompt tp11-user
openstack role add --project tp11-proj-autre --user tp11-user member
cat > ~/tp11-openrc.sh <<EOF
for v in \$(env | grep -o '^OS_[A-Z_]*'); do unset \$v; done
export OS_AUTH_URL=$OS_AUTH_URL
export OS_IDENTITY_API_VERSION=3
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_PROJECT_NAME=tp11-proj-autre
export OS_USERNAME=tp11-user
read -rsp "Mot de passe de tp11-user : " OS_PASSWORD; echo; export OS_PASSWORD
EOF
source ~/tp11-openrc.sh
openstack zone list                                                     # vide
openstack zone create --email a@lab.example tp11.lab.example.           # refusé
openstack zone create --email a@lab.example equipe.tp11.lab.example.    # refusé
openstack zone create --email a@lab.example autre.lab.example.          # accepté
```

Relevez les deux messages d'erreur : `Zone already exists, owned by a different tenant` et
`Unable to create subzone in another tenants zone`.

## Étape 5. Nettoyage

```bash
# [instance]
source ~/tp11-openrc.sh
openstack zone delete autre.lab.example.

source /etc/kolla/admin-openrc.sh
openstack server delete --wait tp11-vm-web tp11-vm-client
openstack floating ip delete $FIP $FIP2 $FIP0
openstack router remove subnet tp11-rtr tp11-subnet
openstack router unset --external-gateway tp11-rtr
openstack router delete tp11-rtr
openstack network delete tp11-net
openstack zone delete tp11.lab.example.
openstack user delete tp11-user
openstack project delete tp11-proj-autre
rm ~/tp11-openrc.sh
```

## Questions

1. À quoi servent les enregistrements NS et SOA créés automatiquement avec la zone ?
2. Quelle différence entre un enregistrement A et un CNAME ? Dans quel cas choisir un CNAME ?
3. Décrivez la chaîne qui publie `tp11-vm-web.tp11.lab.example.` : quel service fait quoi, à quel moment ?
4. Pourquoi Designate refuse-t-il qu'un autre projet crée `equipe.tp11.lab.example.` ? Quel risque
   cela évite-t-il ?
5. Les zones de ce lab ne sont pas joignables depuis Internet. Que faudrait-il pour qu'un vrai domaine
   soit résolu par tout le monde ?

## Validation

- [ ] `www`, `intranet` et `tp11-vm-web` résolus par `dig` ; `www` résolu depuis une VM.
- [ ] Publication et suppression automatiques de `tp11-vm-web` observées ; `api` publié par la floating IP.
- [ ] Les deux refus de l'étape 4 relevés.
- [ ] Nettoyage fait.

## Sources

- Designate : <https://docs.openstack.org/designate/2025.1/>
- Designate dans Kolla-Ansible : <https://docs.openstack.org/kolla-ansible/2025.1/reference/networking/designate-guide.html>
- Neutron : intégration DNS avec Designate : <https://docs.openstack.org/neutron/2025.1/admin/config-dns-int-ext-serv.html>
- Toutes les sources du parcours : [sources.md](sources.md)
