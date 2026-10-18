#!/usr/bin/env bash
# =============================================================================
#  deploy.sh : Déploiement OpenStack "All-in-One" via Kolla-Ansible
# -----------------------------------------------------------------------------
#  Cible   : Ubuntu 24.04 (Noble), une seule interface réseau (ex. EC2)
#  Usage   : ./deploy.sh scenarios/<scenario>.env     (utilisateur non-root + sudo)
#  Le script est idempotent : on peut le relancer après un échec, ou avec un
#  autre scénario pour faire évoluer un déploiement existant (ex. ajout de Cinder).
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_FILE="${1:-$SCRIPT_DIR/scenarios/01-aio-base.env}"
[[ -f "$SCENARIO_FILE" ]] || { echo "Scénario introuvable : $SCENARIO_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$SCENARIO_FILE"

# ----------------------------------------------------------------- CONFIG ----
# Valeurs par défaut ; un fichier de scénario ou l'environnement peut les surcharger.
OPENSTACK_RELEASE="${OPENSTACK_RELEASE:-2025.1}"   # branche stable Kolla-Ansible
WORKDIR="${WORKDIR:-$HOME/kolla}"                   # venv + inventaire + logs
VENV="$WORKDIR/venv"
INVENTORY="$WORKDIR/all-in-one"
LOGFILE="$WORKDIR/deploy-$(date +%Y%m%d-%H%M%S).log"

# Interface "management" : détectée via la route par défaut (enX0, eth0, ens5…)
MGMT_IF="${MGMT_IF:-$(ip -o -4 route show default | awk '{print $5; exit}')}"
MGMT_IP="${MGMT_IP:-$(ip -o -4 addr show dev "$MGMT_IF" | awk '{print $4}' | cut -d/ -f1 | head -1)}"

# Réseau "externe" Neutron, interne à l'hôte (paire veth + NAT)
VETH_HOST="veth-ext"
VETH_NEUTRON="veth-neutron"
EXT_CIDR="${EXT_CIDR:-10.0.2.0/24}"
EXT_GW="${EXT_GW:-10.0.2.1}"
EXT_POOL_START="${EXT_POOL_START:-10.0.2.100}"
EXT_POOL_END="${EXT_POOL_END:-10.0.2.200}"

# Services optionnels
ENABLE_HEAT="${ENABLE_HEAT:-no}"
ENABLE_CINDER="${ENABLE_CINDER:-no}"
ENABLE_BARBICAN="${ENABLE_BARBICAN:-no}"          # secrets ; requis pour chiffrer les volumes Cinder
ENABLE_DESIGNATE="${ENABLE_DESIGNATE:-no}"        # DNS (backend bind9 sur l'hôte, port 53)
ENABLE_LAB_BACKUP="${ENABLE_LAB_BACKUP:-no}"      # stockage objet S3 (Garage) + restic, hors Kolla (TP 10)
NEUTRON_DNS_DOMAIN="${NEUTRON_DNS_DOMAIN:-lab.example.}"   # domaine DNS des ports Neutron (avec point final)
DESIGNATE_NS_RECORD="${DESIGNATE_NS_RECORD:-ns1.lab.example}"   # serveur de noms des zones, SANS point final (Kolla l'ajoute)
CINDER_DEVICE="${CINDER_DEVICE:-}"                  # ex. /dev/nvme1n1 (vide = fichier loop)
CINDER_LOOP_FILE="${CINDER_LOOP_FILE:-/var/lib/cinder-volumes.img}"
CINDER_LOOP_SIZE_GB="${CINDER_LOOP_SIZE_GB:-20}"

LAB_CONF_DIR=/etc/openstack-lab                     # config hôte persistante (lue au boot)

# Virtualisation : kvm si /dev/kvm existe (instance *.metal), sinon émulation qemu
if [[ -e /dev/kvm ]]; then VIRT_TYPE="kvm"; else VIRT_TYPE="qemu"; fi

# ---------------------------------------------------------------- HELPERS ----
mkdir -p "$WORKDIR"
exec > >(tee -a "$LOGFILE") 2>&1
log() { printf '\n\e[1;34m[%(%H:%M:%S)T] ==> %s\e[0m\n' -1 "$*"; }
die() { printf '\e[1;31mERREUR: %s\e[0m\n' "$*" >&2; exit 1; }
trap 'die "échec ligne $LINENO (commande: $BASH_COMMAND). Log: $LOGFILE"' ERR

# -------------------------------------------------------------- PRÉ-CHECKS ---
log "Vérifications préalables (scénario : $(basename "$SCENARIO_FILE"))"
[[ $EUID -ne 0 ]] || die "Lancer en utilisateur normal (avec sudo), pas en root."
sudo -n true 2>/dev/null || die "sudo sans mot de passe requis."
. /etc/os-release
[[ "$ID" == "ubuntu" && "$VERSION_ID" == "24.04" ]] || echo "ATTENTION: validé sur Ubuntu 24.04 uniquement (détecté: $PRETTY_NAME)"
[[ -n "$MGMT_IF" && -n "$MGMT_IP" ]] || die "Impossible de détecter l'interface/IP de management."
mem_gb=$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo)
(( mem_gb >= 8 ))   || die "8 Go de RAM minimum requis (détecté: ${mem_gb} Go)."
(( $(nproc) >= 2 )) || die "2 vCPU minimum requis."
if [[ "$ENABLE_CINDER" == "yes" && -n "$CINDER_DEVICE" ]]; then
  [[ -b "$CINDER_DEVICE" ]] || die "CINDER_DEVICE=$CINDER_DEVICE n'est pas un disque bloc."
  if ! sudo pvs "$CINDER_DEVICE" >/dev/null 2>&1 && sudo blkid "$CINDER_DEVICE" >/dev/null 2>&1; then
    die "$CINDER_DEVICE contient déjà des données (blkid) : refus de l'écraser."
  fi
fi
echo "Interface mgmt : $MGMT_IF ($MGMT_IP) | virt_type : $VIRT_TYPE | release : $OPENSTACK_RELEASE"
echo "Cinder : $ENABLE_CINDER ${CINDER_DEVICE:-(fichier loop $CINDER_LOOP_FILE)} | Heat : $ENABLE_HEAT | Barbican : $ENABLE_BARBICAN | Designate : $ENABLE_DESIGNATE | Sauvegarde (S3) : $ENABLE_LAB_BACKUP"
if [[ "$ENABLE_BARBICAN$ENABLE_DESIGNATE" == *yes* ]] && (( mem_gb < 15 )); then
  echo "ATTENTION: Barbican/Designate ajoutent ~1 à 2 Go de RAM ; 16 Go recommandés (détecté: ${mem_gb} Go)."
fi
if [[ "$ENABLE_LAB_BACKUP" == "yes" ]] && ! sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx lab-s3; then
  for p in 3900 3901 3903; do
    sudo ss -Hltn "sport = :$p" | grep -q . && die "Port $p déjà utilisé : le stockage objet du lab (Garage) ne pourra pas démarrer."
  done
fi
if [[ "$ENABLE_DESIGNATE" == "yes" ]]; then
  # Le port 53 doit être libre, sauf pour systemd-resolved (127.0.0.53/54) et le bind9 de Designate
  # lui-même ("named", présent quand on relance deploy.sh sur un déploiement existant).
  other53=$(sudo ss -Hlnup "sport = :53" | grep -v '127\.0\.0\.5[34]' | grep -v '"named"' || true)
  [[ -z "$other53" ]] || die "Port 53 déjà utilisé : Designate (bind9) ne pourra pas démarrer. $other53"
fi

# ------------------------------------------------------------ DÉPENDANCES ----
log "Installation des paquets système"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -q
sudo apt-get install -yq git python3-dev python3-venv libffi-dev gcc libssl-dev \
     libdbus-glib-1-dev libdbus-1-dev libglib2.0-dev pkg-config cmake lvm2 bind9-dnsutils

# Swap de 8 Go : évite l'OOM pendant le déploiement et le lancement de VM
if ! swapon --show | grep -q /swapfile; then
  log "Création d'un swap de 8 Go"
  [[ -f /swapfile ]] || { sudo fallocate -l 8G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile; }
  sudo swapon /swapfile
fi
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null

# Le hostname doit être résolvable (RabbitMQ en dépend)
grep -qw "$(hostname)" /etc/hosts || echo "$MGMT_IP $(hostname)" | sudo tee -a /etc/hosts >/dev/null

# ------------------------------------------------- RÉSEAU HÔTE (veth + NAT) --
log "Réseau externe Neutron interne à l'hôte ($VETH_HOST <-> $VETH_NEUTRON, $EXT_CIDR)"
sudo mkdir -p "$LAB_CONF_DIR"
sudo tee "$LAB_CONF_DIR/network.env" >/dev/null <<EOF
MGMT_IF=$MGMT_IF
VETH_HOST=$VETH_HOST
VETH_NEUTRON=$VETH_NEUTRON
EXT_CIDR=$EXT_CIDR
EXT_GW=$EXT_GW
EOF
sudo install -m 755 "$SCRIPT_DIR/tools/openstack-lab-net.sh" /usr/local/sbin/openstack-lab-net.sh
sudo tee /etc/systemd/system/openstack-lab-net.service >/dev/null <<'EOF'
[Unit]
Description=OpenStack lab : paire veth, NAT du réseau externe Neutron, floating IP publiques
After=network-online.target
Wants=network-online.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openstack-lab-net.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable openstack-lab-net.service
sudo systemctl restart openstack-lab-net.service
# Si systemd-networkd reconfigure l'interface (renouvellement DHCP, netplan apply…), il
# efface les IP qu'il ne gère pas : networkd-dispatcher relance alors le script réseau.
if [[ -d /etc/networkd-dispatcher ]]; then
  # routable.d : déclenché chaque fois que l'interface redevient opérationnelle
  HOOK=/etc/networkd-dispatcher/routable.d/50-openstack-lab
  sudo mkdir -p "$(dirname "$HOOK")"
  sudo tee "$HOOK" >/dev/null <<EOF
#!/bin/sh
# Relance le service (et non le script seul) : un service en échec, par exemple
# démarré sans réseau, se rétablit dès que l'interface redevient opérationnelle.
[ "\$IFACE" = "$MGMT_IF" ] && systemctl restart --no-block openstack-lab-net.service
exit 0
EOF
  sudo chmod 755 "$HOOK"
else
  echo "ATTENTION: networkd-dispatcher absent ; les floating IP publiques (scénario 03) ne seront pas restaurées après une reconfiguration réseau."
fi

# ------------------------------------------- STOCKAGE CINDER (LVM) -----------
if [[ "$ENABLE_CINDER" == "yes" ]]; then
  log "Préparation du groupe de volumes LVM cinder-volumes"
  if [[ -z "$CINDER_DEVICE" ]]; then
    # Fichier "loop" : pas de disque supplémentaire (donc pas de coût), mais
    # performances et capacité limitées par le disque racine.
    [[ -f "$CINDER_LOOP_FILE" ]] || sudo truncate -s "${CINDER_LOOP_SIZE_GB}G" "$CINDER_LOOP_FILE"
    echo "CINDER_LOOP_FILE=$CINDER_LOOP_FILE" | sudo tee "$LAB_CONF_DIR/cinder.env" >/dev/null
    sudo install -m 755 "$SCRIPT_DIR/tools/openstack-lab-cinder-loop.sh" /usr/local/sbin/openstack-lab-cinder-loop.sh
    # Dépendances par défaut conservées : le service attend que / soit monté en
    # écriture (sinon la boucle serait attachée en lecture seule).
    sudo tee /etc/systemd/system/openstack-lab-cinder-loop.service >/dev/null <<EOF
[Unit]
Description=OpenStack lab : attache le fichier loop du VG cinder-volumes
RequiresMountsFor=$(dirname "$CINDER_LOOP_FILE")
After=systemd-remount-fs.service local-fs.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openstack-lab-cinder-loop.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable openstack-lab-cinder-loop.service
    if sudo vgs cinder-volumes >/dev/null 2>&1; then
      sudo systemctl restart openstack-lab-cinder-loop.service   # VG existant : vérifie/répare la boucle
    else
      sudo losetup -j "$CINDER_LOOP_FILE" | grep -q . || sudo losetup -f "$CINDER_LOOP_FILE"
    fi
    PV=$(sudo losetup -j "$CINDER_LOOP_FILE" | cut -d: -f1 | head -1)
  else
    PV="$CINDER_DEVICE"
  fi
  sudo vgs cinder-volumes >/dev/null 2>&1 || { sudo pvcreate "$PV" && sudo vgcreate cinder-volumes "$PV"; }
  sudo vgs cinder-volumes
fi

# ------------------------------------------------------------ KOLLA-ANSIBLE --
log "Installation de Kolla-Ansible stable/$OPENSTACK_RELEASE dans $VENV"
[[ -d "$VENV" ]] || python3 -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
pip install -q -U pip
pip install -q "git+https://opendev.org/openstack/kolla-ansible@stable/$OPENSTACK_RELEASE"
pip install -q docker dbus-python python-openstackclient python-barbicanclient python-designateclient \
    -c "https://releases.openstack.org/constraints/upper/$OPENSTACK_RELEASE"

sudo mkdir -p /etc/kolla/config/nova
sudo chown -R "$USER:$USER" /etc/kolla
[[ -f /etc/kolla/passwords.yml ]] || cp "$VENV/share/kolla-ansible/etc_examples/kolla/passwords.yml" /etc/kolla/
cp "$VENV/share/kolla-ansible/ansible/inventory/all-in-one" "$INVENTORY"

log "Installation des collections Ansible Galaxy"
kolla-ansible install-deps

# kolla-genpwd ne remplit que les mots de passe vides : les existants sont conservés. On le lance à
# chaque fois, pour que les services ajoutés à un déploiement existant aient leurs secrets.
log "Génération des mots de passe manquants (les existants sont conservés)"
kolla-genpwd

# --------------------------------------------------------------- CONFIG ------
log "Écriture de /etc/kolla/globals.yml"
# Avec Designate, le domaine DNS de Neutron doit finir par un point (contrôlé par les prechecks),
# et ne doit PAS valoir "openstacklocal." : avec cette valeur par défaut, Neutron ignore le dns_name
# des ports (neutron/plugins/ml2/extensions/dns_integration.py) et aucun nom n'est publié.
NEUTRON_DNS_DOMAIN_LINE=""
[[ "$ENABLE_DESIGNATE" == "yes" ]] && NEUTRON_DNS_DOMAIN_LINE="neutron_dns_domain: \"$NEUTRON_DNS_DOMAIN\""
cat > /etc/kolla/globals.yml <<EOF
---
# Généré par deploy.sh ($(basename "$SCENARIO_FILE")) le $(date -Iseconds)
kolla_base_distro: "ubuntu"
openstack_release: "$OPENSTACK_RELEASE"

# Une seule interface : pas de load balancer ni de VIP, l'API écoute sur l'IP de l'hôte
network_interface: "$MGMT_IF"
kolla_internal_vip_address: "$MGMT_IP"
enable_loadbalancer: "no"        # désactive haproxy + keepalived + proxysql
enable_haproxy: "no"
enable_keepalived: "no"
enable_proxysql: "no"

# Réseau externe Neutron = extrémité de la paire veth
neutron_external_interface: "$VETH_NEUTRON"
neutron_plugin_agent: "openvswitch"

# Services
enable_openstack_core: "yes"
enable_horizon: "yes"
# Console des VM : Nova annonce par défaut l'IP privée de l'hôte, injoignable depuis un poste.
# Le navigateur la joint par le tunnel SSH d'Horizon (-L 6080:<IP_PRIVEE>:6080), sans port ouvert.
nova_novncproxy_fqdn: "localhost"
enable_heat: "$ENABLE_HEAT"
enable_barbican: "$ENABLE_BARBICAN"
enable_designate: "$ENABLE_DESIGNATE"
designate_backend: "bind9"
designate_ns_record:
  - "$DESIGNATE_NS_RECORD"
$NEUTRON_DNS_DOMAIN_LINE
enable_cinder: "$ENABLE_CINDER"
enable_cinder_backend_lvm: "$ENABLE_CINDER"
enable_cinder_backup: "no"       # nécessiterait Swift, Ceph ou NFS
cinder_volume_group: "cinder-volumes"

nova_compute_virt_type: "$VIRT_TYPE"
EOF

# MariaDB : par défaut InnoDB réserve ~40 % de la RAM ; on la limite pour un AIO
cat > /etc/kolla/config/galera.cnf <<EOF
[mysqld]
innodb_buffer_pool_size = 1G
EOF

# Nova-compute : relance des VM après reboot de l'hôte ; en QEMU, CPU compatible émulation
cat > /etc/kolla/config/nova/nova-compute.conf <<EOF
[DEFAULT]
resume_guests_state_on_host_boot = true
EOF
if [[ "$VIRT_TYPE" == "qemu" ]]; then
  cat >> /etc/kolla/config/nova/nova-compute.conf <<EOF
[libvirt]
virt_type = qemu
cpu_mode = none
EOF
fi

# ---------------------------------------------------------------- DÉPLOIEMENT
log "bootstrap-servers (Docker, utilisateurs, paquets)"
kolla-ansible bootstrap-servers -i "$INVENTORY"
sudo usermod -aG docker "$USER"

log "prechecks"
kolla-ansible prechecks -i "$INVENTORY"

log "pull des images"
kolla-ansible pull -i "$INVENTORY"

log "deploy"
kolla-ansible deploy -i "$INVENTORY"

log "post-deploy (admin-openrc.sh / clouds.yaml)"
kolla-ansible post-deploy -i "$INVENTORY"
mkdir -p "$HOME/.config/openstack"
cp /etc/kolla/clouds.yaml "$HOME/.config/openstack/clouds.yaml"

# Horizon : après l'ajout d'un tableau de bord (ex. Designate sur un déploiement existant), sa page de
# connexion peut répondre 500 (OfflineGenerationError : compression des fichiers statiques périmée).
# On le détecte et on force la régénération au redémarrage du conteneur.
log "Contrôle de la page de connexion Horizon"
horizon_code() { curl -s -o /dev/null -m 20 -w '%{http_code}' "http://$MGMT_IP/auth/login/" || true; }
for _ in $(seq 24); do code=$(horizon_code); [[ "$code" != 000 ]] && break; sleep 5; done
if [[ "$code" != 200 ]]; then
  echo "Horizon répond HTTP $code : régénération de la compression des fichiers statiques"
  sudo docker exec horizon rm -f /var/lib/kolla/.settings.md5sum.txt
  sudo systemctl restart kolla-horizon-container.service
  for _ in $(seq 40); do code=$(horizon_code); [[ "$code" == 200 ]] && break; sleep 5; done
  [[ "$code" == 200 ]] || die "Horizon répond toujours HTTP $code : voir /var/log/kolla/horizon/horizon-error.log"
fi
echo "Horizon : page de connexion OK (HTTP 200)"

# Stockage objet du lab (hors Kolla) : Garage (S3) + restic statique, pour le TP 10
if [[ "$ENABLE_LAB_BACKUP" == "yes" ]]; then
  log "Stockage objet du lab (Garage S3) et restic"
  sudo "$SCRIPT_DIR/tools/lab-s3.sh" install "$MGMT_IP"
fi
# ------------------------------------------------- RESSOURCES DE DÉMO --------
log "Ressources de démo (réseau externe, image, flavors, keypair)"
# shellcheck disable=SC1091
source /etc/kolla/admin-openrc.sh
if ! openstack network show public1 >/dev/null 2>&1; then
  EXT_NET_CIDR="$EXT_CIDR" EXT_NET_GATEWAY="$EXT_GW" \
  EXT_NET_RANGE="start=$EXT_POOL_START,end=$EXT_POOL_END" \
    "$VENV/share/kolla-ansible/init-runonce"
else
  echo "Déjà présentes, étape ignorée."
fi

# ------------------------------------------------------------------ RÉSUMÉ ---
log "Déploiement terminé"
cat <<EOF
  Horizon        : http://$MGMT_IP/  (via l'IP publique ou un tunnel SSH, voir README)
  Utilisateur    : admin  (mot de passe : grep keystone_admin_password /etc/kolla/passwords.yml)
  CLI            : source $VENV/bin/activate && source /etc/kolla/admin-openrc.sh
  Réseau externe : $EXT_CIDR (floating IP $EXT_POOL_START-$EXT_POOL_END)
  Vérification   : $SCRIPT_DIR/verify.sh
  Log            : $LOGFILE
EOF
