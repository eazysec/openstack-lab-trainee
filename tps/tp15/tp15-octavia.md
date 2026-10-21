# TP 15 (bonus). Répartir la charge avec Octavia

| | |
|---|---|
| Prérequis | TP 00 à 12 ; TP 08 et 08 bis (Barbican, ACL) ; scénario 04 déployé ; le TP 13 aide (HAProxy installé à la main) |
| Durée | une demi-journée (estimé) |
| À la fin du TP | Vous avez ajouté un service de répartition de charge à un cloud en fonctionnement, placé deux serveurs web derrière un répartiteur, observé la bascule quand l'un tombe, publié le site en HTTPS avec un certificat rangé dans Barbican puis renouvelé, réduit les accès au plus juste, puis retiré le service |

Octavia est le service de répartition de charge d'OpenStack. On lui demande un **répartiteur**
(*load balancer*) ; il démarre une VM dédiée, l'**amphore**, qui fait tourner HAProxy. On décrit
ensuite ce qu'elle publie : un **écouteur** (*listener* : un protocole et un port), un **groupe** de
serveurs (*pool*), ses **membres**, et un **contrôle de santé** (*health monitor*).

Au TP 13, vous avez installé HAProxy vous-même dans une VM. Ici, Octavia le fait pour vous : la
comparaison est l'objet de la dernière question.

| Partie | Étapes | Ce que vous faites |
|---|---|---|
| Plateforme | 0 et 1 | Vérifier le lab, ajouter Octavia, regarder ce qu'il a créé |
| A. Premier répartiteur | 2 à 4 | Deux serveurs web, un répartiteur, la bascule quand un serveur tombe |
| B. HTTPS | 5 et 6 | Certificat dans Barbican, accès d'Octavia au secret, renouvellement, redirection HTTP vers HTTPS |
| C. Au plus juste | 7 | Qui peut joindre le site ; ce qu'un membre du projet voit de l'amphore |
| Plateforme | 8 et 9 | Tout nettoyer, retirer Octavia, vérifier l'état de sortie |

## Objectifs

- Ajouter un service OpenStack à un déploiement existant et en mesurer le coût.
- Créer un répartiteur, un écouteur, un groupe, ses membres et un contrôle de santé ; observer la
  bascule.
- Terminer le HTTPS sur le répartiteur avec un certificat rangé dans Barbican, puis le renouveler.
- Limiter les clients du site, et savoir ce qu'un projet voit ou ne voit pas de l'amphore.
- Retirer un service et rendre la plateforme dans l'état où vous l'avez trouvée.

## Étape 0. Vérifier les conditions d'entrée

```bash
# [instance]
./openstack-lab-trainee/verify.sh | tail -1                  # "Résultat : 42 réussis, 0 échoués"
./openstack-lab-trainee/tps/tp15/verifier-entree.sh          # dernière ligne : "Lab prêt pour le TP 15."
```

`verifier-entree.sh` ne modifie rien. Il contrôle :

| Condition | Pourquoi | Si elle n'est pas remplie |
|---|---|---|
| OpenStack répond ; `mykey`, `public1`, `cirros`, `m1.tiny` présents | les VM du TP les utilisent | relancer `deploy.sh` (TP 01) |
| Barbican présent | partie B (HTTPS) | scénario 04 (TP 08, étape 0) |
| Aucun reste `tp15-`, ni FIP étiquetée `tp15`, ni dossier `~/tp15` | essai précédent | étape 8 |
| Octavia absent et `ENABLE_OCTAVIA=no` dans le scénario 04 ; ni conteneur `octavia`, ni interface `o-hm0`, ni unité `octavia-interface` | l'étape 1 l'ajoute ; un retrait inachevé laisse ces traces | si Octavia est déjà là (TP rejoué), passer à la fin de l'étape 1 ; sinon étape 9 |

La mémoire disponible est affichée : notez-la. Chaque écart est affiché avec ce qu'il faut faire. Ne
commencez pas tant que la dernière ligne n'est pas `Lab prêt pour le TP 15.`

## Étape 1. Ajouter Octavia à un cloud en fonctionnement

Octavia n'est pas déployé : il consomme de la mémoire, et chaque répartiteur démarre une VM. Vous
l'ajoutez comme Heat au TP 14 : en modifiant le scénario, puis en relançant le déploiement.

```bash
# [instance]
free -m | awk '/^Mem:/{print $7}'        # mémoire disponible, en Mo : notez la valeur
sed -i 's/^ENABLE_OCTAVIA=no$/ENABLE_OCTAVIA=yes/' openstack-lab-trainee/scenarios/04-aio-complet.env
grep '^ENABLE_OCTAVIA' openstack-lab-trainee/scenarios/04-aio-complet.env     # ENABLE_OCTAVIA=yes
```

```bash
# [instance] : dans tmux (tmux new -s deploy), un quart d'heure environ
./openstack-lab-trainee/deploy.sh openstack-lab-trainee/scenarios/04-aio-complet.env
```

En plus de `enable_octavia: "yes"`, `deploy.sh` :

- installe le client (`openstack loadbalancer …`) et `dhclient` (paquet `isc-dhcp-client`) ;
- fait générer par Kolla-Ansible une autorité de certification et les certificats qui protègent le
  dialogue entre les services d'Octavia et les amphores (`/etc/kolla/config/octavia`) ;
- télécharge l'image des amphores et l'enregistre dans le projet `service`, avec l'étiquette
  `amphora` par laquelle Octavia la choisit.

Vérifiez, et regardez ce qui a été créé :

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
./openstack-lab-trainee/verify.sh | tail -1                    # 42 réussis, 0 échoués
openstack loadbalancer provider list                           # amphora
openstack image list --tag amphora -c Name -c Status           # l'image des amphores
grep 'SHA-256 de l' ~/kolla/deploy-*.log | tail -1             # son empreinte, relevée au téléchargement
openstack network list -c Name                                 # lb-mgmt-net : le réseau de gestion
ip -br addr show o-hm0                                         # l'hôte branché sur ce réseau
ip route show default                                          # inchangée : toujours par l'interface d'administration
free -m | awk '/^Mem:/{print $7}'                              # comparez avec la valeur notée
```

Les services d'Octavia (sur l'hôte) parlent aux amphores (des VM) par un réseau de gestion,
`lb-mgmt-net`. L'hôte y est relié par l'interface `o-hm0`, branchée sur le commutateur virtuel de
Neutron : c'est le mode prévu par Kolla-Ansible pour les essais. Sa route par défaut n'a pas changé.

> **Provenance de l'image.** L'image des amphores est une image **de test** du projet Octavia
> (`test-only-amphora-…`), reconstruite chaque nuit et publiée **sans empreinte**. On ne peut donc pas
> vérifier qu'on a reçu le bon fichier ; `deploy.sh` note seulement son empreinte au téléchargement.
> En production, on construit soi-même l'image (outil `diskimage-builder`), on la signe, et on
> la met à jour comme tout système : chaque amphore est une VM exposée sur le réseau.

## Étape 2 (partie A). Deux serveurs web

Un réseau, un routeur (la floating IP du site en aura besoin), et un security group qui n'ouvre le
port 80 qu'au sous-réseau : c'est par là que l'amphore joindra les serveurs.

```bash
# [instance]
openstack network create --tag tp15 tp15-network-web-demo
openstack subnet create --network tp15-network-web-demo --subnet-range 192.168.150.0/24 tp15-subnet-web-demo
openstack router create --tag tp15 tp15-router-demo
openstack router set --external-gateway public1 tp15-router-demo
openstack router add subnet tp15-router-demo tp15-subnet-web-demo
openstack security group create --tag tp15 tp15-sg-web-demo
openstack security group rule create --protocol tcp --dst-port 80 --remote-ip 192.168.150.0/24 tp15-sg-web-demo
```

Chaque serveur publie son nom avec le serveur web de busybox, lancé au premier démarrage :

```bash
# [instance]
mkdir -p ~/tp15 && cat > ~/tp15/web.sh <<'EOF'
#!/bin/sh
mkdir -p /tmp/www && hostname > /tmp/www/index.html && httpd -p 80 -h /tmp/www
EOF
for n in 1 2; do
  openstack server create --image cirros --flavor m1.tiny --network tp15-network-web-demo \
    --security-group tp15-sg-web-demo --user-data ~/tp15/web.sh --wait tp15-vm-web$n-demo -c status -f value
done
```

## Étape 3. Le répartiteur

```bash
# [instance] : l'amphore démarre ; cinq minutes environ sur le lab (VM émulée, sans KVM)
openstack loadbalancer create --name tp15-lb-web-demo --vip-subnet-id tp15-subnet-web-demo --wait
openstack loadbalancer show tp15-lb-web-demo -c vip_address -c provisioning_status -c operating_status
openstack loadbalancer amphora list -c id -c role -c lb_network_ip -c ha_ip    # l'amphore (vue admin)
openstack server list --all-projects -c Name -c Status | grep amphora           # une VM du projet service
free -m | awk '/^Mem:/{print $7}'
```

L'amphore a deux adresses : une sur `lb-mgmt-net` (`lb_network_ip`), par laquelle Octavia la pilote,
et une sur votre sous-réseau (`ha_ip`), par laquelle elle joint les serveurs.

Décrivez ce qu'elle publie : un écouteur HTTP, un groupe en tourniquet, les deux membres, et un
contrôle de santé qui interroge `/` toutes les 5 secondes.

```bash
# [instance]
openstack loadbalancer listener create --name tp15-listener-http-demo --protocol HTTP --protocol-port 80 \
  --wait tp15-lb-web-demo
openstack loadbalancer pool create --name tp15-pool-web-demo --lb-algorithm ROUND_ROBIN --protocol HTTP \
  --listener tp15-listener-http-demo --wait
for n in 1 2; do
  IP=$(openstack server show tp15-vm-web$n-demo -f json -c addresses \
    | python3 -c "import json,sys; print(list(json.load(sys.stdin)['addresses'].values())[0][0])")
  openstack loadbalancer member create --name tp15-member-web$n-demo --subnet-id tp15-subnet-web-demo \
    --address $IP --protocol-port 80 --wait tp15-pool-web-demo
done
openstack loadbalancer healthmonitor create --name tp15-hm-web-demo --type HTTP --url-path / \
  --delay 5 --timeout 3 --max-retries 2 --wait tp15-pool-web-demo
```

Publiez le site par une floating IP, posée sur l'adresse du répartiteur (le *VIP*) :

```bash
# [instance]
FIP=$(openstack floating ip create public1 --description FIP_PUBLICATION --tag tp15 \
  -f value -c floating_ip_address)
openstack floating ip set --port "$(openstack loadbalancer show tp15-lb-web-demo -f value -c vip_port_id)" $FIP
until openstack loadbalancer member list tp15-pool-web-demo -f value -c operating_status \
  | sort -u | grep -qx ONLINE; do sleep 5; done
openstack loadbalancer member list tp15-pool-web-demo -c name -c operating_status
for i in $(seq 10); do curl -s http://$FIP/; done | sort | uniq -c     # 5 et 5 : le tourniquet
```

## Étape 4. Un serveur tombe

`pause` gèle la VM : elle ne répond plus, comme un serveur bloqué.

```bash
# [instance]
openstack server pause tp15-vm-web1-demo
until [ "$(openstack loadbalancer member show tp15-pool-web-demo tp15-member-web1-demo \
  -f value -c operating_status)" = ERROR ]; do sleep 2; done
openstack loadbalancer show tp15-lb-web-demo -f value -c operating_status          # DEGRADED
for i in $(seq 10); do curl -s http://$FIP/; done | sort | uniq -c                  # 10 : tout va au serveur 2
openstack server unpause tp15-vm-web1-demo
until [ "$(openstack loadbalancer member show tp15-pool-web-demo tp15-member-web1-demo \
  -f value -c operating_status)" = ONLINE ]; do sleep 2; done
for i in $(seq 10); do curl -s http://$FIP/; done | sort | uniq -c                  # de nouveau 5 et 5
```

Mesuré sur le lab : membre en erreur environ 40 secondes après la pause, de retour environ
15 secondes après la reprise. Aucune requête n'a échoué : le contrôle de santé a retiré le serveur,
puis l'a remis.

## Étape 5 (partie B). HTTPS avec un certificat rangé dans Barbican

Le répartiteur peut terminer le HTTPS : il déchiffre, puis parle aux serveurs en HTTP sur le réseau
interne. Il lit son certificat et sa clé dans Barbican, sous forme d'un fichier PKCS#12.

Le certificat est **auto-signé**, par simplicité : les navigateurs le refuseront. En production, il
serait signé par une autorité de certification reconnue.

```bash
# [instance]
cd ~/tp15
openssl req -x509 -newkey rsa:2048 -nodes -keyout cle.pem -out cert.pem -days 30 \
  -subj "/CN=tp15.lab.example" -addext "subjectAltName=IP:$FIP"
openssl pkcs12 -export -inkey cle.pem -in cert.pem -passout pass: -out tls.p12
base64 -w0 tls.p12 | wc -c          # quelques milliers d'octets : sous la limite de Barbican (TP 08)
H=$(openstack secret store --name tp15-barbican-tls-demo --payload-content-type application/octet-stream \
  --payload-content-encoding base64 --payload "$(base64 -w0 tls.p12)" -f value -c "Secret href")
openstack acl get $H -c Users       # personne d'autre que vous
cd ~
```

Créez l'écouteur HTTPS. Il réutilise le groupe de serveurs de l'écouteur HTTP :

```bash
# [instance]
openstack loadbalancer listener create --name tp15-listener-https-demo --protocol TERMINATED_HTTPS \
  --protocol-port 443 --default-tls-container-ref $H --default-pool tp15-pool-web-demo --wait tp15-lb-web-demo
openstack acl get $H -c Users                         # un utilisateur est apparu
openstack user show "$(openstack acl get $H -f value -c Users | tr -d "[]'")" -c name -f value
```

Octavia s'est donné le droit de lire le secret : à la création de l'écouteur, il a ajouté son propre
compte (`octavia`) à la liste d'accès du secret, avec vos droits. Sans cela, l'amphore ne pourrait
pas obtenir la clé.

```bash
# [instance]
for i in 1 2 3 4; do curl -sk https://$FIP/; done      # -k : certificat auto-signé
curl -s https://$FIP/ ; echo "code $?"                 # sans -k : refusé (code 60)
openssl x509 -in ~/tp15/cert.pem -noout -fingerprint -sha256
openssl s_client -connect $FIP:443 </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256
```

Les deux empreintes sont identiques : le répartiteur présente bien votre certificat.

**Renouveler le certificat.** Un secret ne se modifie pas (TP 08 bis) : on en range un nouveau, on
le donne à l'écouteur, puis on retire l'ancien. Le site ne s'interrompt pas.

```bash
# [instance]
cd ~/tp15
openssl req -x509 -newkey rsa:2048 -nodes -keyout cle2.pem -out cert2.pem -days 30 \
  -subj "/CN=tp15.lab.example" -addext "subjectAltName=IP:$FIP"
openssl pkcs12 -export -inkey cle2.pem -in cert2.pem -passout pass: -out tls2.p12
H2=$(openstack secret store --name tp15-barbican-tls2-demo --payload-content-type application/octet-stream \
  --payload-content-encoding base64 --payload "$(base64 -w0 tls2.p12)" -f value -c "Secret href")
cd ~
openstack loadbalancer listener set --default-tls-container-ref $H2 --wait tp15-listener-https-demo
openssl s_client -connect $FIP:443 </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256
openssl x509 -in ~/tp15/cert2.pem -noout -fingerprint -sha256      # identique : le nouveau est servi
openstack acl get $H -c Users                         # l'ancien secret : Octavia peut toujours le lire
openstack secret delete $H                            # on le retire, avec ses accès
```

L'accès d'Octavia à l'ancien secret ne disparaît pas tout seul : on le supprime avec le secret.

## Étape 6. Rediriger HTTP vers HTTPS

Une règle de niveau 7 (sur le contenu de la requête) renvoie toute requête HTTP vers le HTTPS. Une
politique sans règle ne s'applique à rien : la règle « le chemin commence par `/` » couvre tout.
Chaque modification est poussée dans l'amphore : sans `--wait`, la commande suivante est refusée
(`409 … is immutable and cannot be updated`) tant que le répartiteur n'est pas revenu à `ACTIVE`.

```bash
# [instance]
openstack loadbalancer l7policy create --name tp15-l7-https-demo --action REDIRECT_PREFIX \
  --redirect-prefix https://$FIP --wait tp15-listener-http-demo
openstack loadbalancer l7rule create --type PATH --compare-type STARTS_WITH --value / --wait tp15-l7-https-demo
curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' http://$FIP/page    # 302 -> https://…/page
```

`l7rule create --wait` affiche `<identifiant> not found (HTTP 404)` : le client ne retrouve pas la
règle pendant son attente. La règle est pourtant créée, et appliquée : la redirection répond `302`.

## Étape 7 (partie C). Au plus juste

**Qui peut joindre le site ?** Le port du VIP porte un security group créé par Octavia, dans le
projet `service` :

```bash
# [instance]
SGVIP=$(openstack port show "$(openstack loadbalancer show tp15-lb-web-demo -f value -c vip_port_id)" \
  -f json -c security_group_ids | python3 -c "import json,sys; print(json.load(sys.stdin)['security_group_ids'][0])")
openstack security group show $SGVIP -c name -c project_id
openstack security group rule list $SGVIP -c "IP Protocol" -c "IP Range" -c "Port Range" -c Direction
```

Les ports 80 et 443 sont ouverts à `0.0.0.0/0`. Ce groupe n'appartient pas à votre projet : on ne le
modifie pas, on demande à Octavia de limiter les clients de chaque écouteur (`--allowed-cidr`).
L'hôte joint le site depuis `10.0.2.1` :

```bash
# [instance]
openstack loadbalancer listener set --allowed-cidr 192.0.2.0/24 --wait tp15-listener-https-demo
curl -sk -m 5 https://$FIP/ ; echo "code $?"           # 28 : l'hôte n'est pas dans la liste
openstack security group rule list $SGVIP -c "IP Range" -c "Port Range" | grep 443
openstack loadbalancer listener set --allowed-cidr 10.0.2.0/24 --wait tp15-listener-https-demo
curl -sk -m 5 https://$FIP/                             # accepté
```

**Ce qu'un membre du projet voit de l'amphore.** Un projet `tp15-proj-equipe`, un utilisateur
`member` :

```bash
# [instance]
openstack project create tp15-proj-equipe
openstack user create --project tp15-proj-equipe --password-prompt tp15-user-equipe   # choisir un mot de passe
openstack role add --project tp15-proj-equipe --user tp15-user-equipe member
read -rsp "Mot de passe de tp15-user-equipe : " MDP15; echo
moi() { OS_USERNAME=tp15-user-equipe OS_PROJECT_NAME=tp15-proj-equipe OS_PASSWORD="$MDP15" "$@"; }
moi openstack loadbalancer list                    # vide : le répartiteur de l'admin ne lui est pas visible
moi openstack loadbalancer amphora list            # refusé (403) : les amphores sont l'affaire de l'exploitant
moi openstack loadbalancer provider list           # accepté
```

Un membre peut créer ses propres répartiteurs (rôle `member`, mesuré sur le lab) ; il ne voit
jamais les amphores, ni leur réseau, ni leur image. Il ne peut ni s'y connecter, ni les mettre à
jour : c'est l'exploitant qui en a la charge.

## Étape 8. Nettoyage

Un répartiteur en cours de création ne se supprime pas : attendez qu'il soit `ACTIVE`.
`--cascade` supprime aussi ses écouteurs, groupes, membres et règles ; l'amphore disparaît avec lui.

```bash
# [instance]
openstack user delete tp15-user-equipe; openstack project delete tp15-proj-equipe
unset -f moi; unset MDP15
openstack loadbalancer delete --cascade --wait tp15-lb-web-demo
openstack acl get $H2 -c Users                  # Octavia peut toujours lire le secret restant
openstack secret delete $H2
openstack floating ip delete $FIP
openstack server delete --wait tp15-vm-web1-demo tp15-vm-web2-demo
openstack router remove subnet tp15-router-demo tp15-subnet-web-demo
openstack router unset --external-gateway tp15-router-demo
openstack router delete tp15-router-demo
openstack network delete tp15-network-web-demo
openstack security group delete tp15-sg-web-demo
rm -r ~/tp15; unset FIP H H2 SGVIP IP
openstack loadbalancer amphora list               # vide
```

## Étape 9. Retirer Octavia et rendre la plateforme

Comme Heat au TP 14 : Kolla-Ansible ne sait pas désinstaller un service. On le retire pas à pas, et
il y a plus à retirer : une interface de l'hôte, un réseau, une image, des certificats.

**Arrêter Octavia tant qu'il est encore activé**, puis supprimer ses conteneurs et leurs unités :

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
kolla-ansible stop -i ~/kolla/all-in-one --tags octavia --yes-i-really-really-mean-it
U=$(systemctl list-unit-files 'kolla-octavia_*' --no-legend | awk '{print $1}')
sudo systemctl disable $U
for u in $U; do sudo rm -f /etc/systemd/system/$u; done
sudo docker rm $(sudo docker ps -aq --filter name=octavia)
sudo docker volume rm octavia_driver_agent
```

**Débrancher l'hôte du réseau de gestion** : l'unité `octavia-interface`, l'interface `o-hm0` et son
port sur le commutateur de Neutron.

```bash
# [instance]
sudo systemctl disable --now octavia-interface.service      # rend l'adresse (dhclient -r)
sudo rm -f /etc/systemd/system/octavia-interface.service /etc/dhcp/octavia-dhclient.conf
sudo systemctl daemon-reload
sudo docker exec openvswitch_vswitchd ovs-vsctl del-port br-int o-hm0
ip -br link | grep -c o-hm0                                  # 0
ip route show default                                        # inchangée
```

**Retirer ce qu'Octavia a créé dans OpenStack** : réseau de gestion, security groups, gabarit,
image, paire de clés, service, compte et rôles.

```bash
# [instance]
for p in $(openstack port list --network lb-mgmt-net -f value -c ID); do openstack port delete $p; done
openstack network delete lb-mgmt-net
openstack security group delete lb-mgmt-sec-grp lb-health-mgr-sec-grp
openstack flavor delete amphora
openstack image delete amphora-x64-haproxy
openstack keypair delete --user octavia octavia_ssh_key
openstack service delete octavia                            # supprime aussi les points d'accès
openstack user delete octavia
openstack role delete load-balancer_admin load-balancer_global_observer load-balancer_member \
  load-balancer_observer load-balancer_quota_admin
MDP=$(sudo awk '/^database_password:/{print $2}' /etc/kolla/passwords.yml)
sudo docker exec mariadb mariadb -uroot -p"$MDP" -e \
  "DROP DATABASE octavia; DROP DATABASE octavia_persistence; DROP USER 'octavia'@'%'; DROP USER 'octavia_persistence'@'%';"
unset MDP
```

**Supprimer les fichiers, dont l'autorité de certification** : sa clé privée permettrait de fabriquer
des certificats qu'une amphore accepterait.

```bash
# [instance]
sudo rm -rf /etc/kolla/octavia-api /etc/kolla/octavia-worker /etc/kolla/octavia-health-manager \
  /etc/kolla/octavia-housekeeping /etc/kolla/octavia-openrc.sh /var/log/kolla/octavia
sudo rm -rf /etc/kolla/config/octavia /etc/kolla/octavia-certificates
```

**Remettre la configuration à « sans Octavia »**, reconfigurer Horizon (son tableau de bord des
répartiteurs), retirer les images, le client et `dhclient` :

```bash
# [instance]
sed -i 's/^ENABLE_OCTAVIA=yes$/ENABLE_OCTAVIA=no/' openstack-lab-trainee/scenarios/04-aio-complet.env
sed -i 's/^enable_octavia: "yes"/enable_octavia: "no"/' /etc/kolla/globals.yml
kolla-ansible reconfigure -i ~/kolla/all-in-one --tags horizon
sudo docker rmi $(sudo docker images -q 'quay.io/openstack.kolla/octavia-*')
pip uninstall -y python-octaviaclient
sudo apt-get purge -y isc-dhcp-client isc-dhcp-common
```

**Vérifier l'état de sortie** : la plateforme doit répondre comme à l'étape 0.

```bash
# [instance]
./openstack-lab-trainee/verify.sh | tail -1                  # 42 réussis, 0 échoués
./openstack-lab-trainee/tps/tp15/verifier-entree.sh          # "Lab prêt pour le TP 15." : Octavia absent
free -m | awk '/^Mem:/{print $7}'                            # la mémoire est revenue
```

## Questions

1. Combien de mémoire Octavia a-t-il pris à l'étape 1, puis le premier répartiteur à l'étape 3 ? Que
   cela implique-t-il pour une plateforme qui héberge des centaines de répartiteurs ?
2. L'image des amphores est une image de test, sans empreinte publiée. Quels risques cela fait-il
   courir ? Que feriez-vous en production ?
3. Pourquoi le security group des serveurs web n'ouvre-t-il le port 80 qu'au sous-réseau
   `192.168.150.0/24` ? Qui, précisément, joint les serveurs ?
4. À l'étape 4, aucune requête n'a échoué. Pourquoi ? Que se serait-il passé sans contrôle de santé ?
5. Octavia s'est ajouté à la liste d'accès du secret. Avec quels droits l'a-t-il fait ? Pourquoi cet
   accès est-il resté après le remplacement du certificat, puis après la suppression du
   répartiteur ? Que faut-il prévoir dans une procédure de renouvellement ?
6. Le security group du VIP appartient au projet `service`. Pourquoi Octavia ne vous laisse-t-il pas
   le modifier, et comment limitez-vous quand même les clients ?
7. Pourquoi faut-il supprimer la clé de l'autorité de certification d'Octavia au retrait ? Où est-elle
   rangée pendant que le service tourne, et que proposeriez-vous en production ?
8. Comparez avec le HAProxy installé à la main au TP 13 : qui met à jour HAProxy et le système qui le
   porte ? Qui voit quoi ? Citez un avantage et une limite de chaque approche.

## Validation

- [ ] Octavia ajouté ; mémoire relevée avant, après l'ajout, après le premier répartiteur.
- [ ] Image des amphores, réseau de gestion et interface `o-hm0` regardés ; route par défaut inchangée.
- [ ] Tourniquet constaté (5 et 5) ; bascule observée (membre en erreur, 10 requêtes au serveur 2) et
  retour.
- [ ] HTTPS servi avec votre certificat (empreintes identiques) ; accès d'Octavia au secret constaté ;
  certificat renouvelé sans interruption, ancien secret supprimé.
- [ ] Redirection HTTP vers HTTPS (302) ; clients limités par `--allowed-cidr` (refus puis accès).
- [ ] Vue d'un membre : amphores refusées (403).
- [ ] Nettoyage fait ; Octavia retiré ; `verify.sh` sans échec ; `verifier-entree.sh` : lab prêt.

## Sources

- Kolla-Ansible, Octavia (réseau de gestion, certificats, image) :
  <https://docs.openstack.org/kolla-ansible/2025.1/reference/networking/octavia.html>
- Octavia, guide de l'utilisateur et recettes (HTTPS, L7) :
  <https://docs.openstack.org/octavia/2025.1/user/guides/basic-cookbook.html>
- Octavia, politiques et rôles : <https://docs.openstack.org/octavia/2025.1/configuration/policy.html>
- Client `openstack loadbalancer` : <https://docs.openstack.org/python-octaviaclient/latest/cli/index.html>
- Images de test des amphores : <https://tarballs.opendev.org/openstack/octavia/test-images/>
- Kolla-Ansible, exploitation (`deploy`, `stop`, `reconfigure`, `--tags`) :
  <https://docs.openstack.org/kolla-ansible/2025.1/user/operating-kolla.html>
- Toutes les sources du parcours : [sources.md](../sources.md)
