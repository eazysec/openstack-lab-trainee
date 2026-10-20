# TP 13 bis. Administrer la base sans ouvrir de port

| | |
|---|---|
| Prérequis | TP 13 fait jusqu'à l'étape 14, **sans** son nettoyage (étape 16) : l'architecture est en place |
| À la fin du TP | Vous administrez la base sous un rôle dédié, depuis votre poste, sans port ouvert, et chaque action est tracée ; l'application n'a plus que les droits dont elle a besoin |

## Objectifs

- Ne plus administrer en superutilisateur anonyme (`postgres`) : un rôle d'administration dédié,
  relié à un compte du système.
- Retirer à l'application les droits dont elle n'a pas besoin, et comprendre ce qui casse.
- Administrer la base depuis le poste par un tunnel SSH vers sa socket locale, sans ouvrir de port.
- Tracer les connexions et les changements de structure, et savoir les relire.

---

## Étape 0. Vérifier les conditions d'entrée

```bash
# [instance]
./openstack-lab-trainee/tps/tp13-bis/verifier-entree.sh   # dernière ligne : "Lab prêt pour le TP 13 bis."
```

Ce script ne modifie rien. Il vérifie que l'architecture du TP 13 est en place : les deux VM sont
actives et l'application, jointe par la FIP, est connectée à sa base. Il ne voit pas l'intérieur des
VM : l'étape 1 fait ce constat.

Vos commandes du TP 13 restent valables : `~/.ssh/tp13_config` sur le poste, rebond par le bastion.

## Étape 1. Le constat

```bash
# [poste]
ssh -F ~/.ssh/tp13_config tp13-vm-bdd-demo
```

```bash
# [VM] tp13-vm-bdd-demo
sudo runuser -u postgres -- psql -X -c '\du' -c '\l tp13'
sudo runuser -u postgres -- psql -X -d tp13 -c '\dt'
sudo runuser -u postgres -- psql -X -Atc 'show log_connections' -c 'show log_statement'
ls -l /var/run/postgresql/.s.PGSQL.5432
```

| Constat | Ce qu'il implique |
|---|---|
| On administre par `sudo runuser -u postgres` | Superutilisateur, sans nom : on ne sait pas qui a agi |
| `tp13app` possède la base `tp13` et la table `messages` | L'application peut vider ou supprimer ses propres données ; compromise, elle le peut aussi |
| `log_connections` à `off`, `log_statement` à `none` | Aucune trace des connexions ni des changements de structure |
| La socket `.s.PGSQL.5432` est ouverte à tous les comptes de la VM (`srwxrwxrwx`) | Elle ne protège rien par elle-même : c'est `pg_hba.conf` qui décide |

## Étape 2. Tracer d'abord

On active la trace avant de changer quoi que ce soit : les étapes suivantes y seront visibles.

```bash
# [VM] tp13-vm-bdd-demo
printf '%s\n' "log_connections = on" "log_disconnections = on" "log_statement = 'ddl'" \
  | sudo tee /etc/postgresql/17/main/conf.d/tp13-bis.conf
sudo runuser -u postgres -- psql -X -Atc 'select pg_reload_conf()'
sudo runuser -u postgres -- psql -X -Atc 'show log_connections'      # on
sudo tail -n 2 /var/log/postgresql/postgresql-17-main.log            # la dernière connexion, tracée
```

`log_statement = 'ddl'` trace les changements de structure (`CREATE`, `ALTER`, `DROP`), pas les
lectures ni les écritures de l'application. Une session déjà ouverte au moment du rechargement garde
l'ancienne valeur de `log_connections` : c'est pourquoi on la relit dans une nouvelle session.

## Étape 3. Un rôle d'administration

Le rôle `tp13adm` administrera la base. Il n'a pas de mot de passe : PostgreSQL l'accorde au seul
compte système `debian` de la VM, par l'authentification *peer* (le noyau dit quel compte se
connecte à la socket) et une table de correspondance (`pg_ident.conf`).

```bash
# [VM] tp13-vm-bdd-demo
sudo runuser -u postgres -- psql -X -c 'CREATE ROLE tp13adm LOGIN'
echo "tp13adm   debian   tp13adm" | sudo tee -a /etc/postgresql/17/main/pg_ident.conf
sudo sed -i '/^local   all             postgres/i local   tp13   tp13adm   peer map=tp13adm' \
  /etc/postgresql/17/main/pg_hba.conf
sudo grep -v '^#' /etc/postgresql/17/main/pg_hba.conf | grep -v '^$' | head -3   # la nouvelle ligne en premier
sudo runuser -u postgres -- psql -X -Atc 'select pg_reload_conf()'
sudo runuser -u postgres -- psql -X -Atc "select line_number, error from pg_hba_file_rules where error is not null"  # rien
```

`pg_hba.conf` est lu de haut en bas et la première ligne qui correspond décide : la ligne de
`tp13adm` doit précéder la ligne générale `local all all peer`.

```bash
# [VM] tp13-vm-bdd-demo
psql -X -U tp13adm -d tp13 -Atc 'select current_user'                        # tp13adm
psql -X -U postgres -d tp13 -Atc 'select 1'                                  # refusé
sudo runuser -u postgres -- psql -X -U tp13adm -d tp13 -Atc 'select 1'       # refusé
```

Les refus répondent `FATAL:  Peer authentication failed`. Le compte `debian` n'obtient que
`tp13adm`, et `tp13adm` n'est accordé qu'au compte `debian`.

## Étape 4. Retirer à l'application ce dont elle n'a pas besoin

L'application lit et ajoute des messages. Elle n'a besoin ni de supprimer, ni de vider, ni de
modifier la table. `tp13adm` devient le propriétaire ; `tp13app` ne garde que la lecture et l'ajout.

```bash
# [VM] tp13-vm-bdd-demo
sudo runuser -u postgres -- psql -X -d tp13 -c 'ALTER DATABASE tp13 OWNER TO tp13adm' \
  -c 'ALTER TABLE messages OWNER TO tp13adm' -c 'GRANT SELECT, INSERT ON messages TO tp13app'
```

Regardez l'application :

```bash
# [poste]
ssh -F ~/.ssh/tp13_config tp13-vm-web-haproxy-demo \
  'curl -s http://192.168.120.10/ | grep "data-test=\"etat-base\"" | sed "s/<[^>]*>//g"; sudo journalctl -u tp13-appli -n 3 --no-pager'
```

Résultat : `Bloquant : requête refusée par la base`, et dans le journal `permission denied for schema
public`, sur `create table if not exists messages`. L'application exécute cette instruction à chaque
requête ; PostgreSQL vérifie le droit de créer **avant** de constater que la table existe déjà.

Rendez-lui ce seul droit, en tant que `tp13adm`, désormais propriétaire de la base :

```bash
# [VM] tp13-vm-bdd-demo
psql -X -U tp13adm -d tp13 -c 'GRANT CREATE ON SCHEMA public TO tp13app'
```

```bash
# [poste]
ssh -F ~/.ssh/tp13_config tp13-vm-web-haproxy-demo \
  'curl -s http://192.168.120.10/ | grep "data-test=\"etat-base\"" | sed "s/<[^>]*>//g"'   # Réussi
```

Vérifiez ce que `tp13app` peut encore faire. `SET ROLE` fait agir le superutilisateur avec les
seuls droits de `tp13app` :

```bash
# [VM] tp13-vm-bdd-demo
for q in "SELECT count(*) FROM messages" "DELETE FROM messages" "TRUNCATE messages" "DROP TABLE messages"; do
  echo "$q :"; sudo runuser -u postgres -- psql -X -d tp13 -Atc 'SET ROLE tp13app' -c "$q" 2>&1 | tail -1
done
```

Seul le `SELECT` passe ; les autres répondent `permission denied for table messages` ou `must be
owner of table messages`.

## Étape 5. Administrer depuis le poste, sans port ouvert

Le tunnel relie un port local de votre poste à la **socket** de PostgreSQL sur la VM, à travers le
bastion. Aucun port n'est ouvert sur la VM ni dans les security groups.

```bash
# [poste]
ssh -F ~/.ssh/tp13_config -f -N -M -S ~/.ssh/tp13-bis.sock -o ExitOnForwardFailure=yes \
  -L 15432:/var/run/postgresql/.s.PGSQL.5432 tp13-vm-bdd-demo
psql -h localhost -p 15432 -U tp13adm -d tp13 -c 'select current_user, inet_server_addr()'
psql -h localhost -p 15432 -U tp13adm -d tp13 -c 'CREATE INDEX messages_cree_le ON messages (cree_le)'
psql -h localhost -p 15432 -U postgres -d tp13 -c 'select 1'      # refusé
```

`inet_server_addr()` est vide : vu de PostgreSQL, la connexion arrive par la socket, au nom du
compte `debian` qui a ouvert la session SSH. Il faut le client `psql` sur le poste (paquet
`postgresql-client`).

Le port reste fermé partout ailleurs :

```bash
# [VM] tp13-vm-bdd-demo
sudo ss -ltnp | grep postgres                  # 192.168.122.12:5432 seulement, comme au TP 13
```

```bash
# [instance]
nc -z -w 4 192.168.121.12 5432 && echo ouvert || echo fermé     # fermé : réseau adm
```

Fermez le tunnel :

```bash
# [poste]
ssh -S ~/.ssh/tp13-bis.sock -O exit tp13-vm-bdd-demo
psql -h localhost -p 15432 -U tp13adm -d tp13 -c 'select 1'       # refusé : plus de tunnel
```

## Étape 6. Qui a fait quoi ?

```bash
# [VM] tp13-vm-bdd-demo
sudo grep -E 'connection authorized|statement:|Peer authentication failed' \
  /var/log/postgresql/postgresql-17-main.log | tail -n 12
sudo journalctl -u ssh --since '-1 hour' --no-pager | grep Accepted | tail -n 3
exit
```

Le journal de PostgreSQL donne le rôle (`user=tp13adm`), l'heure et l'instruction (`CREATE INDEX`) ;
celui de SSH donne la clé qui a ouvert la session et l'adresse d'où elle vient (le bastion,
`10.0.2.1`). Les refus y figurent aussi. Et l'application elle-même apparaît à chaque page servie :
son `create table if not exists` est un changement de structure, tracé comme tel.

## Étape 7. Fin du TP

Le tunnel est fermé. Les réglages de ce TP vivent dans les VM : ils disparaissent avec elles au
nettoyage du TP 13. Continuez par l'**étape 16 du TP 13**.

## Questions

1. Qu'apporte `tp13adm` par rapport à `sudo runuser -u postgres` ? Sur ce lab, le compte `debian` est
   partagé : que faudrait-il pour savoir **quelle personne** a agi ?
2. Pourquoi l'application est-elle tombée à l'étape 4 ? Quel droit lui a-t-on rendu, et lequel garde-t-
   elle en trop ? Comment devrait-elle être écrite pour s'en passer ?
3. Avec le tunnel, quel port est ouvert, et sur quelle machine ? Pourquoi est-ce préférable à
   l'ouverture du port 5432 sur le réseau adm ?
4. Que permet de prouver le journal de PostgreSQL ? Qu'est-ce qui pourrait l'effacer ou le fausser, et
   comment s'en protéger ?

## Validation

- [ ] Journal activé : connexions et changements de structure tracés.
- [ ] `tp13adm` accordé au seul compte `debian` ; refus de `postgres` et de `tp13app` relevés.
- [ ] Panne de l'application constatée et expliquée ; application rétablie ; `DELETE`, `TRUNCATE` et
  `DROP` refusés à `tp13app`.
- [ ] Index créé depuis le poste par le tunnel ; aucun port ouvert en plus ; tunnel fermé.
- [ ] Questions 1 et 2 argumentées.

## Sources

- PostgreSQL 17 : `pg_hba.conf` <https://www.postgresql.org/docs/17/auth-pg-hba-conf.html>,
  authentification *peer* <https://www.postgresql.org/docs/17/auth-peer.html>,
  correspondances `pg_ident.conf` <https://www.postgresql.org/docs/17/auth-username-maps.html>
- PostgreSQL 17 : droits <https://www.postgresql.org/docs/17/ddl-priv.html>,
  journalisation <https://www.postgresql.org/docs/17/runtime-config-logging.html>
- OpenSSH : redirection vers une socket (`-L`), session maître (`-M`, `-S`, `-O exit`) <https://man.openbsd.org/ssh>
- Toutes les sources du parcours : [sources.md](../sources.md)
