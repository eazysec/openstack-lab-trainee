#!/usr/bin/env bash
# =============================================================================
#  verifier-entree.sh : le lab est-il prêt pour le TP 15 ? [instance]
#  Lecture seule : ne crée, ne modifie et ne supprime rien.
#
#  Usage : ./openstack-lab-trainee/tps/tp15/verifier-entree.sh
#  Code retour : 0 si toutes les conditions d'entrée sont remplies, 1 sinon.
#  Chaque écart est suivi de ce qu'il faut faire. Une commande en échec (API injoignable,
#  sudo refusé) est un écart, jamais un « rien à signaler ».
# =============================================================================
set -uo pipefail
DEPOT=$(cd "$(dirname "$0")/../.." && pwd)
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
for c in "keypair:mykey" "network:public1" "image:cirros" "flavor:m1.tiny"; do
  t=${c%%:*}; n=${c#*:}
  openstack $t show "$n" >/dev/null 2>&1 && ok "$t $n présent" \
    || ecart "$t $n absent" "relancer deploy.sh avec le scénario en place : il recrée les ressources communes (TP 01)"
done
openstack service show key-manager >/dev/null 2>&1 && ok "Barbican présent (partie C, HTTPS)" \
  || ecart "Barbican absent" "déployer le scénario 04 (TP 08, étape 0)"

echo; echo "== Restes d'un essai précédent du TP 15"
R="faire l'étape de nettoyage du TP 15"
zero "VM tp15-*" "$(nb '^tp15-' openstack server list --all-projects -f value -c Name)" "$R"
zero "réseaux tp15-*" "$(nb '^tp15-' openstack network list -f value -c Name)" "$R"
zero "routeurs tp15-*" "$(nb '^tp15-' openstack router list -f value -c Name)" "$R"
zero "security groups tp15-*" "$(nb '^tp15-' openstack security group list -f value -c Name)" "$R"
zero "FIP étiquetées tp15" "$(nb . openstack floating ip list --tags tp15 -f value -c ID)" "$R"
zero "secrets tp15-*" "$(nb '"Name": "tp15-' openstack secret list -f json)" "$R"
zero "projets tp15-*" "$(nb '^tp15-' openstack project list -f value -c Name)" "$R"
zero "utilisateurs tp15-*" "$(nb '^tp15-' openstack user list -f value -c Name)" "$R"
[ -e ~/tp15 ] && ecart "dossier ~/tp15 présent" "$R" || ok "dossier ~/tp15 : absent"

echo; echo "== Octavia"
fichier=$(grep -E '^ENABLE_OCTAVIA=' "$DEPOT/scenarios/04-aio-complet.env" | cut -d= -f2)
if ! TYPES=$(openstack service list -f value -c Type 2>/dev/null); then
  ecart "liste des services : commande en échec" "vérifier que la plateforme répond (./openstack-lab-trainee/verify.sh)"
elif grep -qx load-balancer <<< "$TYPES"; then
  info "Octavia est déjà déployé (TP rejoué) : à l'étape 1, passez directement à la vérification"
  zero "répartiteurs tp15-*" "$(nb '^tp15-' openstack loadbalancer list -f value -c name)" "$R"
  [ "$fichier" = yes ] || info "le scénario 04 indique ENABLE_OCTAVIA=$fichier alors qu'Octavia est déployé"
else
  ok "Octavia : absent (l'étape 1 l'ajoute)"
  [ "$fichier" = no ] && ok "scénario 04 : ENABLE_OCTAVIA=no" \
    || ecart "scénario 04 : ENABLE_OCTAVIA=$fichier alors qu'Octavia est absent" "reprendre l'étape 1 (déploiement interrompu ?)"
  R2="reprendre le retrait d'Octavia (dernière étape du TP 15)"
  zero "conteneurs octavia" "$(nb '^octavia' sudo docker ps -a --format '{{.Names}}')" "$R2"
  zero "interface o-hm0 sur l'hôte" "$(nb ' o-hm0[:@]' ip -o link show)" "$R2"
  [ -e /etc/systemd/system/octavia-interface.service ] && ecart "unité octavia-interface présente" "$R2" \
    || ok "unité octavia-interface : absente"
fi
info "mémoire disponible : $(awk '/^MemAvailable/{printf "%d Mo", $2/1024}' /proc/meminfo)"

echo
if [ "$ECARTS" -eq 0 ]; then echo "Lab prêt pour le TP 15."; else echo "$ECARTS écart(s) à corriger avant de commencer."; fi
[ "$ECARTS" -eq 0 ]
