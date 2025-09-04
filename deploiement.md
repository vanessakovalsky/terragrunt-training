# Exercice Terragrunt - Gestion des Modules, DRY et Environnements
**Durée : 90 minutes**

## Objectifs pédagogiques
À l'issue de cet exercice, vous serez capable de :
- Structurer un projet Terragrunt multi-environnements
- Appliquer le principe DRY (Don't Repeat Yourself) avec Terragrunt
- Gérer des modules Terraform réutilisables
- Configurer des environnements avec des paramètres spécifiques
- Utiliser les fonctionnalités avancées de Terragrunt (dependencies, hooks, etc.)

## Prérequis
- Terraform installé (version 1.0+)
- Terragrunt installé (version 0.45+)
- AWS CLI configuré avec des credentials valides
- Connaissances de base en Terraform

## Contexte du projet
Vous devez déployer une infrastructure web simple sur AWS avec :
- Un VPC avec subnets publics et privés
- Un groupe de sécurité
- Des instances EC2
- Un Load Balancer
- 3 environnements : dev, staging, prod

---

## Phase 1 : Préparation de la structure (15 minutes)

## Étapes de préparation

1. Cloner le dépôt et lire le contenu du dossier fichier-base/deploiement
2. Créez les fichiers terragrunt.hcl pour staging en adaptant les configurations de dev.


## Phase 2 : Déploiement et tests (15 minutes)


### Étape 2.1 : Déploiement de l'environnement DEV

```bash
cd environments/dev

# Initialiser l'environnement
terragrunt run-all init
# Cette commande peut générer des erreurs de dépendances, c'est normal elles seront résolus au moment du apply

# Planifier tous les modules
terragrunt run-all plan

# Déployer tous les modules
terragrunt run-all apply --terragrunt-non-interactive

# Vérifier les outputs
terragrunt run-all output
```

### Étape 2.2 : Tests et validation

```bash
# Tester la connectivité aux instances
# Récupérer les IPs des instances depuis les outputs
cd environments/dev/ec2
terragrunt output instance_ips

# Tester l'accès web (remplacez par l'IP réelle)
curl http://INSTANCE_IP
```


## A vous de jouer 

* Mutualiser dans un dossier _envcommon (à créer) les variables de configurations identiques de chaque environnement pour chaque module
* Puis exécuter votre configuration : `terragrunt apply`

* Pour vous qu'est ce qui est plus facile à mettre en place et à maintenir : une version distribuée (sans envcommon) ou une version centralisée (avec envcommon) et pourquoi ?



## Nettoyage

```bash
# Détruire l'infrastructure dev
cd environments/dev
terragrunt run-all destroy --terragrunt-non-interactive

# Supprimer le bucket S3 et la table DynamoDB si nécessaire
aws s3 rb s3://votre-nom-terragrunt-state-${USER} --force
aws dynamodb delete-table --table-name terragrunt-locks --region eu-west-1
```

---

## Ressources supplémentaires

- [Documentation officielle Terragrunt](https://terragrunt.gruntwork.io/)
- [Best practices Terraform](https://www.terraform.io/docs/cloud/guides/recommended-practices/index.html)
- [Patterns de structuration](https://github.com/gruntwork-io/terragrunt-infrastructure-live-example)


## Exercices supplémentaires avancés (bonus)

### Exercice A : Configuration multi-région avec _envcommon
1. Créez `_envcommon/multi-region.hcl` pour gérer le déploiement sur plusieurs régions
2. Adaptez les configurations pour supporter us-east-1 et eu-west-1
3. Gérez la réplication des données entre régions

```hcl
# _envcommon/multi-region.hcl
locals {
  region_configs = {
    "eu-west-1" = {
      azs = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
      cidr_offset = 10  # 10.x.0.0/16
    }
    "us-east-1" = {
      azs = ["us-east-1a", "us-east-1b", "us-east-1c"]
      cidr_offset = 20  # 10.x.0.0/16 où x = 20 + env_offset
    }
  }
}
```

### Exercice B : Intégration CI/CD avec _envcommon
1. Créez `_envcommon/ci-cd.hcl` pour les configurations d'intégration continue
2. Ajoutez des hooks pour la validation automatique
3. Implémentez des checks de sécurité automatisés

### Exercice C : Monitoring et observabilité centralisés
1. Créez `_envcommon/monitoring.hcl` pour CloudWatch, alertes et dashboards
2. Configurez des métriques communes à tous les environnements
3. Implémentez des alertes différenciées par environnement

--

## Avantages de l'approche _envcommon + _common

### Réduction drastique du code
- **Avant** : ~100 lignes par module par environnement = 900 lignes pour 3 env × 3 modules
- **Après** : ~300 lignes dans `_envcommon` + ~50 lignes de surcharge = 350 lignes total
- **Gain** : ~62% de réduction de code

### Maintenance simplifiée
- Modification d'une logique = 1 seul fichier à modifier
- Rollout automatique sur tous les environnements
- Tests centralisés des configurations

### Cohérence garantie
- Standards appliqués automatiquement
- Impossibilité de dériver les configurations
- Validation centralisée

### Flexibilité préservée
- Surcharges possibles par environnement
- Configurations spéciales pour prod/dev
- Extension facile pour nouveaux environnements

