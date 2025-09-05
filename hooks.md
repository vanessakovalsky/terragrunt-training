# Exercice Terragrunt - Chaîne de Dépendances avec Hooks

## 🎯 Objectif
Créer une infrastructure complète AWS avec hooks Terragrunt pour gérer les dépendances : VPC → Security Groups → RDS → EC2

## 📋 Prérequis
- AWS CLI configuré
- Terragrunt installé
- Terraform installé
- Accès AWS avec permissions appropriées

## 🏗️ Architecture Cible
```
VPC (10.0.0.0/16)
├── Public Subnet (10.0.1.0/24)
├── Private Subnet (10.0.2.0/24)
├── Internet Gateway
└── NAT Gateway
    │
    ├── Security Groups
    │   ├── Web SG (HTTP/HTTPS)
    │   └── DB SG (MySQL)
    │
    ├── RDS MySQL (Private)
    └── EC2 Web Server (Public)
```


### Structure des dossiers
```
exercice1/
├── terragrunt.hcl                 # Configuration root
├── vpc/
│   └── terragrunt.hcl
├── security-groups/
│   └── terragrunt.hcl
├── database/
│   └── terragrunt.hcl
└── web-servers/
    └── terragrunt.hcl
```

## Préparation

* Récupérer le contenu du dossier fichier-base/hooks (git clone ou git pull si vous aviez déjà cloner avant son ajout)
* Modifier les fichiers de configurations hcl pour mettre votre nom sur les différentes ressources et les retrouver facilement
* Modifier également le nom du bucket dans le script de déploiement
* Etudiez comment sont gérer les dépendances entre chaque modules et quel est le rôle de chaque hook pour les différents modules.

## Tests et Validation 

* Ouvrir un terminal, vérifiez que vous êtes toujours connecté à AWS ou vous reconnecter si nécessaire
* Se mettre dans le dossier hooks
* Exécuter le script :
```bash
chmod u+x deploy.sh
./deploy.sh
```
* Une fois le script exécuté vérifié les éléments suivants dans la console web ou en ligne de commande avec AWS cli

###  Points de validation
- [ ] VPC créé avec subnets publics et privés
- [ ] Security Groups créés avec bonnes règles
- [ ] RDS déployé dans subnet privé
- [ ] EC2 accessible via IP publique
- [ ] Page web affiche les informations d'infrastructure
- [ ] Hooks s'exécutent correctement à chaque étape
- [ ] Dépendances respectées dans l'ordre

## 🎯 Critères de Réussite
1. **Hooks fonctionnels** : Tous les hooks s'exécutent sans erreur
2. **Dépendances respectées** : Modules déployés dans le bon ordre
3. **Infrastructure opérationnelle** : Web server accessible avec page d'accueil
4. **Sécurité** : Database accessible uniquement depuis le VPC
5. **Nettoyage** : Destruction complète possible

## 🚀 Extensions Possibles
- Ajouter un Load Balancer
- Implémenter des hooks de notification (Slack/Teams)
- Utiliser AWS Systems Manager pour les secrets
- Ajouter des hooks de tests automatisés
- Intégrer un pipeline CI/CD

## 📚 Points Clés Appris
- Gestion des dépendances avec Terragrunt
- Utilisation des hooks pour automation
- Validation et tests intégrés
- Gestion des erreurs dans les hooks
- Structure modulaire d'infrastructure