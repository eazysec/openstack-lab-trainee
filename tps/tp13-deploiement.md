# TP 13. Déployer une architecture sécurisée sur OpenStack

| | |
|---|---|
| Prérequis | TP 00 à 12 ; scénario 04 déployé ; image `debian13` et gabarit `m1.1g` (TP 12) ; architecture lue : [tp13-architecture.md](tp13-architecture.md) |
| Durée | une journée, en plusieurs séances |
| À la fin du TP | Vous avez construit, vérifié et nettoyé une application web publiée et sa base de données, protégées comme en production, et vous savez prouver chaque règle de sécurité par un accès qui réussit et un accès qui échoue |

> **Instance ou VM ?** Comme dans tout le parcours, l'*instance* est la machine louée chez AWS, qui
> héberge OpenStack. Dans ce TP, elle joue aussi le rôle de **bastion** : seul point d'administration
> des VM, et seul point de sortie vers Internet (proxy et heure). Vue depuis les VM, elle a toujours
> l'adresse **10.0.2.1**.
>
> ```
> Votre poste ── ssh -i ec2_key ──► instance AWS = hôte OpenStack = bastion
>                                     ├─ enX0     adresse privée AWS (SSH, Internet)
>                                     └─ veth-ext 10.0.2.1 (côté OpenStack, réseau public1)
>                                                 │
>                          tp13-router-pub-demo ──┴── tp13-router-adm-demo
>                          FIP 10.0.2.150              │
>                                │                     │
>              carte pub (ens4) ─┴─ tp13-vm-web-haproxy-demo ─┬─ carte adm (ens3)
>                                     carte data (ens5)       │
>                                           │                 │
>                          carte data (ens4) ─ tp13-vm-bdd-demo ─ carte adm (ens3)
> ```

## Objectifs

- Construire une architecture réseau segmentée : publication (pub), administration (adm), données
  (data), avec deux routeurs sans SNAT et un réseau data sans routeur.
- Traduire des objectifs de sécurité en security groups au plus juste, en entrée **et en sortie**.
- Administrer les VM uniquement par rebond SSH à travers le bastion, sans jamais y déposer de clé.
- Contrôler toutes les sorties des VM par un proxy à liste blanche, et l'heure par le bastion.
- Protéger les secrets (Barbican, entrée standard) et les données (volume chiffré).
- Durcir un service applicatif avec systemd, le publier derrière HAProxy, puis sur Internet.
- Diagnostiquer avec `tcpdump` un piège réel de routage asymétrique, dans les deux sens.
- Prouver chaque règle par un test qui réussit et un test qui échoue ; nettoyer intégralement.

### Repères

Ce TP met en œuvre la conception décrite dans [tp13-architecture.md](tp13-architecture.md) : lisez
d'abord ses sections 1 à 4. Vous y trouverez la topologie, les principes de sécurité et les objectifs
O1 à O8 à atteindre.

**Mode de travail.** Les étapes de mise en place et de diagnostic sont guidées, commande par commande.
Les règles de sécurité (security groups, liste blanche du proxy, accès à la base) sont à **écrire par
vous** : l'énoncé donne le besoin, la syntaxe sur un exemple et le contrôle à obtenir. Un test qui
échoue est une information : lisez-le avant de modifier quoi que ce soit.

**Les bonnes pratiques mises en œuvre**, à repérer au fil des étapes :

| Pratique | Où dans le TP |
|---|---|
| Moindre privilège : chaque carte n'a que les flux dont elle a besoin | étape 5 |
| Filtrage en sortie : aucune règle de sortie par défaut | étape 5 |
| Point d'administration unique, sans clé sur le bastion | étapes 7 et 8 |
| Clés d'hôte vérifiées, jamais acceptées à l'aveugle | étape 8 |
| Sorties contrôlées et journalisées (proxy à liste blanche) | étapes 4 et 12 |
| Secrets jamais en argument, jamais dans un fichier en clair | étapes 9 et 10 |
| Données chiffrées au repos | étape 9 |
| Service durci (utilisateur dynamique, système en lecture seule, appels système filtrés) | étape 10 |
| Défense en profondeur : plusieurs barrières indépendantes | étapes 3, 5, 12 |
| Preuve du refus autant que de l'accès | étapes 8, 12, 14 |
| Traçabilité : nommage, étiquette `tp13`, nettoyage complet | étapes 1 à 16 |

**Fichiers fournis** dans le dépôt, dossier [tp13/](tp13/) : l'application (`appli/`), le user-data
des VM (`user-data-tp13.yaml`) et un modèle de configuration SSH (`ssh_config.exemple`).

**Avant chaque bloc `[instance]`**, chargez l'environnement OpenStack (comme aux TP précédents) :

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
```

---

## Étape 0. Vérifier la plateforme

```bash
# [instance]
cd ~/openstack-lab-trainee && ./verify.sh | tail -1        # "Résultat : 42 réussis, 0 échoués"
openstack image show debian13 -f value -c status           # active
openstack flavor show m1.1g -f value -c ram -c vcpus       # 1024, 1
openstack network list --tags tp13 -f value | wc -l        # 0 : aucun reste d'un essai précédent
```

Si l'image ou le gabarit manquent, refaites l'étape 0 du TP 12.

## Étape 1. Trois réseaux et leurs sous-réseaux

Seul le réseau pub annonce une passerelle : c'est la future route par défaut de la VM web. Le réseau
adm n'a pas de passerelle, mais pousse **une seule** route, vers le bastion. Le réseau data n'a ni
passerelle ni route.

```bash
# [instance]
openstack network create --tag tp13 tp13-network-pub-demo
openstack subnet create --tag tp13 --network tp13-network-pub-demo \
  --subnet-range 192.168.120.0/24 --gateway 192.168.120.1 \
  --allocation-pool start=192.168.120.2,end=192.168.120.254 tp13-subnet-pub-demo

openstack network create --tag tp13 tp13-network-adm-demo
openstack subnet create --tag tp13 --network tp13-network-adm-demo \
  --subnet-range 192.168.121.0/24 --gateway none \
  --allocation-pool start=192.168.121.2,end=192.168.121.254 \
  --host-route destination=10.0.2.1/32,gateway=192.168.121.1 tp13-subnet-adm-demo

openstack network create --tag tp13 tp13-network-data-demo
openstack subnet create --tag tp13 --network tp13-network-data-demo \
  --subnet-range 192.168.122.0/24 --gateway none \
  --allocation-pool start=192.168.122.2,end=192.168.122.254 tp13-subnet-data-demo
```

Le pool commence à .2 : l'adresse .1 du réseau adm est réservée au routeur adm (étape 2).

```bash
# [instance] contrôle
for s in pub adm data; do
  openstack subnet show tp13-subnet-$s-demo -f yaml -c cidr -c gateway_ip -c host_routes
done
```

Attendu : pub `gateway_ip: 192.168.120.1` ; adm `gateway_ip: null` et une route
`10.0.2.1/32` via `192.168.121.1` ; data `gateway_ip: null`, aucune route.

## Étape 2. Deux routeurs sans SNAT

Sans SNAT, un routeur ne cache pas les adresses de ses VM derrière la sienne : aucune VM ne peut sortir
vers Internet par lui. Le routeur pub ne servira qu'à la FIP ; le routeur adm, qu'à relier le bastion.

```bash
# [instance]
openstack router create --tag tp13 tp13-router-pub-demo
openstack router set --external-gateway public1 --disable-snat tp13-router-pub-demo
openstack router add subnet tp13-router-pub-demo tp13-subnet-pub-demo

openstack router create --tag tp13 tp13-router-adm-demo
openstack router set --external-gateway public1 --disable-snat tp13-router-adm-demo
openstack port create --tag tp13 --network tp13-network-adm-demo \
  --fixed-ip subnet=tp13-subnet-adm-demo,ip-address=192.168.121.1 \
  --no-security-group --disable-port-security tp13-port-adm-router-demo
openstack router add port tp13-router-adm-demo tp13-port-adm-router-demo
```

Le sous-réseau adm n'ayant pas de passerelle, `router add subnet` ne peut pas lui attribuer d'adresse :
on crée d'abord un port à l'adresse .1, sans security group (comme l'interface que crée
`router add subnet` ; sinon `port create` attache le groupe `default` du projet).

```bash
# [instance] contrôle : SNAT désactivé, dans l'API et dans le noyau
for r in pub adm; do
  openstack router show tp13-router-$r-demo -f value -c external_gateway_info
  ID=$(openstack router show tp13-router-$r-demo -f value -c id)
  sudo ip netns exec qrouter-$ID iptables -t nat -S | grep -c -E -- "-o qg-[^ ]+ -j SNAT"
done
```

Attendu : `'enable_snat': False` et `0` pour chaque routeur. Une règle SNAT subsiste avec
`--ctstate DNAT` : elle ne concerne que les connexions déjà traduites par une FIP, pas la sortie vers
Internet (question 1).

## Étape 3. L'hôte : route de retour et pare-feu

Les VM du réseau adm joignent le bastion avec leur propre adresse (pas de SNAT). Sans route de retour,
l'hôte leur répondrait par sa route par défaut, vers AWS, et la réponse serait perdue.

```bash
# [instance]
GW=$(openstack router show tp13-router-adm-demo -f json -c external_gateway_info \
     | jq -r '.external_gateway_info.external_fixed_ips[0].ip_address')
echo "$GW"                                           # adresse du routeur adm sur public1 (variable)
sudo ip route replace 192.168.121.0/24 via "$GW" dev veth-ext
ip route get 192.168.121.11                          # via <GW> dev veth-ext src 10.0.2.1
ping -c 2 192.168.121.1                              # le routeur adm répond
```

**Défense en profondeur.** Aucun paquet des réseaux du TP ne doit partir vers AWS sans avoir été traduit
par une FIP. Sans traduction, il n'aurait pas de retour, mais l'hôte le transmettrait quand même. Une
règle sur l'hôte le refuse :

```bash
# [instance]
sudo iptables -C FORWARD -s 192.168.120.0/22 -o enX0 -m comment --comment tp13 -j DROP 2>/dev/null \
  || sudo iptables -A FORWARD -s 192.168.120.0/22 -o enX0 -m comment --comment tp13 -j DROP
sudo iptables -S FORWARD | grep tp13
```

La route et la règle ne survivent pas à un redémarrage de l'instance : refaites cette étape après un
redémarrage.

## Étape 4. Le bastion : proxy Squid et serveur de temps

Les VM n'ont aucun accès direct à Internet. Pour installer des paquets, elles passent par un proxy sur
le bastion, qui n'autorise que des domaines choisis et journalise chaque requête.

```bash
# [instance]
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y squid
sudo cp -p /etc/squid/squid.conf /etc/squid/squid.conf.tp13-orig
sudo sed -i 's/^http_port 3128$/# http_port 3128   # TP 13 : écoute définie dans conf.d\/tp13.conf/' /etc/squid/squid.conf
grep -c '^http_port' /etc/squid/squid.conf            # 0
```

Par défaut, Squid écoute sur **toutes** les interfaces, y compris celle tournée vers AWS. On le limite à
l'adresse du bastion côté OpenStack.

À vous : écrivez `/etc/squid/conf.d/tp13.conf`. Il doit :

1. écouter sur `10.0.2.1:3128` seulement (`http_port`) ;
2. autoriser la VM web (192.168.121.11) et la VM bdd (192.168.121.12) **chacune** vers les seuls
   domaines dont elle a besoin, et seulement sur les ports 80 et 443.

Syntaxe, sur un exemple qui n'est pas la solution :

```
acl ma_source src 192.0.2.10/32
acl mes_domaines dstdomain exemple.org
acl ports_web port 80 443
http_access allow ma_source mes_domaines ports_web
```

Indice : les images Debian téléchargent leurs paquets, y compris les mises à jour de sécurité, sur
`deb.debian.org`. Tout ce qui n'est pas autorisé est refusé par la dernière ligne de `squid.conf`
(`http_access deny all`).

```bash
# [instance] vérifier AVANT de redémarrer : ne redémarrer que si la configuration est valide
sudo squid -k parse > /tmp/squid-parse.txt 2>&1 && ! grep -E "WARNING|ERROR|FATAL" /tmp/squid-parse.txt \
  && sudo systemctl restart squid && echo "Squid redémarré"
sudo ss -ltnp | grep squid                           # 10.0.2.1:3128 seulement
```

Ici, il faut redémarrer Squid, et non le recharger, car l'adresse d'écoute change. Ne simplifiez pas
cette vérification en `squid -k parse | grep … && exit 1` : dans un script en
`set -o pipefail`, une telle ligne ne s'arrête jamais sur une erreur (question 9).

Le bastion sert aussi l'heure aux VM. `chrony` y est déjà installé et synchronisé sur AWS ; on lui
demande de répondre au seul réseau adm, sur la seule adresse du bastion :

```bash
# [instance]
sudo tee /etc/chrony/conf.d/tp13.conf > /dev/null <<'EOF'
# TP 13 : heure servie aux VM du réseau admin, sur l'adresse du bastion seulement
allow 192.168.121.0/24
bindaddress 10.0.2.1
EOF
sudo systemctl restart chrony
sudo ss -lunp | grep chronyd                          # 10.0.2.1:123 (et le port de commande local 323)
sleep 15; chronyc -n sources | grep '^\^\*'           # l'hôte se resynchronise en une quinzaine de secondes
```

## Étape 5. Les security groups

Un groupe par rôle de carte, sans **aucune** règle de sortie par défaut.

```bash
# [instance]
for g in web adm data-web data-bdd; do
  openstack security group create --tag tp13 --description "TP 13, carte $g" tp13-sg-$g-demo
  for r in $(openstack security group rule list tp13-sg-$g-demo --egress -f value -c ID); do
    openstack security group rule delete "$r"
  done
done
```

Neutron ajoute à chaque nouveau groupe deux règles de sortie (IPv4 et IPv6, vers tout) : la boucle les
supprime. Oublier la règle IPv6 laisserait une sortie ouverte.

| Groupe | Carte | Besoin |
|---|---|---|
| `tp13-sg-web-demo` | pub de la VM web | recevoir le HTTP des clients (étape 15 : d'Internet) ; ne rien émettre de lui-même |
| `tp13-sg-adm-demo` | adm des deux VM | recevoir le SSH du bastion ; joindre le proxy et le serveur de temps du bastion |
| `tp13-sg-data-web-demo` | data de la VM web | joindre la base de données, et elle seule |
| `tp13-sg-data-bdd-demo` | data de la VM bdd | recevoir les connexions de l'application, et d'elle seule ; ne rien émettre de lui-même |

Un security group laisse passer la réponse à une connexion qu'il a acceptée. Une règle de sortie ne
sert donc qu'aux connexions que la carte **ouvre** elle-même.

À vous : écrivez les règles. Une seule règle est donnée, celle du groupe web. Exécutez-la, puis
inspirez-vous de sa syntaxe pour les autres :

```bash
# [instance]
openstack security group rule create --ingress --protocol tcp --dst-port 80 \
  --remote-ip 0.0.0.0/0 --description "HTTP vers HAProxy" tp13-sg-web-demo
```

Pour une source ou une destination **interne**, désignez un groupe (`--remote-group <groupe>`) plutôt
qu'une adresse : la règle suit les cartes, même si leurs adresses changent. Pour une source ou une
destination **externe** (le bastion, 10.0.2.1), utilisez `--remote-ip <adresse>/32`. Pour une règle
de sortie, remplacez `--ingress` par `--egress`. Les ports utiles :

| Service | Protocole et port |
|---|---|
| SSH | TCP 22 |
| proxy Squid (étape 4) | TCP 3128 |
| serveur de temps | **UDP** 123 (`--protocol udp`) |
| PostgreSQL | TCP 5432 |

```bash
# [instance] contrôle
for g in web adm data-web data-bdd; do
  echo "== tp13-sg-$g-demo"
  for r in $(openstack security group rule list tp13-sg-$g-demo -f value -c ID); do
    openstack security group rule show "$r" -f value -c direction -c protocol -c port_range_min \
      -c normalized_cidr -c remote_group_id | paste -sd' '
  done
done
```

Attendu : aucune ligne `egress` avec `0.0.0.0/0` ou `::/0`. Attention : la colonne « IP Range » de
`openstack security group rule list` affiche `0.0.0.0/0` pour une règle qui désigne un **groupe** ;
ce n'est pas une ouverture. Le champ fiable est `normalized_cidr`, vide (`None`) pour une règle par
groupe.

Une règle manque volontairement à la liste des besoins : vous la découvrirez à l'étape 7.

## Étape 6. Les ports, à adresse fixe

Créer les ports avant les VM permet d'imposer adresse et security group.

```bash
# [instance]
port() {  # $1 = nom, $2 = réseau, $3 = adresse, $4 = groupe
  openstack port create --tag tp13 --network tp13-network-$2-demo \
    --fixed-ip subnet=tp13-subnet-$2-demo,ip-address=$3 \
    --security-group tp13-sg-$4-demo tp13-port-$1-demo
}
port pub-web  pub  192.168.120.10 web
port adm-web  adm  192.168.121.11 adm
port data-web data 192.168.122.11 data-web
port adm-bdd  adm  192.168.121.12 adm
port data-bdd data 192.168.122.12 data-bdd
```

```bash
# [instance] contrôle : un seul groupe par port, le bon
for p in pub-web adm-web data-web adm-bdd data-bdd; do
  openstack port show tp13-port-$p-demo -f json \
    | jq -r '"\(.name) \(.fixed_ips[0].ip_address) \(.security_group_ids|length) groupe(s) \(.status)"'
done
```

Attendu : cinq lignes, `1 groupe(s)`, état `DOWN` (aucune VM attachée).

## Étape 7. La clé, puis les VM

La clé privée des VM reste **sur votre poste**. Seule la clé publique va dans OpenStack.

```bash
# [poste]
ssh-keygen -q -t ed25519 -N "" -C tp13-keypair-adm-demo -f ~/.ssh/tp13-keypair-adm-demo
scp -i ec2_key ~/.ssh/tp13-keypair-adm-demo.pub ubuntu@<IP_PUBLIQUE>:
```

```bash
# [instance]
openstack keypair create --public-key ~/tp13-keypair-adm-demo.pub tp13-keypair-adm-demo
```

Lisez [tp13/user-data-tp13.yaml](tp13/user-data-tp13.yaml). Il est commun aux deux VM :

| Bloc | Effet |
|---|---|
| `apt: proxy`, `https_proxy` | les paquets passent par le proxy du bastion |
| `ntp` | l'heure vient du bastion (10.0.2.1) |
| `ssh_pwauth: false` | connexion par clé seulement |
| fichier `90-tp13-admin.yaml` | la carte adm (`ens3`) gagne pour joindre les métadonnées (métrique 50) |
| fichier `91-tp13-pub.yaml`, si `role` vaut `lb-app` | sur la VM web seulement : routage par source (étape 11) |

La première ligne, `## template: jinja`, fait de ce fichier un gabarit (TP 12) : le second fichier
réseau n'est écrit que sur la VM qui porte la propriété `role=lb-app`. Un gabarit ne se valide pas
sur l'instance : `cloud-init schema -c` échoue faute de propriété `role`. On le valide dans la VM, une
fois rendu (étape 8).

La carte adm est toujours la **première** carte : sans métadonnées, cloud-init ne configure que la
première carte, et c'est par elle qu'il les demande.

Lancez d'abord la VM bdd :

```bash
# [instance]
openstack server create --image debian13 --flavor m1.1g --key-name tp13-keypair-adm-demo \
  --port tp13-port-adm-bdd-demo --port tp13-port-data-bdd-demo \
  --user-data ~/openstack-lab-trainee/tps/tp13/user-data-tp13.yaml \
  --property role=db --tag tp13 tp13-vm-bdd-demo
```

Attendez environ 5 minutes, puis lisez la fin de la console :

```bash
# [instance]
openstack console log show tp13-vm-bdd-demo | grep -E "finished at|metadata|authorized"
```

**Exercice.** Si vous lisez `Datasource DataSourceNone` et `no authorized SSH keys`, la VM n'a pas pu
lire ses métadonnées : elle n'a ni votre clé ni son user-data. Le service de métadonnées répond sur
`169.254.169.254`, en TCP 80, et cloud-init l'interroge par la carte adm. Quelle règle manque, dans
quel groupe ? Ajoutez-la, puis recréez la VM (ses ports sont conservés) :

```bash
# [instance]
openstack server delete --wait tp13-vm-bdd-demo
# puis la même commande « server create » que ci-dessus
```

Attendu après correction : `Datasource DataSourceOpenStackLocal` et un bloc `Authorized keys … for user
debian`. Lancez ensuite la VM web, avec ses trois cartes, la carte adm en premier :

```bash
# [instance]
openstack server create --image debian13 --flavor m1.1g --key-name tp13-keypair-adm-demo \
  --port tp13-port-adm-web-demo --port tp13-port-pub-web-demo --port tp13-port-data-web-demo \
  --user-data ~/openstack-lab-trainee/tps/tp13/user-data-tp13.yaml \
  --property role=lb-app --tag tp13 tp13-vm-web-haproxy-demo
```

Pendant le démarrage, lisez le journal du proxy : vous y voyez les VM installer leurs mises à jour.

```bash
# [instance]
sudo tail -f /var/log/squid/access.log        # Ctrl+C pour quitter
```

Attendu : des lignes `TCP_TUNNEL/200 … CONNECT deb.debian.org:443` pour 192.168.121.11 et .12.
D'autres lignes `TCP_DENIED/403` peuvent apparaître (par exemple
`metadata.ftp-master.debian.org`, demandé chaque heure par `apt-listchanges`) : c'est la liste blanche
qui fait son travail, ces demandes ne sont pas nécessaires (question 4).

## Étape 8. Administrer par le bastion

Copiez le modèle de configuration SSH sur votre poste et complétez-le :

```bash
# [poste]
scp -i ec2_key ubuntu@<IP_PUBLIQUE>:openstack-lab-trainee/tps/tp13/ssh_config.exemple ~/.ssh/tp13_config
nano ~/.ssh/tp13_config        # remplacer <IP_PUBLIQUE> et <CHEMIN_EC2_KEY> (chemin complet de ec2_key)
```

`ProxyJump` fait relayer la connexion TCP par le bastion : la clé des VM ne quitte pas votre poste.

**Ne faites pas confiance à la première connexion.** Chaque VM a une clé d'hôte. Cloud-init a
affiché son empreinte dans la console. Comparez-la à celle que la VM présente sur le réseau :

```bash
# [instance] VM web, puis VM bdd
openstack console log show tp13-vm-web-haproxy-demo | sed -n '/BEGIN SSH HOST KEY FINGERPRINTS/,/END/p' | grep ED25519
ssh-keyscan -t ed25519 192.168.121.11 2>/dev/null | ssh-keygen -lf -
openstack console log show tp13-vm-bdd-demo | sed -n '/BEGIN SSH HOST KEY FINGERPRINTS/,/END/p' | grep ED25519
ssh-keyscan -t ed25519 192.168.121.12 2>/dev/null | ssh-keygen -lf -
```

Pour chaque VM, les deux empreintes `SHA256:…` doivent être identiques. Si c'est le cas, enregistrez
les clés sur le poste, puis vérifiez que ce sont bien celles que vous avez comparées :

```bash
# [poste]
ssh -F ~/.ssh/tp13_config tp13-bastion 'ssh-keyscan -t ed25519 192.168.121.11 192.168.121.12 2>/dev/null' >> ~/.ssh/tp13_known_hosts
ssh-keygen -lf ~/.ssh/tp13_known_hosts       # les deux empreintes vues ci-dessus
```

Si une empreinte diffère, ne vous connectez pas : supprimez `~/.ssh/tp13_known_hosts` et cherchez la
cause.

```bash
# [poste]
ssh -F ~/.ssh/tp13_config tp13-vm-web-haproxy-demo 'hostname; echo "${SSH_CONNECTION%% *}"'
ssh -F ~/.ssh/tp13_config tp13-vm-bdd-demo 'cloud-init status --long | head -3; timedatectl show -p NTPSynchronized'
ssh -F ~/.ssh/tp13_config tp13-vm-web-haproxy-demo 'sudo cloud-init schema --system'
```

Attendu : le client vu par la VM est `10.0.2.1` (le bastion) ; `status: done` ; `NTPSynchronized=yes` ;
`Valid schema user-data` pour le user-data rendu de la VM web.

### Observer le trafic d'une VM

`tcpdump` est installé dans les VM. Identifiez d'abord les cartes, puis capturez :

```bash
# [VM] tp13-vm-web-haproxy-demo
ip -br addr                                  # ens3 = adm, ens4 = pub, ens5 = data
sudo timeout 15 tcpdump -e -n -i ens4 -c 10             # une carte ; -e : adresses physiques
sudo timeout 15 tcpdump -e -n -i any -c 10 not port 22  # toutes les cartes, sans votre session SSH
```

`-c 10` arrête après dix paquets, `timeout 15` après 15 s si la carte est silencieuse (la carte pub
l'est souvent). Avec `-i any`, chaque ligne indique la carte et le sens (`ens3 In`, `ens4 Out`).
N'excluez pas l'ARP : c'est souvent lui qui explique une panne (exercice suivant).

### Exercice : le piège du routage asymétrique

La VM web a deux chemins possibles vers le bastion : sa route `10.0.2.1/32` par la carte adm, et sa
route par défaut par la carte pub. Que se passe-t-il sans la première ?

La commande suivante supprime la route, capture pendant 30 s, puis **rétablit la route
automatiquement au bout de 40 s**, indépendamment de votre session SSH, qui va être coupée :

```bash
# [VM] tp13-vm-web-haproxy-demo
sudo setsid sh -c "timeout 30 tcpdump -l -e -n -i any \"arp or (tcp port 22 and host 10.0.2.1)\" > /tmp/asym.txt 2>&1 &
  sleep 2; ip route del 10.0.2.1/32 dev ens3; sleep 38
  ip route add 10.0.2.1/32 via 192.168.121.1 dev ens3 proto dhcp src 192.168.121.11 metric 50" > /dev/null 2>&1 < /dev/null &
```

```bash
# [instance] pendant la coupure
nc -z -w 5 192.168.121.11 22 && echo ouvert || echo "sans réponse"
```

Reconnectez-vous après une minute et lisez la capture :

```bash
# [VM] tp13-vm-web-haproxy-demo
cut -c1-150 /tmp/asym.txt | head -8
ip -4 route show 10.0.2.1                    # la route est revenue
```

Attendu : en alternance, `ens3 In … 10.0.2.1.<port> > 192.168.121.11.22: Flags [S]` et
`ens4 Out … ARP (0x0806) … Request who-has 192.168.120.1 tell 192.168.121.11`. Expliquez (question 5).

## Étape 9. La VM bdd : volume chiffré, secret, PostgreSQL

```bash
# [instance]
openstack volume type create --encryption-provider luks --encryption-cipher aes-xts-plain64 \
  --encryption-key-size 256 --encryption-control-location front-end tp13-cinder-type-luks-demo
VOL=$(openstack volume create --size 2 --type tp13-cinder-type-luks-demo tp13-cinder-bdd-demo -f value -c id)
for i in $(seq 60); do
  ETAT=$(openstack volume show "$VOL" -f value -c status)
  echo "$ETAT"
  case $ETAT in
    available) break ;;
    error*) echo "Échec de la création : voir openstack volume show $VOL" ; break ;;
  esac
  sleep 2
done
openstack server add volume tp13-vm-bdd-demo "$VOL"
openstack volume show "$VOL" -f value -c status     # in-use ; si reserved ou attaching, relancez dans quelques secondes
echo "$VOL"                                          # à reporter plus bas : <ID_VOLUME>
```

On travaille sur l'**identifiant** du volume : un nom de volume n'est pas unique. Et la boucle ne
contient pas d'`exit` : collée dans votre terminal, elle fermerait votre session.

Le mot de passe de la base est aléatoire, déposé dans Barbican par un fichier temporaire : il
n'apparaît ni dans la ligne de commande (donc ni dans `ps`), ni dans l'historique.

```bash
# [instance]
F=$(mktemp)                                      # droits 600
openssl rand -base64 24 | tr -d '\n' > "$F"
openstack secret store --name tp13-barbican-bdd-demo --payload-content-type text/plain --file "$F" \
  -f value -c "Secret href"                      # à reporter plus bas : <HREF>
shred -u "$F"
```

Formatez et montez le volume **avant** d'installer PostgreSQL, pour que la base soit créée dessus :

```bash
# [VM] tp13-vm-bdd-demo ; <ID_VOLUME> : l'identifiant affiché plus haut
ID=<ID_VOLUME>
DEV=/dev/disk/by-id/virtio-${ID:0:20}
lsblk -o NAME,SIZE "$DEV"
sudo mkfs.ext4 -q -L tp13-db "$DEV"
sudo mkdir -p /var/lib/postgresql
echo "LABEL=tp13-db /var/lib/postgresql ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload && sudo mount /var/lib/postgresql && findmnt /var/lib/postgresql
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql
```

À vous :

1. PostgreSQL ne doit écouter **que** sur la carte data : écrivez la bonne valeur de
   `listen_addresses` dans `/etc/postgresql/17/main/conf.d/tp13.conf` ;
2. seule l'application doit pouvoir se connecter : ajoutez **une** ligne `host` à la fin de
   `/etc/postgresql/17/main/pg_hba.conf` (base `tp13`, utilisateur `tp13app`, source la seule adresse
   data de la VM web, méthode `scram-sha-256`) ;
3. redémarrez : `sudo systemctl restart postgresql@17-main`.

Créez ensuite l'utilisateur et la base. Le mot de passe est lu dans Barbican sur le bastion et passe
par votre poste jusqu'à l'entrée standard de la VM : il n'est écrit sur aucun disque.

```bash
# [poste] (une seule commande ; <HREF> : l'adresse « Secret href » affichée plus haut)
ssh -F ~/.ssh/tp13_config tp13-bastion 'source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh && openstack secret get --payload -f value -c Payload <HREF>' \
  | ssh -F ~/.ssh/tp13_config tp13-vm-bdd-demo 'IFS= read -r PW; printf "%s\n" "\\set pw '"'"'$PW'"'"'" "CREATE ROLE tp13app LOGIN PASSWORD :'"'"'pw'"'"';" "CREATE DATABASE tp13 OWNER tp13app;" | sudo runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q && echo "base créée"'
```

`read` et `printf` sont internes au shell : le mot de passe n'apparaît dans aucune ligne de commande.

```bash
# [VM] tp13-vm-bdd-demo contrôle
sudo ss -ltnp | grep postgres                        # 192.168.122.12:5432 seulement
findmnt -n -o SOURCE -T /var/lib/postgresql/17/main  # /dev/vdb : les données sont sur le volume
psql -h 192.168.122.12 -U tp13app -w tp13 -c "select 1" 2>&1 | head -1   # refusé : no pg_hba.conf entry
```

## Étape 10. La VM web : application et HAProxy

L'application vous est fournie ([tp13/appli/](tp13/appli/)) : une page qui montre le parcours réel de
votre requête et l'état de la base, et un formulaire de messages. Copiez-la par votre poste (aucune
clé de VM sur le bastion), puis déposez le mot de passe dans un fichier lisible de root seul :

```bash
# [poste]
ssh -F ~/.ssh/tp13_config tp13-bastion 'tar -C ~/openstack-lab-trainee/tps/tp13 -cf - appli' \
  | ssh -F ~/.ssh/tp13_config tp13-vm-web-haproxy-demo 'tar -xf -'
ssh -F ~/.ssh/tp13_config tp13-bastion 'source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh && openstack secret get --payload -f value -c Payload <HREF>' \
  | ssh -F ~/.ssh/tp13_config tp13-vm-web-haproxy-demo 'sudo install -d -m 700 /etc/tp13 && sudo sh -c "umask 077; cat > /etc/tp13/db-password"'
```

Lisez `installer-appli.sh` avant de le lancer : on ne lance pas en root un script qu'on n'a pas lu.

```bash
# [VM] tp13-vm-web-haproxy-demo
sudo mkdir -p /opt/tp13-appli
sudo cp -r ~/appli/app.py ~/appli/templates ~/appli/static /opt/tp13-appli/
cd ~/appli && sudo bash installer-appli.sh | tail -2       # active active
```

Lisez [tp13/appli/tp13-appli.service](tp13/appli/tp13-appli.service) : l'application tourne sous un
utilisateur créé au démarrage, sur un système en lecture seule, sans aucune capacité, avec un filtre
d'appels système, et ne peut joindre que la boucle locale et la base (`IPAddressAllow`). Le mot de passe
lui est remis par systemd (`LoadCredential`), jamais par une variable d'environnement.

```bash
# [VM] tp13-vm-web-haproxy-demo contrôle
sudo ss -ltnp | grep -E "gunicorn|haproxy"           # 127.0.0.1:8080 et 192.168.120.10:80 seulement
systemd-analyze security tp13-appli --no-pager | tail -1    # « OK » ; comparez avec un service ordinaire
curl -s http://192.168.120.10/ | grep 'data-test="etat-base"' | sed 's/<[^>]*>//g'   # Réussi : connectée à PostgreSQL 17…
```

## Étape 11. Publier sur le réseau externe : la FIP

```bash
# [instance]
openstack floating ip create --floating-ip-address 10.0.2.150 --port tp13-port-pub-web-demo \
  --description FIP_PUBLICATION --tag tp13 public1
curl -s -o /dev/null -w "%{http_code}\n" http://10.0.2.150/        # 200
for p in 22 8080 5432; do nc -z -w 5 10.0.2.150 $p && echo "$p ouvert" || echo "$p fermé"; done   # fermé ×3
```

L'adresse est fixée (10.0.2.150, dans le pool de `public1`) : tout le monde a la même URL.

**Le second visage du routage asymétrique.** La requête de l'hôte arrive sur la carte pub de la VM web,
mais pour répondre à 10.0.2.1, la VM préférerait sa route adm, plus précise. Le fichier
`91-tp13-pub.yaml` du user-data corrige cela par un **routage par source** : ce qui part de l'adresse
pub ressort par la carte pub.

```bash
# [VM] tp13-vm-web-haproxy-demo
ip rule | grep 120                                   # from 192.168.120.10 lookup 120
ip route get 10.0.2.1 from 192.168.120.10            # … dev ens4 table 120
ip route get 10.0.2.1 from 192.168.121.11            # … dev ens3 (le SSH, inchangé)
```

Constatez l'effet : retirez la règle 40 s, essayez la page depuis l'hôte, la règle revient seule.

```bash
# [VM] tp13-vm-web-haproxy-demo
sudo setsid sh -c "ip rule del from 192.168.120.10 lookup 120; sleep 40; ip rule add from 192.168.120.10 lookup 120" > /dev/null 2>&1 < /dev/null &
```

```bash
# [instance] pendant les 40 s, puis après
curl -s -m 8 -o /dev/null -w "%{http_code}\n" http://10.0.2.150/     # 000, puis 200
```

## Étape 12. Prouver chaque objectif

Pour chaque objectif de [tp13-architecture.md](tp13-architecture.md) (§ 4.4), un accès autorisé doit
réussir **et** un accès interdit doit échouer. Faites au moins les tests suivants, et consignez le
résultat de chacun.

| Objectif | Autorisé (doit réussir) | Interdit (doit échouer) |
|---|---|---|
| O1 | `[instance]` `curl http://10.0.2.150/` : 200 | `[instance]` `nc -z -w 5 10.0.2.150 22` (et 443, 8080, 5432) |
| O2 | `[VM web]` `nc -z -w 4 127.0.0.1 8080` | `[VM bdd]` `nc -z -w 4 192.168.122.11 8080` ; `[instance]` `nc -z -w 4 192.168.121.11 8080` |
| O3 | `[VM web]` `nc -z -w 4 192.168.122.12 5432` | `[VM web]` `nc -z -w 4 192.168.122.12 22` ; `[instance]` `nc -z -w 4 192.168.122.12 5432` |
| O4 | `[poste]` `ssh -F ~/.ssh/tp13_config tp13-vm-bdd-demo hostname` | `[VM web]` `nc -z -w 4 192.168.121.12 22` ; `[instance]` `nc -z -w 4 10.0.2.150 22` |
| O5 | | `[VM web]` `curl -m 8 --noproxy '*' https://deb.debian.org/` ; `nc -z -w 4 1.1.1.1 443` ; `nc -z -w 4 192.168.121.2 53` (DNS) |
| O6 | `[VM bdd]` `sudo apt-get update` : lignes `Hit:`/`Get:`, aucune `Err:` | `[VM bdd]` `curl -s -o /dev/null -w "%{http_connect}\n" -x http://10.0.2.1:3128 https://github.com/` : 403 ; `[instance]` `sudo grep github.com /var/log/squid/access.log` : `TCP_DENIED/403` |
| O7 | `[VM web]` `ip -4 route show default` : une route, par `ens4` | `[VM bdd]` `ip route get 1.1.1.1` : `Network is unreachable` |
| O8 | `[instance]` `openstack port list --tags tp13` (et réseaux, routeurs, groupes, FIP, VM) | volume, type de volume, clé et secret n'acceptent pas d'étiquette : retrouvez-les par leur préfixe `tp13-` |

`apt-get update` renvoie le code 0 même quand les dépôts sont injoignables : lisez sa sortie, pas son
code retour.

**Qui bloque quoi ?** Un test négatif montre quelle barrière arrête un flux. Ajoutez pendant une
minute une sortie TCP 443 vers tout dans `tp13-sg-web-demo`, essayez depuis la VM web
`curl -s -m 8 --noproxy '*' https://1.1.1.1/cdn-cgi/trace | grep ^ip=`, puis **supprimez la règle**.
Quelle adresse source 1.1.1.1 a-t-il vue ? Qu'en concluez-vous sur le rôle de ce groupe (question 7) ?

## Étape 13. L'application dans votre navigateur

```bash
# [poste], dans un terminal dédié : la commande ne rend pas la main (Ctrl+C pour fermer le tunnel)
ssh -i ec2_key -N -L 18080:10.0.2.150:80 ubuntu@<IP_PUBLIQUE>
```

Ouvrez `http://127.0.0.1:18080/`. La page indique le parcours de votre requête (navigateur vu par
HAProxy : `10.0.2.1`, puisque le tunnel se termine sur le bastion), l'état de la base, et propose
d'enregistrer un message. Ouvrez les outils de développement (F12), onglet Console : aucune erreur
de politique de sécurité du contenu (CSP) ne doit apparaître. Parcourez la page au clavier (Tab).

Faites ensuite échouer la base exprès : retirez la règle de sortie de `tp13-sg-data-web-demo`, puis
rechargez la page. Attendu : « Bloquant : base injoignable, délai de 3 s dépassé ». Remettez la règle
et rechargez : la base est de nouveau « Réussi ».

## Étape 14. Niveau avancé : une exception SSH, et une seule

Objectif : autoriser la VM web, et elle seule, à ouvrir une connexion SSH vers `github.com` à travers
le proxy, puis constater dans le journal ce que le proxy voit, et ce qu'il ne voit pas.

À vous : écrivez `/etc/squid/conf.d/tp13-ssh.conf`. Indices :

- le `squid.conf` d'Ubuntu refuse le port 22 **deux fois** avant de lire `conf.d` (`Safe_ports` et
  `SSL_ports`) ; Squid cumule les valeurs d'une même `acl` ;
- `conf.d` est lu dans l'ordre alphabétique : `tp13-ssh.conf` passe **avant** `tp13.conf`, dont il ne
  peut donc pas utiliser les `acl` ;
- vos autorisations de l'étape 4 sont limitées aux ports 80 et 443 : ajouter 22 aux ports admis ne
  doit rien ouvrir d'autre.

Vérifiez la configuration comme à l'étape 4. Cette fois, un rechargement suffit
(`sudo systemctl reload squid`) : l'adresse d'écoute ne change pas.

La VM web doit vérifier la clé d'hôte de GitHub, pas l'accepter à l'aveugle. GitHub publie ses clés à
l'adresse <https://api.github.com/meta>. La VM ne peut pas joindre cette adresse (elle n'est pas dans
la liste blanche) : le bastion la lit, et la clé passe par votre poste jusqu'à la VM.

```bash
# [poste]
ssh -F ~/.ssh/tp13_config tp13-bastion 'curl -s -m 15 https://api.github.com/meta | jq -r ".ssh_keys[] | select(startswith(\"ssh-ed25519\")) | \"github.com \" + ."' \
  | ssh -F ~/.ssh/tp13_config tp13-vm-web-haproxy-demo 'cat > ~/.ssh/github_known_hosts'
```

Comparez l'empreinte à celle de la documentation de GitHub (voir les sources), puis essayez :

```bash
# [VM] tp13-vm-web-haproxy-demo
ssh-keygen -lf ~/.ssh/github_known_hosts           # SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU
ssh -o ProxyCommand='nc -X connect -x 10.0.2.1:3128 %h %p' -o UserKnownHostsFile=~/.ssh/github_known_hosts \
  -o StrictHostKeyChecking=yes -T git@github.com
```

Attendu : `git@github.com: Permission denied (publickey).` La connexion est allée jusqu'à
l'authentification : elle échoue seulement parce que la VM n'a pas de clé GitHub.

Vérifiez ensuite que l'exception ne vaut que pour la VM web et pour github.com :

```bash
# [VM] tp13-vm-bdd-demo : une autre VM
echo | nc -X connect -x 10.0.2.1:3128 -w 5 github.com 22     # nc: Proxy error: "HTTP/1.1 403 Forbidden"
```

```bash
# [VM] tp13-vm-web-haproxy-demo : une autre destination
echo | nc -X connect -x 10.0.2.1:3128 -w 5 gitlab.com 22     # nc: Proxy error: "HTTP/1.1 403 Forbidden"
```

Lisez le journal du proxy (`sudo tail /var/log/squid/access.log` sur l'instance) : il montre la
destination et le volume échangé, jamais le contenu. Retirez ensuite l'exception :

```bash
# [instance]
sudo rm /etc/squid/conf.d/tp13-ssh.conf && sudo systemctl reload squid
```

## Étape 15. Publier sur Internet (optionnelle, payante)

> **Coût.** Cette étape alloue une Elastic IP, facturée par AWS (environ 0,005 USD par heure) jusqu'à
> sa libération. Ne la faites qu'avec l'accord du tuteur, et libérez tout à la fin.

Avant tout, vérifiez le security group AWS de l'instance : il s'applique à **toute** son interface
réseau, donc aussi à l'adresse que vous allez ajouter. Le port 80 ne doit être ouvert qu'à votre
propre adresse publique (`curl https://checkip.amazonaws.com` sur le poste), jamais à `0.0.0.0/0`.

```bash
# [poste], dans le dossier du dépôt public ; l'outil demande de taper « oui »
./aws/aws-public-fip.sh create <INSTANCE_ID>              # simulation : rien n'est modifié
./aws/aws-public-fip.sh create <INSTANCE_ID> --apply      # affiche l'IP secondaire, l'Elastic IP et son allocation (eipalloc-…)
```

```bash
# [instance]
sudo ~/openstack-lab-trainee/tools/public-fip.sh add <IP_SECONDAIRE> 10.0.2.150
```

Ouvrez `http://<ELASTIC_IP>/` dans le navigateur du poste : la page affiche cette fois **votre**
adresse publique. Depuis un téléphone en réseau mobile (Wi-Fi coupé), la page ne doit pas s'afficher.

Libérez, dans cet ordre :

```bash
# [instance]
sudo ~/openstack-lab-trainee/tools/public-fip.sh del <IP_SECONDAIRE>
```

```bash
# [poste]
./aws/aws-public-fip.sh delete <ALLOCATION_ID> --apply
./aws/aws-public-fip.sh list                              # plus aucune Elastic IP du lab
```

## Étape 16. Nettoyage

Dans l'ordre inverse de la création :

```bash
# [instance]
openstack floating ip delete $(openstack floating ip list --tags tp13 -f value -c ID)
openstack server delete --wait tp13-vm-web-haproxy-demo tp13-vm-bdd-demo
VOL=$(openstack volume show tp13-cinder-bdd-demo -f value -c id)
for i in $(seq 30); do [ "$(openstack volume show "$VOL" -f value -c status)" = available ] && break; sleep 2; done
openstack volume delete "$VOL"
for i in $(seq 30); do openstack volume show "$VOL" > /dev/null 2>&1 || break; sleep 2; done   # volume disparu
openstack secret delete "$(openstack secret list --name tp13-barbican-bdd-demo -f value -c 'Secret href')"
openstack volume type delete tp13-cinder-type-luks-demo
openstack port delete tp13-port-pub-web-demo tp13-port-adm-web-demo tp13-port-data-web-demo \
  tp13-port-adm-bdd-demo tp13-port-data-bdd-demo
openstack security group delete tp13-sg-web-demo tp13-sg-adm-demo tp13-sg-data-web-demo tp13-sg-data-bdd-demo
openstack router remove port tp13-router-adm-demo tp13-port-adm-router-demo
openstack router remove subnet tp13-router-pub-demo tp13-subnet-pub-demo
openstack router unset --external-gateway tp13-router-adm-demo
openstack router unset --external-gateway tp13-router-pub-demo
openstack router delete tp13-router-adm-demo tp13-router-pub-demo
for s in pub adm data; do openstack subnet delete tp13-subnet-$s-demo; done
for s in pub adm data; do openstack network delete tp13-network-$s-demo; done
openstack keypair delete tp13-keypair-adm-demo
rm -f ~/tp13-keypair-adm-demo.pub /tmp/squid-parse.txt
```

```bash
# [instance] l'hôte
sudo iptables -D FORWARD -s 192.168.120.0/22 -o enX0 -m comment --comment tp13 -j DROP
sudo ip route del 192.168.121.0/24 dev veth-ext
sudo rm -f /etc/chrony/conf.d/tp13.conf && sudo systemctl restart chrony
sudo rm -f /etc/squid/conf.d/tp13.conf /etc/squid/conf.d/tp13-ssh.conf
sudo mv /etc/squid/squid.conf.tp13-orig /etc/squid/squid.conf
sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y \
  squid squid-common squid-langpack libecap3 libdbi-perl libltdl7 libtdb1 ssl-cert
sudo rm -rf /var/log/squid /var/spool/squid
```

N'utilisez pas `apt-get autoremove` : il retirerait aussi des paquets déjà orphelins avant le TP, sans
rapport avec Squid (vérifiez-le avec `sudo apt-get -s autoremove`).

```bash
# [instance] contrôle : plus rien du TP
for t in network subnet router port "security group" "floating ip"; do
  echo "$t : $(openstack $t list --tags tp13 -f value | wc -l)"
done
openstack server list -f value -c Name | grep -c '^tp13-'
openstack volume list -f value -c Name | grep -c '^tp13-'
ip route show 192.168.121.0/24 | wc -l; sudo iptables -S FORWARD | grep -c tp13
cd ~/openstack-lab-trainee && ./verify.sh | tail -1        # le lab de base est intact
```

```bash
# [poste]
rm -f ~/.ssh/tp13-keypair-adm-demo ~/.ssh/tp13-keypair-adm-demo.pub ~/.ssh/tp13_known_hosts ~/.ssh/tp13_config
```

Conservez l'image `debian13` et le gabarit `m1.1g`.

## Questions

1. Pourquoi un routeur « sans SNAT » garde-t-il une règle SNAT `--ctstate DNAT` ? Ouvre-t-elle une
   sortie vers Internet ?
2. Pourquoi le réseau data n'a-t-il pas de routeur ? Qu'est-ce qui empêcherait la base de sortir s'il en
   avait un ?
3. Pourquoi faut-il créer à la main le port .1 du routeur adm, et pourquoi sans security group ?
4. Le journal du proxy contient des refus pour des domaines que vous n'avez pas autorisés. Faut-il les
   ajouter à la liste blanche ? Selon quel critère ?
5. Expliquez, capture à l'appui, pourquoi le SSH échoue sans la route `10.0.2.1/32` : où le paquet
   de réponse est-il arrêté, et par quoi ?
6. À l'étape 11, le même piège apparaît dans l'autre sens. Pourquoi la correction n'est-elle pas une
   simple route, mais une règle de routage par source ?
7. Le test négatif de l'étape 12 montre quelle seule barrière empêche la VM web de sortir sur
   Internet. Laquelle ? Que deviendrait l'architecture avec une règle de sortie de trop ?
8. Pourquoi le mot de passe de la base passe-t-il par l'entrée standard, et non par un argument ou une
   variable d'environnement ? Comment le vérifiez-vous ?
9. Pourquoi `squid -k parse 2>&1 | grep ERROR && exit 1 || true` ne s'arrête-t-il jamais sur une
   erreur dans un script en `set -o pipefail` ?
10. Un security group AWS filtre l'interface entière. Quel risque cela pose-t-il à l'étape 15, et
    qu'avez-vous vérifié avant d'allouer l'Elastic IP ?

## Validation

- [ ] Réseaux, routeurs sans SNAT, route et pare-feu de l'hôte contrôlés (étapes 1 à 3).
- [ ] Squid écoute sur 10.0.2.1:3128 seulement ; liste blanche par VM, ports 80 et 443 seulement.
- [ ] Security groups : aucune sortie vers tout ; sources internes désignées par groupe.
- [ ] Règle manquante de l'étape 7 trouvée et expliquée (console avant et après).
- [ ] Clés d'hôte comparées aux empreintes de la console avant la première connexion.
- [ ] Piège du routage asymétrique capturé et expliqué (questions 5 et 6).
- [ ] Mot de passe absent de tout fichier et de tout historique ; base sur le volume chiffré.
- [ ] Appli : écoutes vérifiées, `systemd-analyze security` relevé, page servie par la FIP.
- [ ] Tableau de l'étape 12 complet : chaque objectif prouvé par un succès et un échec.
- [ ] Page affichée dans le navigateur, console sans erreur de CSP.
- [ ] Étape 15 (si faite) : Elastic IP libérée, vérifiée par `list`.
- [ ] Nettoyage complet : 0 ressource `tp13`, `verify.sh` sans échec.

## Sources

- Neutron, routeurs et SNAT : <https://docs.openstack.org/neutron/2025.1/admin/intro-os-networking.html>
- Client `openstack`, règles de security group : <https://docs.openstack.org/python-openstackclient/latest/cli/command-objects/security-group-rule.html>
- Nova, service de métadonnées : <https://docs.openstack.org/nova/2025.1/user/metadata.html>
- Cinder, volumes chiffrés : <https://docs.openstack.org/cinder/2025.1/configuration/block-storage/volume-encryption.html>
- Barbican, secrets : <https://docs.openstack.org/python-barbicanclient/latest/cli/usage.html>
- cloud-init, gabarits Jinja : <https://cloudinit.readthedocs.io/en/latest/explanation/instancedata.html>
- Netplan, routage par source (`routing-policy`) : <https://netplan.readthedocs.io/en/stable/netplan-yaml/>
- Squid, contrôle d'accès : <https://wiki.squid-cache.org/SquidFaq/SquidAcl>
- chrony, `allow` et `bindaddress` : <https://chrony-project.org/doc/4.5/chrony.conf.html>
- PostgreSQL 17, `pg_hba.conf` : <https://www.postgresql.org/docs/17/auth-pg-hba-conf.html>
- systemd, durcissement d'un service : <https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html>
- HAProxy 3.0, `option forwardfor` : <https://docs.haproxy.org/3.0/configuration.html>
- GitHub, clés d'hôte SSH : <https://docs.github.com/fr/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints>
- AWS, adresses IP Elastic : <https://docs.aws.amazon.com/fr_fr/AWSEC2/latest/UserGuide/elastic-ip-addresses-eip.html>
- Toutes les sources du parcours : [sources.md](sources.md)
