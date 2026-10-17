#!/usr/bin/env bash
# =============================================================================
#  recover-network.sh : Récupère une instance devenue injoignable à cause de la
#  publication d'IP secondaires (tools/public-fip.sh). Voir aws-setup.md §6.
#  À lancer depuis un poste disposant de l'AWS CLI, PAS depuis l'instance.
#
#  Principe (méthode documentée par AWS, gratuite) :
#   1. arrêt de l'instance ;
#   2. ajout d'un user-data qui, au démarrage suivant, supprime la configuration
#      réseau des IP publiées puis recharge systemd-networkd ;
#   3. démarrage. Le user-data de réparation ne s'exécute qu'une fois (fichier
#      témoin) : il peut rester en place et être retiré au prochain arrêt planifié.
#      Le user-data d'origine éventuel est sauvegardé dans le répertoire courant.
#
#  Usage : ./recover-network.sh <INSTANCE_ID>            # affiche le plan
#          ./recover-network.sh <INSTANCE_ID> --apply    # exécute
#  ATTENTION : l'IP publique auto-attribuée change au redémarrage.
# =============================================================================
set -Eeuo pipefail
command -v aws >/dev/null || { echo "AWS CLI introuvable." >&2; exit 1; }
IID="${1:-}"; APPLY="${2:-}"
[[ "$IID" =~ ^i- ]] || { sed -n '3,18p' "$0"; exit 1; }

STAMP=$(date +%Y%m%d%H%M%S)
read -r STATE PUBIP < <(aws ec2 describe-instances --instance-ids "$IID" \
  --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress]' --output text)
ORIG_UD=$(aws ec2 describe-instance-attribute --instance-id "$IID" --attribute userData \
  --query 'UserData.Value' --output text)

cat <<EOF
Plan pour $IID (état : $STATE, IP publique actuelle : $PUBIP)
  1. aws ec2 stop-instances           (gratuit ; OpenStack s'arrête proprement)
  2. aws ec2 modify-instance-attribute --attribute userData   (script de réparation, exécution unique)
  3. aws ec2 start-instances          (l'IP publique CHANGE)
  4. vérification et affichage de la nouvelle IP
  User-data d'origine : $([[ "$ORIG_UD" == "None" ]] && echo "aucun" || echo "présent (sauvegardé dans ./userdata-$IID-$STAMP.b64)")
Coût : aucun (hors temps d'arrêt).
EOF
[[ "$APPLY" == "--apply" ]] || { echo; echo "Mode simulation : rien n'a été modifié. Relancer avec --apply."; exit 0; }
read -r -p "Confirmer en tapant 'oui' : " ok; [[ "$ok" == "oui" ]] || { echo "Annulé."; exit 1; }

[[ "$ORIG_UD" != "None" ]] && echo "$ORIG_UD" > "userdata-$IID-$STAMP.b64"

UD=$(mktemp)
cat > "$UD" <<EOF
Content-Type: multipart/mixed; boundary="//"
MIME-Version: 1.0

--//
Content-Type: text/cloud-config; charset="us-ascii"
MIME-Version: 1.0
Content-Transfer-Encoding: 7bit
Content-Disposition: attachment; filename="cloud-config.txt"

#cloud-config
cloud_final_modules:
- [scripts-user, always]

--//
Content-Type: text/x-shellscript; charset="us-ascii"
MIME-Version: 1.0
Content-Transfer-Encoding: 7bit
Content-Disposition: attachment; filename="userdata.txt"

#!/bin/sh
# openstack-lab network repair ($STAMP) - runs once.
# Log: /var/log/openstack-lab-recover.log and serial console (aws ec2 get-console-output).
MARK=/var/lib/openstack-lab-recovered-$STAMP
[ -f "\$MARK" ] && exit 0
exec >>/var/log/openstack-lab-recover.log 2>&1
log() { echo "openstack-lab-recover: \$*"; echo "openstack-lab-recover: \$*" > /dev/console 2>/dev/null || true; }
log "start ($STAMP)"
log "before: \$(ip -o -4 addr show | awk '{print \$2, \$4}' | tr '\n' ' ')"
# 1. IPs declared in drop-ins: read BEFORE removal, then removed explicitly
#    (networkd does not always remove an address it no longer manages)
for f in /etc/systemd/network/*.network.d/openstack-lab-fip.conf; do
  [ -f "\$f" ] || continue
  dir=\$(dirname "\$f")
  iface=\$(awk -F= '/^Name=/{print \$2; exit}' "/run/systemd/network/\$(basename "\$dir" .d)" 2>/dev/null)
  for a in \$(awk -F= '/^Address=/{print \$2}' "\$f"); do
    for dev in \${iface:-\$(ls /sys/class/net)}; do ip addr del "\$a" dev "\$dev" 2>/dev/null && log "removed \$a from \$dev"; done
  done
  rm -f "\$f"; log "deleted \$f"
done
# 2. IPs added without networkd (label labfip)
ip -o -4 addr show | awk '/labfip/{print \$2, \$4}' | while read -r dev a; do
  ip addr del "\$a" dev "\$dev" && log "removed \$a from \$dev (labfip)"
done
# 3. no more published IPs when openstack-lab-net starts again
[ -f /etc/openstack-lab/public-fip.map ] && : > /etc/openstack-lab/public-fip.map
# 4. full network reconfiguration from the clean configuration
networkctl reload
# colonnes : IDX LINK TYPE OPERATIONAL SETUP ; une interface en echec a SETUP=failed
for dev in \$(networkctl list --no-legend | awk '\$2!="lo" && \$5!="unmanaged" {print \$2}'); do
  networkctl reconfigure "\$dev"
done
sleep 10
log "after: \$(ip -o -4 addr show | awk '{print \$2, \$4}' | tr '\n' ' ')"
log "route: \$(ip -o -4 route get 1.1.1.1 2>&1)"
touch "\$MARK"
log "end"
--//--
EOF

# Garde-fou : cloud-init rejette une partie "us-ascii" contenant un caractère non ASCII
# (le script ne s'exécuterait pas, sans autre signe qu'un avertissement dans la console).
if LC_ALL=C grep -q '[^[:print:][:space:]]' "$UD"; then
  echo "ERREUR : le user-data contient des caractères non ASCII ; abandon (instance non arrêtée)." >&2
  rm -f "$UD"; exit 1
fi
echo "== Arrêt"
aws ec2 stop-instances --instance-ids "$IID" >/dev/null
aws ec2 wait instance-stopped --instance-ids "$IID"
echo "== User-data de réparation"
aws ec2 modify-instance-attribute --instance-id "$IID" --attribute userData --value "$(base64 -w0 "$UD")"
rm -f "$UD"
echo "== Démarrage"
aws ec2 start-instances --instance-ids "$IID" >/dev/null
aws ec2 wait instance-running --instance-ids "$IID"
NEWIP=$(aws ec2 describe-instances --instance-ids "$IID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "Nouvelle IP publique : $NEWIP"
echo "Attendre ~2 min, puis : ssh -i ec2_key ubuntu@$NEWIP"
echo "Le user-data de réparation ne s'exécute qu'une fois ; il pourra être retiré au prochain arrêt planifié."
