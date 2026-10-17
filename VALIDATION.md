# Validation de la version 2026.10.0

Validée le 17/10/2026, sur un lab reconstruit de zéro avec cette version du dépôt.

## Environnement

| Élément | Valeur |
|---|---|
| Instance | AWS EC2 `t2.xlarge` (4 vCPU, 16 Go), Ubuntu 24.04, une seule interface réseau, sans KVM |
| OpenStack | 2025.1 (Epoxy), Kolla-Ansible 20.6, images `2025.1-ubuntu-noble` |
| Scénario | 04 (Cinder, Barbican, Designate, stockage objet du lab) |

## Résultats

| Contrôle | Résultat |
|---|---|
| Purge complète de l'hôte, puis déploiement neuf (`deploy.sh`, scénario 04) | Réussi en 19 min |
| `verify.sh` | 42 réussis, 0 échec |
| Commandes des TP 02 à 06 et 08 à 11, rejouées avec contrôle des résultats et messages annoncés | 208 réussis, 0 échec |
| TP 02 depuis un poste : méthodes d'accès aux VM et Horizon par tunnel | 12 réussis, 0 échec |
| TP 10 depuis un poste : copie hors de l'hôte et restauration | 7 réussis, 0 échec |
| TP 07 : publication de floating IP côté hôte, sans ressource AWS | 28 réussis, 0 échec |

Résultats précédents, sur les versions de travail : chaîne cumulative 01, puis 02, puis 04 sur un hôte
neuf (les trois scénarios déployés et vérifiés), redémarrage de l'hôte avec reprise automatique des VM
et des volumes, relance de `deploy.sh` sans changement des mots de passe.

## Non testé

| Élément | Raison |
|---|---|
| `sshuttle`, redirection de port sur l'instance (TP 02, méthodes G et H) | Droits root sur le poste ; ouverture d'un port dans le Security Group |
| Partie AWS du scénario 03 (Elastic IP), niveau 3 « cloud » du TP 10 (bucket S3) | Ressources payantes |
| Volume EBS dédié à Cinder (`CINDER_DEVICE`) | Ressource payante |
| Autres hébergeurs (OVHcloud…) | Prévu pour une version ultérieure |
