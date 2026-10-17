# Logiciels tiers

Ce dépôt ne contient le code d'aucun logiciel tiers : les scripts les téléchargent depuis leurs sources
officielles au moment du déploiement. Chacun reste soumis à sa propre licence.

| Logiciel | Usage dans le lab | Licence | Source |
|---|---|---|---|
| OpenStack, Kolla-Ansible | Plateforme déployée, outil de déploiement | Apache 2.0 | <https://opendev.org/openstack/kolla-ansible> |
| restic | Sauvegardes (TP 10), binaire officiel, empreinte vérifiée | BSD 2-Clause | <https://github.com/restic/restic> |
| Garage | Stockage objet S3 du lab (TP 10), image Docker officielle non modifiée | AGPL 3.0 | <https://git.deuxfleurs.fr/Deuxfleurs/garage> |
| s3cmd | Client S3 (TP 10), paquet Ubuntu | GPL 2.0 | <https://github.com/s3tools/s3cmd> |
| CirrOS | Image de VM de test, téléchargée par Kolla-Ansible | voir le projet | <https://github.com/cirros-dev/cirros> |

Garage est utilisé tel quel, sans modification, comme service interne au lab. Si vous le modifiez et
l'exposez à des utilisateurs à travers un réseau, la licence AGPL vous oblige à leur fournir le code
source modifié.
