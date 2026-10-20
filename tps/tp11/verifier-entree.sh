#!/usr/bin/env bash
# =============================================================================
#  verifier-entree.sh : le lab est-il prêt pour le TP 11 ? [instance]
#  Lecture seule : ne crée, ne modifie et ne supprime rien.
#
#  Usage : ./openstack-lab-trainee/tps/tp11/verifier-entree.sh
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
openstack service show dns >/dev/null 2>&1 && ok "Designate présent" \
  || info "Designate absent : l'étape 0 renvoie au déploiement du scénario 04"

echo; echo "== Ressources communes du déploiement (à ne jamais supprimer)"
for c in "keypair:mykey" "network:demo-net" "network:public1" "router:demo-router" "image:cirros" "flavor:m1.tiny"; do
  t=${c%%:*}; n=${c#*:}
  openstack $t show "$n" >/dev/null 2>&1 && ok "$t $n présent" \
    || ecart "$t $n absent" "relancer deploy.sh avec le scénario en place : il recrée les ressources communes (TP 01)"
done

echo; echo "== Zones DNS et fichiers"
z=$(openstack zone list --all-projects -f value -c name 2>/dev/null) || z=erreur
if [ "$z" = erreur ]; then info "zones DNS illisibles (Designate absent ?)"
else zero "zones DNS hormis la zone inverse" "$(grep -v 'in-addr\.arpa\.$' <<< "$z" | grep -c .)" "supprimer les zones d'un essai précédent (TP 11, nettoyage)"; fi
[ -e ~/tp11-openrc.sh ] && ecart "~/tp11-openrc.sh présent (essai précédent)" "rm -f ~/tp11-openrc.sh (TP 11, nettoyage)" || ok "~/tp11-openrc.sh : absent"

echo; echo "== Restes d'un essai précédent du TP 11"
R="faire le nettoyage du TP 11 (dernière étape de l'énoncé)"
zero "VM tp11-*" "$(nb '^tp11-' openstack server list --all-projects -f value -c Name)" "$R"
zero "réseaux tp11-*" "$(nb '^tp11-' openstack network list -f value -c Name)" "$R"
zero "routeurs tp11-*" "$(nb '^tp11-' openstack router list -f value -c Name)" "$R"
zero "projets tp11-*" "$(nb '^tp11-' openstack project list -f value -c Name)" "$R"
zero "utilisateurs tp11-*" "$(nb '^tp11-' openstack user list -f value -c Name)" "$R"

echo
if [ "$ECARTS" -eq 0 ]; then echo "Lab prêt pour le TP 11."; else echo "$ECARTS écart(s) à corriger avant de commencer."; fi
[ "$ECARTS" -eq 0 ]
