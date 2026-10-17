#!/bin/sh
# =============================================================================
#  openstack-lab-cinder-loop.sh : attache le fichier loop du VG cinder-volumes
#  (exécuté au boot par systemd, service openstack-lab-cinder-loop, avant Docker).
#  Idempotent. Si la boucle est en lecture seule (attachée avant que / soit
#  monté en écriture), elle est détachée puis rattachée en lecture-écriture.
# =============================================================================
set -eu
. /etc/openstack-lab/cinder.env
VG=cinder-volumes

dev=$(losetup -j "$CINDER_LOOP_FILE" | cut -d: -f1 | head -1)
if [ -n "$dev" ] && [ "$(losetup -n -l -O RO "$dev" | tr -d ' ')" = "1" ]; then
  echo "$dev est en lecture seule : rattachement en lecture-écriture"
  vgchange -an "$VG" || true
  losetup -d "$dev"
  dev=""
fi
[ -n "$dev" ] || dev=$(losetup -f --show "$CINDER_LOOP_FILE")

[ "$(losetup -n -l -O RO "$dev" | tr -d ' ')" = "0" ] || { echo "ERREUR : $dev toujours en lecture seule" >&2; exit 1; }
vgchange -ay "$VG"
echo "$CINDER_LOOP_FILE attaché sur $dev (lecture-écriture), VG $VG actif"
