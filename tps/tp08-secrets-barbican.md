# TP 08. Gérer des secrets avec Barbican

| | |
|---|---|
| Prérequis | TP 06 ; Barbican déployé (scénario 04) |
| À la fin du TP | Vous savez stocker et protéger un secret, et vous connaissez les limites du stockage du lab |

## Objectifs

- Comprendre à quoi sert un gestionnaire de secrets (*key manager*).
- Stocker, lister, relire et supprimer un secret ; faire générer une clé par Barbican.
- Comprendre qui a le droit de lire un secret (rôles Barbican, isolation entre projets).
- Savoir comment Barbican protège les secrets sur ce lab, et pourquoi ce n'est pas suffisant en production.

---

## Étape 0. Vérifier les conditions d'entrée et Barbican

```bash
# [instance]
./openstack-lab-trainee/tps/tp08/verifier-entree.sh        # dernière ligne : "Lab prêt pour le TP 08."
```

Ce script ne modifie rien. Il vérifie que la plateforme répond, que les ressources communes du déploiement sont là (`mykey`,
`demo-net`, `public1`, `demo-router`, `cirros`, `m1.tiny`) et qu'il ne reste rien d'un essai précédent
(`tp08-`, fichier `~/tp08-openrc.sh`). Si Barbican manque, il le signale : déployez-le ci-dessous.
Chaque écart est affiché avec ce qu'il faut faire. Ne commencez pas tant que la dernière ligne n'est
pas `Lab prêt pour le TP 08.`

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
openstack service list | grep key-manager
```

Si rien ne s'affiche, déployez le scénario 04 (dans tmux, ~20 min, les VM existantes sont conservées) :

```bash
# [instance]
./openstack-lab-trainee/deploy.sh openstack-lab-trainee/scenarios/04-aio-complet.env
./openstack-lab-trainee/verify.sh
```

## Étape 1. Stocker et relire un secret

```bash
# [instance]
H=$(openstack secret store --name tp08-secret-motdepasse --payload "valeur-de-demonstration" \
  --payload-content-type text/plain -f value -c "Secret href")
echo $H                                   # l'adresse du secret : c'est son identifiant
openstack secret list -c Name -c Status -c "Content types"
openstack secret get $H                   # les métadonnées : le contenu n'est PAS affiché
openstack secret get --payload $H         # le contenu
```

Un secret est désigné par son adresse (*href*) ; son contenu ne s'obtient qu'à la demande
(`--payload`).

## Étape 2. Faire générer une clé par Barbican

Plutôt que de fabriquer une clé soi-même, on la commande (*order*) : Barbican la génère et la
garde, elle n'a jamais existé ailleurs.

```bash
# [instance]
O=$(openstack secret order create --name tp08-secret-cle-aes --algorithm aes --bit-length 256 \
  --mode cbc --payload-content-type application/octet-stream key -f value -c "Order href")
openstack secret order get $O -c Status -c "Secret href"     # attendre "ACTIVE"
S=$(openstack secret order get $O -f value -c "Secret href")
openstack secret get $S -c Name -c Algorithm -c "Bit length" -c "Content types"
```

> Gardez l'adresse de la commande au moment où vous la créez (`O=$(…)`). La liste des commandes
> (`openstack secret order list`) peut en contenir d'autres : par exemple celles que Cinder passe pour
> chaque volume chiffré (TP 09), qui restent dans la liste après la suppression du volume et de sa clé.

## Étape 3. Qui peut lire un secret ?

Barbican a ses propres rôles, en plus de ceux de Keystone : `creator` (créer et lire les secrets de
son projet), `observer` (lire), `audit` (métadonnées seulement).

```bash
# [instance]
openstack role list | grep -E "creator|observer|audit"
openstack project create tp08-proj-autre
openstack user create --project tp08-proj-autre --password-prompt tp08-user
openstack role add --project tp08-proj-autre --user tp08-user member
```

Créez un fichier d'identifiants pour `tp08-user`, comme au TP 06 :

```bash
# [instance]
cat > ~/tp08-openrc.sh <<EOF
for v in \$(env | grep -o '^OS_[A-Z_]*'); do unset \$v; done
export OS_AUTH_URL=$OS_AUTH_URL
export OS_IDENTITY_API_VERSION=3
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_PROJECT_NAME=tp08-proj-autre
export OS_USERNAME=tp08-user
read -rsp "Mot de passe de tp08-user : " OS_PASSWORD; echo; export OS_PASSWORD
EOF
```

Avec le seul rôle `member` :

```bash
# [instance]
source ~/tp08-openrc.sh
openstack secret list
```

Réponse : `Forbidden: Secret(s) retrieval attempt not allowed - please review your user/project
privileges`. Le rôle `member` de Keystone ne suffit pas pour Barbican.

Avec le rôle `creator` :

```bash
# [instance]
source /etc/kolla/admin-openrc.sh
openstack role add --project tp08-proj-autre --user tp08-user creator
source ~/tp08-openrc.sh
HU=$(openstack secret store --name tp08-secret-user --payload "secret-user" -f value -c "Secret href")
openstack secret list -c Name
openstack secret get --payload $HU                     # son propre secret : accepté
openstack secret get --payload <HREF_DU_SECRET_ADMIN>  # la valeur de $H de l'étape 1 : refusé
```

Le dernier accès répond `Forbidden: Secret payload retrieval attempt not allowed`. Les secrets
appartiennent à un projet : un autre projet ne les lit pas, même avec `creator`.

## Étape 4. Comment Barbican protège-t-il les secrets ici ?

```bash
# [instance]
sudo grep -E "^enabled_(secretstore|crypto)_plugins" /etc/kolla/barbican-api/barbican.conf
```

Résultat : `store_crypto` et `simple_crypto`. Les secrets sont chiffrés puis rangés dans la base
MariaDB. La clé qui les chiffre (*KEK*, *key encryption key*) est la valeur `kek` de la section
`[simple_crypto_plugin]` de ce même fichier ; elle vient de `barbican_crypto_key` dans
`/etc/kolla/passwords.yml`. N'affichez pas cette valeur : c'est la clé de tous les secrets.

## Étape 5. Nettoyage

```bash
# [instance]
source ~/tp08-openrc.sh
openstack secret delete $HU

source /etc/kolla/admin-openrc.sh
openstack secret delete $H                # une seule adresse par commande
openstack secret delete $S
openstack secret order delete $O
openstack user delete tp08-user
openstack project delete tp08-proj-autre
rm ~/tp08-openrc.sh
openstack secret list
```

## Questions

1. Pourquoi stocker un mot de passe dans Barbican plutôt que dans un fichier de configuration ou un
   script ?
2. Quelle différence entre `openstack secret store` et `openstack secret order create` ? Pourquoi la
   seconde est-elle préférable pour une clé de chiffrement ?
3. `tp08-user` a le rôle `member`. Pourquoi ne peut-il pas lister les secrets de son projet ? Que
   faut-il lui donner ?
4. Sur ce lab, la clé qui chiffre tous les secrets est dans un fichier de l'hôte, à côté de la base de
   données. Qu'est-ce que cela implique si l'hôte est compromis ? Que propose-t-on en production ?

## Validation

- [ ] Secret stocké, relu, puis supprimé ; clé AES-256 générée par commande.
- [ ] Refus avec `member`, accès avec `creator`, refus d'un autre projet : messages relevés.
- [ ] Réponse argumentée à la question 4.
- [ ] Nettoyage fait.

## Sources

- Barbican : <https://docs.openstack.org/barbican/2025.1/>
- Keystone : projets, utilisateurs, rôles : <https://docs.openstack.org/keystone/2025.1/>
- Guide de sécurité OpenStack : <https://docs.openstack.org/security-guide/>
- Toutes les sources du parcours : [sources.md](sources.md)
