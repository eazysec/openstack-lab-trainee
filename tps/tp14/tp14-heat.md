# TP 14 (bonus). Déployer avec Heat : l'infrastructure décrite en code

| | |
|---|---|
| Prérequis | TP 00 à 13 ; scénario 04 déployé ; TP 13 nettoyé (étape 16) ; image `debian13` et gabarit `m1.1g` (TP 12) ; vos notes du TP 13 (fichier `tp13.conf` de Squid, réglages de PostgreSQL) |
| Durée | une demi-journée (estimé) |
| À la fin du TP | Vous avez ajouté un service à un cloud en fonctionnement, décrit une infrastructure dans un modèle Heat, reconstruit l'architecture du TP 13 en une commande, constaté ce qu'un modèle ne voit pas, puis rendu la plateforme dans l'état où vous l'avez trouvée |

Heat est le service d'orchestration d'OpenStack. On lui donne un **modèle** (un fichier YAML) qui décrit
des ressources : réseaux, ports, VM, volumes… Heat les crée dans le bon ordre et les regroupe dans une
**pile** (*stack*). On modifie la pile en modifiant le modèle ; on la supprime d'une commande.

Le TP comporte trois parties, encadrées par l'ajout puis le retrait de Heat :

| Partie | Étapes | Ce que vous faites |
|---|---|---|
| Plateforme | 0 et 1 | Vérifier le lab, ajouter Heat |
| A. Prise en main | 2 à 4 | Lire un petit modèle, créer la pile, la regarder dans Horizon, la modifier |
| B. Le TP 13 en code | 5 à 8 | Reconstruire l'architecture du TP 13 avec Heat, et prouver que c'est la même |
| C. Niveau avancé | 9 | Modifier une ressource à la main, hors du modèle, et voir ce que Heat en sait |
| Plateforme | 10 et 11 | Tout nettoyer, retirer Heat, vérifier l'état de sortie |

## Objectifs

- Ajouter un service OpenStack à un déploiement existant, comme un exploitant, et en mesurer le coût.
- Lire un modèle Heat : paramètres, ressources, dépendances, sorties.
- Créer, mettre à jour et supprimer une pile, en ligne de commande et dans Horizon.
- Reconstruire l'architecture du TP 13 à partir d'un modèle, et vérifier qu'elle est identique.
- Situer les limites d'un modèle : ce qui reste hors de Heat, ce qui ne doit jamais y figurer, ce
  que Heat ne voit pas.
- Retirer un service et rendre la plateforme dans l'état où vous l'avez trouvée.

## Étape 0. Vérifier les conditions d'entrée

Le TP 14 reconstruit l'architecture du TP 13 avec les mêmes adresses et la même FIP. Il part donc
d'un lab sans aucun reste du TP 13, ni dans OpenStack ni sur l'hôte.

```bash
# [instance]
./openstack-lab-trainee/verify.sh | tail -1                  # "Résultat : 42 réussis, 0 échoués"
./openstack-lab-trainee/tps/tp14/verifier-entree.sh          # dernière ligne : "Lab prêt pour le TP 14."
```

`verifier-entree.sh` ne modifie rien. Il contrôle :

| Condition | Pourquoi | Si elle n'est pas remplie |
|---|---|---|
| OpenStack répond ; image `debian13` et gabarit `m1.1g` présents | les VM du TP 14 les utilisent | `verify.sh`, puis étape 0 du TP 12 |
| Aucune ressource `tp13`, FIP `10.0.2.150` libre | la pile recrée les mêmes adresses et la même FIP | étape 16 du TP 13 |
| Hôte sans route `192.168.121.0/24`, règle FORWARD `tp13`, configuration chrony du TP 13 ni Squid | le TP 14 les remet en place lui-même | étape 16 du TP 13 |
| Aucun reste `tp14-` | essai précédent du TP 14 | étape 10 du TP 14 |
| Heat absent et `ENABLE_HEAT=no` dans le scénario 04 | l'étape 1 l'ajoute | si Heat est déjà là (TP rejoué), passer à la fin de l'étape 1 |

Chaque écart est affiché avec ce qu'il faut faire. Ne commencez pas tant que la dernière ligne n'est
pas `Lab prêt pour le TP 14.`

## Étape 1. Ajouter Heat à un cloud en fonctionnement

Heat n'est pas déployé : il consomme de la mémoire, et aucun TP précédent n'en avait besoin. Vous
l'ajoutez maintenant, sans toucher aux autres services ni aux VM existantes.

Notez d'abord la mémoire disponible :

```bash
# [instance]
free -m | awk '/^Mem:/{print $7}'        # mémoire disponible, en Mo : notez la valeur
```

Activez Heat dans le scénario, puis relancez le déploiement :

```bash
# [instance]
sed -i 's/^ENABLE_HEAT=no$/ENABLE_HEAT=yes/' openstack-lab-trainee/scenarios/04-aio-complet.env
grep '^ENABLE_HEAT' openstack-lab-trainee/scenarios/04-aio-complet.env     # ENABLE_HEAT=yes
```

```bash
# [instance] : dans tmux (tmux new -s deploy), un quart d'heure environ
./openstack-lab-trainee/deploy.sh openstack-lab-trainee/scenarios/04-aio-complet.env
```

`deploy.sh` réécrit `/etc/kolla/globals.yml` à partir du scénario (`enable_heat: "yes"`), installe
le client `python-heatclient`, puis repasse sur tous les services : ceux qui n'ont pas changé ne sont
que vérifiés.

Vérifiez :

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
./openstack-lab-trainee/verify.sh | tail -1                  # 46 réussis, 0 échoués : une section "Heat" est apparue
openstack orchestration service list -c Binary -c Status     # heat-engine : up
openstack stack list                                         # vide, sans erreur
free -m | awk '/^Mem:/{print $7}'                            # comparez avec la valeur notée
```

Dans Horizon, un menu **Projet > Orchestration** est apparu. Si vous étiez déjà connecté à Horizon,
déconnectez-vous puis reconnectez-vous : les menus sont construits à la connexion, à partir de la
liste des services de ce moment-là.

> **Variante d'exploitant : ne déployer que ce qui change.** En production, on évite de repasser sur
> tous les services pour en ajouter un. Kolla-Ansible sait limiter le déploiement à certains rôles :
>
> ```bash
> # [instance]
> source ~/kolla/venv/bin/activate
> sed -i 's/^enable_heat: "no"/enable_heat: "yes"/' /etc/kolla/globals.yml   # à faire soi-même
> pip install python-heatclient -c https://releases.openstack.org/constraints/upper/2025.1
> kolla-ansible deploy -i ~/kolla/all-in-one --tags heat,horizon            # deux minutes environ
> ```
>
> `--tags heat,horizon` ne joue que le rôle de Heat (conteneurs, service et points d'accès dans
> Keystone) et celui d'Horizon (menu Orchestration). Cette commande ne lit pas le scénario : la
> modification de `globals.yml` et l'installation du client sont à faire vous-même. Modifiez aussi le
> scénario (`ENABLE_HEAT=yes`) : sinon, le prochain `deploy.sh` réécrira `enable_heat: "no"`.

## Étape 2. Lire un modèle

Ouvrez [partie-a.yaml](partie-a.yaml). Il décrit une VM CirrOS, son port, un security group
et une floating IP. Un modèle Heat a quatre parties :

| Partie | Dans `partie-a.yaml` | Rôle |
|---|---|---|
| `heat_template_version` | `2021-04-16` | Version du langage : elle fixe les fonctions disponibles |
| `parameters` | `prefixe`, `image`, `gabarit`, `cle`, `reseau`, `acces_admin` | Les valeurs qu'on peut changer sans toucher au modèle ; chacune a une valeur par défaut |
| `resources` | `groupe`, `port`, `vm`, `fip` | Les ressources à créer, chacune avec un type (`OS::Neutron::Port`…) et ses propriétés |
| `outputs` | `fip`, `adresse_privee` | Ce que la pile affiche une fois créée |

Trois fonctions reviennent partout :

- `get_param: prefixe` lit la valeur d'un paramètre ;
- `get_resource: groupe` désigne une autre ressource du modèle. C'est ce lien qui crée une
  **dépendance** : Heat crée le security group avant le port, et le port avant la VM ;
- `get_attr: [fip, floating_ip_address]` lit une propriété d'une ressource une fois créée.

Les noms sont construits avec `list_join` à partir du paramètre `prefixe` (`ht-tp14` par défaut) :
`ht-tp14-vm-demo`, `ht-tp14-sg-admin-demo`… Le préfixe `ht-` signale une ressource créée par Heat.

Faites valider le modèle par Heat avant de l'utiliser :

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
openstack orchestration template validate -t openstack-lab-trainee/tps/tp14/partie-a.yaml > /dev/null && echo "modèle valide"
```

## Étape 3. Créer la pile, la regarder

```bash
# [instance]
openstack stack create -t openstack-lab-trainee/tps/tp14/partie-a.yaml --wait ht-tp14-stack-demo
openstack stack resource list ht-tp14-stack-demo -c resource_name -c resource_type -c resource_status
openstack stack output show ht-tp14-stack-demo --all
```

`--wait` affiche les événements au fur et à mesure : relevez l'ordre de création, et comparez-le aux
dépendances de l'étape 2. Les quatre ressources doivent être `CREATE_COMPLETE`.

Dans Horizon, **Projet > Orchestration > Piles > `ht-tp14-stack-demo`** : regardez les onglets
**Topologie**, **Ressources**, **Événements** et **Modèle**. Les mêmes ressources apparaissent aussi dans
**Calcul > Instances** et **Réseau > Security groups**, comme si vous les aviez créées à la main.

La VM met une minute environ à démarrer : la deuxième commande attend que son SSH réponde.

```bash
# [instance]
F=$(openstack stack output show ht-tp14-stack-demo fip -f value -c output_value)
until nc -z -w 2 "$F" 22; do sleep 5; done; echo "la VM est prête"
ping -c 2 "$F"
ssh cirros@"$F" hostname                       # ht-tp14-vm-demo (acceptez la clé d'hôte : VM de test)
```

## Étape 4. Modifier la pile

Le paramètre `acces_admin` dit qui a le droit de joindre la VM en SSH et en ping. Donnez-lui une autre
adresse, sans toucher au modèle :

```bash
# [instance]
openstack stack update --existing --parameter acces_admin=10.0.2.2/32 --wait ht-tp14-stack-demo
ping -c 2 -W 2 "$F"                             # échec : l'hôte (10.0.2.1) n'est plus autorisé
openstack stack event list ht-tp14-stack-demo -f value -c resource_name -c resource_status
```

Dans la liste des événements, seul `groupe` est passé par `UPDATE_IN_PROGRESS`, puis
`UPDATE_COMPLETE`. La VM, le port et la FIP n'ont pas bougé : Heat compare le modèle et les paramètres
avec ceux de la création, et ne touche qu'aux ressources concernées.

Revenez à la valeur par défaut :

```bash
# [instance]
openstack stack update --existing --parameter acces_admin=10.0.2.1/32 --wait ht-tp14-stack-demo
ping -c 2 "$F"                                  # de nouveau : réponse
```

Gardez cette pile : vous la supprimerez à l'étape 10.

## Étape 5 (partie B). Préparer l'hôte, avant la pile

> **Note : le modèle de la partie B**
>
> [partie-b.yaml](partie-b.yaml) décrit toute l'architecture du TP 13, y compris les règles
> des security groups que vous avez écrites aux étapes 5 et 7. Ouvrez-le une fois le TP 13 terminé :
> vous y retrouverez vos propres choix, traduits en code.

Lisez le modèle en entier. Chaque bloc porte en commentaire l'étape du TP 13 qu'il remplace. Il ne
remplace pas tout : l'hôte n'est pas une ressource OpenStack, et Heat ne le connaît pas.

Les VM installent leurs paquets dès leur premier démarrage, par le proxy du bastion. Squid et chrony
doivent donc être prêts **avant** la pile. Refaites l'étape 4 du TP 13 :

```bash
# [instance]
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y squid
sudo cp -p /etc/squid/squid.conf /etc/squid/squid.conf.tp13-orig
sudo sed -i 's/^http_port 3128$/# http_port 3128   # TP 13 : écoute définie dans conf.d\/tp13.conf/' /etc/squid/squid.conf
grep -c '^http_port' /etc/squid/squid.conf            # 0
```

Écrivez de nouveau votre `/etc/squid/conf.d/tp13.conf` (TP 13, étape 4), puis :

```bash
# [instance] vérifier AVANT de redémarrer : ne redémarrer que si la configuration est valide
sudo squid -k parse > /tmp/squid-parse.txt 2>&1 && ! grep -E "WARNING|ERROR|FATAL" /tmp/squid-parse.txt \
  && sudo systemctl restart squid && echo "Squid redémarré"
sudo ss -ltnp | grep squid                           # 10.0.2.1:3128 seulement
```

```bash
# [instance]
sudo tee /etc/chrony/conf.d/tp13.conf > /dev/null <<'EOF'
# TP 13 : heure servie aux VM du réseau admin, sur l'adresse du bastion seulement
allow 192.168.121.0/24
bindaddress 10.0.2.1
EOF
sudo systemctl restart chrony
sudo iptables -C FORWARD -s 192.168.120.0/22 -o enX0 -m comment --comment tp13 -j DROP 2>/dev/null \
  || sudo iptables -A FORWARD -s 192.168.120.0/22 -o enX0 -m comment --comment tp13 -j DROP
sudo iptables -S FORWARD | grep tp13
```

Sur votre poste, recréez la clé d'administration des VM (le nettoyage du TP 13 l'a supprimée) :

```bash
# [poste]
ssh-keygen -q -t ed25519 -N "" -C tp13-keypair-adm-demo -f ~/.ssh/tp13-keypair-adm-demo
scp -i ec2_key ~/.ssh/tp13-keypair-adm-demo.pub ubuntu@<IP_PUBLIQUE>:
```

## Étape 6. Créer l'architecture du TP 13 avec Heat

La route de retour de l'hôte (TP 13, étape 3) passe par l'adresse du routeur adm sur `public1`, que
Neutron choisit à la création. Elle doit être posée avant que les VM ne démarrent. On lance donc la
pile **sans** `--wait`, on pose la route dès que le routeur existe, puis on attend la fin.

```bash
# [instance]
P=ht-tp13; PILE=ht-tp13-stack-demo
openstack stack create -t openstack-lab-trainee/tps/tp14/partie-b.yaml \
  --parameter cle_publique="$(cat ~/tp13-keypair-adm-demo.pub)" "$PILE" -f value -c id
until GW=$(openstack router show $P-router-adm-demo -f json -c external_gateway_info 2>/dev/null \
      | jq -r '.external_gateway_info.external_fixed_ips[0].ip_address // empty') && [ -n "$GW" ]; do
  sleep 2
done
sudo ip route replace 192.168.121.0/24 via "$GW" dev veth-ext
ip route get 192.168.121.11                          # via <GW> dev veth-ext src 10.0.2.1
until S=$(openstack stack show "$PILE" -f value -c stack_status) && [ "$S" != CREATE_IN_PROGRESS ]; do
  sleep 5
done; echo "$S"                                      # CREATE_COMPLETE
openstack stack output show "$PILE" --all
```

Regardez la topologie de la pile dans Horizon : les trois réseaux, les deux routeurs, les deux VM et
leurs cinq ports, comme sur le schéma du TP 13.

Attendez la fin de cloud-init dans les deux VM (deux à cinq minutes) :

```bash
# [instance]
for v in web-haproxy bdd; do
  until openstack console log show $P-vm-$v-demo | grep -q 'Cloud-init v.*finished'; do sleep 10; done
  echo "$P-vm-$v-demo : cloud-init terminé"
done
```

## Étape 7. Ce que Heat ne fait pas : accès, secret, base, application

Ces gestes sont ceux des étapes 8 à 10 du TP 13. Ils restent à faire à la main : le modèle crée
l'infrastructure, pas le contenu des VM, et ne doit jamais contenir de mot de passe.

**Accès par le bastion.** Récupérez le modèle de configuration SSH et vérifiez les clés d'hôte, comme
au TP 13 : ce sont de nouvelles VM, avec de nouvelles clés.

```bash
# [poste]
scp -i ec2_key ubuntu@<IP_PUBLIQUE>:openstack-lab-trainee/tps/tp13/ssh_config.exemple ~/.ssh/tp13_config
nano ~/.ssh/tp13_config        # remplacer <IP_PUBLIQUE> et <CHEMIN_EC2_KEY> (chemin complet de ec2_key)
```

```bash
# [instance] VM web, puis VM bdd : les deux empreintes de chaque VM doivent être identiques
openstack console log show $P-vm-web-haproxy-demo | sed -n '/BEGIN SSH HOST KEY FINGERPRINTS/,/END/p' | grep ED25519
ssh-keyscan -t ed25519 192.168.121.11 2>/dev/null | ssh-keygen -lf -
openstack console log show $P-vm-bdd-demo | sed -n '/BEGIN SSH HOST KEY FINGERPRINTS/,/END/p' | grep ED25519
ssh-keyscan -t ed25519 192.168.121.12 2>/dev/null | ssh-keygen -lf -
```

```bash
# [poste]
ssh -F ~/.ssh/tp13_config tp13-bastion 'ssh-keyscan -t ed25519 192.168.121.11 192.168.121.12 2>/dev/null' >> ~/.ssh/tp13_known_hosts
ssh-keygen -lf ~/.ssh/tp13_known_hosts       # les deux empreintes vues ci-dessus
ssh -F ~/.ssh/tp13_config tp13-vm-web-haproxy-demo 'hostname; echo "${SSH_CONNECTION%% *}"'   # client 10.0.2.1
```

**Secret et base.** Le volume chiffré existe et il est attaché : c'est la pile qui l'a créé. Son
identifiant est une sortie de la pile. Le secret, lui, est créé à la main : son nom commence par
`tp13-`, et non par `ht-`.

```bash
# [instance]
openstack stack output show "$PILE" volume_bdd -f value -c output_value     # à reporter plus bas : <ID_VOLUME>
F=$(mktemp)                                      # droits 600
openssl rand -base64 24 | tr -d '\n' > "$F"
openstack secret store --name tp13-barbican-bdd-demo --payload-content-type text/plain --file "$F" \
  -f value -c "Secret href"                      # à reporter plus bas : <HREF>
shred -u "$F"
```

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

Reprenez vos réglages du TP 13, étape 9 (`listen_addresses` et la ligne `host` de `pg_hba.conf`),
redémarrez PostgreSQL, puis créez l'utilisateur et la base :

```bash
# [poste] (une seule commande ; <HREF> : l'adresse « Secret href » affichée plus haut)
ssh -F ~/.ssh/tp13_config tp13-bastion 'source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh && openstack secret get --payload -f value -c Payload <HREF>' \
  | ssh -F ~/.ssh/tp13_config tp13-vm-bdd-demo 'IFS= read -r PW; printf "%s\n" "\\set pw '"'"'$PW'"'"'" "CREATE ROLE tp13app LOGIN PASSWORD :'"'"'pw'"'"';" "CREATE DATABASE tp13 OWNER tp13app;" | sudo runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q && echo "base créée"'
```

**Application.** Refaites l'étape 10 du TP 13 telle quelle : copie de l'application, mot de passe déposé
dans `/etc/tp13/db-password`, `installer-appli.sh`, puis ses trois contrôles.

## Étape 8. Est-ce bien la même architecture ?

Une architecture décrite en code n'a de valeur que si elle fait exactement ce que faisait la
construction à la main. La FIP `10.0.2.150` a été créée par la pile : vérifiez d'abord la page, puis
rejouez les tests de l'étape 12 du TP 13 (objectifs O1 à O8). Ils désignent les machines par leur
adresse, qui n'a pas changé.

```bash
# [instance]
curl -s http://10.0.2.150/ | grep 'data-test="etat-base"' | sed 's/<[^>]*>//g'   # Réussi : connectée à PostgreSQL 17…
```

> **Note : à confirmer avant de continuer**
>
> - [ ] Les tests autorisés de l'étape 12 du TP 13 réussissent, les tests interdits échouent, comme
>   au TP 13.
> - [ ] La page `http://10.0.2.150/` affiche « Réussi : connectée à PostgreSQL ».
> - [ ] Vous avez constaté les trois écarts ci-dessous, et vous savez expliquer chacun.
>
> Si un test donne un autre résultat qu'au TP 13, l'écart vient du modèle : comparez la ressource
> concernée avec la commande de l'étape correspondante du TP 13.

### Les écarts, et ce qu'ils signifient

```bash
# [instance]
openstack security group list --tags tp13 -f value -c Name | wc -l     # 0 : aucun security group étiqueté
openstack floating ip list --long --floating-ip-address 10.0.2.150 -f value -c Description -c Tags
                                                                       # " []" : description vide, aucune étiquette
for g in web data-bdd; do
  openstack security group rule list $P-sg-$g-demo --egress -f value -c "Remote Security Group" | wc -l
done                                                                   # 1 et 1 : une sortie de plus
```

| Écart avec le TP 13 | Pourquoi | Conséquence | Ce qu'on fait |
|---|---|---|---|
| Les security groups n'ont pas l'étiquette `tp13` | La ressource Heat `OS::Neutron::SecurityGroup` n'a pas de propriété `tags` | L'inventaire par étiquette (O8) ne les trouve pas | Étiquette posée après la pile, hors du modèle (ci-dessous) |
| La FIP n'a ni étiquette ni description `FIP_PUBLICATION` | `OS::Neutron::FloatingIP` n'a ni `tags` ni `description` | La FIP ne se retrouve plus par son étiquette ni par sa description | Idem |
| Les security groups web et data-bdd ont une règle de sortie de plus, vers leur propre security group | Heat ne retire les sorties par défaut (vers tout, IPv4 et IPv6) que si le security group déclare au moins une sortie | Aucune : la règle n'autorise que les ports du même security group, c'est-à-dire le port lui-même | Règle gardée, et commentée dans le modèle |

Sans la règle de sortie de plus, ces deux security groups garderaient leurs sorties par défaut vers
tout : la VM web pourrait tenter de sortir par sa carte pub. C'est le genre d'écart qu'un modèle peut
cacher, et que seuls les tests négatifs révèlent.

Posez ce que Heat ne sait pas poser, puis vérifiez O8 :

```bash
# [instance]
for g in web adm data-web data-bdd; do openstack security group set --tag tp13 $P-sg-$g-demo; done
F=$(openstack floating ip list --floating-ip-address 10.0.2.150 -f value -c ID)
openstack floating ip set --tag tp13 --description FIP_PUBLICATION "$F"
openstack security group list --tags tp13 -f value -c Name | wc -l     # 4
```

Ces commandes modifient des ressources de la pile en dehors du modèle. Heat ne gère pas ces
propriétés : une mise à jour de la pile ne les effacera pas, mais le modèle ne les décrit pas non plus.
Notez-le dans le dépôt qui contient le modèle.

Pour O8, le volume, le type de volume et la clé portent maintenant le préfixe `ht-tp13-` ; le secret,
créé à la main, garde `tp13-`.

### Synthèse : construire à la main ou décrire en code

| | TP 13 : commande par commande | TP 14 : modèle Heat |
|---|---|---|
| Comprendre | Chaque brique est vue, nommée, vérifiée ; le diagnostic se fait couche par couche | Le modèle montre l'ensemble et les dépendances ; le détail de chaque appel est caché |
| Construire | Une quarantaine de blocs de commandes, dans un ordre imposé | Une commande ; Heat déduit l'ordre des dépendances |
| Refaire à l'identique | Rejouer tous les blocs sans erreur ni oubli | Rejouer le même fichier ; il se range et se compare dans git |
| Modifier | Une commande ciblée ; rien ne garde trace de l'état voulu | `openstack stack update` : seules les ressources modifiées changent, les autres restent en place |
| Détruire | Nettoyage en ordre inverse, étape par étape | `openstack stack delete` |
| Ce qui reste à la main | Tout | L'hôte (route, pare-feu, proxy, heure), le secret de la base, l'installation dans les VM, les propriétés que Heat ne gère pas |
| Risques | Oubli, faute de frappe, ressource restée d'un essai | Limite d'une ressource Heat qui change le résultat sans erreur (sorties par défaut) ; modifications faites à la main hors du modèle (étape 9) |
| Coût | Aucun service en plus | Le service Heat, qui consomme de la mémoire en permanence |

Les deux méthodes se complètent : on apprend une architecture en la construisant à la main, puis on
la décrit en code pour la reproduire, la faire relire et la modifier sans surprise. Le modèle ne
dispense pas des tests : ce sont eux qui ont révélé l'écart des sorties par défaut.

## Étape 9 (niveau avancé). Une modification hors du modèle

Un collègue « dépanne » en ajoutant à la main une sortie HTTPS vers tout dans le security group web.
Que voit Heat ?

```bash
# [instance]
R=$(openstack security group rule create --egress --protocol tcp --dst-port 443 --remote-ip 0.0.0.0/0 \
    --description "ajout à la main" $P-sg-web-demo -f value -c id)
openstack stack check "$PILE" > /dev/null
until S=$(openstack stack show "$PILE" -f value -c stack_status) && [ "$S" != CHECK_IN_PROGRESS ]; do sleep 3; done; echo "$S"
openstack stack update --existing --wait "$PILE" > /dev/null
openstack security group rule list $P-sg-web-demo --egress -f value -c "IP Protocol" -c "Port Range" -c "IP Range"
```

`stack check` répond `CHECK_COMPLETE` : il vérifie que les ressources existent, pas qu'elles sont
conformes au modèle. `stack update` avec le même modèle ne change rien : Heat compare le modèle avec
celui de la dernière mise à jour, pas avec l'état réel. La règle ajoutée à la main est toujours là.

Retirez-la, puis répondez à la question 7.

```bash
# [instance]
openstack security group rule delete "$R"
openstack security group rule list $P-sg-web-demo --egress -f value | wc -l      # 1 : la sortie d'origine
```

## Étape 10. Nettoyage

La pile emporte tout ce qu'elle a créé, dans l'ordre inverse des dépendances :

```bash
# [instance]
openstack stack delete -y --wait "$PILE"
openstack stack delete -y --wait ht-tp14-stack-demo
openstack secret delete "$(openstack secret list --name tp13-barbican-bdd-demo -f value -c 'Secret href')"
rm -f ~/tp13-keypair-adm-demo.pub /tmp/squid-parse.txt
```

L'hôte, lui, n'est pas dans la pile. Défaites-le comme à l'étape 16 du TP 13 :

```bash
# [instance] l'hôte
sudo iptables -D FORWARD -s 192.168.120.0/22 -o enX0 -m comment --comment tp13 -j DROP
sudo ip route del 192.168.121.0/24 dev veth-ext
sudo rm -f /etc/chrony/conf.d/tp13.conf && sudo systemctl restart chrony
sudo rm -f /etc/squid/conf.d/tp13.conf
sudo mv /etc/squid/squid.conf.tp13-orig /etc/squid/squid.conf
sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y \
  squid squid-common squid-langpack libecap3 libdbi-perl libltdl7 libtdb1 ssl-cert
sudo rm -rf /var/log/squid /var/spool/squid
```

```bash
# [poste]
rm -f ~/.ssh/tp13-keypair-adm-demo ~/.ssh/tp13-keypair-adm-demo.pub ~/.ssh/tp13_known_hosts ~/.ssh/tp13_config
```

## Étape 11. Retirer Heat et rendre la plateforme

Kolla-Ansible ne sait pas désinstaller un service : remettre `enable_heat: "no"` ne fait que
l'ignorer. Les conteneurs continueraient de tourner, et le service resterait inscrit dans Keystone.
On le retire donc pas à pas, dans cet ordre.

**Arrêter Heat tant qu'il est encore activé.** Kolla-Ansible n'applique le rôle d'un service qu'aux
machines où il est activé : avec `enable_heat: "no"`, `stop --tags heat` n'arrêterait rien.

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
kolla-ansible stop -i ~/kolla/all-in-one --tags heat --yes-i-really-really-mean-it
```

**Supprimer les conteneurs et leurs unités systemd.** Les unités restent activées après l'arrêt : au
prochain redémarrage de l'instance, elles relanceraient Heat.

```bash
# [instance]
U="kolla-heat_api-container.service kolla-heat_api_cfn-container.service kolla-heat_engine-container.service"
sudo systemctl disable $U
for u in $U; do sudo rm -f /etc/systemd/system/$u; done
sudo systemctl daemon-reload
sudo docker rm heat_api heat_api_cfn heat_engine
sudo rm -rf /etc/kolla/heat-api /etc/kolla/heat-api-cfn /etc/kolla/heat-engine /var/log/kolla/heat
```

**Retirer Heat de Keystone et de la base de données.**

```bash
# [instance]
openstack service delete heat heat-cfn                    # supprime aussi les points d'accès
openstack user delete heat
openstack user delete --domain heat_user_domain heat_domain_admin
openstack domain set --disable heat_user_domain && openstack domain delete heat_user_domain
openstack role delete heat_stack_owner heat_stack_user
MDP=$(sudo awk '/^database_password:/{print $2}' /etc/kolla/passwords.yml)
sudo docker exec mariadb mariadb -uroot -p"$MDP" -e "DROP DATABASE heat; DROP USER 'heat'@'%';"
```

**Remettre la configuration à « sans Heat » et reconfigurer Horizon.**

```bash
# [instance]
sed -i 's/^ENABLE_HEAT=yes$/ENABLE_HEAT=no/' openstack-lab-trainee/scenarios/04-aio-complet.env
sed -i 's/^enable_heat: "yes"/enable_heat: "no"/' /etc/kolla/globals.yml
kolla-ansible reconfigure -i ~/kolla/all-in-one --tags horizon
sudo docker rmi $(sudo docker images -q 'quay.io/openstack.kolla/heat-*')
pip uninstall -y python-heatclient
```

**Vérifier l'état de sortie.** La plateforme doit être revenue à l'état d'entrée du TP : le même contrôle
qu'à l'étape 0 doit répondre de la même façon.

```bash
# [instance]
./openstack-lab-trainee/verify.sh | tail -1                  # 42 réussis, 0 échoués : plus de section "Heat"
./openstack-lab-trainee/tps/tp14/verifier-entree.sh          # "Lab prêt pour le TP 14." : Heat absent, ENABLE_HEAT=no
free -m | awk '/^Mem:/{print $7}'                            # la mémoire est revenue
```

Dans Horizon, après une nouvelle connexion, le menu Orchestration a disparu.

## Questions

1. Pourquoi faut-il arrêter Heat avec `kolla-ansible stop --tags heat` **avant** de remettre
   `enable_heat: "no"` ?
2. L'ajout ciblé (`deploy --tags heat,horizon`) est bien plus rapide qu'une relance de `deploy.sh`.
   Quel risque crée-t-il si l'on oublie de modifier aussi le scénario ?
3. À l'étape 4, quelles ressources la mise à jour a-t-elle modifiées ? Pourquoi la VM n'a-t-elle pas
   été recréée ?
4. Pourquoi la route de l'hôte doit-elle être posée avant que les VM ne démarrent ? Que se
   passerait-il sinon, et comment le verriez-vous ?
5. Pourquoi le mot de passe de la base n'est-il ni dans le modèle, ni dans un paramètre de la pile ?
6. Quelle règle de sortie Heat ajoute-t-on aux security groups web et data-bdd, et pourquoi n'ouvre-t-elle
   aucun flux ? Comment l'écart aurait-il été découvert sans le test négatif ?
7. À l'étape 9, pourquoi ni `stack check` ni `stack update` ne voient-ils la règle ajoutée à la main ?
   Quelles règles d'équipe et quels contrôles éviteraient cette situation ?
8. Citez deux situations où vous construiriez à la main, et deux où vous écririez un modèle.

## Validation

- [ ] Heat ajouté, mémoire relevée avant et après ; menu Orchestration visible dans Horizon.
- [ ] Modèle de la partie A lu : paramètres, ressources, dépendances, sorties expliqués.
- [ ] Pile créée, regardée dans Horizon, modifiée par un paramètre ; test négatif (ping refusé) fait.
- [ ] Architecture du TP 13 créée par Heat ; route posée avant le démarrage des VM.
- [ ] Clés d'hôte comparées aux empreintes de la console ; base et application en place.
- [ ] Tests de l'étape 12 du TP 13 rejoués : mêmes résultats ; trois écarts constatés et expliqués.
- [ ] Modification hors du modèle constatée, puis retirée (étape 9).
- [ ] Nettoyage complet ; Heat retiré ; `verify.sh` sans échec ; `verifier-entree.sh` : lab prêt.

## Sources

- Heat, guide des modèles : <https://docs.openstack.org/heat/2025.1/template_guide/>
- Heat, spécification HOT (fonctions `get_param`, `get_resource`, `get_attr`, `list_join`) : <https://docs.openstack.org/heat/2025.1/template_guide/hot_spec.html>
- Heat, types de ressources OpenStack : <https://docs.openstack.org/heat/2025.1/template_guide/openstack.html>
- Client `openstack stack` : <https://docs.openstack.org/python-heatclient/latest/cli/stack.html>
- Kolla-Ansible, exploitation (`deploy`, `stop`, `reconfigure`, `--tags`) : <https://docs.openstack.org/kolla-ansible/2025.1/user/operating-kolla.html>
- Toutes les sources du parcours : [sources.md](../sources.md)
