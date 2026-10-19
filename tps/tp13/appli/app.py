"""TP 13 : application de démonstration (VM web, derrière HAProxy).

Affiche le parcours réel de la requête et l'état de la base PostgreSQL de la VM bdd.
Configuration par l'environnement (unité systemd) :
  TP13_DB_HOST (défaut 192.168.122.12), TP13_DB_NAME (tp13), TP13_DB_USER (tp13app)
Mot de passe : fichier « db-password » du répertoire $CREDENTIALS_DIRECTORY (LoadCredential=).
"""
import os
import socket
from datetime import datetime, timezone

import psycopg
from flask import Flask, abort, redirect, render_template, request, send_from_directory

POLICES = "/usr/share/fonts-atkinson-hyperlegible/woff2"   # paquet fonts-atkinson-hyperlegible-web
CSP = ("default-src 'none'; style-src 'self'; font-src 'self'; img-src 'self'; "
       "form-action 'self'; frame-ancestors 'none'; base-uri 'none'")

LONGUEUR_MAX = 140
SCHEMA = """create table if not exists messages (
  id bigint generated always as identity primary key,
  cree_le timestamptz not null default now(),
  texte varchar(140) not null check (char_length(texte) between 1 and 140))"""

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 4096        # un message fait au plus 140 caractères


def mot_de_passe():
    with open(os.path.join(os.environ["CREDENTIALS_DIRECTORY"], "db-password"), encoding="utf-8") as f:
        return f.read().strip()


def connexion():
    return psycopg.connect(host=os.environ.get("TP13_DB_HOST", "192.168.122.12"),
                           dbname=os.environ.get("TP13_DB_NAME", "tp13"),
                           user=os.environ.get("TP13_DB_USER", "tp13app"),
                           password=mot_de_passe(), connect_timeout=3,
                           options="-c TimeZone=UTC")      # heures des messages en UTC, comme la page


def cause(erreur):
    """Traduit une erreur de connexion en ce que le stagiaire doit savoir."""
    texte = str(erreur)
    if "timeout expired" in texte:
        return "délai de 3 s dépassé (paquets perdus en route : routes ou security groups)"
    if "Connection refused" in texte:
        return "connexion refusée (PostgreSQL arrêté ou n'écoute pas sur cette adresse)"
    if "no pg_hba.conf entry" in texte:
        return "refusée par pg_hba.conf (source, utilisateur ou base non admis)"
    if "password authentication failed" in texte:
        return "mot de passe refusé"
    return "erreur de connexion (voir le journal : journalctl -u tp13-appli)"


def etat_base(nouveau=None):
    """État de la base et dix derniers messages ; enregistre d'abord « nouveau » s'il est donné."""
    try:
        with connexion() as c:
            with c.transaction():
                c.execute("select pg_advisory_xact_lock(1313)")   # création de la table une seule fois
                c.execute(SCHEMA)
            if nouveau is not None:
                c.execute("insert into messages (texte) values (%s)", (nouveau,))   # requête paramétrée
            adresse, port, version = c.execute(
                "select host(inet_server_addr()), inet_server_port(), "
                "current_setting('server_version')").fetchone()
            messages = c.execute("select cree_le, texte from messages "
                                 "order by id desc limit 10").fetchall()
        return {"ok": True, "adresse": f"{adresse}:{port}", "version": version.split()[0],
                "messages": messages}
    except (psycopg.OperationalError, OSError, KeyError) as e:   # connexion impossible
        app.logger.warning("base injoignable : %s", e)
        return {"ok": False, "titre": "base injoignable", "cause": cause(e),
                "cible": f"{os.environ.get('TP13_DB_HOST', '192.168.122.12')}:5432"}
    except psycopg.Error as e:                                # base jointe, requête refusée
        app.logger.warning("requête refusée : %s", e)
        return {"ok": False, "titre": "requête refusée par la base",
                "cause": "voir le journal : journalctl -u tp13-appli",
                "cible": f"{os.environ.get('TP13_DB_HOST', '192.168.122.12')}:5432"}


def adresse_application():
    s = request.environ.get("gunicorn.socket")
    if s is None:
        return request.environ.get("SERVER_NAME", "?") + ":" + request.environ.get("SERVER_PORT", "?")
    hote, port = s.getsockname()[:2]
    return f"{hote}:{port}"


@app.after_request
def entetes(reponse):
    reponse.headers["Content-Security-Policy"] = CSP
    reponse.headers["X-Content-Type-Options"] = "nosniff"
    # same-origin et non no-referrer : avec no-referrer, le navigateur envoie « Origin: null »
    # sur un envoi de formulaire, et la vérification d'origine refuserait tout
    reponse.headers["Referrer-Policy"] = "same-origin"
    if reponse.mimetype == "text/html":
        reponse.headers["Cache-Control"] = "no-store"
    return reponse


@app.get("/static/polices/<path:nom>")
def polices(nom):
    return send_from_directory(POLICES, nom, mimetype="font/woff2")


def afficher(base, statut=200, saisie="", erreur=None):
    relais = request.headers.get("X-Forwarded-For")
    # HAProxy ajoute l'adresse du client en dernier : les valeurs précédentes peuvent être forgées
    client = relais.split(",")[-1].strip() if relais else request.remote_addr
    return render_template(
        "page.html",
        saisie=saisie,
        erreur=erreur,
        enregistre=request.args.get("enregistre") == "1" and statut == 200,
        longueur_max=LONGUEUR_MAX,
        serveur=socket.gethostname(),
        client=client,
        relais=bool(relais),
        haproxy=request.headers.get("X-Tp13-Frontend"),
        application=adresse_application(),
        heure=datetime.now(timezone.utc).strftime("%d/%m/%Y %H:%M:%S UTC"),
        ntp=os.path.exists("/run/systemd/timesync/synchronized"),
        base=base,
    ), statut


@app.get("/")
def page():
    return afficher(etat_base())


@app.post("/messages")
def enregistrer():
    # Envoi forgé depuis un autre site (CSRF) : l'origine doit être ce site, et présente
    if request.headers.get("Origin") != f"{request.scheme}://{request.host}":
        abort(403)
    saisie = request.form.get("message", "")
    texte = saisie.strip()
    if not texte:
        return afficher(etat_base(), 422, saisie, "Non enregistré : message vide.")
    if len(texte) > LONGUEUR_MAX:
        return afficher(etat_base(), 422, saisie,
                        f"Non enregistré : {len(texte)} caractères, {LONGUEUR_MAX} au plus.")
    if any(ord(car) < 32 for car in texte):
        return afficher(etat_base(), 422, saisie, "Non enregistré : caractères de contrôle interdits.")
    base = etat_base(texte)
    if not base["ok"]:
        return afficher(base, 503, saisie)
    return redirect("/?enregistre=1", code=303)    # POST puis GET : un rechargement ne renvoie rien
