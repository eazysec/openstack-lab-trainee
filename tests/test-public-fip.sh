#!/bin/bash
# =============================================================================
#  test-public-fip.sh : Test du scénario 03 côté hôte, SANS ressource AWS
#
#  Une IP libre du sous-réseau de l'ENI joue le rôle d'IP secondaire (elle n'est
#  pas déclarée chez AWS : elle n'a d'effet que sur l'hôte). Un client "Internet"
#  est simulé dans un network namespace. Le test couvre : garde-fous, NAT 1:1,
#  adresse source de l'hôte, reconfiguration réseau (networkctl, netplan),
#  retour arrière automatique, retrait.
#
#  Usage (sur l'instance, détaché de la session SSH par précaution) :
#    setsid nohup ./tests/test-public-fip.sh <IP_LIBRE_DU_SOUS_RESEAU> > test.out 2>&1 &
#  Choisir une IP non utilisée dans le VPC. Un interrupteur de sécurité retire
#  toute publication au bout de 15 min quoi qu'il arrive.
#  Crée puis supprime : 1 VM (pubtest), 1 floating IP. Code retour 0 si tout passe.
# =============================================================================
set -u
[[ -n "${1:-}" ]] || { sed -n '3,17p' "$0"; exit 1; }
# shellcheck disable=SC1090,SC1091
source ~/kolla/venv/bin/activate; source /etc/kolla/admin-openrc.sh
source /etc/openstack-lab/network.env
T="$(cd "$(dirname "$0")/.." && pwd)/tools/public-fip.sh"
PRIV="$1"; FIP="${FIP:-}"          # vide : Neutron choisit une floating IP libre
FIP2="${FIP2:-10.0.2.254}"           # hors pool : sert seulement au test du retour arrière
MGMT=$(ip -o -4 route get 1.1.1.1 | grep -o 'src [0-9.]*' | cut -d' ' -f2)
GW=$(ip -o -4 route show default dev "$MGMT_IF" | awk '{print $3; exit}')
PRIV2=$(python3 -c "import ipaddress; print(ipaddress.ip_address('$PRIV')+1)")
SSHO=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
PASS=0; FAIL=0
ok()  { printf '[PASS] %s\n' "$1"; PASS=$((PASS+1)); }
ko()  { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else ko "$d"; fi; }
src_ok() { ip -o -4 route get 1.1.1.1 | grep -q "src $MGMT" && ip -o -4 route get "$GW" | grep -q "src $MGMT"; }
has_priv() { ip -o -4 addr show dev "$MGMT_IF" | grep -q " $PRIV/32 "; }
wait_priv() { for _ in $(seq 30); do has_priv && return 0; sleep 2; done; return 1; }
client() { sudo ip netns exec client "$@"; }

# Interrupteur de sécurité : retire toute publication dans 15 min quoi qu'il arrive
sudo systemd-run --quiet --unit test03-deadman --on-active=900 \
  /bin/sh -c ': > /etc/openstack-lab/public-fip.map; /usr/local/sbin/openstack-lab-net.sh'

echo "== Garde-fous"
# chaque refus doit avoir la bonne cause : on vérifie le message d'erreur
refus() { local out; out=$(sudo "$T" add "$1" "$2" 2>&1) && return 1; grep -q "$3" <<< "$out"; }
chk "refus : IP hors sous-réseau"      refus 10.9.9.9 "$FIP2" "n'est pas dans le sous-réseau"
chk "refus : floating IP hors réseau"  refus "$PRIV" 192.168.1.1 "n'est pas une floating IP"
chk "refus : IP principale de l'hôte"  refus "$MGMT" "$FIP2" "déjà utilisée par l'hôte"
chk "refus : IP invalide"              refus abc "$FIP2" "Usage"

echo "== VM + floating IP"
openstack server create --image cirros --flavor m1.tiny --key-name mykey --network demo-net --wait pubtest >/dev/null
FIP=$(openstack floating ip create public1 ${FIP:+--floating-ip-address $FIP} -f value -c floating_ip_address)
openstack server add floating ip pubtest $FIP
for _ in $(seq 40); do ssh "${SSHO[@]}" cirros@$FIP true 2>/dev/null && break; sleep 5; done
chk "VM joignable via sa floating IP" ssh "${SSHO[@]}" cirros@$FIP true

echo "== Publication"
chk "add $PRIV -> $FIP"                sudo $T add $PRIV $FIP
chk "refus : doublon"                  bash -c "! sudo $T add $PRIV $FIP2"
chk "IP secondaire en /32"             has_priv
chk "IP secondaire dépréciée"          bash -c "ip -4 addr show dev $MGMT_IF | grep ' $PRIV/32 ' | grep -q deprecated"
chk "l'hôte émet toujours avec $MGMT"  src_ok
chk "minuterie de retour arrière annulée" bash -c "! systemctl is-active --quiet labfip-rollback.timer"

echo "== Client simulé (namespace)"
sudo ip netns add client; sudo ip link add cli-h type veth peer name cli-n; sudo ip link set cli-n netns client
sudo ip addr add 192.168.250.1/24 dev cli-h; sudo ip link set cli-h up
client sh -c "ip addr add 192.168.250.2/24 dev cli-n; ip link set cli-n up; ip link set lo up; ip route add default via 192.168.250.1"
sudo iptables -I FORWARD -i cli-h -j ACCEPT; sudo iptables -I FORWARD -o cli-h -j ACCEPT
chk "client -> VM : ping via $PRIV"    client ping -c2 -W2 $PRIV
chk "client -> VM : SSH via $PRIV"     client ssh "${SSHO[@]}" -i ~/.ssh/id_ecdsa cirros@$PRIV true
chk "hôte -> VM : SSH via $PRIV"       ssh "${SSHO[@]}" cirros@$PRIV true

echo "== Robustesse : networkctl reconfigure"
sudo networkctl reconfigure "$MGMT_IF"; sleep 5
chk "IP restaurée par networkd-dispatcher" wait_priv
chk "service openstack-lab-net actif"  systemctl is-active openstack-lab-net
chk "l'hôte émet toujours avec $MGMT"  src_ok
chk "client -> VM après reconfigure"   client ssh "${SSHO[@]}" -i ~/.ssh/id_ecdsa cirros@$PRIV true

echo "== Robustesse : netplan apply"
sudo netplan apply 2>/dev/null; sleep 5
chk "IP restaurée après netplan apply" wait_priv
chk "l'hôte émet toujours avec $MGMT"  src_ok
chk "client -> VM après netplan apply" client ssh "${SSHO[@]}" -i ~/.ssh/id_ecdsa cirros@$PRIV true

echo "== Retour arrière automatique (contrôle forcé en échec)"
cp /etc/openstack-lab/public-fip.map /tmp/map.before
# copie de public-fip.sh dont le contrôle de l'IP source échoue forcément
sed 's/^MGMT_IP=.*/MGMT_IP=203.0.113.1/' "$T" > /tmp/public-fip-ko.sh
chk "add refusé et annulé"             bash -c "! sudo bash /tmp/public-fip-ko.sh add $PRIV2 $FIP2"
chk "publications inchangées"          sudo cmp /tmp/map.before /etc/openstack-lab/public-fip.map
chk "IP $PRIV2 non posée"                bash -c "! ip -o -4 addr show | grep -q ' $PRIV2/'"

echo "== Retrait"
chk "del $PRIV"                        sudo $T del $PRIV
chk "IP secondaire retirée"            bash -c "! ip -o -4 addr show | grep -q ' $PRIV/'"
chk "DNAT retiré"                      bash -c "! sudo iptables -t nat -S LAB_FIP_PRE | grep -q $PRIV"
chk "client : plus joignable"          bash -c "! sudo ip netns exec client ping -c1 -W2 $PRIV"

echo "== Nettoyage"
sudo iptables -D FORWARD -i cli-h -j ACCEPT; sudo iptables -D FORWARD -o cli-h -j ACCEPT
sudo ip link del cli-h; sudo ip netns del client
openstack server delete --wait pubtest; openstack floating ip delete $FIP
sudo systemctl stop test03-deadman.timer 2>/dev/null
rm -f /tmp/map.before /tmp/public-fip-ko.sh
echo "Résultat : $PASS réussis, $FAIL échoués"
(( FAIL == 0 ))
