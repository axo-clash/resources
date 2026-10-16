# Publication et exploitation des bots sur Scaleway

Date : 11 octobre 2026. Spécification cible, sans provisionnement cloud effectué.

## Répartition des responsabilités

L'auteur soumet une référence d'image. La plateforme résout cette référence en digest, copie l'image dans son registry, déploie un container privé et valide son contrat automatiquement avant activation.

Le registry source est contacté avec `crane` ou `skopeo`, sans daemon Docker, sans socket Docker et sans exécuter l'image pendant la copie. Le worker borne sa mémoire, ses transferts et sa concurrence. Les blobs peuvent être transférés entre registries sans conserver toute l'image sur disque. [crane](https://github.com/google/go-containerregistry), [skopeo](https://github.com/podman-container-tools/skopeo/blob/main/docs/skopeo-copy.1.md)

L'API Scaleway est utilisée par un composant de provisionnement côté serveur. Le frontend et les CLI n'ont aucun credential Scaleway. Les namespaces registry et containers sont créés une fois par environnement ; ne pas créer un namespace et une application IAM par bot par défaut.

## Données à conserver

| Entité | Informations |
| --- | --- |
| Bot | Identité métier stable, propriétaire, révision active, disponibilité |
| Révision | Identifiant interne, référence source, digest source de la plateforme choisie, digest destination, architecture, état, erreurs, dates |
| Ressource cloud | Projet, région, namespace, nom technique, ID Scaleway, endpoint retourné, configuration observée |
| Soumission | Propriétaire, clé d'idempotence, état du traitement, tentatives et erreurs |

Un nom technique tel que `bot-<identifiant-interne>` ne dépend pas du nom choisi par l'auteur. Le nom d'affichage reste modifiable. Conserver les IDs retournés ; ne pas recalculer l'endpoint à partir du nom.

Une révision est un contenu figé. Le tag `latest` est accepté comme entrée mais résolu une fois ; tous les contrôles et la copie portent ensuite sur ce digest. Conserver les digests source et destination séparément, notamment si un outil transforme le manifeste.

## Pipeline de publication

1. Authentifier le joueur avec l'identité existante de l'application et vérifier ses droits sur le bot. Appliquer les limites de soumission et une clé d'idempotence.
2. Persister la soumission ; retourner son ID sans attendre le déploiement cloud. Un worker revendique le travail avec un bail récupérable après crash.
3. Résoudre la référence autorisée ; sélectionner `linux/amd64` pour les images multiarchitectures. Épingler le manifeste sélectionné par digest.
4. Inspecter le manifeste/config : plateforme, nombre de couches, somme des tailles compressées, port et contrat attendus. Limiter aussi les octets réellement reçus, les redirections et les délais.
5. Copier la référence figée dans un repository privé de la plateforme avec un tag de révision unique. Interdire sa réécriture par le pipeline ; vérifier le digest destination.
6. Réserver le bot pour publication. Créer son container à la première publication ; pour une mise à jour, attendre qu'aucun combat ne l'utilise, puis redéployer cette même ressource. En V1 le bot est indisponible pendant cette validation.
7. Attendre l'état prêt avec un délai global borné. Appeler `/info`, vérifier la concordance des métadonnées et exécuter la suite du contrat `/play`, sous 512 Mo et 0,5 vCPU.
8. Activer la révision si tous les contrôles passent ; sinon conserver l'échec et remettre la précédente révision en service lorsqu'elle existe. Ne pas utiliser une nouvelle révision pour des combats avant sa validation.

États proposés : `SUBMITTED → INSPECTING → COPYING → DEPLOYING → VALIDATING → READY`, avec sorties `REJECTED` pour un contrôle échoué et `FAILED` pour un incident technique. Retenter les incidents transitoires avec délai croissant ; ne pas boucler sur une image rejetée.

La taille compressée est vérifiable depuis le manifeste. La taille décompressée exige des contrôles supplémentaires bornés ; une petite image compressée peut produire un volume décompressé excessif. Ne pas exécuter l'image sur le worker privilégié pour l'inspecter. Les seuils restent à fixer.

Les noms de registry, redirections et URL éventuelles de blobs sont des entrées non fiables. Le composant d'import doit empêcher les accès à loopback, aux réseaux internes et aux endpoints de métadonnées ; appliquer cette règle aux résolutions DNS et aux redirections, pas seulement au nom initial. Aucune commande shell ne doit être construite à partir de texte utilisateur.

## Configuration du container

| Paramètre logique | Valeur cible |
| --- | --- |
| Autoscaling | `min=0`, `max=1` |
| RAM du bot | 512 Mo, conversion exacte à vérifier dans le schéma choisi |
| CPU du bot | 500 mvCPU, soit 0,5 vCPU |
| Accès | Privé, authentification IAM du fournisseur |
| Image | Référence interne figée par digest, à valider sur l'API déployée |
| Sandbox | V2 |
| Réseau base/API | Aucun attachement des bots au réseau de la base |
| Port/base HTTP | Proposition : 9000, `/api/v1/bots` |
| Secrets applicatifs | Aucun dans le bot |

Créer puis déployer la ressource sont des opérations distinctes dans les exemples Scaleway. Les schémas publiés évoluent : l'ancien exemple emploie `memory_limit`, `cpu_limit`, `registry_image`, alors que la référence CLI récente expose des paramètres en bytes, `mvcpu-limit` et `image`. L'adaptateur doit utiliser un schéma/API épinglé et tester la conversion des unités. Ne pas copier un payload ancien sans validation. [Exemple API de déploiement](https://www.scaleway.com/en/docs/serverless-containers/api-cli/deploy-container-api/), [Référence CLI actuelle](https://www.scaleway.com/en/developers/cli/container)

Si le déploiement par digest n'est pas accepté dans la version utilisée, employer un tag unique non réécrit, vérifier son digest juste avant déploiement et enregistrer la révision réellement déployée. Tester ce comportement avant de le considérer comme acquis.

## Authentification et secrets

Scaleway utilise désormais IAM pour les containers privés ; les anciens JWT d'invocation sont dépréciés. L'appel privé utilise `X-Auth-Token`. [Authentification Scaleway](https://www.scaleway.com/en/docs/serverless-containers/how-to/create-auth-token-from-console/)

Séparer trois fonctions : importer/pousser les images, gérer les containers, invoquer les bots. Utiliser des identités de service avec les permissions minimales et un périmètre limité aux ressources de bots. La création de chaque bot le rend privé et lui applique ce périmètre ; elle ne nécessite pas intrinsèquement un secret injecté dans le bot.

Point à vérifier impérativement : le credential d'invocation doit être consommé par le frontal Scaleway et ne pas être transmis au code tiers. Déployer un bot témoin qui inspecte les headers reçus ; vérifier la suppression avant ouverture aux soumissions tierces. Si le secret est visible, revoir le dispositif d'invocation avec Scaleway ; ne pas transmettre une clé partagée réutilisable à tous les bots. Ni les JSON de jeu, ni les logs, ni le CLI ne contiennent de credentials cloud.

## Concurrence, remplacement et nettoyage

Une seule ressource cloud par bot est la cible V1, avec scale 0 à 1. Les combats figent la révision utilisée et prennent une réservation exclusive. Ne jamais redéployer un bot au milieu d'un combat. Les nouvelles publications de ce bot attendent sa libération.

Les opérations cloud sont idempotentes au niveau applicatif : persistances avant/après chaque étape, recherche de la ressource existante après timeout ambigu, rapprochement par identifiant interne et reprise sans duplication. Les ressources orphelines sont réconciliées périodiquement.

La désactivation empêche de nouveaux combats. La suppression du container ou de l'image attend la fin des réservations et respecte la rétention des révisions nécessaire au diagnostic. Le rollback est piloté par la plateforme et validé, pas présumé automatique.

Les quotas effectifs doivent être lus dans l'organisation : la page des quotas décrit 250 containers par défaut ; la page des limites annonce 1 000 par organisation. Les demandes d'augmentation passent par le support. La mémoire cumulée est calculée avec le maximum de réplicas, pas uniquement les instances actives. [Quotas](https://www.scaleway.com/en/docs/organizations-and-projects/organization/organization-quotas/), [Limites](https://www.scaleway.com/en/docs/serverless-containers/reference-content/containers-limitations/)

## Validation avant ouverture

- Image amd64 copiée, digest enregistré, paramètres RAM/CPU et scale relus depuis le fournisseur.
- Invocation anonyme refusée ; invocation de service acceptée ; secret absent des headers reçus par le bot.
- Bot conforme activé automatiquement ; bot invalide ou trop lent rejeté avec motif exploitable.
- Deux soumissions identiques ne créent pas de ressources en double ; reprise après incident et rollback vérifiés.
- Réservation empêchant deux combats ou un redéploiement concurrent ; libération après crash.
- Démarrage à froid testé séparément du timeout d'action ; jobs longs et quotas vérifiés sur le vrai hébergement.

Les vérifications locales ou simulées ne constituent pas la preuve de ces comportements Scaleway.
