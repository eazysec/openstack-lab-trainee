#!/usr/bin/env bash
# =============================================================================
#  verify.sh : Test de bout en bout d'un déploiement (à lancer sur l'hôte)
#  Usage : ./verify.sh [--keep]     (--keep : ne supprime pas la VM de test)
#  Code retour : 0 si tous les tests passent, 1 sinon.
#  Crée puis supprime (ressources préfixées verify-) : 1 VM, 2 floating IP, et selon les
#  services présents : 2 volumes de 1 Go, 1 type de volume chiffré, 1 secret, 1 zone DNS.
# =============================================================================
set -uo pipefail
KEEP="${1:-}"
WORKDIR="${WORKDIR:-$HOME/kolla}"
# shellcheck disable=SC1091
source "$WORKDIR/venv/bin/activate"
# shellcheck disable=SC1091
source /etc/kolla/admin-openrc.sh
# shellcheck disable=SC1091
source /etc/openstack-lab/network.env

NAME="verify-$(date +%s)"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR)
PASS=0; FAIL=0
check() {  # check "description" commande...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '  \e[32m[PASS]\e[0m %s\n' "$desc"; PASS=$((PASS+1))
  else printf '  \e[31m[FAIL]\e[0m %s\n' "$desc"; FAIL=$((FAIL+1)); fi
}
retry() {  # retry <essais> <pause> commande...
  local n=$1 s=$2; shift 2
  for _ in $(seq "$n"); do "$@" && return 0; sleep "$s"; done; return 1
}
vm_ssh() { ssh -n "${SSH_OPTS[@]}" "cirros@$FIP" "$@"; }   # -n : ne lit pas l'entrée standard
# Connexion réelle à Horizon (formulaire + jeton CSRF) : succès si le tableau de bord s'affiche
horizon_login() {
  local url="http://$1" jar page csrf region post pw
  pw=$(awk '/^keystone_admin_password:/{print $2}' /etc/kolla/passwords.yml)
  jar=$(mktemp)
  page=$(curl -s -c "$jar" -b "$jar" "$url/auth/login/")
  csrf=$(awk '$6=="csrftoken"{print $7}' "$jar")
  region=$(grep -oE 'name="region" value="[^"]*"' <<< "$page" | head -1 | cut -d'"' -f4)   # champ caché
  post=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -c "$jar" -b "$jar" -e "$url/auth/login/" \
    --data-urlencode "csrfmiddlewaretoken=$csrf" --data-urlencode "username=admin" \
    --data-urlencode "password=$pw" --data-urlencode "region=$region" "$url/auth/login/")
  [[ "$post" == 302* && "$post" != *auth/login* ]] \
    && [[ "$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" "$url/project/")" == 200 ]]
  local rc=$?; rm -f "$jar"; return $rc
}
# Supprime un volume, y compris s'il est bloqué (error, error_deleting, attaching…)
volume_purge() {
  local vol="$1" srv
  srv=$(openstack volume show "$vol" -f value -c attachments 2>/dev/null | grep -o "'server_id': '[^']*'" | cut -d"'" -f4)
  [[ -n "$srv" ]] && openstack server remove volume "$srv" "$vol" 2>/dev/null && sleep 5
  openstack volume delete "$vol" 2>/dev/null && return 0
  openstack volume set --state error --detached "$vol" 2>/dev/null
  openstack volume delete --force "$vol" 2>/dev/null || openstack volume delete "$vol" 2>/dev/null
}
# Supprime les ressources de test "verify-*" (de cette exécution, ou d'une précédente interrompue)
purge_test_resources() {
  local id fip
  if openstack service show volumev3 >/dev/null 2>&1; then     # seulement si Cinder est déployé
    for id in $(openstack volume list -f value -c ID -c Name | awk '$2 ~ /^verify-/{print $1}'); do volume_purge "$id"; done
  fi
  for id in $(openstack server list -f value -c ID -c Name | awk '$2 ~ /^verify-/{print $1}'); do
    for fip in $(openstack floating ip list --port "$(openstack port list --server "$id" -f value -c ID | head -1)" -f value -c ID 2>/dev/null); do
      openstack floating ip delete "$fip" 2>/dev/null
    done
    openstack server delete --wait "$id" 2>/dev/null
  done
  # Une VM peut rester listée "DELETED" quelques secondes après "delete --wait"
  retry 30 2 bash -c "! openstack server list -f value -c Name | grep -q '^verify-'"
  if openstack service show volumev3 >/dev/null 2>&1; then
    for id in $(openstack volume type list -f value -c ID -c Name 2>/dev/null | awk '$2 ~ /^verify-/{print $1}'); do
      openstack volume type delete "$id" 2>/dev/null
    done
  fi
  if openstack service show key-manager >/dev/null 2>&1; then
    for id in $(openstack secret list -f value -c "Secret href" -c Name 2>/dev/null | awk '$2 ~ /^verify-/{print $1}'); do
      openstack secret delete "$id" 2>/dev/null
    done
  fi
  if openstack service show dns >/dev/null 2>&1; then
    for id in $(openstack zone list -f value -c id -c name 2>/dev/null | awk '$2 ~ /^verify-/{print $1}'); do
      openstack zone delete "$id" >/dev/null 2>&1
    done
  fi
}
cleanup() {
  [[ "$KEEP" == "--keep" ]] && { echo "VM conservée : $NAME ($FIP)"; return; }
  [[ -n "${FIP:-}" ]] && openstack floating ip delete "$FIP" 2>/dev/null
  purge_test_resources
}
trap cleanup EXIT

if [[ "$KEEP" != "--keep" ]]; then
  echo "== Nettoyage des restes de tests précédents (verify-*)"
  purge_test_resources
fi

echo "== Hôte"
check "service openstack-lab-net actif"           systemctl is-active openstack-lab-net
check "passerelle $EXT_GW sur $VETH_HOST"         bash -c "ip -4 addr show $VETH_HOST | grep -q $EXT_GW"
check "aucun conteneur unhealthy"                 bash -c '[ -z "$(sudo docker ps -q --filter health=unhealthy)" ]'
check "aucun conteneur en redémarrage"            bash -c '[ -z "$(sudo docker ps -q --filter status=restarting)" ]'

echo "== API OpenStack"
check "Keystone : jeton"                          openstack token issue
check "Nova : tous les services up"               bash -c '! openstack compute service list -f value -c State | grep -qv up'
check "Neutron : tous les agents alive"           bash -c '! openstack network agent list -f value -c Alive | grep -qv True'
check "Glance : image cirros"                     openstack image show cirros
API_HOST="${OS_AUTH_URL#*://}"; API_HOST="${API_HOST%%[:/]*}"
check "Horizon : HTTP 200/302"                    bash -c "curl -s -o /dev/null -w '%{http_code}' http://$API_HOST/ | grep -qE '200|302'"
check "Horizon : page de connexion (HTTP 200)"    bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' http://$API_HOST/auth/login/)\" = 200 ]"
check "Horizon : connexion admin réelle"           horizon_login "$API_HOST"

echo "== Cycle de vie d'une VM"
check "création VM $NAME (ACTIVE)"                openstack server create --image cirros --flavor m1.tiny \
                                                    --key-name mykey --network demo-net --wait "$NAME"
FIP=$(openstack floating ip create public1 -f value -c floating_ip_address 2>/dev/null)
check "floating IP $FIP associée"                 openstack server add floating ip "$NAME" "$FIP"
check "ping hôte -> VM"                           retry 30 5 ping -c1 -W2 "$FIP"
check "SSH hôte -> VM"                            retry 20 5 vm_ssh true
check "VM -> Internet (ping 8.8.8.8)"             vm_ssh ping -c2 8.8.8.8
check "VM -> DNS (opendev.org)"                   vm_ssh nslookup opendev.org

if openstack service show cinderv3 >/dev/null 2>&1; then
  echo "== Cinder"
  check "Cinder : services up"                    bash -c '! openstack volume service list -f value -c State | grep -qv up'
  VOL=$(openstack volume create --size 1 "$NAME-vol" -f value -c id 2>/dev/null)
  check "volume 1 Go disponible"                  retry 30 2 bash -c "openstack volume show $VOL -f value -c status | grep -qx available"
  check "attachement du volume à la VM"           openstack server add volume "$NAME" "$VOL"
  check "disque /dev/vdb visible dans la VM"      retry 20 3 vm_ssh test -b /dev/vdb
  check "écriture/lecture sur le volume"          vm_ssh "sudo sh -c 'echo ok | dd of=/dev/vdb conv=fsync 2>/dev/null && head -c2 /dev/vdb | grep -q ok'"
fi

if openstack service show key-manager >/dev/null 2>&1; then
  echo "== Barbican"
  SECRET=$(openstack secret store --name "$NAME-secret" --payload "valeur-$NAME" -f value -c "Secret href" 2>/dev/null)
  check "secret enregistré"                       test -n "$SECRET"
  check "secret relu à l'identique"               bash -c "openstack secret get --payload $SECRET -f value -c Payload | grep -qx valeur-$NAME"
  if [[ -n "${VOL:-}" ]]; then
    echo "== Chiffrement des volumes (Cinder + Barbican)"
    check "type de volume chiffré LUKS"           openstack volume type create --encryption-provider luks \
                                                    --encryption-cipher aes-xts-plain64 --encryption-key-size 256 \
                                                    --encryption-control-location front-end "$NAME-luks"
    VOLC=$(openstack volume create --size 1 --type "$NAME-luks" "$NAME-volchiffre" -f value -c id 2>/dev/null)
    check "volume chiffré disponible"             retry 30 2 bash -c "openstack volume show $VOLC -f value -c status | grep -qx available"
    check "attachement du volume chiffré"         openstack server add volume "$NAME" "$VOLC"
    check "disque /dev/vdc visible dans la VM"    retry 20 3 vm_ssh test -b /dev/vdc
    check "écriture/lecture en clair dans la VM"  vm_ssh "sudo sh -c 'echo texte-en-clair | dd of=/dev/vdc conv=fsync 2>/dev/null && head -c14 /dev/vdc | grep -q texte-en-clair'"
    LV="/dev/cinder-volumes/volume-$VOLC"
    check "sur l'hôte : en-tête LUKS sur le volume" bash -c "sudo head -c 6 $LV | grep -q LUKS"
    check "sur l'hôte : texte illisible (chiffré)" bash -c "! sudo head -c 64M $LV | grep -aq texte-en-clair"
  fi
fi

if openstack service show dns >/dev/null 2>&1; then
  echo "== Designate"
  ZONE="$NAME.lab.example."
  check "zone $ZONE créée"                         openstack zone create --email admin@lab.example "$ZONE"
  check "zone ACTIVE"                             retry 30 2 bash -c "openstack zone show $ZONE -f value -c status | grep -qx ACTIVE"
  check "enregistrement A www"                    openstack recordset create --type A --record 192.0.2.10 "$ZONE" www
  check "résolution par bind9 (dig @$API_HOST)"   retry 30 2 bash -c "dig +short @$API_HOST www.$ZONE A | grep -qx 192.0.2.10"
  echo "== Intégration Neutron / Designate"
  PORT=$(openstack port list --server "$NAME" -f value -c ID | head -1)
  openstack port set --dns-name "$NAME" "$PORT" 2>/dev/null
  check "dns_name du port enregistré par Neutron" bash -c "openstack port show $PORT -f value -c dns_name | grep -qx $NAME"
  FIPDNS=$(openstack floating ip create public1 --dns-name api --dns-domain "$ZONE" -f value -c floating_ip_address 2>/dev/null)
  check "floating IP nommée publiée (api.$ZONE)"  retry 30 2 bash -c "dig +short @$API_HOST api.$ZONE A | grep -qx $FIPDNS"
  [[ -n "$FIPDNS" ]] && openstack floating ip delete "$FIPDNS" 2>/dev/null
fi

if sudo docker ps --format '{{.Names}}' | grep -qx lab-s3; then
  echo "== Stockage objet du lab (Garage S3) et restic"
  G=(sudo docker exec lab-s3 /garage)
  check "Garage : nœud en bonne santé, avec un rôle" bash -c "sudo docker exec lab-s3 /garage status 2>/dev/null | grep -A3 'HEALTHY NODES' | grep -q ' lab '"
  check "API S3 à l'écoute ($API_HOST:3900)"       bash -c "sudo ss -Hltn 'sport = :3900' | grep -q $API_HOST"
  check "restic statique installé"                  bash -c "file -L /usr/local/bin/restic | grep -q 'statically linked'"
  # Bucket, clé et dépôt dédiés à verify.sh, réutilisés à chaque passage et purgés (rien ne s'accumule)
  "${G[@]}" key info lab-verify >/dev/null 2>&1 || "${G[@]}" key create lab-verify >/dev/null 2>&1
  "${G[@]}" bucket info lab-verify >/dev/null 2>&1 || { "${G[@]}" bucket create lab-verify >/dev/null 2>&1; \
    "${G[@]}" bucket allow --read --write --owner lab-verify --key lab-verify >/dev/null 2>&1; }
  sudo test -f /srv/lab-s3/verify-pw || sudo sh -c 'umask 077; openssl rand -base64 24 > /srv/lab-s3/verify-pw'
  KINFO=$("${G[@]}" key info lab-verify --show-secret 2>/dev/null)
  VD=$(mktemp -d); VR=$(mktemp -d); head -c 1048576 /dev/urandom > "$VD/donnee.bin"
  rs() { sudo AWS_ACCESS_KEY_ID="$(awk '/Key ID/{print $3}' <<< "$KINFO")" \
           AWS_SECRET_ACCESS_KEY="$(awk '/Secret key/{print $3}' <<< "$KINFO")" AWS_DEFAULT_REGION=garage \
           RESTIC_PASSWORD_FILE=/srv/lab-s3/verify-pw RESTIC_REPOSITORY="s3:http://$API_HOST:3900/lab-verify/verify" \
           /usr/local/bin/restic "$@"; }
  rs cat config >/dev/null 2>&1 || rs init >/dev/null 2>&1
  check "restic -> S3 : sauvegarde"                 rs backup -q "$VD"
  rs restore latest --target "$VR" -q >/dev/null 2>&1
  check "restic -> S3 : restauration identique"     sudo cmp "$VD/donnee.bin" "$VR$VD/donnee.bin"
  # --group-by host : les sauvegardes portent sur des dossiers temporaires différents à chaque passage
  rs forget --group-by host --keep-last 1 --prune -q >/dev/null 2>&1 || true
  sudo rm -rf "$VD" "$VR"
fi

if [[ -s /etc/openstack-lab/public-fip.map ]]; then
  echo "== Floating IP publiques (scénario 03)"
  while read -r priv fip; do
    [[ "$priv" =~ ^# || -z "$priv" ]] && continue
    check "IP secondaire $priv portée par $MGMT_IF"  bash -c "ip -4 addr show $MGMT_IF | grep -qw $priv"
    check "DNAT $priv -> $fip présent"               bash -c "sudo iptables -t nat -S LAB_FIP_PRE | grep -q -- '-d $priv/32.*--to-destination $fip'"
  done < /etc/openstack-lab/public-fip.map
  echo "  (l'accès depuis Internet se teste depuis votre poste : ssh cirros@<ELASTIC_IP>)"
fi

echo
echo "Résultat : $PASS réussis, $FAIL échoués"
(( FAIL == 0 ))
