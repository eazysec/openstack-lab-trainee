#!/usr/bin/env bash
# =============================================================================
#  verifier-entree.sh : tout est-il prêt pour le TP 00 ? [poste]
#  Lecture seule : ne crée, ne modifie et ne supprime rien.
#
#  Usage : ./openstack-lab-trainee/tps/tp00/verifier-entree.sh [<IP_PUBLIQUE>]
#          (sur le poste, dans le dossier qui contient openstack-lab-trainee/ et ec2_key)
#  Code retour : 0 si toutes les conditions d'entrée sont remplies, 1 sinon.
#  Chaque écart est suivi de ce qu'il faut faire.
# =============================================================================
set -uo pipefail
IP=${1:-}
ECARTS=0
ok()    { echo "[OK]         $*"; }
ecart() { echo "[À CORRIGER] $1"; echo "             -> $2"; ECARTS=$((ECARTS + 1)); }
info()  { echo "[INFO]       $*"; }

echo "== Poste"
for c in ssh scp; do
  command -v $c >/dev/null && ok "commande $c présente" || ecart "commande $c absente" "installer un client OpenSSH (README du lab, accès)"
done
command -v aws >/dev/null && ok "AWS CLI présente (étape 1 : contrôle des crédits CPU)" \
  || ecart "AWS CLI absente : l'étape 1 en a besoin" "l'installer et la configurer (openstack-lab-trainee/aws/aws-setup.md)"
[ -f ec2_key ] && ok "clé ec2_key présente dans le dossier courant" \
  || ecart "clé ec2_key absente du dossier courant" "se placer dans le dossier qui contient ec2_key (téléchargée à la création de l'instance)"
[ -d openstack-lab-trainee ] && ok "dépôt openstack-lab-trainee présent" \
  || ecart "dépôt openstack-lab-trainee absent du dossier courant" "se placer dans le dossier qui contient le dépôt"

echo; echo "== Instance"
if [ -z "$IP" ]; then
  info "pas d'adresse fournie : si l'instance n'existe pas encore, l'étape 1 la crée ; sinon, relancez avec <IP_PUBLIQUE>"
elif timeout 8 bash -c "echo > /dev/tcp/$IP/22" 2>/dev/null; then
  ok "port 22 de $IP joignable depuis ce poste"
else
  ecart "port 22 de $IP injoignable depuis ce poste" "vérifier que l'instance est démarrée et que son Security Group AWS autorise SSH depuis votre adresse (TP 00, étape 1)"
fi

echo
if [ "$ECARTS" -eq 0 ]; then echo "Prêt pour le TP 00."; else echo "$ECARTS écart(s) à corriger avant de commencer."; fi
[ "$ECARTS" -eq 0 ]
