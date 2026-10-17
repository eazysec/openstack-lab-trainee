# TP 07. Floating IP publiques et réseau AWS

| | |
|---|---|
| Durée | 1 h 30 |
| Prérequis | TP 03 ; avoir lu [../aws/aws-setup.md §2.3 et §4](../aws/aws-setup.md) |
| Coût | **Aucun** : la partie AWS est simulée. La version réelle (Elastic IP payante) se fait uniquement avec l'accord du tuteur |
| À la fin du TP | Vous savez pourquoi une floating IP n'est pas joignable depuis Internet sur AWS, et comment la publier |

## Objectifs

- Comprendre la règle AWS : **une IP n'est routée vers une instance que si elle est déclarée sur son
  interface réseau (ENI)**.
- Comprendre le montage du scénario 03 : IP secondaire de l'ENI → NAT 1:1 par l'hôte → floating IP.
- Le tester sans rien créer dans AWS, avec un client « Internet » simulé.

> Règle du lab n°2 : on ne modifie jamais le réseau de `enX0` à la main. Ce TP passe uniquement par
> les outils du dépôt, qui ont un retour arrière automatique.

---

## Étape 1. Constater le problème

```bash
# [instance]
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
openstack server create --image cirros --flavor m1.tiny --key-name mykey \
  --network demo-net --wait tp07-vm
FIP=$(openstack floating ip create public1 -f value -c floating_ip_address)
openstack server add floating ip tp07-vm $FIP
echo $FIP
ip addr show enX0           # la floating IP n'apparaît pas sur l'interface de l'instance
```

Depuis votre poste, `ping <FIP>` ne peut pas fonctionner : 10.0.2.x est une adresse privée, interne à
l'hôte, que ni Internet ni le VPC AWS ne connaissent.

## Étape 2. Le montage du scénario 03, sur le papier

Lisez [../aws/aws-setup.md §4](../aws/aws-setup.md) et complétez ce tableau dans votre compte rendu :

| Étape | Adresse destination du paquet | Qui fait la traduction | Couche (AWS / hôte / OpenStack) |
|---|---|---|---|
| Internet → AWS | Elastic IP | | |
| AWS → instance | | | |
| instance → routeur Neutron | | | |
| routeur Neutron → VM | | | |

## Étape 3. Le tester sans AWS

`tests/test-public-fip.sh` prend une IP libre du sous-réseau de l'instance, la publie comme le
ferait le scénario 03, puis simule un client Internet dans un *network namespace*. Cette IP n'est pas
déclarée chez AWS : elle n'a d'effet que sur l'hôte.

Choisissez une IP libre avec le tuteur. Il peut vérifier qu'aucune interface du VPC ne l'utilise
(lecture seule, gratuit) :

```bash
# [poste] : AWS CLI configurée ; ne doit rien afficher
aws ec2 describe-network-interfaces --filters Name=addresses.private-ip-address,Values=<IP_LIBRE> \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
```

Lancez le test détaché de la session SSH (s'il touche au réseau, une coupure ne doit pas
l'interrompre au milieu) :

```bash
# [instance]
setsid nohup ./openstack-lab-trainee/tests/test-public-fip.sh <IP_LIBRE> > ~/tp07.out 2>&1 < /dev/null &
tail -f ~/tp07.out                  # Ctrl+C quand "Résultat" apparaît (~5 min)
```

Résultat attendu : `Résultat : 28 réussis, 0 échoués`. Le test supprime tout ce qu'il a créé.

Lisez le script et la sortie, et repérez :
- la ligne qui pose l'IP secondaire en `/32` et pourquoi elle est « dépréciée » ;
- le test « l'hôte émet toujours avec … » et ce qu'il protège ;
- le test du retour arrière automatique.

## Étape 4. (Optionnel, payant, accord du tuteur) La version réelle

Suivre [../aws/aws-setup.md §4](../aws/aws-setup.md), étapes 1 à 7, y compris le nettoyage qui
libère l'Elastic IP et arrête la facturation.

## Étape 5. Nettoyage

```bash
# [instance]
openstack server delete --wait tp07-vm
openstack floating ip delete $FIP
rm -f ~/tp07.out
```

## Questions

1. Pourquoi le VPC ignore-t-il les annonces ARP que Neutron fait pour ses floating IP ?
2. Dans le scénario 03, pourquoi faut-il déclarer l'IP secondaire côté AWS (sur l'ENI) en plus de
   la poser sur l'hôte ?
3. Pourquoi l'IP secondaire ne doit-elle jamais être utilisée comme adresse source par l'hôte ?
   Que s'est-il passé quand c'est arrivé ? ([../aws/aws-setup.md §6](../aws/aws-setup.md))
4. Citez deux autres façons d'accéder à une VM depuis votre poste, sans aucun coût.
   ([../aws/aws-setup.md §3.2](../aws/aws-setup.md))

## Validation

- [ ] Tableau de l'étape 2 complété.
- [ ] `test-public-fip.sh` : 28 réussis, 0 échoués, et les trois points du script expliqués.
- [ ] Nettoyage fait.

## Sources

- Adresses IP multiples (AWS) : <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/MultipleIP.html>
- Elastic IP : <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/elastic-ip-addresses-eip.html>
- `ip address` (`preferred_lft`) : <https://man7.org/linux/man-pages/man8/ip-address.8.html>
- systemd-networkd : fichiers `.network` : <https://man7.org/linux/man-pages/man5/systemd.network.5.html>
- networkd-dispatcher : <https://gitlab.com/craftyguy/networkd-dispatcher>
- Récupération par user-data (AWS) : <https://repost.aws/knowledge-center/execute-user-data-ec2>
- Incident réseau du lab : [../aws/aws-setup.md](../aws/aws-setup.md)
- Toutes les sources du parcours : [sources.md](sources.md)
