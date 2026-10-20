#!/usr/bin/env bash
# =============================================================================
#  verifier-entree.sh : le lab est-il prêt pour le TP 10 ? [instance]
#  Lecture seule : ne crée, ne modifie et ne supprime rien.
#
#  Usage : ./openstack-lab-trainee/tps/tp10/verifier-entree.sh
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
openstack service show volumev3 >/dev/null 2>&1 && ok "Cinder présent" \
  || ecart "Cinder absent" "déployer le scénario 04 (TP 08, étape 0)"
openstack service show key-manager >/dev/null 2>&1 && ok "Barbican présent" \
  || ecart "Barbican absent" "déployer le scénario 04 (TP 08, étape 0)"

echo; echo "== Ressources communes du déploiement (à ne jamais supprimer)"
for c in "keypair:mykey" "network:demo-net" "network:public1" "router:demo-router" "image:cirros" "flavor:m1.tiny"; do
  t=${c%%:*}; n=${c#*:}
  openstack $t show "$n" >/dev/null 2>&1 && ok "$t $n présent" \
    || ecart "$t $n absent" "relancer deploy.sh avec le scénario en place : il recrée les ressources communes (TP 01)"
done

echo; echo "== Stockage objet du lab et restic"
sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qx lab-s3 && ok "stockage objet du lab (lab-s3) démarré" \
  || ecart "stockage objet du lab absent ou arrêté" "relancer le déploiement du scénario 04 (TP 08, étape 0)"
[ -x /usr/local/bin/restic ] && ok "restic installé sur l'hôte" || ecart "restic absent de l'hôte" "relancer le déploiement du scénario 04 (TP 08, étape 0)"
zero "secrets tp10-*" "$(nb '"Name": "tp10-' openstack secret list -f json)" "faire le nettoyage du TP 10 (étape 6)"
zero "bucket ou clé tp10-* du stockage objet" "$(nb 'tp10-' bash -c 'sudo docker exec lab-s3 /garage bucket list && sudo docker exec lab-s3 /garage key list')" "faire le nettoyage du TP 10 (étape 6)"

echo; echo "== Restes d'un essai précédent du TP 10"
R="faire le nettoyage du TP 10 (dernière étape de l'énoncé)"
zero "VM tp10-*" "$(nb '^tp10-' openstack server list --all-projects -f value -c Name)" "$R"
zero "volumes tp10-*" "$(nb '^tp10-' openstack volume list --all-projects -f value -c Name)" "$R"

echo
if [ "$ECARTS" -eq 0 ]; then echo "Lab prêt pour le TP 10."; else echo "$ECARTS écart(s) à corriger avant de commencer."; fi
[ "$ECARTS" -eq 0 ]
