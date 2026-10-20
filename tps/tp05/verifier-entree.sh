#!/usr/bin/env bash
# =============================================================================
#  verifier-entree.sh : le lab est-il prêt pour le TP 05 ? [instance]
#  Lecture seule : ne crée, ne modifie et ne supprime rien.
#
#  Usage : ./openstack-lab-trainee/tps/tp05/verifier-entree.sh
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

echo; echo "== État laissé par une panne simulée"
s=$(openstack compute service list -f value -c Binary -c State 2>/dev/null) || s=erreur
[ "$s" != erreur ] && ! grep -qv ' up$' <<< "$s" && ok "services de calcul tous « up »" \
  || ecart "service de calcul arrêté ou illisible : $(echo $s)" "redémarrer le conteneur (TP 05, étape 3) : sudo systemctl start kolla-nova_compute-container.service"
sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qx horizon && ok "conteneur horizon démarré" \
  || ecart "conteneur horizon arrêté" "sudo systemctl start kolla-horizon-container.service (TP 05, étape 2)"
[ -e /etc/kolla/config/nova.conf ] && ecart "/etc/kolla/config/nova.conf présent (étape 4 d'un essai précédent)" "le supprimer, puis kolla-ansible reconfigure (TP 05, fin de l'étape 4)" || ok "configuration de Nova : valeurs par défaut"

echo; echo "== Restes d'un essai précédent du TP 05"
R="faire le nettoyage du TP 05 (dernière étape de l'énoncé)"
zero "VM tp05-*" "$(nb '^tp05-' openstack server list --all-projects -f value -c Name)" "$R"

echo
if [ "$ECARTS" -eq 0 ]; then echo "Lab prêt pour le TP 05."; else echo "$ECARTS écart(s) à corriger avant de commencer."; fi
[ "$ECARTS" -eq 0 ]
