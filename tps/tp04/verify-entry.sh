#!/usr/bin/env bash
# =============================================================================
#  verify-entry.sh : le lab est-il prêt pour le TP 04 ? [instance]
#  Lecture seule : ne crée, ne modifie et ne supprime rien.
#
#  Usage : ./openstack-lab-trainee/tps/tp04/verify-entry.sh
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
CINDER=0
openstack volume service list >/dev/null 2>&1 && { ok "Cinder présent"; CINDER=1; } \
  || info "Cinder absent : l'étape 0 l'ajoute (scénario 02), puis relancez ce script"

echo; echo "== Mode de virtualisation de Nova (TP 02, étape 7)"
VT=$(sudo -n grep '^virt_type' /etc/kolla/nova-compute/nova.conf 2>/dev/null)
if [ -z "$VT" ]; then
  ecart "virt_type illisible dans /etc/kolla/nova-compute/nova.conf (sudo refusé ou ligne absente)" "vérifier sudo, puis relancer deploy.sh avec le scénario en place (TP 01)"
elif [ "$VT" = "virt_type = qemu" ] || { [ "$VT" = "virt_type = kvm" ] && [ -e /dev/kvm ]; }; then
  ok "$VT (/dev/kvm $([ -e /dev/kvm ] && echo présent || echo absent))"
else
  ecart "$VT alors que /dev/kvm est $([ -e /dev/kvm ] && echo présent || echo absent) : aucune VM ne démarrera" "revenir à QEMU comme au TP 02, étape 7, partie C"
fi

echo; echo "== Ressources communes du déploiement (à ne jamais supprimer)"
for c in "keypair:mykey" "network:demo-net" "network:public1" "router:demo-router" "image:cirros" "flavor:m1.tiny"; do
  t=${c%%:*}; n=${c#*:}
  openstack $t show "$n" >/dev/null 2>&1 && ok "$t $n présent" \
    || ecart "$t $n absent" "relancer deploy.sh avec le scénario en place : il recrée les ressources communes (TP 01)"
done

echo; echo "== Restes d'un essai précédent du TP 04"
R="faire le nettoyage du TP 04 (dernière étape de l'énoncé)"
zero "VM tp04-*" "$(nb '^tp04-' openstack server list --all-projects -f value -c Name)" "$R"
if [ "$CINDER" = 1 ]; then
  zero "volumes tp04-*" "$(nb '^tp04-' openstack volume list --all-projects -f value -c Name)" "$R"
  zero "snapshots de volume tp04-*" "$(nb '^tp04-' openstack volume snapshot list --all-projects -f value -c Name)" "$R"
else
  info "volumes et snapshots tp04-* : non vérifiés tant que Cinder est absent"
fi

echo; echo "== Disque"
BESOIN=5   # Go libres demandés pour le TP 04
LIBRE=$(df --output=avail -BG / | tail -1 | tr -dc 0-9)
if [ "$LIBRE" -ge "$BESOIN" ]; then ok "place libre sur / : $LIBRE Go ($BESOIN Go demandés)"
else ecart "place libre sur / : $LIBRE Go, $BESOIN Go demandés" "libérer de la place (sudo docker image prune -f supprime les images sans étiquette ; sudo docker system df montre ce qui est récupérable) ou agrandir le disque de l'instance (TP 00)"; fi

echo
if [ "$ECARTS" -eq 0 ]; then echo "Lab prêt pour le TP 04."; else echo "$ECARTS écart(s) à corriger avant de commencer."; fi
[ "$ECARTS" -eq 0 ]
