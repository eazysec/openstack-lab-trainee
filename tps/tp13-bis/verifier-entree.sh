#!/usr/bin/env bash
# =============================================================================
#  verifier-entree.sh : le lab est-il prêt pour le TP 13 bis ? [instance]
#  Lecture seule : ne crée, ne modifie et ne supprime rien.
#
#  Usage : ./openstack-lab-trainee/tps/tp13-bis/verifier-entree.sh
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
R="faire le TP 13 jusqu'à l'étape 14, sans son nettoyage (étape 16)"

echo; echo "== Architecture du TP 13 (elle doit être en place)"
for vm in tp13-vm-web-haproxy-demo tp13-vm-bdd-demo; do
  st=$(openstack server show "$vm" -f value -c status 2>/dev/null) || st=absente
  [ "$st" = ACTIVE ] && ok "VM $vm : ACTIVE" || ecart "VM $vm : $st" "$R"
done
p=$(curl -s -m 10 http://10.0.2.150/ 2>/dev/null | grep 'data-test="etat-base"' | sed 's/<[^>]*>//g' | tr -s ' ') || p=
case "$p" in
  *Réussi*) ok "application jointe par la FIP 10.0.2.150 et connectée à sa base" ;;
  "") ecart "application injoignable par la FIP 10.0.2.150" "$R ; vérifier avec les tests de l'étape 12 du TP 13" ;;
  *) ecart "application jointe, mais base en échec :$p" "relire l'étape 9 du TP 13 (pg_hba.conf, mot de passe)" ;;
esac
info "l'intérieur des VM (rôles, pg_hba.conf, journal) n'est pas vu d'ici : l'étape 1 en fait le constat"

echo
if [ "$ECARTS" -eq 0 ]; then echo "Lab prêt pour le TP 13 bis."; else echo "$ECARTS écart(s) à corriger avant de commencer."; fi
[ "$ECARTS" -eq 0 ]
