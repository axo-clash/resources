# Contrat interne API ↔ publication-worker

Ce contrat interne n'est jamais exposé au navigateur, au CLI ni au code d'un
bot. `BACKEND_SERVICE_TOKEN` est un secret dédié injecté par Secret Manager
dans le Job. Le serveur le compare en temps constant et ne l'accepte sur
aucune route joueur.

`BACKEND_BASE_URL` est l'origine HTTPS de l'API avec le préfixe `/api/v1`, par
exemple `https://api.example.invalid/api/v1`. Le worker ajoute les chemins
ci-dessous. Les identifiants de ce contrat sont des chaînes opaques.

## Publication

Le déclencheur événementiel fournit `PUBLICATION_SUBMISSION_ID`. Le worker
appelle `POST /internal/publications/claim` avec `X-Worker-Token` et :

```json
{
  "submissionId": "123",
  "workerId": "job-execution-id",
  "leaseSeconds": 300
}
```

Le trigger UTC de réconciliation appelle le même endpoint sans
`PUBLICATION_SUBMISSION_ID` (`submissionId` est alors une chaîne vide). L'API
choisit atomiquement une soumission persistée récupérable. Une réponse `204`
vide signifie qu'il n'y a rien à réclamer et termine le Job avec succès; un
claim renvoie toujours la structure ci-dessous.

Le serveur vérifie l'identifiant, le propriétaire et l'état `SUBMITTED`, le
verrouille dans une transaction, crée un bail récupérable de cinq minutes et
renvoie la structure suivante (avec `sourceDigest` lorsque déjà persisté) :

```json
{
  "submissionId": "123",
  "botId": "42",
  "revisionId": "456",
  "revisionTag": "r-123",
  "sourceReference": "docker.io/example/bot:1.2.3",
  "sourceDigest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "destinationRepository": "bot-42",
  "leaseToken": "opaque-memory-only",
  "state": "INSPECTING",
  "activationGate": "attestation",
  "attestationVerified": false
}
```

`sourceDigest` est facultatif sur un premier claim; après une inspection
persistée, le backend le renvoie et le worker utilise exclusivement
`sourceReference` épinglée sur ce digest, sans relire le tag mutable. Le worker
refuse une réponse incomplète et ne reconstruit aucun champ métier.
`destinationRepository` est fourni par l'API; l'auteur ne peut pas choisir un
autre dépôt. Un `204` vide est une réussite idempotente quand aucun travail ne
reste à réclamer, y compris pendant le rejeu d'un déclencheur ciblé déjà
terminé.

Les requêtes suivantes portent `X-Worker-Token` et `X-Lease-Token` :

| Méthode | Chemin | Corps |
| --- | --- | --- |
| `POST` | `/internal/publications/{submissionId}/renew` | `{ "leaseSeconds": 300 }` |
| `POST` | `/internal/publications/{submissionId}/progress` | `{ "state": "INSPECTING\|COPYING\|DEPLOYING\|VALIDATING", "message": "...", "sourceDigest": "sha256:<64 hex>", "sourceReference": "repository@sha256:<64 hex>" }` |
| `POST` | `/internal/publications/{submissionId}/complete` | digests, référence immutable, plateforme et attestation |
| `POST` | `/internal/publications/{submissionId}/fail` | `{ "code": "...", "message": "...", "retryable": false }` |

Le worker publie `INSPECTING`, résout le manifeste sélectionné, puis publie
`COPYING` avec le digest et la référence `repository@sha256:<64 hex>` avant
toute écriture dans le registry. L'appel `complete` demande au backend d'exécuter le pipeline
manager/invoker. Le corps de `complete` est :

```json
{
  "sourceDigest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "destinationDigest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "destinationReference": "rg.fr-par.scw.cloud/bots/bot-42@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "platform": "linux/amd64",
  "attestationVerified": true,
  "attestationReference": "operator-witness-1"
}
```

`attestationVerified` et `attestationReference` sont recopiés depuis la
configuration et l'état d'attestation du backend; le worker ne peut pas les
élever à `true`. Si la gate vaut `false`, le backend rejette l'activation
jusqu'à ce qu'un opérateur fournisse la preuve témoin.

Le worker résout `destinationRepository` dans le namespace bots configuré par
le Job puis renvoie toujours `registry/bot-id@digest`, jamais un tag. Le
backend doit contrôler que le dépôt appartient au bot et que le digest
correspond à la copie revendiquée.

Le backend refuse toute transition illégale, rend les appels idempotents,
libère le bail dans chaque état terminal et n'active jamais une révision par
la seule valeur fournie par le worker. Il utilise son identité `manager` pour
créer ou mettre à jour le container privé et `invoker` pour `/info` et `/play`.
Un échec après inspection conserve le `sourceDigest` épinglé pour le rejeu et
le diagnostic; il ne le remplace pas par le tag mutable ni ne l'efface.
Il ne passe à `READY` qu'après la validation réelle et le read-back des limites
Scaleway : `512000000` octets, `500` mvCPU, `sandbox=v2`, `private`,
`min=0`, `max=1`.

Le worker ne reçoit jamais la clé `ContainersPrivateAccess`. `activationGate` et
`attestationVerified` viennent de la configuration et de l'état attesté par le
backend; aucune variable utilisateur ne peut les remplacer. L'activation reste
refusée tant que le test témoin n'a pas établi que la clé d'invocation est
consommée par la passerelle Scaleway et absente des headers, logs et payloads
reçus par le code du bot.

## Job de combat long

Un combat cloud/cloud ou relayé est persistant en base. Le Job
`game-keepalive` appelle une seule fois
`POST /internal/game-runs/{gameRunId}/keepalive` avec le même token interne.
L'API garde la connexion HTTP ouverte jusqu'à la fin du run et renvoie alors :

```json
{ "terminal": true, "status": "FINISHED" }
```

Une réponse `terminal=false` est une violation de contrat et le Job échoue;
il n'effectue pas de pause suivie d'un polling court. Un thread JVM détaché
après la requête initiale ne constitue pas une preuve de liveness sur
Serverless Containers. Le timeout HTTP du worker est de dix minutes pour le
callback de publication; le timeout de chaque connexion de transport registry
est de trente secondes. Le Job de combat est borné à une heure, l'API à 55
minutes pour un run et le client keep-alive à 56 minutes. Le renouvellement du
bail continue en parallèle du déploiement/validation.

## Variables

| Variable | Source | Utilisation |
| --- | --- | --- |
| `WORKER_MODE` | Job | `import` ou `game-keepalive` |
| `WORKER_ID` | optionnel; sinon `SCW_SLS_RESOURCE_ID` (ou alias `SCW_JOB_RUN_ID`) | audit de l'exécution |
| `PUBLICATION_SUBMISSION_ID` | déclencheur Job, absent pour la réconciliation | soumission ciblée ou claim générique |
| `GAME_RUN_ID` | déclencheur Job | combat ciblé |
| `BACKEND_BASE_URL` | variable non sensible | origine API + `/api/v1` |
| `BACKEND_SERVICE_TOKEN` | Secret Manager | token interne dédié |
| `REGISTRY_DESTINATION` | variable non sensible | namespace registry bots privé |
| `DESTINATION_REGISTRY_SECRET` | Secret Manager | clé registry d'import |
| `IMPORT_REQUEST_TIMEOUT_SECONDS` | optionnel, défaut `600` | budget global de résolution/copie/callback |
| `IMPORT_TRANSPORT_TIMEOUT_SECONDS` | optionnel, défaut `30` | délai d'une connexion registry |

Les logs identifient la soumission, la révision et l'état sans imprimer de
token, de clé Scaleway, d'URL source complète potentiellement propriétaire ou
de payload de jeu.
