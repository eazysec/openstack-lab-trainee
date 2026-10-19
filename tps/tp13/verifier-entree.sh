#!/usr/bin/env bash
# =============================================================================
#  verifier-entree.sh : le lab est-il prêt pour le TP 13 ? [instance]
#  Lecture seule : ne crée, ne modifie et ne supprime rien.
#
#  Usage : ./openstack-lab-trainee/tps/tp13/verifier-entree.sh
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
for s in volumev3 key-manager; do
  openstack service show $s >/dev/null 2>&1 && ok "service $s présent" \
    || ecart "service $s absent : le TP 13 demande le scénario 04 (volumes chiffrés, secrets)" "déployer le scénario 04 (TP 08, étape 0)"
done
[ "$(openstack image show debian13 -f value -c status 2>/dev/null)" = active ] && ok "image debian13 : active" \
  || ecart "image debian13 absente ou inutilisable" "refaire l'étape 0 du TP 12"
[ "$(openstack flavor show m1.1g -f value -c ram 2>/dev/null)" = 1024 ] && ok "gabarit m1.1g : 1024 Mo" \
  || ecart "gabarit m1.1g absent ou différent" "refaire l'étape 0 du TP 12"
for c in jq nc; do
  command -v $c >/dev/null && ok "commande $c présente sur l'hôte" || ecart "commande $c absente de l'hôte" "sudo apt-get install -y $( [ $c = nc ] && echo netcat-openbsd || echo $c )"
done

echo; echo "== Restes d'un essai précédent du TP 13 (ou du TP 14)"
R13="faire l'étape 16 du TP 13 (nettoyage)"
for t in network router port "security group" "floating ip"; do
  zero "$t avec le tag tp13" "$(nb . openstack $t list --tags tp13 -f value)" "$R13"
done
zero "VM tp13-*" "$(nb '^tp13-' openstack server list --all-projects -f value -c Name)" "$R13"
zero "volumes tp13-*" "$(nb '^tp13-' openstack volume list --all-projects -f value -c Name)" "$R13"
zero "types de volume tp13-*" "$(nb '^tp13-' openstack volume type list -f value -c Name)" "$R13"
zero "paires de clés tp13-*" "$(nb '^tp13-' openstack keypair list -f value -c Name)" "$R13"
zero "secrets tp13-*" "$(nb '"Name": "tp13-' openstack secret list -f json)" "$R13"
zero "réseaux ht-tp13-* (architecture créée par Heat au TP 14)" "$(nb '^ht-tp13-' openstack network list -f value -c Name)" "faire l'étape 10 du TP 14 (nettoyage)"
zero "FIP 10.0.2.150 allouée" "$(nb '^10\.0\.2\.150$' openstack floating ip list -f value -c 'Floating IP Address')" "$R13"

echo; echo "== Hôte : restes des étapes 3 et 4 d'un essai précédent"
zero "route 192.168.121.0/24" "$(nb . ip route show 192.168.121.0/24)" "$R13"
zero "règle FORWARD tp13" "$(nb tp13 sudo iptables -S FORWARD)" "$R13"
[ -e /etc/chrony/conf.d/tp13.conf ] && ecart "/etc/chrony/conf.d/tp13.conf présent" "$R13" || ok "configuration chrony du TP 13 : absente"
dpkg -l squid 2>/dev/null | grep -q '^ii' && ecart "Squid installé" "$R13" || ok "Squid : non installé"

info "mémoire disponible : $(awk '/^MemAvailable/{printf "%d Mo", $2/1024}' /proc/meminfo) (le TP 13 démarre deux VM de 1 Go)"

echo
if [ "$ECARTS" -eq 0 ]; then echo "Lab prêt pour le TP 13."; else echo "$ECARTS écart(s) à corriger avant de commencer."; fi
[ "$ECARTS" -eq 0 ]
