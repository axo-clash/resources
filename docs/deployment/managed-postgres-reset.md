# Nouvelle base PostgreSQL privée et remise à zéro

Cette bascule crée une **base vierge**. Aucun joueur, bot, combat, publication,
tournoi ni historique de l’ancienne base n’est transféré. Le choix retenu est
une instance managée `DB-PLAY2-PICO`, PostgreSQL 17, sans haute disponibilité,
5 Go de Block Storage SBS 5K (`sbs_5k`) chiffré au repos, sauvegarde quotidienne conservée 7 jours.
La disponibilité et les tarifs du catalogue sont à revérifier avant l’apply.

## Réseau et TLS

- Le VPC dédié reste celui de l’application.
- L’API reste sur `10.240.0.0/24` et la base a un réseau séparé `10.240.1.0/24`
  lorsque la plage configurée est `10.240.0.0/16`.
- La base ne possède aucun endpoint public (`load_balancer` absent).
- Les ACL IPv4 et IPv6 autorisent le réseau de l’API avant de refuser les autres
  échanges avec le réseau de la base. Aucun bot, Job ni frontend n’y est rattaché.
  Les ressources qu’un administrateur ajouterait au réseau API auraient aussi
  cet accès réseau : ce réseau doit rester réservé à l’API.
- Le compte JDBC `axo_clash` n’est pas administrateur de l’instance. Ses droits
  sont limités à la base applicative, avec DDL pour Flyway.
- La CA PostgreSQL provient automatiquement du champ `certificate` de l’instance,
  distinct de la CA des endpoints des bots. L’entrypoint de l’image API écrit
  `APPLICATION_DATABASE_CA_PEM` dans un fichier lisible uniquement par son UID.
- JDBC utilise le hostname privé et `sslmode=verify-full` lorsque Scaleway fournit
  un hostname. Sinon, il utilise l’IP privée et `sslmode=verify-ca`, avec le
  certificat de cette instance comme seule ancre de confiance : le certificat
  réel ne contient pas l’IP privée dans ses SANs. Le trafic reste chiffré et le
  certificat est vérifié ; le nom d’hôte n’est pas vérifié dans ce second mode.
  Une adresse privée vide bloque le plan/apply au lieu de cibler localhost.
  Aucun mot de passe n’apparaît dans l’URL JDBC. Les secrets
  restent dans l’environnement secret du conteneur et dans le state protégé.

Les ACL existantes sont relues avant chaque plan et leurs règles dynamiques
par bot sont conservées. **Mettre les publications en pause pendant plan/apply** :
OpenTofu et le backend ne partagent pas le même verrou de mise à jour des ACL.
Ne pas appliquer un ancien plan après une nouvelle publication.

## Initialisation et identité

Les migrations V012/V013 ont été adaptées pour une nouvelle base : elles ne
créent plus les six bots de démonstration ni le joueur système `axopen`.
Le seul joueur initial est Nathan Mittelette (`nathan.mittelette`), rôle
`CREATOR`, lié à l’object ID Entra `f9a8d6f1-d45e-4432-a9b6-65cd7792db55`.
La connexion retrouve ce joueur par `oid` ; le pseudo ou l’adresse seuls ne
permettent pas d’obtenir le rôle créateur.

**Ne pas déployer cette version contre l’ancienne base** : les checksums Flyway
V012/V013 ont changé volontairement pour cette remise à zéro. Ne pas faire de
`flyway repair` pour contourner cette différence. Utiliser la nouvelle base vierge
et l’image API contenant le nouvel entrypoint.

## Bascule à effectuer

1. Construire et pousser l’image API contenant ces changements, puis renseigner
   son digest dans le tfvars local. Aucun push n’a été effectué par cette tâche.
2. Arrêter les combats/publications et empêcher les anciens Jobs de rappeler
   l’API pendant la bascule. Les anciens IDs de publication ne correspondent pas
   aux nouveaux enregistrements.
3. Exécuter `tofu plan -var-file=terraform.tfvars`. Vérifier la création de
   `module.managed_database`, du réseau base et des ACL, la bascule des secrets
   de l’API et la **suppression de l’ancienne base et de ses trois ressources IAM**
   (application, politique et clé). Le même plan réalise toute la bascule.
4. Appliquer ce plan une seule fois. Aucune donnée n’est transférée : l’ancienne
   base et son identité IAM sont supprimées. L’apply ne construit ni ne publie
   l’image API ; son nouveau digest doit avoir été renseigné à l’étape 1.
   L’opération n’est pas une transaction atomique et n’offre pas de retour
   automatique à l’ancienne base en cas d’échec.

5. Vérifier depuis le conteneur API : adresse privée non vide, connexion
   PostgreSQL avec TLS et certificat vérifié (nom d’hôte également si disponible), Flyway à jour, aucune ligne
   dans `bots`, aucun joueur `axopen`, Nathan créateur après authentification.
6. Vérifier que le SQL n’est joignable ni d’Internet ni d’un bot du VPC, en IPv4
   et IPv6. Un apply réussi ou des tests simulés ne prouvent pas ces accès réels.
7. Faire l’inventaire des anciens conteneurs de bots avant toute nouvelle
   publication. Une base vierge ne supprime pas les ressources cloud précédentes
   et redémarre les séquences d’identifiants. Purger les ressources obsolètes
   identifiées avant de réutiliser ces IDs.

## Reprise après changement d’identifiant de l’instance

Si l’instance PostgreSQL 17 existe déjà, mais que l’apply échoue avec
`Database already exists` et `User already exists`, comparer les IDs de l’état
aux ressources Scaleway avant toute suppression. Une base et un utilisateur
peuvent avoir été conservés sur la nouvelle instance alors que leurs anciennes
entrées ont disparu de l’état après rafraîchissement.

Pour le déploiement vérifié le 16 octobre 2026, le fichier local ignoré
`infrastructure/recovery-imports.local.tf` réimporte la base `axo-clash`,
l’utilisateur `axo_clash` et son privilège sur l’instance PostgreSQL 17 existante.
Il ne doit pas être copié vers un autre environnement. Le plan de récupération
vérifié prévoit **3 imports, 0 création et 0 destruction**, plus la mise à jour du
mot de passe applicatif et du conteneur API.

Depuis `application-backend/infrastructure`, avec les identifiants habituels :

```sh
tofu plan --var-file terraform.tfvars
tofu apply --var-file terraform.tfvars
```

Après un apply réussi, supprimer `recovery-imports.local.tf` : les trois ressources
sont désormais suivies dans l’état. Ce fichier n’est utile qu’à cette reprise.
Le message tronqué du conteneur en erreur ne suffit pas à identifier sa cause
PostgreSQL : vérifier les logs complets après redéploiement. L’API doit utiliser
l’image contenant l’entrypoint qui écrit le certificat PostgreSQL.

## Sources Scaleway

- [Endpoints RDB privés](https://registry.terraform.io/providers/scaleway/scaleway/latest/docs/resources/rdb_instance)
- [Vérification TLS PostgreSQL](https://www.scaleway.com/en/docs/managed-databases-for-postgresql-and-mysql/api-cli/verify-ca-postgresql/)
- [Tarifs PostgreSQL managé](https://www.scaleway.com/en/pricing/managed-databases/)

Ce guide et le code préparent la bascule ; aucune instance n’a été créée et aucun
apply n’a été exécuté. La connexion réelle au nouveau service reste à vérifier.
