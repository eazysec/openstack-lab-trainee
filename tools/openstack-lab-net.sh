#!/bin/sh
# =============================================================================
#  openstack-lab-net.sh : réseau hôte du lab (exécuté au boot par systemd,
#  service openstack-lab-net). Idempotent : peut être relancé à tout moment.
#
#  1. Paire veth : VETH_NEUTRON est donnée à br-ex (OVS), VETH_HOST porte la
#     passerelle EXT_GW du réseau externe Neutron.
#  2. NAT sortant : le trafic du réseau externe sort avec l'IP de l'ENI
#     (seule IP que le VPC AWS accepte).
#  3. (Scénario 03) Floating IP publiques : pour chaque ligne de
#     /etc/openstack-lab/public-fip.map "IP_PRIVEE_SECONDAIRE FLOATING_IP",
#     l'hôte porte l'IP secondaire sur l'ENI et fait un NAT 1:1 vers la
#     floating IP. AWS associe l'Elastic IP à cette IP secondaire.
# =============================================================================
set -eu
. /etc/openstack-lab/network.env
MAP=/etc/openstack-lab/public-fip.map

# ---- 1. paire veth
ip link show "$VETH_HOST" >/dev/null 2>&1 || ip link add "$VETH_HOST" type veth peer name "$VETH_NEUTRON"
ip addr replace "$EXT_GW/${EXT_CIDR#*/}" dev "$VETH_HOST"
ip link set "$VETH_HOST" up
ip link set "$VETH_NEUTRON" up
sysctl -qw net.ipv4.ip_forward=1

# ---- 2. NAT sortant + autorisation du transit
iptables -t nat -C POSTROUTING -s "$EXT_CIDR" -o "$MGMT_IF" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s "$EXT_CIDR" -o "$MGMT_IF" -j MASQUERADE
iptables -C FORWARD -s "$EXT_CIDR" -j ACCEPT 2>/dev/null || iptables -I FORWARD -s "$EXT_CIDR" -j ACCEPT
iptables -C FORWARD -d "$EXT_CIDR" -j ACCEPT 2>/dev/null || iptables -I FORWARD -d "$EXT_CIDR" -j ACCEPT

# ---- 3. floating IP publiques (NAT 1:1). Chaîne dédiée, reconstruite à chaque appel.
# Les IP secondaires sont posées en /32 et "dépréciées" (preferred lifetime 0) : elles
# reçoivent le trafic mais ne sont JAMAIS choisies comme source par l'hôte. Sans cela,
# une IP secondaire peut devenir l'adresse principale du sous-réseau : l'hôte émet alors
# avec elle, et si elle n'est pas (ou plus) déclarée sur l'ENI, AWS jette tout son trafic.
PREFIX=32
for chain in LAB_FIP_PRE LAB_FIP_POST LAB_FIP_OUT; do
  iptables -t nat -N "$chain" 2>/dev/null || iptables -t nat -F "$chain"
done
iptables -t nat -C PREROUTING  -j LAB_FIP_PRE  2>/dev/null || iptables -t nat -I PREROUTING  -j LAB_FIP_PRE
iptables -t nat -C OUTPUT      -j LAB_FIP_OUT  2>/dev/null || iptables -t nat -I OUTPUT      -j LAB_FIP_OUT
iptables -t nat -C POSTROUTING -j LAB_FIP_POST 2>/dev/null || iptables -t nat -I POSTROUTING -j LAB_FIP_POST

[ -f "$MAP" ] && ENTRIES=$(grep -Ev '^[[:space:]]*(#|$)' "$MAP" || true) || ENTRIES=""

# Règles NAT 1:1
echo "$ENTRIES" | while read -r priv fip; do
  [ -n "$priv" ] || continue
  iptables -t nat -A LAB_FIP_PRE  -d "$priv" -j DNAT --to-destination "$fip"
  iptables -t nat -A LAB_FIP_OUT  -d "$priv" -j DNAT --to-destination "$fip"
  iptables -t nat -A LAB_FIP_POST -s "$fip" -o "$MGMT_IF" -j SNAT --to-source "$priv"
done

# NB : dans les boucles, toujours "if" et non "[ … ] && …" : avec set -e, un test faux en
# dernière commande de la boucle rendrait le script en échec (cas d'une liste vide).
# IP secondaires sur l'interface, ajoutées avec "ip addr" (étiquette labfip pour les retrouver).
# On ne touche PAS à la configuration systemd-networkd de l'interface d'administration :
# une adresse statique y déclenche une détection de conflit ARP à laquelle le VPC AWS
# répond lui-même ; l'interface passe alors en échec, sans DHCP, et l'instance devient
# injoignable. Si networkd reconfigure l'interface (et efface ces IP), le hook
# networkd-dispatcher installé par deploy.sh relance ce script.
current=$(ip -o -4 addr show dev "$MGMT_IF" label "$MGMT_IF:labfip" | awk '{print $4}')
echo "$ENTRIES" | while read -r priv _; do
  if [ -n "$priv" ]; then
    ip addr replace "$priv/$PREFIX" dev "$MGMT_IF" label "$MGMT_IF:labfip" preferred_lft 0
  fi
done
for a in $current; do
  echo "$ENTRIES" | grep -q "^${a%/*} " || ip addr del "$a" dev "$MGMT_IF"
done
exit 0
