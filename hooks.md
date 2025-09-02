# Exercice autours des hooks

## Exercice 1 : Chaîne de Dépendances

### Objectif
Créer une infrastructure complète avec dépendances : VPC → Security Groups → RDS → EC2




### Structure attendue
```
exercice1/
├── vpc/
├── security-groups/
├── database/
└── web-servers/
```



### Instructions
1. Configurer le VPC avec subnets publics et privés
2. Créer les security groups avec dépendance VPC
3. Déployer RDS avec dépendance security groups
4. Déployer EC2 avec toutes les dépendances




### Code de démarrage

```hcl
# vpc/terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-vpc.git?ref=v3.0.0"
}

inputs = {
  # À compléter...
}
```




## Exercice 2 : Hooks Avancés

### Objectif
Implémenter un système de hooks complet avec validation, sécurité et notifications

### Tasks
1. Hook de validation pré-déploiement
2. Hook de sécurité avec tfsec
3. Hook de notification post-déploiement
4. Hook de backup automatique

### Template

```hcl
# À compléter dans web-servers/terragrunt.hcl
terraform {
  before_hook "validation" {
    # Implémenter validation complète
  }
  
  before_hook "security" {
    # Implémenter check sécurité
  }
  
  after_hook "notification" {
    # Implémenter notification
  }
}
```
