#!/usr/bin/env bash
# =============================================================================
#  verifier-entree.sh : le lab est-il prêt pour le TP 05 bis ? [instance]
#  Lecture seule : ne crée, ne modifie et ne supprime rien.
#
#  Usage : ./openstack-lab-trainee/tps/tp05-bis/verifier-entree.sh
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

echo; echo "== Ressources communes du déploiement (à ne jamais supprimer)"
for c in "keypair:mykey" "network:demo-net" "network:public1" "router:demo-router" "image:cirros" "flavor:m1.tiny"; do
  t=${c%%:*}; n=${c#*:}
  openstack $t show "$n" >/dev/null 2>&1 && ok "$t $n présent" \
    || ecart "$t $n absent" "relancer deploy.sh avec le scénario en place : il recrée les ressources communes (TP 01)"
done

echo; echo "== Restes d'un essai précédent du TP 05 bis"
R="faire le nettoyage du TP 05 bis (étape 7) : la VM et le réseau d'abord, puis l'utilisateur et le projet"
zero "VM tp05b-* (tous projets)" "$(nb '^tp05b-' openstack server list --all-projects -f value -c Name)" "$R ; une VM d'un projet supprimé se supprime par son ID (openstack server list --all-projects)"
zero "réseaux tp05b-*" "$(nb '^tp05b-' openstack network list -f value -c Name)" "$R"
zero "projets tp05b-*" "$(nb '^tp05b-' openstack project list -f value -c Name)" "$R"
zero "utilisateurs tp05b-*" "$(nb '^tp05b-' openstack user list -f value -c Name)" "$R"

echo
if [ "$ECARTS" -eq 0 ]; then echo "Lab prêt pour le TP 05 bis."; else echo "$ECARTS écart(s) à corriger avant de commencer."; fi
[ "$ECARTS" -eq 0 ]
