# TP 10. Sauvegarder une VM : du dépôt local au stockage objet, puis hors de l'hôte

| | |
|---|---|
| Prérequis | TP 04, TP 08 ; scénario 04 (Cinder, Barbican, stockage objet du lab) |
| Coût | **Aucun** (niveaux 1 à 3). Le niveau 3 « cloud » (bucket AWS S3) est payant : accord du tuteur |
| À la fin du TP | Vous savez sauvegarder et restaurer, et dire ce qu'une sauvegarde protège réellement |

## Objectifs

- Sauvegarder les données d'une VM avec restic (chiffrement, déduplication) et tester la restauration.
- Comprendre le stockage objet (bucket, clé d'accès, API S3) avec Garage, un serveur S3 léger.
- Constater qu'une sauvegarde sur le même hôte ne protège pas de la perte de l'hôte, et en faire une
  copie ailleurs (règle 3-2-1).
- Comprendre pourquoi le mot de passe d'une sauvegarde doit lui aussi être conservé ailleurs.

La règle 3-2-1 : au moins 3 copies des données, sur 2 supports différents, dont 1 hors
site. Les trois niveaux du TP s'en rapprochent pas à pas :

| Niveau | Dépôt de sauvegarde | Survit à la perte de la VM ? | De l'hôte ? |
|---|---|---|---|
| 1 | 2ᵉ volume Cinder de la même VM | Oui, si le volume est rattaché ailleurs | Non |
| 2 | Bucket S3 (Garage) sur l'hôte | Oui | Non |
| 3 | Copie sur votre poste | Oui | Oui |

> Sur ce lab, Garage tourne à côté d'OpenStack (Swift n'existe plus dans Kolla-Ansible 2025.1). Il
> s'utilise comme n'importe quel service S3 : AWS S3, OVHcloud Object Storage, Ceph RGW…

---

## Étape 0. Vérifier les outils

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
sudo ./openstack-lab-trainee/tools/lab-s3.sh status      # un nœud, zone "lab", avec une capacité
restic version                                       # restic 0.19.1
file /usr/local/bin/restic                           # "statically linked" : copiable dans une VM
IPH=$(ip -o -4 route get 1.1.1.1 | grep -o 'src [0-9.]*' | cut -d' ' -f2)   # IP privée de l'instance
```

Si `lab-s3.sh` est absent ou ne répond pas : relancez le déploiement du scénario 04 (TP 08, étape 0).

## Étape 1. Une VM avec des données, et restic dedans

```bash
# [instance]
openstack server create --image cirros --flavor m1.tiny --key-name mykey \
  --network demo-net --wait tp10-vm
FIP=$(openstack floating ip create public1 -f value -c floating_ip_address)
openstack server add floating ip tp10-vm $FIP
openstack volume create --size 1 tp10-donnees          # les données à protéger
openstack volume create --size 1 tp10-depot            # le dépôt de sauvegarde du niveau 1
openstack server add volume tp10-vm tp10-donnees       # attendre "available" avant chaque ajout
openstack server add volume tp10-vm tp10-depot
scp -O /usr/local/bin/restic cirros@$FIP:/dev/shm/restic   # attendre ~1 min le démarrage
```

Deux particularités de CirrOS :
- `scp -O` : les versions récentes d'OpenSSH transfèrent par le protocole SFTP, que CirrOS ne propose
  pas (`sftp-server: not found`) ; `-O` force l'ancien protocole SCP ;
- `/dev/shm` : la partition système de CirrOS n'a que ~40 Mo libres ; on met restic (30 Mo) en
  mémoire. À recopier si la VM redémarre.

Le mot de passe du dépôt est généré, rangé dans Barbican (TP 08), puis transmis à la VM par l'entrée
standard : il n'apparaît dans aucune commande exécutée sur la VM.

```bash
# [instance]
HPW=$(openstack secret store --name tp10-mdp-restic --payload "$(openssl rand -base64 24)" \
  -f value -c "Secret href")
openstack secret get --payload -f value -c Payload $HPW | ssh cirros@$FIP "umask 077; cat > /dev/shm/restic-pw"
ssh cirros@$FIP
```

```bash
# [VM]
sudo mkfs.ext4 /dev/vdb && sudo mkfs.ext4 /dev/vdc
sudo mkdir -p /mnt/donnees /mnt/depot
sudo mount /dev/vdb /mnt/donnees && sudo mount /dev/vdc /mnt/depot
for i in 1 2 3; do sudo sh -c "head -c 1048576 /dev/urandom > /mnt/donnees/f$i.bin"; done
echo rapport | sudo tee /mnt/donnees/rapport.txt
(cd /mnt/donnees && sudo find . -type f -exec md5sum {} \; | sort) > /dev/shm/ref.md5   # empreintes de référence
export TMPDIR=/dev/shm RESTIC_CACHE_DIR=/dev/shm/restic-cache RESTIC_PASSWORD_FILE=/dev/shm/restic-pw
```

## Étape 2. Niveau 1 : un dépôt local

```bash
# [VM]
sudo -E /dev/shm/restic -r /mnt/depot/restic init
sudo -E /dev/shm/restic -r /mnt/depot/restic backup /mnt/donnees
sudo -E /dev/shm/restic -r /mnt/depot/restic snapshots
```

Une sauvegarde ne vaut que si sa restauration est testée :

```bash
# [VM]
sudo -E /dev/shm/restic -r /mnt/depot/restic restore latest --target /dev/shm/r1
sudo sh -c 'cd /dev/shm/r1/mnt/donnees && find . -type f -exec md5sum {} \; | sort' | cmp - /dev/shm/ref.md5 \
  && echo "restauration identique"
```

`sudo` est nécessaire : restic restaure les propriétaires d'origine (root).

## Étape 3. Niveau 2 : le stockage objet

En administrateur du stockage, sur l'instance : une clé d'accès, un bucket, et le droit de la clé
sur ce bucket.

```bash
# [instance] : dans une 2e session SSH (la 1re reste dans la VM) : on recharge l'environnement
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
IPH=$(ip -o -4 route get 1.1.1.1 | grep -o 'src [0-9.]*' | cut -d' ' -f2)
FIP=<FLOATING_IP_DE_TP10-VM>                                # la valeur de $FIP de la 1re session
G="sudo docker exec lab-s3 /garage"
$G key create tp10-cle
$G bucket create tp10-sauvegardes
$G bucket allow --read --write --owner tp10-sauvegardes --key tp10-cle
KI=$($G key info tp10-cle --show-secret | awk '/Key ID/{print $3}')
KS=$($G key info tp10-cle --show-secret | awk '/Secret key/{print $3}')
echo $KI                                                    # identifiant de la clé (pas secret)
HS3=$(openstack secret store --name tp10-s3-secret --payload "$KS" -f value -c "Secret href")
openstack secret get --payload -f value -c Payload $HS3 | ssh cirros@$FIP "umask 077; cat > /dev/shm/s3-secret"
```

Dans la VM, restic parle S3 au serveur de l'hôte (`<IP_PRIVEE_INSTANCE>` est la valeur de `$IPH`) :

```bash
# [VM]
export AWS_ACCESS_KEY_ID=<KI> AWS_DEFAULT_REGION=garage
export AWS_SECRET_ACCESS_KEY=$(cat /dev/shm/s3-secret)
S3=s3:http://<IP_PRIVEE_INSTANCE>:3900/tp10-sauvegardes/vm1
sudo -E /dev/shm/restic -r $S3 init
sudo -E /dev/shm/restic -r $S3 backup /mnt/donnees
sudo -E /dev/shm/restic -r $S3 restore latest --target /dev/shm/r2
sudo sh -c 'cd /dev/shm/r2/mnt/donnees && find . -type f -exec md5sum {} \; | sort' | cmp - /dev/shm/ref.md5 \
  && echo "restauration identique"
```

Moindre privilège : essayez un dépôt dans un bucket qui n'existe pas.

```bash
# [VM]
sudo -E /dev/shm/restic -r s3:http://<IP_PRIVEE_INSTANCE>:3900/un-autre-bucket init
```

Réponse : `Access key … is not allowed to create buckets`. La clé ne peut que lire et écrire dans le
bucket qu'on lui a confié ; c'est l'administrateur qui crée les buckets. D'où le dépôt dans un
chemin du bucket (`…/tp10-sauvegardes/vm1`).

Ce que voit le stockage, et où il est :

```bash
# [instance]
S3C=(s3cmd --access_key="$KI" --secret_key="$KS" --host="$IPH:3900" --host-bucket="$IPH:3900" --no-ssl --region=garage)
"${S3C[@]}" ls --recursive s3://tp10-sauvegardes        # config, data/…, index/…, keys/… : des noms opaques
sudo grep -rac rapport /srv/lab-s3/data | awk -F: '{s+=$NF} END{print s+0}'   # 0 : tout est chiffré
sudo du -sh /srv/lab-s3/data                            # les objets sont… sur le disque de l'instance
```

## Étape 4. Niveau 3 : une copie hors de l'hôte

Les niveaux 1 et 2 disparaissent avec l'instance. On copie le dépôt sur votre poste, en le tirant
depuis le poste par un tunnel SSH : rien n'est ouvert dans le Security Group.

Installer restic sur le poste (binaire officiel, empreinte vérifiée, sans droits root) :

```bash
# [poste]
V=0.19.1; B=restic_${V}_linux_amd64.bz2
curl -sSLO https://github.com/restic/restic/releases/download/v$V/$B
curl -sSLO https://github.com/restic/restic/releases/download/v$V/SHA256SUMS
grep " $B\$" SHA256SUMS | sha256sum -c -               # doit répondre OK
bunzip2 $B && mkdir -p ~/bin && install -m 755 restic_${V}_linux_amd64 ~/bin/restic
~/bin/restic version
```

Mettre le mot de passe en séquestre sur le poste : sans lui, la copie serait illisible le jour où
l'instance (et donc Barbican) n'existe plus.

```bash
# [poste] : <HPW> est la valeur de $HPW sur l'instance (echo $HPW)
mkdir -p ~/tp10 && umask 077
ssh -i ec2_key ubuntu@<IP_PUBLIQUE> \
  "source ~/kolla/venv/bin/activate; source /etc/kolla/admin-openrc.sh; openstack secret get --payload -f value -c Payload <HPW>" \
  > ~/tp10/mdp-sequestre
```

Copier le dépôt à travers un tunnel vers le port S3 de l'instance :

```bash
# [poste]
ssh -i ec2_key -f -N -L 3900:<IP_PRIVEE_INSTANCE>:3900 ubuntu@<IP_PUBLIQUE>
export AWS_ACCESS_KEY_ID=<KI> AWS_SECRET_ACCESS_KEY=<KS> AWS_DEFAULT_REGION=garage
SRC=s3:http://localhost:3900/tp10-sauvegardes/vm1
~/bin/restic -r ~/tp10/depot-poste init --password-file ~/tp10/mdp-sequestre \
  --from-repo $SRC --from-password-file ~/tp10/mdp-sequestre --copy-chunker-params
~/bin/restic -r ~/tp10/depot-poste copy --password-file ~/tp10/mdp-sequestre \
  --from-repo $SRC --from-password-file ~/tp10/mdp-sequestre
pkill -f "3900:<IP_PRIVEE_INSTANCE>:3900"                # fermer le tunnel
```

`--copy-chunker-params` donne aux deux dépôts le même découpage des données : les copies suivantes ne
transfèrent que ce qui a changé.

Simuler la perte de l'instance : le tunnel est fermé, on n'utilise plus que le poste.

```bash
# [poste]
~/bin/restic -r ~/tp10/depot-poste snapshots --password-file ~/tp10/mdp-sequestre
~/bin/restic -r ~/tp10/depot-poste restore latest --target ~/tp10/restaure --password-file ~/tp10/mdp-sequestre
ssh -i ec2_key ubuntu@<IP_PUBLIQUE> "ssh cirros@<FIP> cat /dev/shm/ref.md5" > ~/tp10/ref.md5   # empreintes d'origine
(cd ~/tp10/restaure/mnt/donnees && find . -type f -exec md5sum {} \; | sort) | cmp - ~/tp10/ref.md5 \
  && echo "restauration depuis le poste identique"
```

La restauration affiche des erreurs `lchown … invalid argument` puis `Fatal: There were 7 errors` :
elles ne portent que sur le propriétaire des fichiers (root dans la VM), qu'un utilisateur normal
ne peut pas redonner. Le contenu est intact : les empreintes le prouvent.

Et sans le mot de passe :

```bash
# [poste]
~/bin/restic -r ~/tp10/depot-poste snapshots --insecure-no-password
```

Réponse : `wrong password or no key found`. Personne ne peut lire la copie sans le mot de passe… vous
non plus.

## Étape 5. (Optionnel, payant, accord du tuteur) Le niveau 3 « cloud »

En entreprise, la copie hors site va dans un stockage objet **d'un autre fournisseur ou d'une autre
région**. Sur AWS : un bucket S3 dans une autre région, un utilisateur IAM limité à ce bucket (ses
clés dans Barbican), une règle de cycle de vie qui supprime les anciennes données, éventuellement
*Object Lock* pour empêcher toute suppression pendant une durée donnée (protection contre un
rançongiciel). Le coût est de quelques centimes par mois pour un TP (voir
[../aws/finops.md](../aws/finops.md)), à condition de supprimer le bucket à la fin. Cette étape
n'a pas été réalisée sur le lab.

## Étape 6. Nettoyage

```bash
# [poste]
rm -rf ~/tp10
```

```bash
# [instance]
"${S3C[@]}" del --recursive --force s3://tp10-sauvegardes   # un bucket doit être vide pour être supprimé
$G bucket delete --yes tp10-sauvegardes
$G key delete --yes tp10-cle
openstack server remove volume tp10-vm tp10-donnees
openstack server remove volume tp10-vm tp10-depot
sleep 10
openstack volume delete tp10-donnees
openstack volume delete tp10-depot
openstack server delete --wait tp10-vm
openstack floating ip delete $FIP
openstack secret delete $HPW
openstack secret delete $HS3
```

## Questions

1. Pourquoi « une sauvegarde non restaurée n'est pas une sauvegarde » ?
2. Le niveau 2 utilise un « vrai » stockage objet. Protège-t-il mieux que le niveau 1 contre la perte de
   l'instance ? Qu'apporte-t-il alors ?
3. Le mot de passe du dépôt est dans Barbican. Pourquoi le mettre aussi en séquestre hors de
   l'hôte ? Que se passe-t-il sinon le jour où l'instance est perdue ?
4. Pourquoi la clé `tp10-cle` ne peut-elle pas créer de bucket ? Quel risque cela limite-t-il ?
5. Un rançongiciel chiffre la VM et dispose de la clé S3. Que peut-il faire au dépôt du niveau 2 ?
   Quelle fonction d'un stockage objet l'en empêcherait ?
6. Proposez une organisation 3-2-1 réaliste pour une VM de production sur OpenStack.

## Validation

- [ ] Restauration identique aux niveaux 1, 2 et 3 (empreintes comparées).
- [ ] Refus `not allowed to create buckets` relevé et expliqué.
- [ ] Copie du poste restaurée tunnel fermé ; échec sans mot de passe constaté.
- [ ] Questions 2, 3 et 5 argumentées.
- [ ] Nettoyage fait (instance et poste).

## Sources

- restic : <https://restic.readthedocs.io/en/stable/>
- restic : créer un dépôt (dont S3) : <https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html>
- restic : copier entre dépôts : <https://restic.readthedocs.io/en/stable/045_working_with_repos.html>
- restic : rétention et purge (`forget`, `--group-by`) : <https://restic.readthedocs.io/en/stable/060_forget.html>
- restic : versions et empreintes : <https://github.com/restic/restic/releases>
- Garage : <https://garagehq.deuxfleurs.fr/documentation/>
- s3cmd : <https://s3tools.org/s3cmd>
- AWS S3 : verrouillage d'objets : <https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html>
- AWS S3 : cycle de vie : <https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html>
- AWS S3 : tarifs : <https://aws.amazon.com/s3/pricing/>
- Toutes les sources du parcours : [sources.md](sources.md)
