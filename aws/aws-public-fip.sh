#!/usr/bin/env bash
# =============================================================================
#  aws-public-fip.sh : Partie AWS du scénario 03 (à lancer depuis un poste
#  disposant de l'AWS CLI configurée, PAS depuis l'instance)
#
#  create : ajoute une IP privée secondaire à l'ENI de l'instance (gratuit)
#           + alloue une Elastic IP et l'associe à cette IP (PAYANT)
#  delete : dissocie et libère l'Elastic IP, retire l'IP secondaire
#  list   : liste les Elastic IP créées par ce script (tag openstack-lab=true)
#
#  Usage : ./aws-public-fip.sh create <INSTANCE_ID>            # affiche le plan
#          ./aws-public-fip.sh create <INSTANCE_ID> --apply    # exécute
#          ./aws-public-fip.sh delete <ALLOCATION_ID> [--apply]
#          ./aws-public-fip.sh list
#  Sans --apply, AUCUNE commande modifiant AWS n'est exécutée.
# =============================================================================
set -Eeuo pipefail
command -v aws >/dev/null || { echo "AWS CLI introuvable (https://docs.aws.amazon.com/cli/)." >&2; exit 1; }
ACTION="${1:-}"; TARGET="${2:-}"; APPLY="${3:-}"
TAG='Key=openstack-lab,Value=true'

confirm() {
  [[ "$APPLY" == "--apply" ]] || { echo; echo "Mode simulation : rien n'a été modifié. Relancer avec --apply."; exit 0; }
  read -r -p "Confirmer en tapant 'oui' : " ok; [[ "$ok" == "oui" ]] || { echo "Annulé."; exit 1; }
}

case "$ACTION" in
  create)
    [[ "$TARGET" =~ ^i- ]] || { echo "Usage : $0 create <INSTANCE_ID> [--apply]" >&2; exit 1; }
    ENI=$(aws ec2 describe-instances --instance-ids "$TARGET" \
          --query 'Reservations[0].Instances[0].NetworkInterfaces[?Attachment.DeviceIndex==`0`].NetworkInterfaceId' --output text)
    TYPE=$(aws ec2 describe-instances --instance-ids "$TARGET" --query 'Reservations[0].Instances[0].InstanceType' --output text)
    MAXIP=$(aws ec2 describe-instance-types --instance-types "$TYPE" --query 'InstanceTypes[0].NetworkInfo.Ipv4AddressesPerInterface' --output text)
    NOW=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI" --query 'length(NetworkInterfaces[0].PrivateIpAddresses)' --output text)
    cat <<EOF
Plan :
  Instance      : $TARGET ($TYPE)
  ENI primaire  : $ENI ($NOW IP privée(s) sur $MAXIP autorisées pour ce type)
  1. aws ec2 assign-private-ip-addresses --network-interface-id $ENI --secondary-private-ip-address-count 1   (gratuit)
  2. aws ec2 allocate-address --domain vpc                                                                  (PAYANT)
  3. aws ec2 associate-address --allocation-id <EIP> --network-interface-id $ENI --private-ip-address <IP secondaire>
Coût : toute IPv4 publique est facturée par AWS (~0,005 USD/heure, soit ~3,6 USD/mois par Elastic IP),
       qu'elle soit utilisée ou non, jusqu'à sa libération (commande delete).
EOF
    (( NOW < MAXIP )) || { echo "Limite d'IP par ENI atteinte pour $TYPE." >&2; exit 1; }
    confirm
    PRIV=$(aws ec2 assign-private-ip-addresses --network-interface-id "$ENI" \
           --secondary-private-ip-address-count 1 --query 'AssignedPrivateIpAddresses[0].PrivateIpAddress' --output text)
    read -r ALLOC PUB < <(aws ec2 allocate-address --domain vpc \
           --tag-specifications "ResourceType=elastic-ip,Tags=[{$TAG},{Key=openstack-lab-eni,Value=$ENI}]" \
           --query '[AllocationId,PublicIp]' --output text)
    aws ec2 associate-address --allocation-id "$ALLOC" --network-interface-id "$ENI" --private-ip-address "$PRIV" >/dev/null
    cat <<EOF

Créé :
  IP privée secondaire : $PRIV
  Elastic IP           : $PUB  (allocation $ALLOC)
Étape suivante, SUR L'INSTANCE :
  sudo ~/openstack-lab-trainee/tools/public-fip.sh add $PRIV <FLOATING_IP_OPENSTACK>
Pour tout supprimer (et arrêter la facturation) :
  $0 delete $ALLOC --apply
EOF
    ;;
  delete)
    [[ "$TARGET" =~ ^eipalloc- ]] || { echo "Usage : $0 delete <ALLOCATION_ID> [--apply]" >&2; exit 1; }
    read -r ASSOC ENI PRIV PUB < <(aws ec2 describe-addresses --allocation-ids "$TARGET" \
      --query 'Addresses[0].[AssociationId,NetworkInterfaceId,PrivateIpAddress,PublicIp]' --output text)
    echo "Plan : dissocier et libérer $PUB ($TARGET), retirer l'IP secondaire $PRIV de $ENI"
    echo "Pensez d'abord, sur l'instance : sudo tools/public-fip.sh del $PRIV"
    confirm
    [[ "$ASSOC" != "None" ]] && aws ec2 disassociate-address --association-id "$ASSOC"
    aws ec2 release-address --allocation-id "$TARGET"
    [[ "$PRIV" != "None" ]] && aws ec2 unassign-private-ip-addresses --network-interface-id "$ENI" --private-ip-addresses "$PRIV"
    echo "Supprimé."
    ;;
  list)
    aws ec2 describe-addresses --filters Name=tag:openstack-lab,Values=true \
      --query 'Addresses[].[AllocationId,PublicIp,PrivateIpAddress,NetworkInterfaceId]' --output table
    ;;
  *) sed -n '3,15p' "$0"; exit 1 ;;
esac
