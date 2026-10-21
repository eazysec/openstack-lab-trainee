# TP 06. Projets, utilisateurs, rôles et quotas

| | |
|---|---|
| Prérequis | TP 03 |
| À la fin du TP | Vous savez ouvrir un espace isolé à une équipe et limiter ses ressources |

## Objectifs

- Créer un projet (*tenant*) et un utilisateur, lui donner un rôle.
- Constater l'isolation entre projets.
- Voir ce qu'un projet sait de l'hôte qui porte ses VM, et ce que l'administrateur en sait.
- Fixer des quotas et observer leur effet.

---

## Étape 0. Vérifier les conditions d'entrée

```bash
# [instance]
./openstack-lab-trainee/tps/tp06/verifier-entree.sh        # dernière ligne : "Lab prêt pour le TP 06."
```

Ce script ne modifie rien. Il vérifie que la plateforme répond, que les ressources communes du déploiement sont là (`mykey`,
`demo-net`, `public1`, `demo-router`, `cirros`, `m1.tiny`) et qu'il ne reste rien d'un essai précédent
(ressources `tp06-`, fichier `~/tp06-openrc.sh`).
Chaque écart est affiché avec ce qu'il faut faire. Ne commencez pas tant que la dernière ligne n'est
pas `Lab prêt pour le TP 06.`

## Étape 1. Projet, utilisateur, rôle (en admin)

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh

openstack project create --description "Equipe TP 06" tp06-proj-equipe
openstack user create --project tp06-proj-equipe --password-prompt tp06-user-stagiaire   # choisir un mot de passe
openstack role add --project tp06-proj-equipe --user tp06-user-stagiaire member
openstack role assignment list --project tp06-proj-equipe --names
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
export OS_PROJECT_NAME=tp06-proj-equipe
export OS_USERNAME=tp06-user-stagiaire
read -rsp "Mot de passe de tp06-user-stagiaire : " OS_PASSWORD; echo; export OS_PASSWORD
EOF
source ~/tp06-openrc.sh
openstack token issue -c project_id -c user_id
```

## Étape 3. L'isolation

Toujours en tant que `tp06-user-stagiaire` :

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
openstack router create tp06-rtr
openstack router set --external-gateway public1 tp06-rtr
openstack router add subnet tp06-rtr tp06-subnet
openstack server create --image cirros --flavor m1.tiny --network tp06-net --wait tp06-vm-1
```

Sur quel hôte tourne cette VM ?

```bash
# [instance]
openstack server show tp06-vm-1 -c hostId -c OS-EXT-SRV-ATTR:host -c OS-EXT-SRV-ATTR:hypervisor_hostname
openstack hypervisor list       # refusé (403) : réservé à l'administrateur
```

`hostId` est rempli ; `host` et `hypervisor_hostname` sont vides (`None`) : un membre du projet ne
voit pas le nom de l'hôte.

Connectez-vous à Horizon (tunnel du TP 02) avec `tp06-user-stagiaire` : vous ne voyez que le projet
`tp06-proj-equipe`.

## Étape 4. Où tournent les VM (en admin)

L'administrateur voit l'hyperviseur et l'hôte de chaque VM :

```bash
# [instance]
source /etc/kolla/admin-openrc.sh
openstack hypervisor list
openstack hypervisor show -c hypervisor_type -c hypervisor_version \
  "$(openstack hypervisor list -f value -c "Hypervisor Hostname")"
openstack server show "$(openstack server list --all-projects --name tp06-vm-1 -f value -c ID)" \
  -c hostId -c OS-EXT-SRV-ATTR:host -c OS-EXT-SRV-ATTR:hypervisor_hostname
```

La VM est dans un autre projet : l'administrateur la désigne par son identifiant.

Le lab n'a qu'un hôte, sans accélération KVM : l'instance AWS ne la propose pas, les VM sont émulées
par QEMU. La version s'écrit en un nombre : `8002002` se lit 8.2.2.

Une VM dans un autre projet, sur le même hôte :

```bash
# [instance]
openstack server create --image cirros --flavor m1.tiny --network demo-net --wait tp06-vm-admin
openstack server show tp06-vm-admin -c hostId -c OS-EXT-SRV-ATTR:host
```

Même hôte, mais un `hostId` différent. Nova le calcule ainsi : empreinte SHA-224 de l'identifiant du
projet suivi du nom de l'hôte. Recalculez-le :

```bash
# [instance]
HOTE=$(openstack server show tp06-vm-admin -f value -c OS-EXT-SRV-ATTR:host)
printf '%s' "$(openstack project show tp06-proj-equipe -f value -c id)$HOTE" | sha224sum   # hostId de tp06-vm-1
printf '%s' "$(openstack project show admin -f value -c id)$HOTE" | sha224sum              # hostId de tp06-vm-admin
```

## Étape 5. Les quotas (en admin)

```bash
# [instance]
source /etc/kolla/admin-openrc.sh
openstack quota show tp06-proj-equipe | grep -E "instances|cores|ram"
openstack quota set --instances 2 tp06-proj-equipe
```

En tant que `tp06-user-stagiaire`, essayez de créer deux VM de plus :

```bash
# [instance]
source ~/tp06-openrc.sh
openstack server create --image cirros --flavor m1.tiny --network tp06-net --wait tp06-vm-2
openstack server create --image cirros --flavor m1.tiny --network tp06-net --wait tp06-vm-3
```

La troisième est refusée. Relevez le message d'erreur.

Comparez le `hostId` des deux VM du projet :

```bash
# [instance]
openstack server show tp06-vm-1 -f value -c hostId
openstack server show tp06-vm-2 -f value -c hostId      # même valeur : même projet, même hôte
```

## Étape 6. Nettoyage

```bash
# [instance]
source ~/tp06-openrc.sh
openstack server delete --wait tp06-vm-1 tp06-vm-2
openstack router remove subnet tp06-rtr tp06-subnet
openstack router unset --external-gateway tp06-rtr
openstack router delete tp06-rtr
openstack network delete tp06-net

source /etc/kolla/admin-openrc.sh
openstack server delete --wait tp06-vm-admin
openstack user delete tp06-user-stagiaire
openstack project delete tp06-proj-equipe
rm ~/tp06-openrc.sh
```

## Questions

1. Quelle est la différence entre un utilisateur, un projet et un rôle ?
2. Pourquoi deux projets peuvent-ils utiliser tous les deux le réseau 10.0.0.0/24 sans conflit ?
3. `tp06-user-stagiaire` voit `public1`, mais pas `demo-net`. Pourquoi ?
4. À quoi servent les quotas sur une plateforme partagée ? Citez trois ressources limitables.
5. Un membre du projet voit le `hostId` de ses VM, mais pas le nom de l'hôte ni la version de
   l'hyperviseur. Pourquoi les lui cacher ? À quoi lui sert le `hostId` ? Pourquoi le même hôte
   donne-t-il un `hostId` différent à deux projets ?

## Validation

- [ ] Connexion en `tp06-user-stagiaire` (CLI et Horizon) avec une vue limitée à son projet.
- [ ] Hôte et hyperviseur : vue du membre (`hostId` seul) et vue de l'administrateur relevées ;
  `hostId` recalculé pour les deux projets.
- [ ] Quota atteint et message d'erreur relevé.
- [ ] Nettoyage fait (projet et utilisateur supprimés).

## Sources

- Keystone : projets, utilisateurs, rôles : <https://docs.openstack.org/keystone/2025.1/>
- Nova, API : `hostId` et champs `OS-EXT-SRV-ATTR` de `server show` :
  <https://docs.openstack.org/api-ref/compute/#show-server-details>
- Keystone dans Kolla-Ansible : <https://docs.openstack.org/kolla-ansible/2025.1/reference/shared-services/keystone-guide.html>
- Guide de sécurité OpenStack : <https://docs.openstack.org/security-guide/>
- Toutes les sources du parcours : [sources.md](../sources.md)
