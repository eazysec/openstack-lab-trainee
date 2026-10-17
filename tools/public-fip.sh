#!/usr/bin/env bash
# =============================================================================
#  public-fip.sh : Publie une floating IP OpenStack via une IP secondaire de l'ENI
#  (côté hôte uniquement ; la partie AWS se fait avec aws/aws-public-fip.sh)
#
#  Usage : sudo ./public-fip.sh add <IP_PRIVEE_SECONDAIRE> <FLOATING_IP>
#          sudo ./public-fip.sh del <IP_PRIVEE_SECONDAIRE>
#          sudo ./public-fip.sh list
#
#  Chemin d'un paquet entrant :
#    Internet -> Elastic IP -(NAT AWS)-> IP secondaire de l'ENI
#             -(DNAT hôte)-> floating IP -(routeur Neutron)-> IP privée de la VM
# =============================================================================
set -Eeuo pipefail
MAP=/etc/openstack-lab/public-fip.map
[[ $EUID -eq 0 ]] || { echo "À lancer avec sudo." >&2; exit 1; }
[[ -f /etc/openstack-lab/network.env ]] || { echo "deploy.sh n'a pas été exécuté." >&2; exit 1; }
# shellcheck disable=SC1091
source /etc/openstack-lab/network.env
touch "$MAP"
is_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
MGMT_IP=$(ip -o -4 route get 1.1.1.1 | grep -o 'src [0-9.]*' | cut -d' ' -f2)
ROLLBACK_DELAY=120

# Sécurité anti-verrouillage : modifier le réseau de l'interface par laquelle on est
# connecté peut couper l'accès à l'instance. Avant chaque modification, un retour
# arrière automatique est programmé (systemd, indépendant de la session SSH) ; il
# n'est annulé que si l'hôte sort toujours avec son IP principale.
apply_with_rollback() {
  cp "$MAP.bak" "$MAP.rollback"
  systemctl stop labfip-rollback.timer 2>/dev/null || true
  systemd-run --quiet --unit labfip-rollback --on-active="$ROLLBACK_DELAY" \
    /bin/sh -c "cp '$MAP.rollback' '$MAP' && /usr/local/sbin/openstack-lab-net.sh"
  /usr/local/sbin/openstack-lab-net.sh
  local gw src_gw src_out
  gw=$(ip -o -4 route show default dev "$MGMT_IF" | awk '{print $3; exit}')
  src_gw=$(ip -o -4 route get "$gw" | grep -o 'src [0-9.]*' | cut -d' ' -f2)
  src_out=$(ip -o -4 route get 1.1.1.1 | grep -o 'src [0-9.]*' | cut -d' ' -f2)
  if [[ "$src_gw" == "$MGMT_IP" && "$src_out" == "$MGMT_IP" ]]; then
    systemctl stop labfip-rollback.timer 2>/dev/null || true
    rm -f "$MAP.rollback"
  else
    echo "ERREUR : l'hôte n'émet plus avec $MGMT_IP (source vers passerelle : $src_gw, vers Internet : $src_out)." >&2
    echo "Retour arrière immédiat." >&2
    systemctl stop labfip-rollback.timer 2>/dev/null || true
    cp "$MAP.rollback" "$MAP"; rm -f "$MAP.rollback"
    /usr/local/sbin/openstack-lab-net.sh
    exit 1
  fi
}

case "${1:-}" in
  add)
    priv="${2:-}"; fip="${3:-}"
    is_ip "$priv" && is_ip "$fip" || { echo "Usage : $0 add <IP_PRIVEE_SECONDAIRE> <FLOATING_IP>" >&2; exit 1; }
    mgmt_net=$(ip -o -4 route show dev "$MGMT_IF" scope link proto kernel | awk '{print $1; exit}')
    python3 -c "import ipaddress,sys; sys.exit(ipaddress.ip_address('$priv') not in ipaddress.ip_network('$mgmt_net'))" \
      || { echo "$priv n'est pas dans le sous-réseau de $MGMT_IF ($mgmt_net)." >&2; exit 1; }
    python3 -c "import ipaddress,sys; sys.exit(ipaddress.ip_address('$fip') not in ipaddress.ip_network('$EXT_CIDR'))" \
      || { echo "$fip n'est pas une floating IP du réseau externe ($EXT_CIDR)." >&2; exit 1; }
    grep -q "^$priv " "$MAP" && { echo "$priv est déjà publiée." >&2; exit 1; }
    awk -v f="$fip" '$2==f{found=1} END{exit !found}' "$MAP" && { echo "$fip est déjà publiée." >&2; exit 1; }
    ip -o -4 addr show | grep -q " $priv/" \
      && { echo "$priv est déjà utilisée par l'hôte." >&2; exit 1; }
    cp "$MAP" "$MAP.bak"
    echo "$priv $fip" >> "$MAP"
    ;;
  del)
    priv="${2:-}"; is_ip "$priv" || { echo "Usage : $0 del <IP_PRIVEE_SECONDAIRE>" >&2; exit 1; }
    cp "$MAP" "$MAP.bak"
    sed -i "/^$priv /d" "$MAP"
    ;;
  list)
    echo "IP_PRIVEE_SECONDAIRE  FLOATING_IP"; cat "$MAP"; exit 0 ;;
  *)
    sed -n '3,9p' "$0"; exit 1 ;;
esac
apply_with_rollback
echo "OK. Correspondances actives :"; cat "$MAP"
