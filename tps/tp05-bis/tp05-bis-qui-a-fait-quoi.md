# TP 05 bis. Qui a fait quoi ? Tracer les appels aux API

| | |
|---|---|
| Prérequis | TP 05 (les journaux) et TP 06 bis (identifiants d'application, règles d'accès) ; scénario 01 ou 02 |
| À la fin du TP | Vous savez retrouver qui a fait une action, suivre une requête d'un service à l'autre, et dire ce que les journaux ne permettent pas de prouver |

## Objectifs

- Relier une action sur le cloud à l'utilisateur qui l'a faite.
- Suivre une requête à travers plusieurs services grâce à son identifiant.
- Retrouver un échec d'authentification et un appel refusé par une règle d'accès.
- Connaître les limites de ces traces : ce qu'elles taisent, combien de temps on les garde, qui peut
  les effacer.

---

## Étape 0. Vérifier les conditions d'entrée

```bash
# [instance]
./openstack-lab-trainee/tps/tp05-bis/verifier-entree.sh    # dernière ligne : "Lab prêt pour le TP 05 bis."
```

Ce script ne modifie rien. Il vérifie que la plateforme répond, que les ressources communes du
déploiement sont là et qu'il ne reste rien d'un essai précédent (`tp05b-`). Chaque écart est affiché
avec ce qu'il faut faire. Ne commencez pas tant que la dernière ligne n'est pas
`Lab prêt pour le TP 05 bis.`

## Étape 1. Un utilisateur agit

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
MDP=$(openssl rand -base64 18)            # un mot de passe tiré au hasard, jamais affiché
openstack project create tp05b-proj
openstack user create --project tp05b-proj --password "$MDP" tp05b-user
openstack role add --project tp05b-proj --user tp05b-user member
moi() { OS_USERNAME=tp05b-user OS_PROJECT_NAME=tp05b-proj OS_PASSWORD="$MDP" "$@"; }
moi openstack network create tp05b-net
moi openstack subnet create --network tp05b-net --subnet-range 192.168.50.0/24 tp05b-subnet
moi openstack server create --image cirros --flavor m1.tiny --network tp05b-net --wait tp05b-vm
```

> Gardez le même terminal jusqu'à la fin du TP : `MDP`, les fonctions et les variables des étapes
> suivantes n'existent que dans ce shell.

## Étape 2. Qui a créé cette VM ?

Nova garde l'historique des actions d'une VM, avec l'identifiant de la requête (`req-…`) qui les a
déclenchées :

```bash
# [instance]
moi openstack server event list tp05b-vm
R=$(moi openstack server event list tp05b-vm -f value -c "Request ID" -c Action | awk '$2=="create"{print $1}')
moi openstack server event show tp05b-vm $R -c user_id -c project_id -c start_time
U=$(moi openstack server event show tp05b-vm $R -f value -c user_id)
openstack user show $U -c name             # tp05b-user
sudo grep "$R" /var/log/kolla/nova/nova-api.log | grep POST
```

La ligne du journal de l'API de Nova contient, entre crochets, l'identifiant de la requête, celui de
l'utilisateur et celui du projet ; puis l'adresse du client, la méthode et l'URL (`POST
/v2.1/servers`), et le code de retour (`202`). Les journaux ne donnent que des identifiants :
c'est Keystone qui donne le nom.

## Étape 3. Suivre la requête de service en service

Pour créer la VM, Nova a demandé l'image à Glance et le port à Neutron. Il leur a transmis le même
identifiant :

```bash
# [instance]
for f in nova/nova-api.log nova/nova-compute.log neutron/neutron-server.log glance/glance-api.log; do
  echo "$f : $(sudo grep -c "$R" /var/log/kolla/$f) ligne(s)"
done
sudo grep "$R" /var/log/kolla/neutron/neutron-server.log | head -n 2
```

Chaque service le note : dans Neutron, il apparaît en premier entre les crochets (identifiant
global), suivi de l'identifiant propre à Neutron. Un seul identifiant suffit pour reconstituer tout ce
que la plateforme a fait pour une demande.

## Étape 4. Un échec d'authentification

```bash
# [instance]
OS_USERNAME=tp05b-user OS_PROJECT_NAME=tp05b-proj OS_PASSWORD=faux openstack token issue   # refusé : 401
sudo grep 'POST /v3/auth/tokens' /var/log/kolla/keystone/keystone-apache-public-access.log | grep ' 401 ' | tail -n 1
moi openstack token issue -c expires       # le bon mot de passe
sudo grep 'POST /v3/auth/tokens' /var/log/kolla/keystone/keystone-apache-public-access.log | grep ' 201 ' | tail -n 1
```

L'échec est bien tracé (`401`), à côté des réussites (`201`). Mais regardez ce que la ligne ne dit
pas : ni le nom de l'utilisateur, ni l'adresse d'où vient la tentative (`- - -` en tête de ligne).

## Étape 5. Un appel refusé par une règle d'accès

Un identifiant d'application limité à la lecture de Compute (TP 06 bis) essaie de lister les réseaux :

```bash
# [instance]
{ read -r ID; read -r SECRET; } < <(moi openstack application credential create tp05b-appcred-lecture \
  --access-rules '[{"service": "compute", "method": "GET", "path": "/v2.1/**"}]' -f value -c id -c secret)
appli() {  # appli <id> <secret> <commande…> : la commande, avec l'identifiant d'application seul
  local id=$1 secret=$2; shift 2
  env $(env | grep -o '^OS_[A-Z_]*' | sed 's/^/-u /') OS_AUTH_URL=$OS_AUTH_URL OS_IDENTITY_API_VERSION=3 \
    OS_AUTH_TYPE=v3applicationcredential OS_APPLICATION_CREDENTIAL_ID=$id \
    OS_APPLICATION_CREDENTIAL_SECRET=$secret "$@"
}
appli $ID $SECRET openstack network list   # refusé : 401
sudo grep 'status: 401' /var/log/kolla/neutron/neutron-server.log | tail -n 1
```

Neutron a tracé le refus : l'heure, `GET /v2.0/networks`, `status: 401`. Mais qui l'a provoqué ?
Recommencez quatre fois, en laissant l'admin faire un appel normal avant chaque refus, puis comptez
les identifiants d'utilisateur notés sur les lignes de refus :

```bash
# [instance]
for k in 1 2 3 4; do
  openstack network list > /dev/null                              # l'admin : accepté
  appli $ID $SECRET openstack network list > /dev/null 2>&1       # l'automate : refusé
done
sudo grep 'status: 401' /var/log/kolla/neutron/neutron-server.log | tail -n 8 \
  | grep -oE '[0-9a-f]{32} [0-9a-f]{32}' | cut -d' ' -f1 | sort | uniq -c
echo "tp05b-user : $U ; admin : $(openstack user show admin -f value -c id)"
```

L'identifiant de l'admin apparaît sur des lignes de refus, alors que l'admin n'a rien vu refuser.
Neutron a rejeté le jeton : il ne sait pas qui appelle, et la ligne reprend le contexte d'une requête
précédente traitée par le même processus. Une ligne de refus dit qu'il y a eu un refus, quand et sur
quoi ; pas qui l'a provoqué.

## Étape 6. Combien de temps, et à quelle heure ?

```bash
# [instance]
sudo grep -E '^(weekly|daily|rotate|maxsize|compress)' /etc/kolla/cron/logrotate.conf
sudo ls -lh /var/log/kolla/nova/
chronyc tracking | head -n 3
timedatectl show -p NTPSynchronized        # NTPSynchronized=yes
```

Les journaux tournent chaque semaine (`weekly`), et seules les 6 dernières rotations sont gardées
(`rotate 6`) : environ six semaines d'historique au plus, moins si un fichier dépasse `maxsize`. Pour
relier des lignes de plusieurs services, ou de plusieurs machines, leurs horloges doivent être à
l'heure : l'hôte se synchronise sur le serveur de temps d'AWS.

## Étape 7. Nettoyage

```bash
# [instance]
moi openstack server delete --wait tp05b-vm
moi openstack subnet delete tp05b-subnet
moi openstack network delete tp05b-net
openstack user delete tp05b-user           # son identifiant d'application avec lui
openstack project delete tp05b-proj
unset -f moi appli; unset MDP R U ID SECRET
./openstack-lab-trainee/tps/tp05-bis/verifier-entree.sh | tail -1    # "Lab prêt pour le TP 05 bis."
```

## Questions

1. À partir d'une VM, comment retrouvez-vous qui l'a créée, quand, et ce que chaque service a fait
   pour elle ?
2. Un échec d'authentification : que savez-vous, et que ne savez-vous pas ? Que faudrait-il pour
   savoir qui a essayé, et d'où ?
3. Ces journaux sont des fichiers sur l'hôte. Contre qui ne protègent-ils pas ? Que faire en
   production ?
4. Pourquoi l'heure des machines est-elle indispensable à une enquête ?

## Validation

- [ ] Créateur de la VM retrouvé (identifiant de requête, utilisateur, nom).
- [ ] Même identifiant relevé dans Nova, Neutron et Glance.
- [ ] Échec d'authentification `401` relevé, et ce qui manque à la ligne noté.
- [ ] Refus d'une règle d'accès retrouvé dans le journal de Neutron ; identifiants notés sur les lignes
  de refus comptés et comparés à ceux de `tp05b-user` et de l'admin.
- [ ] Questions 2 et 3 argumentées.
- [ ] Nettoyage fait.

## Sources

- Journaux des services dans Kolla-Ansible : <https://docs.openstack.org/kolla-ansible/2025.1/reference/logging-and-monitoring/central-logging-guide.html>
- Nova : actions et événements d'une instance : <https://docs.openstack.org/api-ref/compute/#servers-actions-servers-os-instance-actions>
- Identifiant de requête global, transmis d'un service à l'autre : <https://specs.openstack.org/openstack/oslo-specs/specs/pike/global-req-id.html>
- Toutes les sources du parcours : [sources.md](../sources.md)
