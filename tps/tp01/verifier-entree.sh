#!/usr/bin/env bash
# =============================================================================
#  verifier-entree.sh : le lab est-il prêt pour le TP 01 ? [instance]
#  Lecture seule : ne crée, ne modifie et ne supprime rien.
#
#  Usage : ./openstack-lab-trainee/tps/tp01/verifier-entree.sh
#  Code retour : 0 si toutes les conditions d'entrée sont remplies, 1 sinon.
#  Chaque écart est suivi de ce qu'il faut faire. OpenStack n'est pas encore installé : seuls
#  l'instance et son accès à Internet sont vérifiés.
# =============================================================================
set -uo pipefail
ECARTS=0
ok()    { echo "[OK]         $*"; }
ecart() { echo "[À CORRIGER] $1"; echo "             -> $2"; ECARTS=$((ECARTS + 1)); }
info()  { echo "[INFO]       $*"; }

echo "== Instance"
[ "$(id -u)" -ne 0 ] && ok "utilisateur normal (pas root)" || ecart "lancé en root" "se connecter en ubuntu (ssh -i ec2_key ubuntu@<IP_PUBLIQUE>)"
sudo -n true 2>/dev/null && ok "sudo sans mot de passe" || ecart "sudo demande un mot de passe" "utiliser l'utilisateur ubuntu de l'image AWS"
. /etc/os-release
[ "$ID $VERSION_ID" = "ubuntu 24.04" ] && ok "Ubuntu 24.04" || ecart "système $PRETTY_NAME : le lab est validé sur Ubuntu 24.04 seulement" "recréer l'instance avec Ubuntu 24.04 (TP 00)"
M=$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo)
if [ "$M" -ge 15 ]; then ok "mémoire : $M Go"; elif [ "$M" -ge 8 ]; then info "mémoire : $M Go : assez pour le scénario 01, pas pour le scénario 04 (16 Go recommandés)"; else ecart "mémoire : $M Go, 8 Go minimum" "choisir un type d'instance plus grand (TP 00)"; fi
[ "$(nproc)" -ge 2 ] && ok "$(nproc) vCPU" || ecart "$(nproc) vCPU, 2 minimum" "choisir un type d'instance plus grand (TP 00)"
command -v tmux >/dev/null && ok "tmux présent" || ecart "tmux absent" "sudo apt-get install -y tmux"
for u in https://opendev.org https://quay.io; do
  curl -s -o /dev/null -m 15 -I "$u" && ok "$u joignable" || ecart "$u injoignable : le déploiement y télécharge Kolla-Ansible et les images" "vérifier l'accès Internet de l'instance (Security Group AWS en sortie, route par défaut)"
done
info "place libre sur / : $(df -h --output=avail / | tail -1 | tr -d ' ')"
if [ -d ~/kolla/venv ] || sudo docker ps -q 2>/dev/null | grep -q .; then
  info "un déploiement existe déjà : relancer deploy.sh est sans risque (il est idempotent)"
fi

echo
if [ "$ECARTS" -eq 0 ]; then echo "Lab prêt pour le TP 01."; else echo "$ECARTS écart(s) à corriger avant de commencer."; fi
[ "$ECARTS" -eq 0 ]
