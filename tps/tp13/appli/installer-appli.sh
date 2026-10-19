#!/usr/bin/env bash
# TP 13, étape 10 : mise en service de l'appli et de HAProxy sur la VM web. [VM] tp13-vm-web-haproxy-demo, en root.
# Prérequis : /opt/tp13-appli (code), /etc/tp13/db-password (mot de passe, droits 600), et dans le
# répertoire courant : tp13-appli.service, tp13-haproxy.cfg.
set -euo pipefail
DEBIAN_FRONTEND=noninteractive apt-get install -y python3-flask gunicorn python3-psycopg \
  fonts-atkinson-hyperlegible-web haproxy < /dev/null

# Appli : unité durcie
systemctl stop tp13-appli 2>/dev/null || true          # service transitoire éventuel
install -m 644 tp13-appli.service /etc/systemd/system/tp13-appli.service
systemctl daemon-reload
systemctl enable --now tp13-appli

# HAProxy : sections du TP ajoutées à la fin de la configuration, copie d'origine gardée une fois
C=/etc/haproxy/haproxy.cfg
[ -f $C.tp13-orig ] || cp -p $C $C.tp13-orig
cp -p $C.tp13-orig $C
cat tp13-haproxy.cfg >> $C
haproxy -c -f $C
systemctl restart haproxy
systemctl is-active tp13-appli haproxy
