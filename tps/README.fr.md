[English](README.md) · **Français**

# Parcours de TP : OpenStack sur AWS

> Public : stagiaires et alternants. Aucune connaissance d'OpenStack n'est supposée ; il faut savoir
> se servir d'un terminal Linux et de SSH.
>
> Chaque TP indique ses objectifs, ses prérequis, les étapes guidées, des questions de compréhension
> et des critères de validation. Les sources et références
> sont dans [sources.md](sources.md).

---

## 1. Progression

Les TP suivent l'avancement du projet : on découvre l'infrastructure, on déploie, on utilise, puis on
exploite et on étend la plateforme.

| TP | Titre | Phase du projet | Scénario | État |
|---|---|---|---|---|
| [00](tp00/tp00-preparer-instance.md) | Préparer et découvrir l'instance AWS | Avant le déploiement | aucun | Prêt |
| [01](tp01/tp01-deployer.md) | Déployer OpenStack et vérifier le déploiement | Déploiement | 01 | Prêt |
| [02](tp02/tp02-instances-ssh.md) | Lancer des instances depuis l'hôte et s'y connecter en SSH | Utilisation | 01 | Prêt |
| [03](tp03/tp03-reseau-neutron.md) | Comprendre le réseau Neutron | Utilisation | 01 | Prêt |
| [04](tp04/tp04-volumes-cinder.md) | Stockage persistant : volumes, montage, snapshots | Utilisation | 02 | Prêt |
| [04 bis](tp04-bis/tp04-bis-revenir-en-arriere.md) | Revenir en arrière : snapshots, revert, re-image | Utilisation | 02 | Prêt |
| [05](tp05/tp05-exploitation.md) | Exploiter la plateforme : logs, pannes, reconfiguration | Exploitation | 01 ou 02 | Prêt |
| [05 bis](tp05-bis/tp05-bis-qui-a-fait-quoi.md) | Qui a fait quoi ? Tracer les appels aux API (après le TP 06 bis) | Exploitation | 01 ou 02 | Prêt |
| [06](tp06/tp06-projets-quotas.md) | Projets, utilisateurs, rôles et quotas | Exploitation | 01 ou 02 | Prêt |
| [06 bis](tp06-bis/tp06-bis-identites-automates.md) | Identités pour les automates : jetons, identifiants d'application, règles d'accès | Exploitation | 01 ou 02 | Prêt |
| [07](tp07/tp07-reseau-aws.md) | Floating IP publiques et réseau AWS | Extension | 03 | Prêt (sans coût) |
| [08](tp08/tp08-secrets-barbican.md) | Gérer des secrets avec Barbican | Extension | 04 | Prêt |
| [08 bis](tp08-bis/tp08-bis-faire-vivre-secrets.md) | Faire vivre un secret : renouveler, partager, regrouper | Extension | 04 | Prêt |
| [09](tp09/tp09-volumes-chiffres.md) | Chiffrer les volumes Cinder | Extension | 04 | Prêt |
| [10](tp10/tp10-sauvegardes-restic.md) | Sauvegarder une VM : dépôt local, stockage objet, copie hors de l'hôte | Extension | 04 | Prêt (sans coût) |
| [11](tp11/tp11-dns-designate.md) | DNS as a Service avec Designate | Extension | 04 | Prêt |
| [12](tp12/tp12-cloud-init.md) | Configurer les VM au démarrage avec cloud-init | Extension | 02 ou 04 | Prêt |
| [12 bis](tp12-bis/tp12-bis-depanner-vm.md) | Dépanner une VM : reprendre la main par le mode rescue, reprendre une personnalisation cloud-init en échec | Extension | 02 ou 04 | Prêt |
| [13](tp13/tp13-deploiement.md) | TP final : déployer une architecture sécurisée sur OpenStack ([architecture](tp13/tp13-architecture.md)) | Synthèse | 04 | Prêt (étape 15 optionnelle et payante) |
| [13 bis](tp13-bis/tp13-bis-administrer-base.md) | Administrer la base sans ouvrir de port : rôle dédié, droits au plus juste, tunnel, traces | Synthèse (après l'étape 14 du TP 13) | 04 | Prêt |
| [14](tp14/tp14-heat.md) | TP bonus : redéployer la même architecture avec Heat, l'infrastructure décrite en code | Bonus | 04, Heat ajouté par le TP | Prêt |
| [15](tp15/tp15-octavia.md) | TP bonus : répartir la charge avec Octavia, HTTPS avec un certificat rangé dans Barbican, bascule, accès au plus juste | Bonus | 04, Octavia ajouté par le TP | Prêt |

Non testés sur le lab, et signalés comme tels dans les énoncés : la partie AWS du scénario 03 et le
niveau 3 « cloud » du TP 10 (payants).

### TP 13 puis TP 14 (bonus) : la même architecture, deux méthodes

Le TP 13, TP final du parcours, construit l'architecture ressource par ressource, en ligne de commande. Le TP 14, en
bonus, la reconstruit avec Heat, à partir d'un modèle qui la décrit. Les deux constructions passent les mêmes
contrôles : c'est ce qui permet de les comparer.

| | TP 13 : commande par commande | TP 14 : modèle Heat |
|---|---|---|
| Ce qu'on écrit | Une commande par ressource, dans le bon ordre | Un fichier qui décrit l'état voulu ; Heat déduit l'ordre des dépendances |
| Construire, détruire | Toutes les étapes ; nettoyage en ordre inverse, étape par étape | Une commande : `openstack stack create`, `openstack stack delete` |
| Modifier | Une commande ciblée ; rien ne garde l'état voulu | `openstack stack update` : Heat ne change que ce qui diffère (constaté : une règle modifiée sur place, la VM conservée) |
| Reproduire à l'identique | Rejouer toutes les commandes sans erreur | Rejouer le même modèle ; le fichier se range dans git |
| Ce qu'on apprend | Le rôle de chaque brique, le diagnostic couche par couche | Décrire, paramétrer, versionner une infrastructure |
| Ce qui reste à faire à la main | Tout | La route, le pare-feu, le proxy et l'heure de l'hôte ; le secret de la base, qu'un modèle ne doit jamais contenir |
| Limites constatées | Oublis et erreurs de saisie ; durée | Heat ne pose pas d'étiquette sur les security groups ni sur la FIP, ni la description de la FIP ; un groupe sans aucune sortie demande une règle de plus ; le service consomme environ 1 Go de mémoire (mesuré) |

Ressources créées par Heat : leur nom commence par `ht-` (par exemple `ht-tp13-vm-web-haproxy-demo`),
pour les distinguer au premier coup d'œil de celles créées à la main.

---

## 2. Conventions

**Conditions d'entrée.** Un TP part de l'état laissé par le précédent. Chaque TP fournit le script
`tps/tpNN/verifier-entree.sh`, que son étape 0 lance : il vérifie, sans
rien modifier, que le lab est prêt, et indique pour chaque écart ce qu'il faut faire. Ne commencez
pas tant que sa dernière ligne n'est pas `Lab prêt pour le TP NN.`

Chaque bloc de commandes indique où l'exécuter :

| Marqueur | Où | Comment y aller |
|---|---|---|
| `# [poste]` | Votre ordinateur | vous y êtes |
| `# [instance]` | L'instance EC2 (l'hôte OpenStack) | `ssh -i ec2_key ubuntu@<IP_PUBLIQUE>` |
| `# [VM]` | Une VM OpenStack (CirrOS ; Debian aux TP 12 et 13) | `ssh cirros@<FLOATING_IP>` depuis l'instance (au TP 12 : `ssh -i ~/.ssh/tp12-key stack@<FLOATING_IP>` ; au TP 13 : `ssh -F ~/.ssh/tp13_config <VM>` depuis le poste, par le bastion) |

```
Votre poste
   │  ssh -i ec2_key ubuntu@<IP_PUBLIQUE>
   ▼
┌─────────────────────────────────────────────────────────┐
│ L'« instance » : une machine virtuelle louée chez AWS   │
│ (t2.xlarge). OpenStack est installé dessus.             │
│                                                         │
│   ┌──────────────┐  ┌──────────────┐                    │
│   │ VM tp02-vm-1 │  │ VM tp02-vm-2 │  ← les « VM » :    │
│   │ (CirrOS)     │  │ (CirrOS)     │    créées PAR      │
│   └──────────────┘  └──────────────┘    OpenStack       │
└─────────────────────────────────────────────────────────┘
```

AWS comme OpenStack appellent « instance » leurs machines virtuelles. Dans ce parcours, *instance*
désigne toujours la machine AWS, et *VM* les machines créées par OpenStack.

- Les valeurs entre chevrons sont à remplacer : `<IP_PUBLIQUE>` (IP publique de l'instance, visible
  dans la console AWS), `<FLOATING_IP>`, `<INSTANCE_ID>`…
- Avant toute commande `openstack`, dans chaque nouvelle session SSH sur l'instance :
  ```bash
  # [instance]
  source ~/kolla/venv/bin/activate
  source /etc/kolla/admin-openrc.sh
  ```
  Sans cela : `Command 'openstack' not found`. N'installez pas le client proposé par Ubuntu
  (`snap`/`apt`) : sa version est trop ancienne.
- Les ressources créées dans un TP portent son préfixe (`tp02-…`, `tp03-…`) : on sait ce qu'on peut
  supprimer sans toucher au reste. Chaque TP se termine par un nettoyage.
- Les floating IP sont réutilisées : une nouvelle VM peut recevoir l'adresse d'une VM supprimée.
  SSH refuse alors la connexion (`WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`), car l'empreinte
  de la VM a changé. C'est normal dans le lab : oubliez l'ancienne empreinte avec
  `ssh-keygen -R <FLOATING_IP>`, puis reconnectez-vous.
- CirrOS, l'image des VM de test, est une distribution minimale : ses commandes sont celles de BusyBox
  (par exemple `ip addr` fonctionne, `ip -br addr` non).

---

## 3. Règles du lab

1. **Aucune ressource AWS payante sans l'accord du tuteur** (Elastic IP, volume EBS, instance
   supplémentaire…). Voir [../aws/finops.md](../aws/finops.md).
2. **Ne jamais modifier le réseau de l'interface `enX0`** de l'instance (adresses, netplan, networkd) :
   c'est par elle qu'on administre l'instance, et une erreur la rend injoignable
   (voir [../aws/aws-setup.md §6](../aws/aws-setup.md)).
3. **Arrêter l'instance en fin de journée** (console AWS, *Arrêter*, jamais *Résilier*). OpenStack redémarre
   tout seul ; l'IP publique change.
4. Pas de secret (clé SSH, mot de passe, clé AWS) dans un chat, un mail ou un dépôt Git.

---

## 4. Grille de suivi

À cocher par le stagiaire, à valider par le tuteur.

| TP | Je sais… | Stagiaire | Tuteur |
|---|---|---|---|
| 00 | expliquer pourquoi les VM OpenStack tournent en émulation sur cette instance |  |  |
| 00 | distinguer IP publique, IP privée et Security Group AWS |  |  |
| 01 | déployer OpenStack, lire le log et interpréter `verify.sh` |  |  |
| 01 | citer le rôle de Keystone, Nova, Neutron, Glance, Placement, Horizon |  |  |
| 02 | lancer une VM, lui donner une floating IP et m'y connecter en SSH |  |  |
| 02 | expliquer ce qu'est une keypair et où se trouve la clé privée |  |  |
| 02 | accéder à une VM depuis mon poste par plusieurs méthodes, et choisir la plus sûre |  |  |
| 03 | créer réseau, sous-réseau, routeur et security group |  |  |
| 03 | suivre le chemin d'un paquet de la VM jusqu'à Internet |  |  |
| 04 | créer, attacher, formater, monter et détacher un volume |  |  |
| 04 | expliquer la différence entre disque éphémère et volume |  |  |
| 04 bis | remettre un volume dans un état antérieur et reconstruire une VM sur volume sans perdre ses données |  |  |
| 05 | trouver le log d'un service et diagnostiquer une panne simple |  |  |
| 05 | modifier une option de configuration de façon durable |  |  |
| 05 bis | retrouver qui a fait une action et suivre une requête dans les journaux, et dire ce qu'ils ne prouvent pas |  |  |
| 06 | créer un projet et un utilisateur, lui donner un rôle et des quotas |  |  |
| 06 bis | dire ce que vaut un jeton révoqué, et donner à un automate un identifiant limité par rôle, règles d'accès et expiration |  |  |
| 07 | expliquer pourquoi une floating IP n'est pas joignable depuis Internet sur AWS |  |  |
| 08 | stocker, générer et protéger un secret ; expliquer les rôles Barbican |  |  |
| 08 bis | renouveler un secret, le partager par une ACL, regrouper les secrets d'une application ; dire contre qui un secret privé protège |  |  |
| 09 | chiffrer un volume et dire contre quoi ce chiffrement protège |  |  |
| 09 | protéger la clé d'un volume chiffré contre sa suppression |  |  |
| 10 | sauvegarder et restaurer une VM, et expliquer la règle 3-2-1 et le séquestre du mot de passe |  |  |
| 11 | publier des noms DNS, à la main et automatiquement par Neutron |  |  |
| 11 | limiter un automate aux seuls enregistrements d'une zone DNS |  |  |
| 12 | décrire la configuration d'une VM dans un user-data cloud-init, la valider et la vérifier |  |  |
| 12 | dire pourquoi un secret ne va jamais dans un user-data, et appliquer l'immutabilité |  |  |
| 12 bis | réparer le disque d'une VM par le mode rescue, et reconnaître un rescue qui démarre sur le mauvais disque |  |  |
| 12 bis | dire ce que la console d'une VM permet et expose, et pourquoi la méthode « GRUB, `init=/bin/bash` » ne s'applique pas à une image de cloud |  |  |
| 12 bis | trouver pourquoi une personnalisation cloud-init a échoué, la reprendre sans recréer la VM, et dire ce que la reprise change |  |  |
| 13 | segmenter un réseau et écrire des security groups au plus juste, en entrée et en sortie |  |  |
| 13 | administrer des VM par un bastion, et contrôler leurs sorties par un proxy |  |  |
| 13 | diagnostiquer un routage asymétrique avec `tcpdump`, et prouver chaque refus par un test |  |  |
| 13 bis | administrer une base par un tunnel SSH sans port ouvert, sous un rôle dédié, et relire la trace de chaque action |  |  |
| 14 | ajouter un service à un cloud en fonctionnement, puis le retirer proprement |  |  |
| 14 | décrire une infrastructure dans un modèle Heat, la créer, la modifier et la détruire |  |  |
| 14 | comparer une construction à la main et une construction par modèle, et dire ce qui reste hors du modèle |  |  |
| 15 | placer des serveurs derrière un répartiteur et observer la bascule quand l'un tombe |  |  |
| 15 | terminer le HTTPS avec un certificat rangé dans Barbican, le renouveler et retirer les accès qui ne servent plus |  |  |
| 15 | limiter les clients d'un service publié, et dire ce que le projet voit de l'infrastructure de l'exploitant |  |  |
