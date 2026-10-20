# TP 01. Déployer OpenStack et vérifier le déploiement

| | |
|---|---|
| Prérequis | TP 00 ; une instance neuve |
| À la fin du TP | OpenStack tourne et vous savez vérifier qu'il fonctionne |

## Objectifs

- Déployer OpenStack « All-in-One » avec Kolla-Ansible (scénario 01).
- Savoir suivre un déploiement et lire son résultat.
- Identifier les services OpenStack et les conteneurs qui les font tourner.

---

## Étape 0. Copier le dépôt et vérifier les conditions d'entrée

```bash
# [poste] : dans le dossier qui contient openstack-lab-trainee/ et ec2_key
scp -r -i ec2_key openstack-lab-trainee ubuntu@<IP_PUBLIQUE>:
ssh -i ec2_key ubuntu@<IP_PUBLIQUE>
```

```bash
# [instance]
./openstack-lab-trainee/tps/tp01/verifier-entree.sh        # dernière ligne : "Lab prêt pour le TP 01."
```

Ce script ne modifie rien. Il vérifie que l'instance convient au lab (Ubuntu 24.04, mémoire,
processeurs, `sudo`, `tmux`) et qu'elle joint les sites d'où le déploiement télécharge Kolla-Ansible et
ses images. Chaque écart est affiché avec ce qu'il faut faire. Ne commencez pas tant que la dernière
ligne n'est pas `Lab prêt pour le TP 01.`

## Étape 1. Lancer le déploiement

Le déploiement dure environ 15 minutes. On le lance dans tmux : si la connexion SSH coupe, il
continue, et on le retrouve avec `tmux attach -t deploy`.

```bash
# [instance]
tmux new -s deploy
./openstack-lab-trainee/deploy.sh openstack-lab-trainee/scenarios/01-aio-base.env
```

Pendant le déploiement, lisez [../README.md §4](../README.md) (ce que fait le script) et
[../README.md §6](../README.md) (les services).

À la fin, le script affiche `Déploiement terminé` et un résumé des accès.

> Le log peut contenir des lignes `fatal:` alors que tout se passe bien : certaines vérifications de
> Kolla sont autorisées à échouer. Seule compte la dernière ligne `PLAY RECAP` de chaque étape :
> `failed=0`.

## Étape 2. Vérifier

```bash
# [instance]
./openstack-lab-trainee/verify.sh
```

Résultat attendu : `Résultat : N réussis, 0 échoués` (le nombre N dépend des services déployés). Le
script a créé une VM, testé le réseau et la connexion à Horizon, puis
tout supprimé.

## Étape 3. Observer ce qui a été déployé

```bash
# [instance]
sudo docker ps --format 'table {{.Names}}\t{{.Status}}'   # un conteneur par composant
cat /etc/kolla/globals.yml                                 # la configuration du déploiement

source ~/kolla/venv/bin/activate
source /etc/kolla/admin-openrc.sh
openstack service list                                     # les services enregistrés dans Keystone
openstack endpoint list -c "Service Name" -c Interface -c URL
openstack compute service list                             # les services de Nova
openstack network agent list                               # les agents de Neutron
```

## Questions

1. Combien de conteneurs tournent ? Choisissez-en trois et expliquez leur rôle.
2. Quel service OpenStack faut-il contacter en premier pour utiliser tous les autres, et pourquoi ?
3. Dans `globals.yml`, que valent `network_interface`, `neutron_external_interface` et
   `nova_compute_virt_type` ? Expliquez chacune de ces valeurs.
4. `deploy.sh` est « idempotent ». Que signifie ce mot ? Pourquoi est-ce utile ?

## Validation

- [ ] `verify.sh` : 0 échoué.
- [ ] Les 4 questions ont une réponse argumentée.

## Sources

- Kolla-Ansible 2025.1 : <https://docs.openstack.org/kolla-ansible/2025.1/>
- Installation rapide Kolla-Ansible : <https://docs.openstack.org/kolla-ansible/2025.1/user/quickstart.html>
- Versions OpenStack : <https://releases.openstack.org/>
- Keystone (identité et catalogue) : <https://docs.openstack.org/keystone/2025.1/>
- Dépannage Kolla-Ansible : <https://docs.openstack.org/kolla-ansible/2025.1/user/troubleshooting.html>
- Toutes les sources du parcours : [sources.md](sources.md)
