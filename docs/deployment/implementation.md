# Livraison publication et déploiement Scaleway

La configuration vise un projet Scaleway existant en `fr-par`. Aucun `apply`,
déploiement cloud, commit ni push n’a été effectué. Les domaines restent à gérer
séparément. Le state OpenTofu utilise un bucket S3 privé versionné et contient des secrets : le conserver
hors Git dans un emplacement protégé.

## Emplacement des éléments

- `infrastructure/` : modules IAM, registries, namespaces, SQL, API et Jobs du backend.
- `publication-worker/` : import OCI anonyme sans daemon Docker, callbacks et maintien des invocations de combat.
- API : publications persistées, réservations, validation cloud, rollback, relais WSS et confidentialité du labo.
- `../../../application-frontend/` : interface de publication et labo, flux SSE authentifiés,
  ainsi que sa stack OpenTofu indépendante pour Object Storage/Edge et son workflow
  de publication statique.
- `../cli/` : commande Go `relay`, association masquée et appels HTTP loopback.

L’infrastructure backend et le worker appartiennent au dépôt backend afin que son
checkout GitHub puisse construire et valider tous ses composants. Le stockage
statique et Edge du frontend sont gérés dans le dépôt frontend, avec un state
OpenTofu local séparé et un workflow de validation indépendant. Le CLI reste à
son emplacement existant.

## Choix retenus

Deux registries privés distincts : API/worker et tous les bots. Deux namespaces
Serverless Containers distincts : API et bots. Les images déployées sont
épinglées par digest. Une seule ressource container et une réservation exclusive
par bot ; aucune clé Scaleway n’est injectée dans un bot tiers.

Les sources OCI publiques de tout registry sont acceptées sans authentification.
Les adresses privées, loopback, link-local et endpoints de métadonnées restent
interdits, y compris après DNS/redirection. Les limites d’import par défaut sont
512 MiB compressés, 2 GiB décompressés, 4 GiB effectivement reçus et 32 couches.
Les soumissions sont limitées à 3 par joueur/heure, avec 5 tentatives maximum et
un délai croissant. Le digest source inspecté est conservé avant copie et repris
après crash ; le tag source n’est pas résolu à nouveau.

Le labo est privé au joueur, hors statistiques et ELO. Les sessions de relais
expirent après 30 minutes par défaut ; les codes sont utilisables une fois pendant
5 minutes. Le délai d’action reste 2 secondes, réseau inclus. La préparation à
froid dispose de son propre budget de 2 minutes. Une partie cloud est bornée à
55 minutes et garde une invocation API ouverte via un Serverless Job.

## Paramètres avant déploiement

Le [runbook](scaleway-runbook.md) détaille le bootstrap, les variables GitHub et
les secrets backend. Renseigner les IDs projet/organisation, les digests API/worker,
`AZURE_TENANT_ID` et `AZURE_CLIENT_ID` dans
`api_secret_environment_variables`. Le token worker est généré par OpenTofu et
partagé entre l’API et les deux Jobs, puis les sorties backend dans les variables
GitHub. Les variables de publication frontend (`SCW_REGION`,
`FRONTEND_BUCKET_NAME`, `VITE_API_URL`, les paramètres Entra, les secrets S3 et,
si Edge est activé, `SCW_EDGE_PIPELINE_ID`) sont configurées dans le dépôt
frontend selon son [guide infra indépendant](../../../application-frontend/infrastructure/README.md).

Le verrou `invocation_header_stripping_verified` reste `false`. Le passer à
`true` seulement après un test témoin réel prouvant que Scaleway retire le
credential d’invocation avant de livrer les headers au bot tiers.

Pour suspendre un bot à titre opérateur, injecter un secret indépendant d’au moins
32 caractères `APPLICATION_OPERATOR_TOKEN` via `api_secret_environment_variables`.
L’API interne `PATCH /api/v1/internal/operations/bots/{id}/suspension` accepte
`{ "suspended": true|false }` avec `X-Operator-Token`. Ce secret n’est partagé
ni avec les bots ni avec le worker. Sans configuration, cette opération est
refusée. La reprise du propriétaire n’annule jamais cette suspension opérateur.

Les checks locaux valident les contrats et la configuration. Ils ne prouvent pas
le comportement IAM, le démarrage à froid, WSS, les quotas ni la durée des
invocations sur Scaleway. Le runbook liste les preuves à relever sur le vrai
hébergement avant ouverture aux soumissions tierces.

## Vérification locale du 11 octobre 2026

- Backend : `mvn -Pprod verify`, 203 tests, aucune erreur ni test ignoré.
- Image API JVM linux/amd64 : build Docker avec `jlink`, puis démarrage avec PostgreSQL jetable et vérification santé, paramètres et validation HTTP 400.
- CLI et worker : `go test -race ./...` et `go vet ./...`.
- Frontend : check, lint, build et sept tests de flux SSE authentifiés.
- Infrastructure : init sans backend, formatage et validation OpenTofu 1.13.1 / provider Scaleway 2.84.0.
- Workflows : actionlint 1.7.7.

Le test WebSocket ouvre une vraie socket sur le serveur local. Les tests JVM et
Docker locaux ne prouvent pas un déploiement Scaleway. Aucun pipeline GitHub ni
ressource Scaleway n’a été exécuté pour cette livraison.

## Avancement de publication

Le frontend suit les publications par SSE authentifié, sans polling périodique.
Le flux est privé au propriétaire et renvoie un instantané après reconnexion.
Les callbacks HTTP du worker restent séparés : le seul credential accepté sur
`/internal/publications/**` et `/internal/game-runs/**` est `X-Worker-Token`.
Un JWT utilisateur/créateur ne donne aucun accès à ces routes, même avant la
validation du corps de requête. Ces endpoints ne figurent pas dans Swagger.

## Image du worker

Go 1.27.2 est aligné dans le builder et la CI. Le runtime utilise `scratch` :
binaire statique, certificats TLS et utilisateur numérique non-root, sans
distribution Linux complète. Le build linux/amd64 et un test HTTPS local de
l’image réelle ont réussi ; Docker annonce 3,52 Mo pour cette image, avec un
binaire de 7,99 Mo une fois décompressé. Aucun push registry n’a été exécuté.

## Construction JVM de l’API

Depuis `application-backend`, utiliser `bash scripts/build-image.sh axo-clash-api:local`.
Le script construit un JAR prod, puis une image linux/amd64 avec Java 25 et un
runtime `jlink`. Le runtime est calculé avec `jdeps` et complété par les modules
utilisés dynamiquement. Le JDK de construction reste dans le premier stage ;
le runtime final Alpine fonctionne avec un utilisateur non-root et les couches
Spring Boot. Le script ne pousse pas l’image. Le workflow GitHub utilise ce
même script avant son `docker push`.

Le démarrage est vérifié avant publication avec
`python3 scripts/smoke-image.py axo-clash-api:local` : migrations sur PostgreSQL
jetable, santé, paramètres publics et pagination invalide rejetée en HTTP 400.
Ce test local a réussi avec l'image JVM ; Docker annonce 128 920 092 octets
(environ 129 Mo) pour cette image sur le poste de vérification.

Les disques locaux des Jobs sont explicites dans les tfvars :
`publication_job_local_storage_mib = 4096` et
`game_keepalive_job_local_storage_mib = 1024`. Les valeurs doivent être
strictement supérieures à 1000 et inférieures à 10240 Mio.
