# TP 03. Comprendre le réseau Neutron

| | |
|---|---|
| Durée | 2 h |
| Prérequis | TP 02 ; avoir lu [../README.md §5](../README.md) |
| À la fin du TP | Vous savez construire un réseau complet et suivre un paquet de la VM jusqu'à Internet |

## Objectifs

- Créer un réseau privé, un sous-réseau, un routeur et un security group.
- Observer sur l'hôte ce que Neutron a créé : namespaces, ponts Open vSwitch, règles NAT.
- Distinguer ce qui relève d'OpenStack, de l'hôte Linux et d'AWS.

---

## Étape 1. Construire son propre réseau

```bash
# [instance]
source ~/kolla/venv/bin/activate
source /etc/kolla/admin-openrc.sh

openstack network create tp03-net
openstack subnet create --network tp03-net --subnet-range 192.168.30.0/24 \
  --dns-nameserver 8.8.8.8 tp03-subnet

openstack router create tp03-router
openstack router set --external-gateway public1 tp03-router     # sortie vers le réseau externe
openstack router add subnet tp03-router tp03-subnet             # entrée côté réseau privé
```

## Étape 2. Un security group sur mesure

Un security group est un pare-feu appliqué à chaque port de VM. Par défaut, tout ce qui entre est
refusé.

```bash
# [instance]
openstack security group create tp03-sg
openstack security group rule create --protocol icmp tp03-sg
openstack security group rule create --protocol tcp --dst-port 22 tp03-sg
openstack security group rule list tp03-sg
```

## Étape 3. Une VM sur ce réseau

```bash
# [instance]
openstack server create --image cirros --flavor m1.tiny --key-name mykey \
  --network tp03-net --security-group tp03-sg --wait tp03-vm
FIP=$(openstack floating ip create public1 -f value -c floating_ip_address)
openstack server add floating ip tp03-vm $FIP
echo $FIP
```

Attendez environ une minute (démarrage de la VM), puis :

```bash
# [instance]
ssh cirros@$FIP
```

```bash
# [VM]
ip addr          # 192.168.30.x : le sous-réseau que vous avez créé
ip route         # passerelle 192.168.30.1 : le routeur tp03-router
exit
```

Expérience : retirez la règle SSH et réessayez de vous connecter.

```bash
# [instance]
openstack security group rule list tp03-sg -f value -c ID -c "Port Range"
openstack security group rule delete <ID_DE_LA_REGLE_22:22>
ssh -o ConnectTimeout=5 cirros@$FIP          # échoue : le security group bloque
ping -c2 $FIP                                # fonctionne toujours : ICMP est autorisé
openstack security group rule create --protocol tcp --dst-port 22 tp03-sg
```

## Étape 4. Ce que Neutron a créé sur l'hôte

Les namespaces réseau. Chaque routeur Neutron est un *namespace* Linux : une pile réseau isolée,
avec ses propres interfaces, routes et règles de pare-feu.

```bash
# [instance]
ROUTER_ID=$(openstack router show tp03-router -f value -c id)
sudo ip netns | grep $ROUTER_ID
sudo ip netns exec qrouter-$ROUTER_ID ip addr
```

Repérez l'interface `qr-…` (côté réseau privé, 192.168.30.1) et l'interface `qg-…` (côté réseau
externe, une adresse 10.0.2.x, plus la floating IP).

```bash
# [instance]
sudo ip netns exec qrouter-$ROUTER_ID iptables -t nat -S | grep -E "SNAT|DNAT"
```

Vous voyez la traduction de la floating IP vers l'IP privée de la VM (DNAT) et dans l'autre sens (SNAT).

Les ponts Open vSwitch.

```bash
# [instance]
sudo docker exec openvswitch_vswitchd ovs-vsctl list-br
sudo docker exec openvswitch_vswitchd ovs-vsctl list-ports br-ex
```

`br-ex` contient `veth-neutron` : c'est l'extrémité de la paire veth créée par le lab (voir
[../README.md §5.2](../README.md)).

Le NAT de l'hôte vers AWS.

```bash
# [instance]
ip addr show veth-ext                                  # passerelle 10.0.2.1 du réseau externe
sudo iptables -t nat -S POSTROUTING | grep 10.0.2.0
```

## Étape 5. Suivre un paquet

Ouvrez deux sessions SSH sur l'instance.

```bash
# [instance] : session 1 : écouter le trafic ICMP sur la paire veth
sudo tcpdump -ni veth-ext icmp
```

```bash
# [instance] : session 2
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh
ssh cirros@<FIP> ping -c3 8.8.8.8
```

Dans la session 1, relevez l'adresse source des paquets. Arrêtez tcpdump (Ctrl+C), puis recommencez
en écoutant sur `enX0` : `sudo tcpdump -ni enX0 icmp and host 8.8.8.8`. Comparez les adresses source.

## Étape 6. Nettoyage

```bash
# [instance]
openstack server delete --wait tp03-vm
openstack floating ip delete $FIP
openstack router remove subnet tp03-router tp03-subnet
openstack router unset --external-gateway tp03-router
openstack router delete tp03-router
openstack network delete tp03-net               # supprime aussi tp03-subnet
openstack security group delete tp03-sg
```

## Questions

1. Dessinez le chemin d'un paquet de `tp03-vm` vers 8.8.8.8 : chaque interface traversée et l'adresse
   source à chaque étape. Indiquez pour chaque étape si elle relève d'OpenStack, de l'hôte Linux ou d'AWS.
2. Quelle adresse source voyez-vous sur `veth-ext` ? Et sur `enX0` ? Qui a fait chaque traduction ?
3. Quelle différence entre un security group OpenStack et un Security Group AWS ?
4. Pourquoi supprimer le sous-réseau du routeur avant de supprimer le routeur ?

## Validation

- [ ] VM joignable en SSH sur `tp03-net`.
- [ ] Expérience du security group réalisée (SSH bloqué, ping toujours OK).
- [ ] Schéma du chemin du paquet, avec les adresses relevées.
- [ ] Nettoyage fait.

## Sources

- Neutron : réseaux *self-service* avec Open vSwitch : <https://docs.openstack.org/neutron/2025.1/admin/deploy-ovs-selfservice.html>
- Neutron dans Kolla-Ansible : <https://docs.openstack.org/kolla-ansible/2025.1/reference/networking/neutron.html>
- Neutron : MTU : <https://docs.openstack.org/neutron/2025.1/admin/config-mtu.html>
- `ip netns` : <https://man7.org/linux/man-pages/man8/ip-netns.8.html>
- Open vSwitch : <https://docs.openvswitch.org/en/latest/>
- `tcpdump` : <https://www.tcpdump.org/manpages/tcpdump.1.html>
- Security Groups AWS : <https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html>
- Toutes les sources du parcours : [sources.md](sources.md)
