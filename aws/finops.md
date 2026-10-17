# FinOps : coûts AWS du lab OpenStack

> Public : responsable du compte AWS, formateurs, stagiaires qui lancent le lab.
> Prix : ordres de grandeur pour us-east-1, à vérifier sur <https://aws.amazon.com/ec2/pricing/>
> avant toute décision.

**Règle du lab : aucune ressource payante n'est créée dans AWS sans l'accord explicite du responsable
du compte.** Les scripts qui touchent à AWS (`aws-public-fip.sh`) sont en mode simulation par défaut
et affichent le coût avant d'agir.

---

## 1. Coût par scénario

| Ressource | Scénarios | Coût indicatif | Facturé quand ? |
|---|---|---|---|
| Instance `t2.xlarge` | tous | ~0,19 USD/h (~135 USD/mois en continu) | Instance démarrée |
| IPv4 publique auto-attribuée | tous | ~0,005 USD/h (~3,6 USD/mois) | Instance démarrée |
| Volume EBS racine 58 Go | tous | ~5 à 6 USD/mois | Toujours, même instance arrêtée |
| Cinder sur fichier loop | 02, 04 | 0 (pris sur le disque racine) | jamais |
| Barbican, Designate | 04 | 0 (services sur l'instance ; ~1 à 2 Go de RAM en plus) | jamais |
| Volume EBS dédié à Cinder (option) | 02 | ~0,08 USD/Go-mois (gp3) | Toujours, jusqu'à suppression |
| IP privée secondaire | 03 | 0 | jamais |
| Elastic IP | 03 | ~0,005 USD/h chacune | Toujours, jusqu'à libération (même non associée) |
| Stockage objet du lab (Garage, sur l'instance) | 04 (TP 10) | 0 (pris sur le disque racine) | jamais |
| Bucket AWS S3 hors site (option du TP 10) | aucun (option) | ~0,023 USD/Go-mois + requêtes (quelques centimes pour un TP) ; versions et *Object Lock* multiplient le volume facturé | Toujours, jusqu'à suppression du bucket |
| Instance `*.metal` (KVM natif) | alternative | ~4 à 5 USD/h (~3 000 USD/mois en continu) | Instance démarrée |

Ordre de grandeur pour une session de TP de 8 h sur la `t2.xlarge` : ~1,6 USD, plus le disque.

---

## 2. Crédits CPU des instances *burstable* (t2, t3, t4g)

Les instances `t*` accumulent des « crédits CPU » quand elles sont peu sollicitées et les dépensent
quand elles travaillent. L'émulation QEMU (pas de KVM sur une instance non *metal*) fait travailler
le CPU en continu dès qu'une VM OpenStack tourne : elle épuise les crédits.

| Mode | Défaut pour | Crédits épuisés → | Risque financier |
|---|---|---|---|
| **standard** | `t2` (notre cas) | CPU bridé (~40 % par vCPU sur une `t2.xlarge`) : tout devient lent | Aucun |
| **unlimited** | `t3`, `t3a`, `t4g` | Pas de bridage, mais surcoût à l'heure de vCPU au-delà du quota | Facture qui grimpe sans alerte visible : **interdit dans le lab** |

**Règle du lab : aucun frais de crédits CPU supplémentaire ne doit jamais être facturé.** Toute instance
*burstable* du lab doit donc être en mode standard : on accepte la lenteur, jamais le surcoût.

Contrôle obligatoire, avant le déploiement puis à chaque nouvelle instance :
```bash
./aws/check-cpu-credits.sh <INSTANCE_ID>            # lecture seule ; code retour 2 si non conforme
./aws/check-cpu-credits.sh <INSTANCE_ID> --apply    # passe en standard (gratuit, sans redémarrage)
```
Le script signale aussi le mode par défaut du compte pour la famille de l'instance : une nouvelle `t3`
démarre en `unlimited` sauf si ce défaut a été changé.

Constaté sur l'instance de référence (`t2.xlarge`, octobre 2026) : mode standard, défaut du compte
pour `t2` : standard. Conforme.

Pour aller plus loin :
- suivre la métrique CloudWatch `CPUCreditBalance` (crédits restants) ;
- pour un usage intensif, une instance non *burstable* (`m5.xlarge`, `m6i.xlarge`) n'a pas de crédits du tout :
  ni bridage ni surcoût, pour un prix horaire proche.

---

## 3. Bonnes pratiques

| Pratique | Économie |
|---|---|
| **Arrêter l'instance** en fin de séance (`Stop`, pas `Terminate`) | On ne paie plus que le disque. Le déploiement OpenStack redémarre tout seul au prochain démarrage |
| Libérer les Elastic IP inutilisées (`aws-public-fip.sh delete`, puis `list` pour vérifier) | ~3,6 USD/mois chacune |
| Supprimer les volumes EBS détachés | Facturés tant qu'ils existent |
| Ne jamais laisser une instance `*.metal` allumée hors TP | ~100 USD/jour |
| Poser une alerte AWS Budgets sur le compte | Prévient avant la mauvaise surprise |
| Étiqueter les ressources (le script pose le tag `openstack-lab=true` sur les Elastic IP) | Retrouver et nettoyer facilement |

Attention : l'IP publique auto-attribuée change à chaque arrêt/démarrage. Une IP fixe passe par une
Elastic IP (payante en continu) : à arbitrer selon le besoin.

---

## 4. Vérifier qu'il ne reste rien de facturé après le lab

```bash
aws ec2 describe-instances --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType]' --output table
aws ec2 describe-addresses --query 'Addresses[].[PublicIp,AllocationId,AssociationId]' --output table
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].[VolumeId,Size]' --output table
```
