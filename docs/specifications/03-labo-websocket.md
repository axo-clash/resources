# Labo cloud et relais WebSocket en Go

Date : 11 octobre 2026. Protocole proposé V1, à implémenter dans le CLI Go existant et l'API Java.

## Parcours utilisateur

Le joueur ouvre `/lab` sur le front cloud et crée une session de relais. L'API authentifie son compte, crée `relaySessionId` et retourne un code d'association court, temporaire et à usage unique. Le joueur lance le CLI et saisit ce code dans une invite masquée.

```sh
# Une connexion et un bot local
axo-clash relay --bot alpha=http://127.0.0.1:9000/api/v1/bots

# Une connexion transportant deux bots locaux
axo-clash relay \
  --bot alpha=http://127.0.0.1:9000/api/v1/bots \
  --bot beta=http://127.0.0.1:9001/api/v1/bots
```

Le code est échangé par HTTPS contre un credential limité à cette session. L'échange est atomique, avec expiration et nombre d'essais borné. La session appartient au joueur authentifié qui l'a créée. Ni le code ni le credential ne sont placés dans l'URL, dans les logs ou dans une option visible de commande. Le CLI conserve le credential en mémoire pour la durée du processus et ouvre `wss://<api>/api/v1/lab/relay` avec un header d'authentification.

Le CLI enregistre ses alias locaux et les informations issues de `/info`. Le serveur attribue un `bindingId` à chaque bot. Le navigateur voit les bots connectés avec leur session, leur nom d'affichage et leur état. La réponse `/info` donne des métadonnées, jamais l'identité ou les droits du joueur.

Sur chaque siège du combat, le joueur sélectionne soit un bot cloud publié et disponible, soit l'un de ses bots locaux connectés. Le bouton de lancement est désactivé si un bot local est déconnecté ou occupé. Le serveur revérifie ces conditions atomiquement lors de la création.

Le navigateur suit ensuite le combat par REST/SSE, comme aujourd'hui. Il ne contacte pas le CLI ni les bots directement ; aucun CORS localhost, port entrant ou VPN n'est nécessaire.

## Combinaisons prises en charge

| Siège A | Siège B | Routage |
| --- | --- | --- |
| Bot local alpha | Bot cloud | A par relais ; B par HTTP authentifié Scaleway |
| Bot local alpha | Bot local beta, même CLI | Une socket ; deux `bindingId` distincts |
| Bot local alpha | Bot local beta, second CLI | Deux sessions/sockets ; une liaison par siège |

Deux CLI sont associés à deux sessions créées par le même joueur. Les combats entre sessions appartenant à des joueurs différents restent hors périmètre V1 : ils nécessiteraient une invitation et un consentement supplémentaires. Les bots cloud autorisés pour le labo sont ceux que la plateforme rend disponibles au joueur ; ne pas contourner ces droits avec une URL.

## Identifiants et autorité

Une socket représente un relais, pas un combat. Les bots sont déclarés avant la création du combat. Le serveur choisit toutes les associations.

| Identifiant | Sens et durée |
| --- | --- |
| `playerId` | Propriétaire issu de l'authentification serveur |
| `relaySessionId` | Session temporaire associée à ce joueur |
| `connectionId` | Génération de connexion ; change à chaque reconnexion |
| `bindingId` | Bot déclaré dans une session, lié à un alias CLI |
| `gameId` | Combat persistant |
| `gameRunId` | Tentative d'exécution ; change lors d'un restart |
| `seat` | `FIRST_BOT` ou `SECOND_BOT` dans ce combat |
| `requestId` | Appel `/info` ou `/play` unique, créé par le serveur |

Table de routage logique :

```text
(gameId, gameRunId, seat)
    → cloud(botId, revisionId)
    OU local(playerId, relaySessionId, bindingId)

(relaySessionId, connectionId)
    → socket active

requestId
    → connexion attendue + binding + combat + tentative + siège + échéance
```

Le client ne peut pas annoncer « je suis le bot du combat X » et obtenir ce rôle. La création REST authentifiée vérifie que chaque binding appartient au joueur, existe dans une session active et n'est pas réservé. Elle fige les associations et prend les deux réservations dans une opération atomique.

La réponse est associée à un appel déjà en attente sur la socket authentifiée. Un `requestId` inconnu, une réponse sur la mauvaise connexion, un binding incohérent, un doublon ou une réponse tardive ne modifie jamais le combat. Un UUID difficile à deviner facilite la corrélation mais ne remplace pas ces contrôles.

## Contrat REST proposé

- `POST /api/v1/lab/relay-sessions` : créer une session et un code temporaire, joueur authentifié.
- `POST /api/v1/lab/relay-sessions/exchange` : échanger le code une fois, avec limite d'essais.
- `GET /api/v1/lab/relay-sessions` : voir uniquement ses sessions et leurs bindings.
- `DELETE /api/v1/lab/relay-sessions/{id}` : révoquer sa session, fermer la socket et terminer les tests qui en dépendent.
- `POST /api/v1/lab/games` : créer un combat de test à partir de deux sélecteurs typés.

Exemple local/cloud :

```json
{
  "firstBot": {"transport": "LOCAL_RELAY", "bindingId": "binding-alpha"},
  "secondBot": {"transport": "CLOUD_HTTP", "botId": 42}
}
```

Exemple local/local :

```json
{
  "firstBot": {"transport": "LOCAL_RELAY", "bindingId": "binding-alpha"},
  "secondBot": {"transport": "LOCAL_RELAY", "bindingId": "binding-beta"}
}
```

`gameId`, les révisions cloud, le joueur et les associations de sockets sont fixés côté serveur. Les exemples sont des contrats cibles, pas des endpoints existants. Le labo est accessible aux joueurs authentifiés, sans exiger le rôle créateur utilisé aujourd'hui pour les combats classés.

## Contrat WebSocket proposé

Messages JSON versionnés, avec tailles maximales et nombres de requêtes en attente bornés. `protocolVersion=1` est négocié dès l'ouverture. Le serveur fournit `connectionId` ; le CLI ne choisit pas son identité de connexion.

Enregistrement CLI → serveur :

```json
{
  "type": "register",
  "protocolVersion": 1,
  "bots": [
    {"alias": "alpha", "info": {"name": "Mon bot", "version": "1.0"}},
    {"alias": "beta", "info": {"name": "Autre bot", "version": "1.0"}}
  ]
}
```

Le serveur répond avec la correspondance alias → `bindingId`. Les URL locales restent configurées dans le CLI, elles ne sont pas fournies par le serveur. Les métadonnées du CLI sont revérifiées par un appel `/info` relayé lors de la préparation.

Appel serveur → CLI :

```json
{
  "type": "bot.request",
  "protocolVersion": 1,
  "connectionId": "connection-1",
  "requestId": "request-123",
  "bindingId": "binding-alpha",
  "gameId": 123,
  "gameRunId": "run-1",
  "seat": "FIRST_BOT",
  "operation": "PLAY",
  "timeoutMs": 2000,
  "payload": {}
}
```

`payload` contient le DTO de jeu actuel, sans transformation des règles. Pour `INFO`, il est omis. Le serveur démarre son délai avant l'envoi ; `timeoutMs` donne un plafond de traitement CLI et n'accorde aucun temps supplémentaire. Les horloges poste/serveur n'ont pas besoin d'être synchronisées.

Réponse CLI → serveur :

```json
{
  "type": "bot.response",
  "protocolVersion": 1,
  "connectionId": "connection-1",
  "requestId": "request-123",
  "bindingId": "binding-alpha",
  "status": 200,
  "payload": {"action": "MOVE_UP"},
  "localHttpDurationMs": 4
}
```

Le serveur retrouve le combat et le siège depuis l'appel en attente ; ils ne sont pas choisis dans la réponse. `status` correspond au statut HTTP du bot. Les erreurs réseau locales utilisent un message `bot.error` avec le même `requestId`, un code borné tel que `LOCAL_UNREACHABLE`, `LOCAL_TIMEOUT` ou `INVALID_RESPONSE`, et un texte de diagnostic sans secrets.

Le CLI accepte seulement `INFO` (GET `/info`) et `PLAY` (POST `/play`). Il n'est pas un proxy HTTP générique : aucune URL, méthode ou liste de headers arbitraire venant du cloud. Refuser les redirections, limiter les réponses et annuler les appels avec le contexte Go. Les URL configurées doivent être loopback en V1 ; les accès LAN éventuels seront un choix explicite ultérieur.

Une goroutine lit la socket ; une seule goroutine écrit les messages via une file bornée. Les appels HTTP peuvent être parallèles entre bots distincts, avec au maximum un appel en cours par binding. Un message `bot.cancel` peut interrompre un appel expiré ; le serveur refuse quand même toute réponse tardive.

## Déconnexion, latence et redémarrage

Prévoir ping/pong, mesure aller-retour et reconnexion avec délai croissant. La limite d'inactivité et la durée totale restent à fixer. Une connexion WSS persistante évite la négociation TLS à chaque tour ; le surcoût principal est un aller-retour poste/cloud.

Le labo affiche le temps total mesuré par le serveur, la latence du relais et le temps HTTP déclaré par le CLI. Le temps local est informatif et ne sert pas à compenser le timeout ni à classer les bots.

Proposition V1 : une déconnexion pendant un combat met ce combat en échec, libère ses réservations et invalide ses requêtes en attente. Ne pas rejouer automatiquement une action dont on ignore si elle a déjà été traitée. La reconnexion permet de nouveaux combats ; une reprise explicite passe par un nouveau `gameRunId` et la vérification des deux bots.

Le serveur peut conserver les bindings de la session à la reconnexion si le CLI redéclare exactement les mêmes alias ; ils restent hors ligne jusqu'à validation. Il remplace l'ancienne `connectionId` atomiquement et refuse les réponses d'une génération précédente. Une deuxième socket ne peut pas détourner une session active sans ce remplacement contrôlé.

Après redémarrage de l'API, les bindings sont hors ligne. Les combats relayés interrompus sont marqués en échec, y compris si le mécanisme Spring Batch actuel tenterait de les reprendre. Les combats cloud/cloud peuvent suivre une politique de récupération séparée. Ne pas reprendre silencieusement un combat local sans son CLI.

## Intégration dans le projet

Introduire une interface de transport `BotTransport` exposant les mêmes opérations que `BotWebService`. L'implémentation HTTP conserve les appels aux bots cloud ; l'implémentation relais attend la future liée à `requestId`. `GameExecutionService` utilise cette abstraction sans réécrire les règles.

Le labo distant peut conserver le type métier `LOCAL` pour les résultats, avec un chemin de création distinct de `createLocalGame` : la vérification `application.local-mode.enabled` continue de protéger les URL arbitraires. Tous les calculs ELO et W/L/D doivent exclure ces tests, quelle que soit la combinaison de transports.

Les nouveaux DTO et migrations doivent représenter les références de transport sans inventer une URL HTTP pour un binding. Le serveur calcule les permissions des participants, réserve leurs ressources et gère les diagnostics avant de déclencher le job.

La politique proposée de confidentialité du labo impose des contrôles de propriétaire sur REST, listes, détails et SSE. Le comportement actuel autorisant les GET publics nécessite une adaptation pour ces données ; masquer seulement les boutons du front ne suffit pas.

## Critères de validation

- Un bot local contre un bot cloud, deux bots sur une socket, deux bots sur deux sockets du même joueur.
- Refus d'un binding d'un autre joueur, de deux sièges sur le même binding et d'un bot occupé.
- Aucune réponse d'une mauvaise socket, d'une ancienne tentative ou d'une requête expirée n'affecte un combat.
- Timeout incluant le réseau, réponses HTTP invalides, messages excessifs et redirections gérés proprement.
- Déconnexion, reconnexion, expiration de session et redémarrage API libèrent les réservations sans replay automatique.
- Pas d'ELO ni de statistiques compétitives modifiés par le labo ; accès aux résultats conforme à la politique choisie.
- Tests réels de WSS, cold start, durée d'invocation, facturation et jobs de combat sur Scaleway.
