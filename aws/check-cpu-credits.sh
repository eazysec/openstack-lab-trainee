#!/usr/bin/env bash
# =============================================================================
#  check-cpu-credits.sh : Garantit qu'aucun frais de crédits CPU ne sera facturé
#  (à lancer depuis un poste disposant de l'AWS CLI, PAS depuis l'instance)
#
#  Règle du lab : les instances burstable (t2, t3, t3a, t4g) doivent être en
#  mode "standard". En mode "unlimited", AWS facture le dépassement de crédits.
#
#  Usage : ./check-cpu-credits.sh <INSTANCE_ID>            # vérifie (lecture seule)
#          ./check-cpu-credits.sh <INSTANCE_ID> --apply    # passe en "standard" si besoin
#  Code retour : 0 = conforme, 2 = non conforme (mode unlimited), 1 = erreur.
#  Passer en "standard" est gratuit et ne redémarre pas l'instance.
# =============================================================================
set -Eeuo pipefail
command -v aws >/dev/null || { echo "AWS CLI introuvable." >&2; exit 1; }
IID="${1:-}"; APPLY="${2:-}"
[[ "$IID" =~ ^i- ]] || { sed -n '3,13p' "$0"; exit 1; }

TYPE=$(aws ec2 describe-instances --instance-ids "$IID" --query 'Reservations[0].Instances[0].InstanceType' --output text)
FAMILY="${TYPE%%.*}"
case "$FAMILY" in
  t2|t3|t3a|t4g) ;;
  *) echo "OK : $IID ($TYPE) n'est pas une instance burstable, pas de crédits CPU."; exit 0 ;;
esac

MODE=$(aws ec2 describe-instance-credit-specifications --instance-ids "$IID" \
       --query 'InstanceCreditSpecifications[0].CpuCredits' --output text)
DEFAULT=$(aws ec2 get-default-credit-specification --instance-family "$FAMILY" \
          --query 'InstanceFamilyCreditSpecification.CpuCredits' --output text)
echo "Instance $IID ($TYPE) : mode $MODE  |  défaut du compte pour la famille $FAMILY : $DEFAULT"
[[ "$DEFAULT" == "standard" ]] || echo "ATTENTION : les nouvelles instances $FAMILY de ce compte démarreront en '$DEFAULT'."

if [[ "$MODE" == "standard" ]]; then
  echo "OK : conforme, aucun frais de crédits CPU possible."
  exit 0
fi

echo "NON CONFORME : en mode '$MODE', le dépassement de crédits CPU est facturé."
if [[ "$APPLY" != "--apply" ]]; then
  echo "Correction (gratuite, sans redémarrage) : $0 $IID --apply"
  exit 2
fi
aws ec2 modify-instance-credit-specification \
  --instance-credit-specifications "InstanceId=$IID,CpuCredits=standard" >/dev/null
MODE=$(aws ec2 describe-instance-credit-specifications --instance-ids "$IID" \
       --query 'InstanceCreditSpecifications[0].CpuCredits' --output text)
[[ "$MODE" == "standard" ]] && echo "OK : $IID est maintenant en mode standard." || { echo "Échec : mode $MODE" >&2; exit 1; }
