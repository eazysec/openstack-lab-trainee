#!/usr/bin/env bash
# =============================================================================
#  verify-entry.sh : le lab est-il prêt pour le TP 12 ? [instance]
#  Lecture seule : ne crée, ne modifie et ne supprime rien.
#
#  Usage : ./openstack-lab-trainee/tps/tp12/verify-entry.sh
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
openstack volume service list >/dev/null 2>&1 && ok "Cinder présent" \
  || ecart "Cinder absent : l'étape 8 crée un volume" "déployer le scénario 02 ou 04 (TP 04, étape 0)"
curl -s -o /dev/null -m 15 -I https://cloud.debian.org/images/cloud/ && ok "l'instance joint cloud.debian.org" \
  || ecart "cloud.debian.org injoignable depuis l'instance : l'étape 0 y télécharge l'image" "vérifier l'accès Internet de l'instance (README du lab, dépannage)"

echo; echo "== Mode de virtualisation de Nova (TP 02, étape 7)"
VT=$(sudo -n grep '^virt_type' /etc/kolla/nova-compute/nova.conf 2>/dev/null)
if [ -z "$VT" ]; then
  ecart "virt_type illisible dans /etc/kolla/nova-compute/nova.conf (sudo refusé ou ligne absente)" "vérifier sudo, puis relancer deploy.sh avec le scénario en place (TP 01)"
elif [ "$VT" = "virt_type = qemu" ] || { [ "$VT" = "virt_type = kvm" ] && [ -e /dev/kvm ]; }; then
  ok "$VT (/dev/kvm $([ -e /dev/kvm ] && echo présent || echo absent))"
else
  ecart "$VT alors que /dev/kvm est $([ -e /dev/kvm ] && echo présent || echo absent) : aucune VM ne démarrera" "revenir à QEMU comme au TP 02, étape 7, partie C"
fi

echo; echo "== Image, gabarit et clé (étape 0)"
L=$(openstack image list --name debian13 -f value -c Status 2>/dev/null) || L=erreur
G=$(openstack flavor show m1.1g -f value -c ram 2>/dev/null) || G=""
I=$(printf '%s\n' "$L" | head -1)
if [ "$L" = erreur ]; then
  ecart "image debian13 : commande en échec" "vérifier que la plateforme répond (./openstack-lab-trainee/verify.sh)"
elif [ "$I" = active ] && [ "$G" = 1024 ]; then
  info "image debian13 et gabarit m1.1g déjà présents : à l'étape 0, passez directement à la création de la clé"
elif [ -n "$I" ] || [ -n "$G" ]; then
  info "image debian13 : ${I:-absente} ; gabarit m1.1g : ${G:-absent} ; ne créez à l'étape 0 que ce qui manque"
else
  ok "image debian13 et gabarit m1.1g absents : l'étape 0 les crée"
fi
if [ "$L" != erreur ]; then
  [ "$(printf '%s\n' "$L" | grep -c .)" -le 1 ] && ok "au plus une image debian13" \
    || ecart "plusieurs images debian13" "supprimer les doublons (openstack image list --name debian13 ; openstack image delete <ID>)"
fi
if [ -e ~/.ssh/tp12-key ] || [ -e ~/.ssh/tp12-key.pub ]; then
  ecart "~/.ssh/tp12-key existe déjà (essai précédent) : ssh-keygen demanderait s'il faut l'écraser et bloquerait le bloc" \
        "rm -f ~/.ssh/tp12-key ~/.ssh/tp12-key.pub (la paire de clés OpenStack est supprimée au nettoyage)"
else
  ok "clé ~/.ssh/tp12-key absente : l'étape 0 la crée"
fi

echo; echo "== Restes d'un essai précédent du TP 12"
R12="faire l'étape 12 du TP 12 (nettoyage)"
zero "VM tp12-*" "$(nb '^tp12-' openstack server list --all-projects -f value -c Name)" "$R12"
zero "volumes tp12-*" "$(nb '^tp12-' openstack volume list --all-projects -f value -c Name)" "$R12"
zero "ports tp12-*" "$(nb '^tp12-' openstack port list -f value -c Name)" "$R12"
zero "security groups tp12-*" "$(nb '^tp12-' openstack security group list -f value -c Name)" "$R12"
zero "paire de clés tp12-key" "$(nb '^tp12-' openstack keypair list -f value -c Name)" "$R12"

info "place libre dans le dossier personnel : $(df -h --output=avail ~ | tail -1 | tr -d ' ') (l'image fait environ 330 Mo)"

echo; echo "== Disque"
BESOIN=5   # Go libres demandés pour le TP 12
LIBRE=$(df --output=avail -BG / | tail -1 | tr -dc 0-9)
if [ "$LIBRE" -ge "$BESOIN" ]; then ok "place libre sur / : $LIBRE Go ($BESOIN Go demandés)"
else ecart "place libre sur / : $LIBRE Go, $BESOIN Go demandés" "libérer de la place (sudo docker image prune -f supprime les images sans étiquette ; sudo docker system df montre ce qui est récupérable) ou agrandir le disque de l'instance (TP 00)"; fi

echo
if [ "$ECARTS" -eq 0 ]; then echo "Lab prêt pour le TP 12."; else echo "$ECARTS écart(s) à corriger avant de commencer."; fi
[ "$ECARTS" -eq 0 ]
