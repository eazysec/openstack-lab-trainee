#!/usr/bin/env bash
# =============================================================================
#  lab-s3.sh : Stockage objet S3 du lab (Garage) et restic, hors Kolla (TP 10)
#
#  Usage : sudo ./lab-s3.sh install <IP_API_S3>   installe/répare (idempotent)
#          sudo ./lab-s3.sh status                état du nœud Garage
#          sudo ./lab-s3.sh remove                supprime le conteneur et les données
#
#  - Garage (serveur S3 léger) tourne dans le conteneur Docker "lab-s3", redémarré
#    automatiquement par Docker ; API S3 sur <IP_API_S3>:3900, RPC et administration
#    sur 127.0.0.1 uniquement. Données et configuration dans /srv/lab-s3 (root, 600).
#  - restic : binaire STATIQUE officiel dans /usr/local/bin/restic (empreinte vérifiée),
#    utilisable sur l'hôte et copiable tel quel dans une VM (CirrOS comprise).
#  - s3cmd (paquet Ubuntu) : client S3 pour lister et vider un bucket.
#  - Ne crée ni clé ni bucket : c'est l'objet du TP 10.
# =============================================================================
set -Eeuo pipefail
GARAGE_IMAGE="${GARAGE_IMAGE:-dxflrs/garage:v2.4.1}"
RESTIC_VERSION="${RESTIC_VERSION:-0.19.1}"
LAB_S3_CAPACITY="${LAB_S3_CAPACITY:-10G}"
DIR=/srv/lab-s3
NAME=lab-s3
G=(docker exec "$NAME" /garage)
[[ $EUID -eq 0 ]] || { echo "À lancer avec sudo." >&2; exit 1; }

install_restic() {
  if [[ -x /usr/local/bin/restic ]] && /usr/local/bin/restic version | grep -q "restic $RESTIC_VERSION "; then
    echo "restic $RESTIC_VERSION déjà installé"; return
  fi
  local t b url
  t=$(mktemp -d); b="restic_${RESTIC_VERSION}_linux_amd64.bz2"
  url="https://github.com/restic/restic/releases/download/v$RESTIC_VERSION"
  curl -fsSL -o "$t/$b" "$url/$b"
  curl -fsSL -o "$t/SHA256SUMS" "$url/SHA256SUMS"
  (cd "$t" && grep " $b\$" SHA256SUMS | sha256sum -c -)        # refuse un binaire altéré
  bunzip2 -c "$t/$b" > "$t/restic"
  install -m 755 "$t/restic" /usr/local/bin/restic
  rm -rf "$t"
  /usr/local/bin/restic version
}

install_garage() {
  local ip=$1
  mkdir -p "$DIR/meta" "$DIR/data"; chmod 700 "$DIR"
  if [[ ! -f "$DIR/garage.toml" ]]; then
    cat > "$DIR/garage.toml" <<EOF
# Généré par lab-s3.sh : contient des secrets
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "sqlite"
replication_factor = 1
rpc_bind_addr = "127.0.0.1:3901"
rpc_public_addr = "127.0.0.1:3901"
rpc_secret = "$(openssl rand -hex 32)"

[s3_api]
s3_region = "garage"
api_bind_addr = "$ip:3900"
root_domain = ".s3.lab.example"

[admin]
api_bind_addr = "127.0.0.1:3903"
admin_token = "$(openssl rand -base64 32)"
EOF
    chmod 600 "$DIR/garage.toml"
  fi
  if ! docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
    docker pull -q "$GARAGE_IMAGE" >/dev/null
    docker run -d --name "$NAME" --restart unless-stopped --network host \
      -v "$DIR/garage.toml:/etc/garage.toml:ro" -v "$DIR/meta:/var/lib/garage/meta" \
      -v "$DIR/data:/var/lib/garage/data" "$GARAGE_IMAGE" >/dev/null
  fi
  docker start "$NAME" >/dev/null
  local st=""
  for _ in $(seq 30); do st=$("${G[@]}" status 2>/dev/null || true); grep -q "HEALTHY NODES" <<< "$st" && break; sleep 2; done
  grep -q "HEALTHY NODES" <<< "$st" || { echo "ERREUR : Garage ne répond pas (docker logs $NAME)" >&2; exit 1; }
  # Premier démarrage : le nœud n'a pas de rôle, on lui donne une zone et une capacité
  if grep -q "NO ROLE ASSIGNED" <<< "$st"; then
    local node cur
    node=$(awk '/NO ROLE ASSIGNED/{print $1; exit}' <<< "$st")
    cur=$("${G[@]}" layout show 2>/dev/null | grep -oiE 'current cluster layout version: *[0-9]+' | grep -oE '[0-9]+$')
    "${G[@]}" layout assign -z lab -c "$LAB_S3_CAPACITY" "$node" >/dev/null
    "${G[@]}" layout apply --version $(( ${cur:-0} + 1 )) >/dev/null
  fi
  "${G[@]}" status 2>/dev/null | sed -n '/HEALTHY NODES/,$p'
}

case "${1:-}" in
  install)
    [[ -n "${2:-}" ]] || { sed -n '4,7p' "$0"; exit 1; }
    # s3cmd : client S3, pour voir le contenu d'un bucket et le vider avant suppression
    command -v s3cmd >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -yq s3cmd >/dev/null
    install_restic; install_garage "$2" ;;
  status)
    "${G[@]}" status 2>/dev/null | sed -n '/HEALTHY NODES/,$p' ;;
  remove)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    rm -rf "$DIR"
    echo "Stockage objet du lab supprimé (conteneur, données, configuration)." ;;
  *) sed -n '3,15p' "$0"; exit 1 ;;
esac
