# 🛠️ TP : Création d'une structure multi-environnements

## Objectif

Créer une structure Terragrunt complète avec 3 environnements (dev, staging, prod) et un module VPC.

## Pré-requis

* Avoir terragrunt et terraform ou opentofu installé : https://terragrunt.gruntwork.io/docs/getting-started/install/
* Avoir aws Cli installé : https://aws.amazon.com/fr/cli/

## Étapes de préparation

1. Cloner le dépôt et lire le contenu du dossier fichier-base/configuration
2. Valider votre compte AWS reçu par mail et définir un mot de passe
3. Vous connecter avec ce compte et récupérer via le bouton Clé d'accès les informations de connexion 
4. Configurer la connexion à AWS CLI :
   * Executer la commande : `aws configure`
   * Entrer les informations fournis par votre formatrice


## Execution des commandes terragrunt
```bash
# Navigation vers l'environnement dev
cd environments/dev/vpc

# Plan Terraform
terragrunt plan

# Application (si bucket S3 configuré)
terragrunt apply
```

## Vérification

* A l'aide de la console AWS ou de AWS cli, vérifier si le VPC est bien créé.
* Vérifier si les tags ont bien été mis sur ce VPC

## A vous de jouer

* Ajouter un deuxième module pour créer un bucket s3 sur AWS
* Vous devez préparer le module avec ces fichiers terrafom
* Et configurer l'appel du module a l'aide d'un fichier hcl pour l'environnement de developpement.
