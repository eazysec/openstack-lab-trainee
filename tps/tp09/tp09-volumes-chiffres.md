# TP 09. Chiffrer les volumes Cinder

| | |
|---|---|
| Prérequis | TP 04 et TP 08 ; scénario 04 (Cinder + Barbican) |
| À la fin du TP | Vous savez chiffrer un volume et dire contre quoi ce chiffrement protège |

## Objectifs

- Créer un type de volume chiffré (LUKS) et un volume de ce type.
- Constater que la VM voit les données en clair et que le stockage ne contient que du chiffré.
- Comprendre le rôle de Barbican : où est la clé, qui la demande, qui peut s'en servir.
- Savoir contre quoi ce chiffrement protège, et contre quoi il ne protège pas.

---

## Étape 0. Vérifier les conditions d'entrée

```bash
# [instance]
./openstack-lab-trainee/tps/tp09/verifier-entree.sh        # dernière ligne : "Lab prêt pour le TP 09."
```

Ce script ne modifie rien. Il vérifie que la plateforme répond, que les ressources communes du déploiement sont là (`mykey`,
`demo-net`, `public1`, `demo-router`, `cirros`, `m1.tiny`), que Cinder et Barbican sont déployés (scénario 04) et
qu'il ne reste rien d'un essai précédent (`tp09-`, type de volume compris).
Chaque écart est affiché avec ce qu'il faut faire. Ne commencez pas tant que la dernière ligne n'est
pas `Lab prêt pour le TP 09.`

## Étape 1. Un type de volume chiffré (en admin)

Le chiffrement se décide par le type du volume.

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
openstack volume type create --encryption-provider luks --encryption-cipher aes-xts-plain64 \
  --encryption-key-size 256 --encryption-control-location front-end tp09-voltype-luks
openstack volume type show --encryption-type tp09-voltype-luks -f value -c encryption
```

`front-end` : le chiffrement et le déchiffrement sont faits par l'hôte de calcul (Nova), au
moment où le volume est branché à la VM.

## Étape 2. Un volume chiffré

```bash
# [instance]
openstack volume create --size 1 --type tp09-voltype-luks tp09-vol
openstack volume show tp09-vol -c status -c encrypted        # attendre "available" ; encrypted = True
openstack secret list -c Name -c Algorithm -c "Bit length" -c Created
```

Un nouveau secret est apparu dans Barbican : une clé AES de 256 bits, sans nom, créée par Cinder pour
ce volume.

## Étape 3. Dans la VM, tout est en clair

```bash
# [instance]
openstack server create --image cirros --flavor m1.tiny --key-name mykey \
  --network demo-net --wait tp09-vm
FIP=$(openstack floating ip create public1 -f value -c floating_ip_address)
openstack server add floating ip tp09-vm $FIP
openstack server add volume tp09-vm tp09-vol
ssh cirros@$FIP                           # attendre ~1 min le démarrage
```

```bash
# [VM]
lsblk                                     # vdb fait 1022 Mo et non 1024 : l'en-tête LUKS occupe la place
sudo mkfs.ext4 /dev/vdb
sudo mkdir -p /mnt/secret
sudo mount /dev/vdb /mnt/secret
echo "donnees confidentielles" | sudo tee /mnt/secret/note.txt
sudo cat /mnt/secret/note.txt
sudo umount /mnt/secret
exit
```

## Étape 4. Sur le stockage, tout est chiffré

```bash
# [instance]
ID=$(openstack volume show tp09-vol -f value -c id)
LV=/dev/cinder-volumes/volume-$ID                  # le volume, tel que stocké par Cinder
sudo head -c 6 $LV | od -c | head -1               # "L U K S" : un en-tête LUKS
sudo cryptsetup luksDump $LV | head -8             # version, algorithme, emplacements de clé
sudo grep -ac "donnees confidentielles" $LV        # 0 : le texte n'apparaît nulle part
```

## Étape 5. Le rôle de Barbican

C'est Cinder qui demande la clé à Barbican, au nom de l'utilisateur qui crée le volume. Il
faut donc que cet utilisateur ait le droit d'utiliser Barbican (TP 08).

```bash
# [instance]
openstack project create tp09-proj
openstack user create --project tp09-proj --password-prompt tp09-user
openstack role add --project tp09-proj --user tp09-user member
cat > ~/tp09-openrc.sh <<EOF
for v in \$(env | grep -o '^OS_[A-Z_]*'); do unset \$v; done
export OS_AUTH_URL=$OS_AUTH_URL
export OS_IDENTITY_API_VERSION=3
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_PROJECT_NAME=tp09-proj
export OS_USERNAME=tp09-user
read -rsp "Mot de passe de tp09-user : " OS_PASSWORD; echo; export OS_PASSWORD
EOF
source ~/tp09-openrc.sh
openstack volume create --size 1 --type tp09-voltype-luks tp09-vol-user
```

Réponse : `Key manager error (HTTP 400)`. Ajoutez le rôle `creator` et recommencez :

```bash
# [instance]
source /etc/kolla/admin-openrc.sh
openstack role add --project tp09-proj --user tp09-user creator
source ~/tp09-openrc.sh
openstack volume create --size 1 --type tp09-voltype-luks tp09-vol-user
openstack volume show tp09-vol-user -c status              # "available"
openstack volume delete tp09-vol-user
```

## Étape 6. Nettoyage

```bash
# [instance]
source /etc/kolla/admin-openrc.sh
openstack server remove volume tp09-vm tp09-vol
openstack volume delete tp09-vol          # Cinder supprime aussi la clé dans Barbican
openstack server delete --wait tp09-vm
openstack floating ip delete $FIP
openstack secret list                     # la clé du volume a disparu
sleep 10                                  # laisser Cinder finir la suppression du volume
openstack volume type delete tp09-voltype-luks    # possible une fois qu'aucun volume ne l'utilise
openstack user delete tp09-user
openstack project delete tp09-proj
rm ~/tp09-openrc.sh
```

## Questions

1. À quel endroit les données sont-elles en clair ? À quel endroit sont-elles chiffrées ?
2. Contre quoi ce chiffrement protège-t-il ? (pensez au vol d'un disque, à l'accès au stockage, aux
   sauvegardes) Contre quoi ne protège-t-il pas ? (pensez à l'hôte de calcul et à la VM)
3. Pourquoi `tp09-user` ne pouvait-il pas créer de volume chiffré avec le seul rôle `member` ?
4. Que devient la clé quand on supprime le volume ? Et si on perdait la base de Barbican ?

## Validation

- [ ] Texte lu en clair dans la VM, introuvable sur le volume côté hôte, en-tête LUKS relevé.
- [ ] Erreur `Key manager error` reproduite, puis création réussie avec `creator`.
- [ ] Questions 2 et 4 argumentées.
- [ ] Nettoyage fait.

## Sources

- Cinder : chiffrement des volumes : <https://docs.openstack.org/cinder/2025.1/configuration/block-storage/volume-encryption.html>
- Barbican : <https://docs.openstack.org/barbican/2025.1/>
- Cinder dans Kolla-Ansible : <https://docs.openstack.org/kolla-ansible/2025.1/reference/storage/cinder-guide.html>
- Guide de sécurité OpenStack : <https://docs.openstack.org/security-guide/>
- Toutes les sources du parcours : [sources.md](../sources.md)
