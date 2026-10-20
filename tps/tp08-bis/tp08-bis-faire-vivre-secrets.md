# TP 08 bis. Faire vivre un secret : renouveler, partager, regrouper

| | |
|---|---|
| Prérequis | TP 08 ; Barbican déployé (scénario 04) |
| À la fin du TP | Vous savez renouveler un secret, le partager avec une seule personne et regrouper les secrets d'une application, et vous connaissez les limites de ces protections |

## Objectifs

- Comprendre pourquoi un secret ne se modifie pas, et le renouveler (rotation).
- Donner une durée de vie à un secret.
- Rendre un secret privé, puis le partager en lecture avec un utilisateur choisi (ACL).
- Savoir contre qui un secret privé protège, et contre qui il ne protège pas.
- Regrouper l'identifiant et le mot de passe d'une application dans un conteneur, et le consulter sans
  afficher les valeurs.
- Retrouver dans le journal de Barbican qui a lu la valeur d'un secret.

---

## Étape 0. Vérifier les conditions d'entrée

```bash
# [instance]
./openstack-lab-trainee/tps/tp08-bis/verifier-entree.sh    # dernière ligne : "Lab prêt pour le TP 08 bis."
```

Ce script ne modifie rien. Il vérifie que la plateforme répond, que Barbican est déployé et qu'il ne
reste rien d'un essai précédent (projets et utilisateurs `tp08b-`). Chaque écart est affiché avec ce
qu'il faut faire. Ne commencez pas tant que la dernière ligne n'est pas `Lab prêt pour le TP 08 bis.`

## Étape 1. Deux projets, quatre utilisateurs

Le TP joue plusieurs rôles : l'application qui possède le secret, un collègue du même projet, un
membre du projet sans rôle Barbican, et un utilisateur d'un autre projet.

| Utilisateur | Projet | Rôle |
|---|---|---|
| `tp08b-user-app` | `tp08b-proj` | `creator` |
| `tp08b-user-collegue` | `tp08b-proj` | `creator` |
| `tp08b-user-membre` | `tp08b-proj` | `member` |
| `tp08b-user-externe` | `tp08b-proj-autre` | `creator` |

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
MDP=$(openssl rand -base64 18)            # un mot de passe tiré au hasard, jamais affiché
openstack project create tp08b-proj
openstack project create tp08b-proj-autre
for u in app collegue membre; do
  openstack user create --project tp08b-proj --password "$MDP" tp08b-user-$u
done
openstack user create --project tp08b-proj-autre --password "$MDP" tp08b-user-externe
openstack role add --project tp08b-proj --user tp08b-user-app creator
openstack role add --project tp08b-proj --user tp08b-user-collegue creator
openstack role add --project tp08b-proj --user tp08b-user-membre member
openstack role add --project tp08b-proj-autre --user tp08b-user-externe creator
```

La fonction `en` lance une commande sous l'identité d'un de ces utilisateurs, sans quitter le compte
admin :

```bash
# [instance]
en() {
  local u=$1; shift
  local p=tp08b-proj; [ "$u" = externe ] && p=tp08b-proj-autre
  OS_USERNAME=tp08b-user-$u OS_PROJECT_NAME=$p OS_PASSWORD="$MDP" "$@"
}
en app openstack token issue -c project_id -c user_id
```

> Gardez le même terminal jusqu'à la fin du TP : `MDP`, `en` et les variables des étapes suivantes
> n'existent que dans ce shell.

## Étape 2. Un secret ne se modifie pas

L'application range le mot de passe de sa base de données :

```bash
# [instance]
H=$(en app openstack secret store --name tp08b-secret-bdd --payload "mdp-v1" \
  --payload-content-type text/plain -f value -c "Secret href")
en app openstack secret update $H "mdp-v2"           # refusé
en app openstack secret get --payload $H -f value    # toujours mdp-v1
```

Réponse : `Conflict: Secret already has data, cannot modify it.` Une valeur stockée ne change plus.
Pour changer le mot de passe, on crée un nouveau secret (rotation) :

```bash
# [instance]
H2=$(en app openstack secret store --name tp08b-secret-bdd --payload "mdp-v2" \
  --payload-content-type text/plain -f value -c "Secret href")
en app openstack secret list --name tp08b-secret-bdd -c "Secret href" -c Created   # deux secrets, même nom
en app openstack secret delete $H                    # l'application utilise désormais H2
H=$H2
```

Deux secrets peuvent porter le même nom : seule l'adresse (*href*) désigne un secret.

`secret update` ne sert qu'à un cas : donner sa valeur, une seule fois, à un secret créé vide.

```bash
# [instance]
HV=$(en app openstack secret store --name tp08b-secret-reserve -f value -c "Secret href")
en app openstack secret get --payload $HV            # refusé : pas encore de valeur
en app openstack secret update $HV "valeur-unique"
en app openstack secret get --payload $HV -f value   # valeur-unique
en app openstack secret update $HV "autre-valeur"    # refusé : Conflict
en app openstack secret delete $HV
```

Le premier `get --payload` répond `Not Found: Not Found. Sorry but your secret has no payload.`

## Étape 3. Une durée de vie

```bash
# [instance]
E=$(date -u -d '+2 minutes' +%Y-%m-%dT%H:%M:%S)
HE=$(en app openstack secret store --name tp08b-secret-temporaire --payload "jeton" \
  --payload-content-type text/plain --expiration "$E" -f value -c "Secret href")
en app openstack secret get $HE -c Name -c Expiration
sleep 130                                            # attendre l'échéance
en app openstack secret get $HE                      # Not Found: Secret not found.
en app openstack secret list --name tp08b-secret-temporaire   # vide
```

À l'échéance, le secret devient introuvable, même pour son propriétaire.

## Étape 4. Rendre un secret privé, puis le partager

Par défaut, tout utilisateur du projet qui a un rôle Barbican lit le secret :

```bash
# [instance]
en collegue openstack secret get --payload $H -f value    # accepté : mdp-v2
en membre openstack secret get --payload $H -f value      # refusé : member seul
en app openstack acl get $H -c "Project Access" -c Users  # True, []
```

L'application rend son secret privé :

```bash
# [instance]
en app openstack acl submit --no-project-access $H -c "Project Access" -c Users
en app openstack secret get --payload $H -f value         # accepté : le créateur
en collegue openstack secret get --payload $H -f value    # refusé
openstack secret get --payload $H -f value                # admin, depuis son projet : refusé
```

Puis elle le partage en lecture avec deux utilisateurs choisis, par leur identifiant :

```bash
# [instance]
M=$(openstack user show tp08b-user-membre -f value -c id)
X=$(openstack user show tp08b-user-externe -f value -c id)
en app openstack acl user add --user $M --operation-type read $H -c Users
en app openstack acl user add --user $X --operation-type read $H -c Users
en membre openstack secret get --payload $H -f value      # accepté, avec le seul rôle member
en externe openstack secret get --payload $H -f value     # accepté, depuis un autre projet
en externe openstack secret list                          # vide : il lui faut l'adresse du secret
en membre openstack secret delete $H                      # refusé : lire n'est pas supprimer
```

Les refus répondent `Forbidden: Secret payload retrieval attempt not allowed - please review your
user/project privileges` (lecture) et `Forbidden: Secret deletion attempt not allowed` (suppression).

**Le collègue peut-il contourner ?** Il n'est pas dans l'ACL, mais il a le rôle `creator` dans le
projet :

```bash
# [instance]
C=$(openstack user show tp08b-user-collegue -f value -c id)
en collegue openstack acl user add --user $C --operation-type read $H -c Users   # accepté !
en collegue openstack secret get --payload $H -f value    # accepté
en collegue openstack secret delete $H                    # refusé
en app openstack acl user remove --user $C --operation-type read $H -c Users
```

Sur ce lab, un `creator` du projet peut modifier l'ACL d'un secret privé et s'y ajouter. « Privé »
écarte les utilisateurs sans rôle Barbican et les autres projets, pas les `creator` du projet.

## Étape 5. Regrouper les secrets d'une application

Une application a souvent besoin de plusieurs secrets : ici, l'identifiant et le mot de passe de sa
base. Un conteneur (*container*) les regroupe sous des noms convenus.

```bash
# [instance]
HU=$(en app openstack secret store --name tp08b-secret-bdd-identifiant --payload "appli" \
  --payload-content-type text/plain -f value -c "Secret href")
K=$(en app openstack secret container create --name tp08b-conteneur-bdd --type generic \
  --secret "username=$HU" --secret "password=$H" -f value -c "Container href")
en app openstack secret container get $K             # les adresses des secrets, jamais leurs valeurs
en app openstack secret get $HU                      # les métadonnées, sans la valeur
```

L'application garde une seule adresse, celle du conteneur, et ne lit la valeur que quand elle en a
besoin (`--payload`).

Le partage d'un conteneur ne s'étend pas aux secrets qu'il contient :

```bash
# [instance]
en app openstack acl user add --user $X --operation-type read $K -c Users
en externe openstack secret container get $K -c Name -c Secrets   # accepté
en externe openstack secret get --payload $HU -f value  # refusé : pas d'ACL sur ce secret
en externe openstack secret get --payload $H -f value   # accepté : ACL de l'étape 4
```

Et rien n'empêche de supprimer un secret encore utilisé :

```bash
# [instance]
en app openstack secret delete $HU                   # accepté, sans avertissement
en app openstack secret container get $K -c Secrets  # username a disparu du conteneur
```

Barbican sait refuser une telle suppression quand l'utilisateur du secret s'est déclaré (*consumer*) :
le TP 09 s'en sert pour protéger la clé d'un volume chiffré.

## Étape 6. Qui a lu le secret ?

Barbican trace chaque lecture de la valeur d'un secret (`…/payload`), avec l'utilisateur qui l'a
demandée et la réponse donnée :

```bash
# [instance]
ID=${H##*/}                                # l'identifiant du secret : la fin de son adresse
sudo grep "secrets/$ID/payload" /var/log/kolla/barbican/barbican-api.log \
  | grep -oE '[0-9a-f]{32} [0-9a-f]{32} - - default default\] Processed request: [0-9]+' \
  | awk '{print $1, "réponse", $NF}' | sort | uniq -c
for u in app collegue membre externe; do echo "tp08b-user-$u : $(openstack user show tp08b-user-$u -f value -c id)"; done
echo "admin : $(openstack user show admin -f value -c id)"
```

Chaque ligne compte les lectures d'un utilisateur, avec le code de la réponse : `200` lecture
accordée, `403` refusée. On y retrouve les accès et les refus des étapes 4 et 5, y compris la
lecture du collègue qui s'était ajouté lui-même à l'ACL.

## Étape 7. Nettoyage

```bash
# [instance]
en app openstack secret container delete $K
en app openstack secret delete $H
openstack user delete tp08b-user-app tp08b-user-collegue tp08b-user-membre tp08b-user-externe
openstack project delete tp08b-proj tp08b-proj-autre
unset -f en; unset MDP H H2 HV HE HU K E M X C
./openstack-lab-trainee/tps/tp08-bis/verifier-entree.sh | tail -1    # "Lab prêt pour le TP 08 bis."
```

## Questions

1. Pourquoi Barbican refuse-t-il de modifier un secret ? Comment change-t-on le mot de passe d'une
   base rangé dans Barbican, et que doit faire l'application ?
2. Un secret supprimé ou arrivé à expiration a-t-il vraiment disparu ? Où chercher ?
3. Contre qui un secret privé protège-t-il ? Contre qui ne protège-t-il pas ? Qu'en déduisez-vous
   pour l'attribution du rôle `creator` ?
4. Pourquoi partager un conteneur ne suffit-il pas pour que l'autre utilisateur lise les valeurs ?
   Que faut-il partager en plus ?
5. Le journal de Barbican dit qui a lu la valeur du secret. Qu'est-ce qu'il ne permet pas de savoir,
   et qui pourrait l'effacer ?
6. Au TP 13, l'application lit le mot de passe de sa base dans un fichier, déposé depuis le bastion.
   Pourquoi ne pas lui donner plutôt un identifiant d'application (TP 06 bis) limité à la lecture de ce
   seul secret dans Barbican ?

## Validation

- [ ] Refus de `secret update` relevé ; rotation faite (deux secrets du même nom, l'ancien supprimé).
- [ ] Secret expiré introuvable à l'échéance.
- [ ] Secret privé : refus du collègue et de l'admin ; lecture accordée au membre et à l'externe par
  l'ACL ; contournement par le collègue `creator` constaté.
- [ ] Conteneur consulté sans afficher les valeurs ; partage du conteneur sans accès aux secrets.
- [ ] Lectures et refus de lecture du secret retrouvés dans le journal de Barbican, par utilisateur.
- [ ] Questions 2 et 3 argumentées.
- [ ] Nettoyage fait.

## Sources

- Barbican : <https://docs.openstack.org/barbican/2025.1/>
- Guide de l'API : secrets <https://docs.openstack.org/api-guide/key-manager/secrets.html>,
  ACL <https://docs.openstack.org/api-guide/key-manager/acls.html>,
  conteneurs <https://docs.openstack.org/api-guide/key-manager/containers.html>
- Client en ligne de commande : <https://docs.openstack.org/python-barbicanclient/latest/cli/usage.html>
- Toutes les sources du parcours : [sources.md](../sources.md)
