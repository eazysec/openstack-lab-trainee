# TP 00. Préparer et découvrir l'instance AWS

| | |
|---|---|
| Prérequis | Une instance (à créer dans la console AWS, ou déjà préparée), la clé `ec2_key` |
| À la fin du TP | Vous savez sur quelle machine OpenStack va tourner et quelles sont ses limites |

## Objectifs

- Vérifier qu'une instance convient au lab.
- Se connecter en SSH à l'instance.
- Comprendre trois contraintes d'AWS qui vont compter pour OpenStack : pas de virtualisation
  matérielle, IP publique « invisible », pare-feu (Security Group) en amont de l'instance.

---

## Étape 0. Vérifier les conditions d'entrée

```bash
# [poste] : dans le dossier qui contient openstack-lab-trainee/ et ec2_key
./openstack-lab-trainee/tps/tp00/verifier-entree.sh <IP_PUBLIQUE>    # sans adresse si l'instance n'existe pas encore
```

Ce script ne modifie rien. Il vérifie que votre poste a un client SSH et l'AWS CLI, que la clé
`ec2_key` et le dépôt sont dans le dossier courant, et, si vous donnez l'adresse de l'instance, que son
port SSH répond. Chaque écart est affiché avec ce qu'il faut faire. Ne commencez pas tant que la
dernière ligne n'est pas `Prêt pour le TP 00.`

## Étape 1. Les caractéristiques de l'instance

Si vous créez vous-même l'instance, utilisez ces paramètres (déjà validés) :

| Paramètre | Valeur |
|---|---|
| Image (AMI) | Ubuntu Server 24.04 LTS |
| Type | `t2.xlarge` (4 vCPU, 16 Go), ou équivalent ≥ 4 vCPU / 16 Go |
| Disque | 60 Go |
| Paire de clés | `ec2_key` |
| Security Group (entrant) | SSH (22) depuis votre IP uniquement. Port 80 (Horizon) **fermé** : on y accède par un tunnel SSH (TP 02). L'ouvrir, même limité à votre IP, ferait circuler le mot de passe admin en clair |

Avant toute chose, vérifier que l'instance ne peut pas générer de frais de crédits CPU (voir
[../../aws/finops.md §2](../../aws/finops.md)). Il faut l'AWS CLI configurée sur votre poste :

```bash
# [poste] : dans le dossier qui contient openstack-lab-trainee/
./openstack-lab-trainee/aws/check-cpu-credits.sh <INSTANCE_ID>
```

Résultat attendu : `OK : conforme, aucun frais de crédits CPU possible.`

## Étape 2. Se connecter

```bash
# [poste]
chmod 600 ec2_key                        # SSH refuse une clé privée lisible par d'autres
ssh -i ec2_key ubuntu@<IP_PUBLIQUE>
```

## Étape 3. Explorer la machine

```bash
# [instance]
lsb_release -d                           # système
nproc; free -h; df -h /                  # CPU, mémoire, disque
ip addr show                             # interfaces réseau et adresses
ip route                                 # route par défaut
ls -l /dev/kvm                           # virtualisation matérielle ?
```

Notez dans votre compte rendu : le nom de l'interface réseau, son adresse IP, la passerelle, et le
résultat de `ls -l /dev/kvm`.

## Questions

1. `ip addr` affiche-t-il l'IP publique avec laquelle vous vous êtes connecté ? Pourquoi ?
2. `/dev/kvm` existe-t-il ? Qu'est-ce que cela implique pour les VM qu'OpenStack va lancer ?
3. Qui filtre les connexions entrantes vers l'instance : l'instance elle-même ou AWS ? Que se passe-t-il
   si le port 22 n'est pas ouvert dans le Security Group ?
4. Pourquoi l'instance doit-elle être en mode de crédits CPU `standard` ?

Pour répondre, lisez [../../aws/aws-setup.md §2](../../aws/aws-setup.md).

## Validation

- [ ] Connexion SSH à l'instance réussie.
- [ ] Les 4 questions ont une réponse argumentée dans le compte rendu.

## Sources

- Instances *burstable* et crédits CPU (AWS) : <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances.html>
- Security Groups AWS : <https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html>
- Tarifs EC2 à la demande : <https://aws.amazon.com/ec2/pricing/on-demand/>
- Contraintes AWS du lab : [../../aws/aws-setup.md](../../aws/aws-setup.md)
- Coûts du lab : [../../aws/finops.md](../../aws/finops.md)
- Toutes les sources du parcours : [sources.md](../sources.md)
