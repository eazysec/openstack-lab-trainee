#!/usr/bin/env bash
# =============================================================================
#  verifier-entree.sh : le lab est-il prêt pour le TP 08 bis ? [instance]
#  Lecture seule : ne crée, ne modifie et ne supprime rien.
#
#  Usage : ./openstack-lab-trainee/tps/tp08-bis/verifier-entree.sh
#  Code retour : 0 si toutes les conditions d'entrée sont remplies, 1 sinon.
#  Chaque écart est suivi de ce qu'il faut faire. Une commande en échec (API injoignable,
#  sudo refusé) est un écart, jamais un « rien à signaler ».
# =============================================================================
set -uo pipefail
source ~/kolla/venv/bin/activate && source /etc/kolla/admin-openrc.sh \
  || { echo "Environnement OpenStack introuvable (~/kolla/venv, /etc/kolla/admin-openrc.sh)." >&2; exit 2; }
ECARTS=0
ok()    { echo "[OK]         $*"; }
ecart() { echo "[À CORRIGER] $1"; echo "             -> $2"; ECARTS=$((ECARTS + 1)); }
info()  { echo "[INFO]       $*"; }
nb() {  # $1 motif (grep -E), puis la commande : nombre de lignes correspondantes, « erreur » si échec
  local motif=$1 s; shift
  s=$("$@" 2>/dev/null) || { echo erreur; return; }
  printf '%s\n' "$s" | grep -cE -- "$motif"
}
zero() {  # $1 libellé, $2 nombre, $3 remède
  if [ "$2" = 0 ]; then ok "$1 : aucun"; elif [ "$2" = erreur ]; then ecart "$1 : commande en échec" "vérifier que la plateforme répond (./openstack-lab-trainee/verify.sh)"; else ecart "$1 : $2" "$3"; fi
}

echo "== Plateforme"
openstack token issue >/dev/null 2>&1 && ok "OpenStack répond" \
  || ecart "OpenStack ne répond pas" "lancer ./openstack-lab-trainee/verify.sh et lire la FAQ du lab"
openstack service show key-manager >/dev/null 2>&1 && ok "Barbican présent" \
  || ecart "Barbican absent" "déployer le scénario 04 (TP 08, étape 0)"

echo; echo "== Restes d'un essai précédent du TP 08 bis"
R="faire le nettoyage du TP 08 bis (étape 6) ; la suppression d'un projet efface aussi ses secrets"
zero "projets tp08b-*" "$(nb '^tp08b-' openstack project list -f value -c Name)" "$R"
zero "utilisateurs tp08b-*" "$(nb '^tp08b-' openstack user list -f value -c Name)" "$R"
zero "secrets tp08b-* du projet admin" "$(nb '"Name": "tp08b-' openstack secret list -f json)" "$R"

echo
if [ "$ECARTS" -eq 0 ]; then echo "Lab prêt pour le TP 08 bis."; else echo "$ECARTS écart(s) à corriger avant de commencer."; fi
[ "$ECARTS" -eq 0 ]
