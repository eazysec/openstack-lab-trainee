#!/usr/bin/env bash
# =============================================================================
#  destroy.sh : Supprime le déploiement OpenStack
#  Usage : ./destroy.sh            supprime conteneurs + volumes Docker (données perdues)
#          ./destroy.sh --purge    + config Kolla, venv, réseau hôte, VG Cinder loop
#                                  (l'hôte revient à l'état "avant deploy.sh",
#                                   hors paquets apt, Docker et swap)
# =============================================================================
set -Eeuo pipefail
WORKDIR="${WORKDIR:-$HOME/kolla}"
read -r -p "Toutes les VM, images et volumes OpenStack seront perdus. Taper 'oui' : " ok
[[ "$ok" == "oui" ]] || { echo "Annulé."; exit 1; }

if [[ -x "$WORKDIR/venv/bin/kolla-ansible" ]]; then
  # shellcheck disable=SC1091
  source "$WORKDIR/venv/bin/activate"
  # kolla-ansible destroy refuse de s'exécuter si des VM tournent ("Some qemu processes were
  # detected") : on les arrête d'abord, elles vont être détruites de toute façon.
  if sudo docker ps --format '{{.Names}}' | grep -qx nova_libvirt; then
    for dom in $(sudo docker exec nova_libvirt virsh list --name 2>/dev/null); do
      sudo docker exec nova_libvirt virsh destroy "$dom" >/dev/null && echo "VM arrêtée : $dom"
    done
  fi
  if pgrep -x qemu-system-x86_64 >/dev/null; then
    echo "ERREUR : des processus qemu tournent encore (pgrep -a qemu-system-x86_64)." >&2
    exit 1
  fi
  kolla-ansible destroy -i "$WORKDIR/all-in-one" --yes-i-really-really-mean-it
fi
# kolla-ansible destroy oublie les volumes des conteneurs d'initialisation :
# on supprime ceux qui portent un nom Kolla et qu'aucun conteneur n'utilise.
KOLLA_VOL_RE='^(bootstrap_|create_cell|nova_|neutron|horizon|keystone|glance|placement|cinder|heat|barbican|designate|mariadb|rabbitmq|kolla_)'
for v in $(sudo docker volume ls -q -f dangling=true 2>/dev/null | grep -E "$KOLLA_VOL_RE" || true); do
  sudo docker volume rm "$v" >/dev/null && echo "volume supprimé : $v"
done

if [[ "${1:-}" == "--purge" ]]; then
  if sudo vgs cinder-volumes >/dev/null 2>&1; then
    pvs_cinder=$(sudo pvs --noheadings -o pv_name -S vg_name=cinder-volumes)
    sudo vgremove -f cinder-volumes
    for pv in $pvs_cinder; do sudo pvremove -y "$pv"; done
  fi
  if [[ -f /etc/openstack-lab/cinder.env ]]; then
    # shellcheck disable=SC1091
    source /etc/openstack-lab/cinder.env
    for dev in $(sudo losetup -j "$CINDER_LOOP_FILE" | cut -d: -f1); do sudo losetup -d "$dev"; done
    sudo rm -f "$CINDER_LOOP_FILE"
  fi
  sudo systemctl disable --now openstack-lab-cinder-loop.service 2>/dev/null || true
  sudo rm -f /etc/openstack-lab/public-fip.map
  sudo /usr/local/sbin/openstack-lab-net.sh 2>/dev/null || true   # retire les IP secondaires
  sudo systemctl disable --now openstack-lab-net.service 2>/dev/null || true
  sudo ip link del veth-ext 2>/dev/null || true
  if sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx lab-s3; then
    sudo docker rm -f lab-s3 >/dev/null && echo "stockage objet du lab supprimé"
  fi
  sudo rm -rf /srv/lab-s3 /usr/local/bin/restic
  sudo rm -f /etc/networkd-dispatcher/*/50-openstack-lab
  sudo rm -rf /etc/systemd/system/openstack-lab-*.service /usr/local/sbin/openstack-lab-*.sh \
              /etc/openstack-lab /etc/kolla "$WORKDIR" "$HOME/.config/openstack"
  sudo systemctl daemon-reload
  echo "Purge terminée. Redémarrer l'hôte pour repartir de règles iptables vierges : sudo reboot"
fi
