# TP 06 bis. Identités pour les automates : jetons, identifiants d'application, règles d'accès

| | |
|---|---|
| Prérequis | TP 06 ; scénario 01 ou 02 |
| À la fin du TP | Vous savez ce que vaut un jeton révoqué, vous donnez à un automate un identifiant qui n'est pas votre mot de passe, et vous le limitez aux seuls appels dont il a besoin |

## Objectifs

- Comprendre ce qu'est un jeton Keystone, sa durée de vie, et ce que valent sa révocation et la
  désactivation d'un compte.
- Créer un identifiant d'application (*application credential*) pour un automate, et savoir ce qu'il
  peut et ne peut pas faire.
- Restreindre un identifiant à des appels d'API précis (*access rules*), et trouver les appels réels
  d'une commande.
- Combiner rôle, règles et date d'expiration (défense en profondeur), et connaître la limite des règles.

---

## Étape 0. Vérifier les conditions d'entrée

```bash
# [instance]
./openstack-lab-trainee/tps/tp06-bis/verifier-entree.sh    # dernière ligne : "Lab prêt pour le TP 06 bis."
```

Ce script ne modifie rien. Il vérifie que la plateforme répond, que les ressources communes du
déploiement sont là et qu'il ne reste rien d'un essai précédent (`tp06b-`). Chaque écart est affiché
avec ce qu'il faut faire. Ne commencez pas tant que la dernière ligne n'est pas
`Lab prêt pour le TP 06 bis.`

## Étape 1. Un projet, un utilisateur, une VM

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
MDP=$(openssl rand -base64 18)            # un mot de passe tiré au hasard, jamais affiché
openstack project create tp06b-proj
openstack user create --project tp06b-proj --password "$MDP" tp06b-user
openstack role add --project tp06b-proj --user tp06b-user member
moi() { OS_USERNAME=tp06b-user OS_PROJECT_NAME=tp06b-proj OS_PASSWORD="$MDP" "$@"; }
moi openstack network create tp06b-net
moi openstack subnet create --network tp06b-net --subnet-range 192.168.60.0/24 tp06b-subnet
moi openstack server create --image cirros --flavor m1.tiny --network tp06b-net --wait tp06b-vm
```

La fonction `moi` lance une commande sous l'identité de `tp06b-user`, sans quitter le compte admin.

> Gardez le même terminal jusqu'à la fin du TP : `MDP`, les fonctions et les variables des étapes
> suivantes n'existent que dans ce shell.

## Étape 2. Les jetons

Chaque commande `openstack` s'authentifie auprès de Keystone et reçoit un **jeton** (*token*), qu'elle
présente ensuite aux autres services. Deux fonctions pour l'observer : `nova` présente un jeton à Nova,
`keystone` demande à Keystone s'il est encore valable.

```bash
# [instance]
NOVA=$(openstack endpoint list --service compute --interface public -f value -c URL)
nova() { curl -s -o /dev/null -w '%{http_code}\n' -H "X-Auth-Token: $1" "$NOVA/servers"; }
keystone() { curl -s -o /dev/null -w '%{http_code}\n' -H "X-Auth-Token: $(openstack token issue -f value -c id)" \
  -H "X-Subject-Token: $1" "$OS_AUTH_URL/v3/auth/tokens"; }
T=$(moi openstack token issue -f value -c id)
TEMOIN=$(moi openstack token issue -f value -c id)
moi openstack token issue -c expires       # dans 24 h
nova $T; keystone $T                       # 200 et 200
```

L'utilisateur révoque son jeton :

```bash
# [instance]
moi openstack token revoke $T
keystone $T                                # 404 : Keystone ne le connaît plus
nova $T                                    # 200 : Nova l'accepte encore !
nova $TEMOIN                               # 200 : le témoin, non révoqué
sleep 310
nova $T                                    # 401 : refusé, enfin
```

Nova ne demande pas à Keystone de valider le jeton à chaque appel : il garde en cache le résultat
d'une validation, 300 secondes par défaut. Pendant ce temps, un jeton révoqué reste accepté.

Désactiver le compte invalide tous ses jetons, du côté de Keystone :

```bash
# [instance]
D=$(moi openstack token issue -f value -c id)
openstack user set --disable tp06b-user
keystone $D                                # 404
openstack user set --enable tp06b-user
keystone $D                                # 404 : le jeton reste invalide après la réactivation
```

## Étape 3. Un identifiant pour un automate

Un script ne doit pas utiliser votre mot de passe. Un identifiant d'application lui est propre : on le
crée, on le restreint, on le supprime, sans toucher au compte.

```bash
# [instance]
{ read -r ID; read -r SECRET; } < <(moi openstack application credential create tp06b-appcred-auto \
  -f value -c id -c secret)
moi openstack application credential show tp06b-appcred-auto     # pas de secret : il n'est donné qu'une fois
appli() {  # appli <id> <secret> <commande…> : la commande, avec l'identifiant d'application seul
  local id=$1 secret=$2; shift 2
  env $(env | grep -o '^OS_[A-Z_]*' | sed 's/^/-u /') OS_AUTH_URL=$OS_AUTH_URL OS_IDENTITY_API_VERSION=3 \
    OS_AUTH_TYPE=v3applicationcredential OS_APPLICATION_CREDENTIAL_ID=$id \
    OS_APPLICATION_CREDENTIAL_SECRET=$secret "$@"
}
appli $ID $SECRET openstack server list
appli $ID $SECRET openstack application credential create tp06b-appcred-autre   # refusé : 403
```

Le secret est rangé dans une variable sans être affiché. `appli` retire d'abord toutes les variables
`OS_*` de la session admin : il ne reste que l'identifiant d'application. Celui-ci a les rôles de
l'utilisateur dans le projet, mais il ne peut pas créer d'autre identifiant (il n'a pas été créé avec
`--unrestricted`).

Changer le mot de passe du compte ne l'affecte pas :

```bash
# [instance]
MDP=$(openssl rand -base64 18); openstack user set --password "$MDP" tp06b-user
appli $ID $SECRET openstack server list    # toujours accepté
```

## Étape 4. Restreindre aux seuls appels utiles

Une règle d'accès (*access rule*) autorise un service, une méthode HTTP et un chemin d'API. `*`
remplace un segment du chemin, `**` plusieurs. Tout appel hors règle est refusé.

Lecture seule de Compute :

```bash
# [instance]
{ read -r ID1; read -r S1; } < <(moi openstack application credential create tp06b-appcred-lecture \
  --access-rules '[{"service": "compute", "method": "GET", "path": "/v2.1/**"}]' -f value -c id -c secret)
appli $ID1 $S1 openstack server list       # accepté
appli $ID1 $S1 openstack server stop tp06b-vm   # refusé
appli $ID1 $S1 openstack network list      # refusé : autre service
```

Les refus répondent `401` (`The request you have made requires authentication`) : pour ces appels,
l'identifiant ne vaut rien.

Supervision : lecture de Compute et de Network.

```bash
# [instance]
{ read -r ID3; read -r S3; } < <(moi openstack application credential create tp06b-appcred-supervision \
  --access-rules '[{"service": "compute", "method": "GET", "path": "/v2.1/**"},
                   {"service": "network", "method": "GET", "path": "/v2.0/**"}]' -f value -c id -c secret)
appli $ID3 $S3 openstack network list      # accepté
appli $ID3 $S3 openstack port list         # accepté
appli $ID3 $S3 openstack network create tp06b-intrus   # refusé
```

## Étape 5. Écrire une règle juste

Un automate doit arrêter et démarrer la VM, rien d'autre. Quels appels fait `server stop` ?

```bash
# [instance]
moi openstack --debug server stop tp06b-vm 2>&1 | grep -oE 'REQ: curl -g -i -X [A-Z]+ [^ ]+'
until moi openstack server show tp06b-vm -f value -c status | grep -qx SHUTOFF; do sleep 3; done
moi openstack server start tp06b-vm
```

Cinq appels : la découverte de Keystone et de Nova, deux recherches de la VM par son nom (`GET
/v2.1/servers/tp06b-vm`, puis `GET /v2.1/servers?name=tp06b-vm`), et l'action (`POST
/v2.1/servers/<id>/action`). La règle doit autoriser les lectures et l'action :

```bash
# [instance]
{ read -r ID7; read -r S7; } < <(moi openstack application credential create tp06b-appcred-marche-arret \
  --access-rules '[{"service": "compute", "method": "POST", "path": "/v2.1/servers/*/action"},
                   {"service": "compute", "method": "GET", "path": "/v2.1/servers/**"},
                   {"service": "compute", "method": "GET", "path": "/v2.1/servers"}]' -f value -c id -c secret)
until moi openstack server show tp06b-vm -f value -c status | grep -qx ACTIVE; do sleep 3; done
appli $ID7 $S7 openstack server stop tp06b-vm      # accepté
until moi openstack server show tp06b-vm -f value -c status | grep -qx SHUTOFF; do sleep 3; done
appli $ID7 $S7 openstack server start tp06b-vm     # accepté
appli $ID7 $S7 openstack server delete tp06b-vm    # refusé : DELETE
until moi openstack server show tp06b-vm -f value -c status | grep -qx ACTIVE; do sleep 3; done
appli $ID7 $S7 openstack server reboot tp06b-vm    # accepté aussi !
```

`reboot` passe : comme `stop` et `start`, c'est un `POST` sur `/v2.1/servers/<id>/action`. La règle
filtre le chemin de l'appel, pas l'action demandée dans son contenu ; `rebuild` ou `resize` passeraient
de même.

## Étape 6. Défense en profondeur

On combine trois limites : le rôle `reader` seulement, les règles de l'étape 5, et une date
d'expiration.

```bash
# [instance]
E=$(date -u -d '+2 minutes' +%Y-%m-%dT%H:%M:%S)
{ read -r ID9; read -r S9; } < <(moi openstack application credential create tp06b-appcred-limite \
  --role reader --expiration $E \
  --access-rules '[{"service": "compute", "method": "POST", "path": "/v2.1/servers/*/action"},
                   {"service": "compute", "method": "GET", "path": "/v2.1/servers/**"},
                   {"service": "compute", "method": "GET", "path": "/v2.1/servers"}]' -f value -c id -c secret)
moi openstack application credential show tp06b-appcred-limite -c roles -c expires_at -c unrestricted
appli $ID9 $S9 openstack server list               # accepté
appli $ID9 $S9 openstack server stop tp06b-vm      # refusé : 403, le rôle reader ne le permet pas
sleep 130
appli $ID9 $S9 openstack server list               # refusé : 401, l'identifiant a expiré
```

La règle autorisait `stop`, le rôle non : Nova répond `403` (`ForbiddenException`). Chaque limite
arrête ce que les autres laissent passer.

## Étape 7. Nettoyage

Les ressources du projet d'abord : un admin ne retrouve pas par son nom la VM d'un autre projet, et
une fois le projet supprimé, elle resterait orpheline.

```bash
# [instance]
moi openstack server delete --wait tp06b-vm
moi openstack subnet delete tp06b-subnet
moi openstack network delete tp06b-net
openstack user delete tp06b-user           # ses identifiants d'application avec lui
openstack project delete tp06b-proj
unset -f moi appli nova keystone; unset MDP T TEMOIN D ID SECRET ID1 S1 ID3 S3 ID7 S7 ID9 S9 E NOVA
./openstack-lab-trainee/tps/tp06-bis/verifier-entree.sh | tail -1    # "Lab prêt pour le TP 06 bis."
```

## Questions

1. Un jeton a fuité. Vous le révoquez : pendant combien de temps reste-t-il utilisable, et pourquoi ?
   Que faire de plus si le compte lui-même est en cause ?
2. Pourquoi donner à un automate un identifiant d'application plutôt que le mot de passe d'un compte ?
   Que se passe-t-il pour l'automate quand le mot de passe du compte change, et quand le compte est
   désactivé ?
3. L'identifiant de l'étape 5 devait seulement arrêter et démarrer la VM. Qu'a-t-il pu faire de plus ?
   Comment limiter davantage ?
4. À l'étape 6, quelle limite a refusé `server stop` ? Quelle limite aurait suffi si le secret avait
   fuité après l'échéance ?

## Validation

- [ ] Jeton révoqué : refusé par Keystone, accepté par Nova jusqu'à la fin du cache, puis refusé.
- [ ] Identifiant d'application utilisé sans le mot de passe ; création d'un autre identifiant refusée.
- [ ] Règles d'accès : lecture acceptée, écriture et autre service refusés ; appels de `server stop`
  relevés ; `reboot` accepté par la règle de l'étape 5.
- [ ] Rôle `reader` et expiration : refus `403` puis `401` relevés.
- [ ] Questions 1 et 3 argumentées.
- [ ] Nettoyage fait, dans l'ordre.

## Sources

- Keystone : identifiants d'application et règles d'accès
  <https://docs.openstack.org/keystone/2025.1/user/application_credentials.html>
- Keystone : jetons Fernet <https://docs.openstack.org/keystone/2025.1/admin/fernet-token-faq.html>
- keystonemiddleware : validation et cache des jetons dans les services
  <https://docs.openstack.org/keystonemiddleware/latest/middlewarearchitecture.html>
- API d'identité v3 : <https://docs.openstack.org/api-ref/identity/v3/>
- Toutes les sources du parcours : [sources.md](../sources.md)
