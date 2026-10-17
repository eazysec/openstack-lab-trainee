# TP 06. Projets, utilisateurs, rôles et quotas

| | |
|---|---|
| Durée | 1 h 30 |
| Prérequis | TP 03 |
| À la fin du TP | Vous savez ouvrir un espace isolé à une équipe et limiter ses ressources |

## Objectifs

- Créer un projet (*tenant*) et un utilisateur, lui donner un rôle.
- Constater l'isolation entre projets.
- Fixer des quotas et observer leur effet.

---

## Étape 1. Projet, utilisateur, rôle (en admin)

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh

openstack project create --description "Equipe TP 06" tp06-equipe
openstack user create --project tp06-equipe --password-prompt tp06-stagiaire   # choisir un mot de passe
openstack role add --project tp06-equipe --user tp06-stagiaire member
openstack role assignment list --project tp06-equipe --names
```

## Étape 2. Se connecter en tant que l'utilisateur

On crée un fichier d'identifiants pour cet utilisateur, sur le modèle de celui de l'admin :

```bash
# [instance]
cat > ~/tp06-openrc.sh <<EOF
for v in \$(env | grep -o '^OS_[A-Z_]*'); do unset \$v; done
export OS_AUTH_URL=$OS_AUTH_URL
export OS_IDENTITY_API_VERSION=3
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_PROJECT_NAME=tp06-equipe
export OS_USERNAME=tp06-stagiaire
read -rsp "Mot de passe de tp06-stagiaire : " OS_PASSWORD; echo; export OS_PASSWORD
EOF
source ~/tp06-openrc.sh
openstack token issue -c project_id -c user_id
```

## Étape 3. L'isolation

Toujours en tant que `tp06-stagiaire` :

```bash
# [instance]
openstack server list           # vide : les VM du projet admin sont invisibles
openstack network list          # seul public1 est visible : il est partagé (réseau externe)
openstack user list             # refusé : ce n'est pas un administrateur
```

L'utilisateur construit son propre réseau, comme au TP 03, avec le même plan d'adressage que l'admin :
les projets sont isolés, les plages d'adresses peuvent se recouvrir.

```bash
# [instance]
openstack network create tp06-net
openstack subnet create --network tp06-net --subnet-range 10.0.0.0/24 tp06-subnet
openstack router create tp06-router
openstack router set --external-gateway public1 tp06-router
openstack router add subnet tp06-router tp06-subnet
openstack server create --image cirros --flavor m1.tiny --network tp06-net --wait tp06-vm1
```

Connectez-vous à Horizon (tunnel du TP 02) avec `tp06-stagiaire` : vous ne voyez que le projet
`tp06-equipe`.

## Étape 4. Les quotas (en admin)

```bash
# [instance]
source /etc/kolla/admin-openrc.sh
openstack quota show tp06-equipe | grep -E "instances|cores|ram"
openstack quota set --instances 2 tp06-equipe
```

En tant que `tp06-stagiaire`, essayez de créer deux VM de plus :

```bash
# [instance]
source ~/tp06-openrc.sh
openstack server create --image cirros --flavor m1.tiny --network tp06-net --wait tp06-vm2
openstack server create --image cirros --flavor m1.tiny --network tp06-net --wait tp06-vm3
```

La troisième est refusée. Relevez le message d'erreur.

## Étape 5. Nettoyage

```bash
# [instance]
source ~/tp06-openrc.sh
openstack server delete --wait tp06-vm1 tp06-vm2
openstack router remove subnet tp06-router tp06-subnet
openstack router unset --external-gateway tp06-router
openstack router delete tp06-router
openstack network delete tp06-net

source /etc/kolla/admin-openrc.sh
openstack user delete tp06-stagiaire
openstack project delete tp06-equipe
rm ~/tp06-openrc.sh
```

## Questions

1. Quelle est la différence entre un utilisateur, un projet et un rôle ?
2. Pourquoi deux projets peuvent-ils utiliser tous les deux le réseau 10.0.0.0/24 sans conflit ?
3. `tp06-stagiaire` voit `public1`, mais pas `demo-net`. Pourquoi ?
4. À quoi servent les quotas sur une plateforme partagée ? Citez trois ressources limitables.

## Validation

- [ ] Connexion en `tp06-stagiaire` (CLI et Horizon) avec une vue limitée à son projet.
- [ ] Quota atteint et message d'erreur relevé.
- [ ] Nettoyage fait (projet et utilisateur supprimés).

## Sources

- Keystone : projets, utilisateurs, rôles : <https://docs.openstack.org/keystone/2025.1/>
- Keystone dans Kolla-Ansible : <https://docs.openstack.org/kolla-ansible/2025.1/reference/shared-services/keystone-guide.html>
- Guide de sécurité OpenStack : <https://docs.openstack.org/security-guide/>
- Toutes les sources du parcours : [sources.md](sources.md)
