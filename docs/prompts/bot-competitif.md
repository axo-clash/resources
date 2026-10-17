# Prompt : créer un bot compétitif pour AXO/CLASH

Copie le texte ci-dessous dans l’IA qui doit développer ton bot. Remplace `NOM_BOT` par le nom enregistré dans l’interface, au format `name-supermodel-version`, par exemple `toto-super-5.2`. Utilise des minuscules, chiffres, points et tirets compatibles avec un nom d’image Docker. La version du modèle dans le nom est distincte de la version `1.0.0` du bot et de son image.

---

Tu es un ingénieur spécialisé en agents de jeux adversariaux et en optimisation. Développe un bot AXO/CLASH aussi performant que possible, avec du code complet, exécutable, testé et une image OCI publique compatible. Tu définis librement ta ligne directrice stratégique, ton raisonnement et ta méthode de conception pour aboutir au meilleur bot possible. Ce prompt fixe les règles et les exigences techniques, sans imposer d’approche stratégique. Ne prétends pas garantir un bot imbattable.

## Cadre autonome

Ce prompt contient le contrat et les règles nécessaires. Tu n’as accès à aucun dépôt,
code source de la plateforme, template ou documentation externe : ne les demande pas.
Tu disposes du binaire **`axo-clash`**, déjà installé et accessible dans le `PATH`.
Tu peux choisir le langage du bot et créer son propre projet ; aucun projet Go
ni source du CLI n’est nécessaire pour utiliser le binaire.

Tous les tests d’intégration doivent passer par **`axo-clash check-bot`** contre
le bot local ou son conteneur. N’utilise aucun frontend, navigateur, compte cloud,
code d’association, relais WebSocket ou session de laboratoire. N’exécute pas la
sous-commande `relay`. Tu peux compléter cette validation par tes propres tests fonctionnels locaux.

## Deux interfaces HTTP obligatoires

### 1. GET /api/v1/bots/info

Retourne HTTP 200, `Content-Type: application/json`, sans redirection :

```json
{"name":"NOM_BOT","version":"1.0.0"}
```

Le nom doit être **strictement identique** à celui de l’interface AXO/CLASH : casse, espaces et accents compris. `name` et `version` sont des chaînes non vides. Le timeout de `/info` est de 30 secondes, mais ce endpoint doit répondre immédiatement une fois le serveur prêt. Il ne doit pas lancer un calcul tactique.

### 2. POST /api/v1/bots/play

Accepte un corps JSON de forme `{"game": {...}, "bot": {...}}` et retourne HTTP 200 avec une seule action (les pièges ajoutent une cible `coordinates`) :

```json
{"action":"MOVE_UP"}
```

Actions : `MOVE_LEFT`, `MOVE_RIGHT`, `MOVE_UP`, `MOVE_DOWN`, `SHOOT_LEFT`, `SHOOT_RIGHT`, `SHOOT_UP`, `SHOOT_DOWN`, `PLACE_TRAP` (avec `coordinates`). `UNKNOWN` existe dans le protocole, mais constitue une action interdite dans le jeu : ne l’utilise pas comme une action d’attente sûre.

Le budget standard de `/play` est de **2 secondes, réseau compris**. Le bot doit répondre dans ce délai, quelle que soit la méthode choisie.

Le champ `bot` désigne notre siège. Distingue les sièges avec `botType` (`FIRST_BOT` ou `SECOND_BOT`), jamais avec le nom ni avec l’hypothèse que nous sommes toujours le premier.

Le DTO de `bot` contient notamment `id`, `name`, `version`, `data`, `botType`, `coordinates`, `faster`, et des champs optionnels. `data` contient `life`, `forbiddenActions`, `state`, `lastActionTimeMs`, `nextTrapTurn`. Les coordonnées sont `{"x":0,"y":0}`.

Le DTO de `game` contient notamment `id`, `firstBot`, `secondBot`, `board`, `currentTurn`, `actions`, `status`, `type`, `rules` et les informations de fin éventuellement absentes. `rules` contient `startingLife`, `responseTimeoutMs`, `maxTurns`, `maxForbiddenActions`.

Le plateau est un tableau de lignes : **`board[y][x]`**. Chaque case possède `coordinates`, éventuellement `content`, et éventuellement `items` et `trap`. Un item possède `type` et `owner`. Les projectiles sont `BULLET_LEFT`, `BULLET_RIGHT`, `BULLET_UP`, `BULLET_DOWN`. Plusieurs items peuvent occuper une case ; ne déduis pas toute la situation du seul champ visuel `content`.

Les champs optionnels peuvent être absents ou `null`. Les dates de l’historique sont en ISO 8601. Accepte les champs supplémentaires et des listes d’items absentes, vides ou nulles. Ne suppose pas que le même processus reçoit tous les tours : pars de l’état reçu, ou rends toute mémoire facultative et indexée par partie/siège.

## Détails de décodage et exemple complet

Voici les champs à prendre en charge, en plus de ceux déjà décrits :

- `BotDTO` : `id` (identifiant du siège dans la partie), `botId` (identité inscrite,
  optionnelle), `name`, `version`, `url` (optionnelle et à ne jamais appeler),
  `data`, `botType`, `coordinates`, `faster`, `eloDelta` (optionnel).
- `data.state` : `UNKNOWN`, `READY`, `PLAYING`, `WAITING_FOR_OPPONENT`.
- `game.status` : `STARTING`, `RUNNING`, `PAUSED`, `FINISHED`, `FAILED`.
- `game.type` : `LOCAL`, `RANKED`, `TOURNAMENT`.
- Une case vide a `content: null` ou pas de `content`, jamais une valeur `EMPTY`.
  Les contenus non nuls sont `FIRST_BOT`, `SECOND_BOT` ou les quatre `BULLET_*`.
- `game.actions` contient des objets avec `id`, `botId`, `action`, `forbidden`,
  `executionTimeMs`, éventuellement `serverDurationMs`, `relayLatencyMs`,
  `localHttpDurationMs`, et `createdDate` (chaîne ISO 8601). `botId` y désigne le
  siège de la partie (`bot.id`), pas nécessairement l’identité inscrite `bot.botId`.
- `winner` peut être `FIRST_BOT`, `SECOND_BOT`, `DRAW`, absent ou nul.
  `endReason` peut être `FIRST_BOT_LIFE`, `SECOND_BOT_LIFE`,
  `FIRST_BOT_FORBIDDEN_ACTION`, `SECOND_BOT_FORBIDDEN_ACTION`, `GAME_TURN`.
  `failureReason` peut être `BOT_CONNECTION_ERROR`, `BOT_INFO_RETRIEVAL_ERROR`,
  `GAME_EXECUTION_ERROR`, `INVALID_BOARD_STATE`, `BOT_COMMUNICATION_TIMEOUT`,
  `JSON_PROCESSING_ERROR`, `BOT_IDENTITY_MISMATCH`, `UNKNOWN_ERROR`.
  Ces champs peuvent être absents ou nuls ; `tournament` est une métadonnée
  facultative à ignorer pour prendre une décision tactique.

Voici un corps `/play` valide, avec un plateau complet de 64 cases. Les mêmes
objets de bot apparaissent dans `game.firstBot`/`game.secondBot`, dans `bot`, et
éventuellement dans `items[].owner` : ce sont des valeurs JSON, pas des références.
Le nom de l’adversaire est libre ; seul notre endpoint `/info` doit renvoyer
`NOM_BOT`.

```json
{
  "game": {
    "id": 1,
    "firstBot": {"id":11,"botId":7,"name":"NOM_BOT","version":"1.0.0","botType":"FIRST_BOT","coordinates":{"x":1,"y":3},"data":{"life":10,"forbiddenActions":0,"state":"PLAYING"},"faster":false},
    "secondBot": {"id":12,"botId":8,"name":"ADVERSAIRE","version":"1.0.0","botType":"SECOND_BOT","coordinates":{"x":6,"y":4},"data":{"life":10,"forbiddenActions":0,"state":"WAITING_FOR_OPPONENT"},"faster":true},
    "board": [
      [{"coordinates":{"x":0,"y":0},"content":null,"items":[]},{"coordinates":{"x":1,"y":0},"content":null,"items":[]},{"coordinates":{"x":2,"y":0},"content":null,"items":[]},{"coordinates":{"x":3,"y":0},"content":null,"items":[]},{"coordinates":{"x":4,"y":0},"content":null,"items":[]},{"coordinates":{"x":5,"y":0},"content":null,"items":[]},{"coordinates":{"x":6,"y":0},"content":null,"items":[]},{"coordinates":{"x":7,"y":0},"content":null,"items":[]}],
      [{"coordinates":{"x":0,"y":1},"content":null,"items":[]},{"coordinates":{"x":1,"y":1},"content":null,"items":[]},{"coordinates":{"x":2,"y":1},"content":null,"items":[]},{"coordinates":{"x":3,"y":1},"content":null,"items":[]},{"coordinates":{"x":4,"y":1},"content":null,"items":[]},{"coordinates":{"x":5,"y":1},"content":null,"items":[]},{"coordinates":{"x":6,"y":1},"content":null,"items":[]},{"coordinates":{"x":7,"y":1},"content":null,"items":[]}],
      [{"coordinates":{"x":0,"y":2},"content":null,"items":[]},{"coordinates":{"x":1,"y":2},"content":null,"items":[]},{"coordinates":{"x":2,"y":2},"content":null,"items":[]},{"coordinates":{"x":3,"y":2},"content":null,"items":[]},{"coordinates":{"x":4,"y":2},"content":null,"items":[]},{"coordinates":{"x":5,"y":2},"content":null,"items":[]},{"coordinates":{"x":6,"y":2},"content":"BULLET_DOWN","items":[{"type":"BULLET_DOWN","owner":{"id":12,"botId":8,"name":"ADVERSAIRE","version":"1.0.0","botType":"SECOND_BOT","coordinates":{"x":6,"y":4},"data":{"life":10,"forbiddenActions":0,"state":"WAITING_FOR_OPPONENT"},"faster":true}}]},{"coordinates":{"x":7,"y":2},"content":null,"items":[]}],
      [{"coordinates":{"x":0,"y":3},"content":null,"items":[]},{"coordinates":{"x":1,"y":3},"content":"FIRST_BOT","items":[]},{"coordinates":{"x":2,"y":3},"content":null,"items":[]},{"coordinates":{"x":3,"y":3},"content":null,"items":[]},{"coordinates":{"x":4,"y":3},"content":null,"items":[]},{"coordinates":{"x":5,"y":3},"content":null,"items":[]},{"coordinates":{"x":6,"y":3},"content":null,"items":[]},{"coordinates":{"x":7,"y":3},"content":null,"items":[]}],
      [{"coordinates":{"x":0,"y":4},"content":null,"items":[]},{"coordinates":{"x":1,"y":4},"content":null,"items":[]},{"coordinates":{"x":2,"y":4},"content":null,"items":[]},{"coordinates":{"x":3,"y":4},"content":null,"items":[]},{"coordinates":{"x":4,"y":4},"content":null,"items":[]},{"coordinates":{"x":5,"y":4},"content":null,"items":[]},{"coordinates":{"x":6,"y":4},"content":"SECOND_BOT","items":[]},{"coordinates":{"x":7,"y":4},"content":null,"items":[]}],
      [{"coordinates":{"x":0,"y":5},"content":null,"items":[]},{"coordinates":{"x":1,"y":5},"content":null,"items":[]},{"coordinates":{"x":2,"y":5},"content":null,"items":[]},{"coordinates":{"x":3,"y":5},"content":null,"items":[]},{"coordinates":{"x":4,"y":5},"content":null,"items":[]},{"coordinates":{"x":5,"y":5},"content":null,"items":[]},{"coordinates":{"x":6,"y":5},"content":null,"items":[]},{"coordinates":{"x":7,"y":5},"content":null,"items":[]}],
      [{"coordinates":{"x":0,"y":6},"content":null,"items":[]},{"coordinates":{"x":1,"y":6},"content":null,"items":[]},{"coordinates":{"x":2,"y":6},"content":null,"items":[]},{"coordinates":{"x":3,"y":6},"content":null,"items":[]},{"coordinates":{"x":4,"y":6},"content":null,"items":[]},{"coordinates":{"x":5,"y":6},"content":null,"items":[]},{"coordinates":{"x":6,"y":6},"content":null,"items":[]},{"coordinates":{"x":7,"y":6},"content":null,"items":[]}],
      [{"coordinates":{"x":0,"y":7},"content":null,"items":[]},{"coordinates":{"x":1,"y":7},"content":null,"items":[]},{"coordinates":{"x":2,"y":7},"content":null,"items":[]},{"coordinates":{"x":3,"y":7},"content":null,"items":[]},{"coordinates":{"x":4,"y":7},"content":null,"items":[]},{"coordinates":{"x":5,"y":7},"content":null,"items":[]},{"coordinates":{"x":6,"y":7},"content":null,"items":[]},{"coordinates":{"x":7,"y":7},"content":null,"items":[]}]
    ],
    "currentTurn": 3,
    "actions": [],
    "status": "RUNNING",
    "type": "LOCAL",
    "rules": {"startingLife":10,"responseTimeoutMs":2000,"maxTurns":100,"maxForbiddenActions":10}
  },
  "bot": {"id":11,"botId":7,"name":"NOM_BOT","version":"1.0.0","botType":"FIRST_BOT","coordinates":{"x":1,"y":3},"data":{"life":10,"forbiddenActions":0,"state":"PLAYING"},"faster":false}
}
```

## Règles du jeu

- Plateau 8 × 8, déplacements orthogonaux d’une case, pas de sortie du plateau ni de déplacement sur l’adversaire.
- Les coordonnées commencent à 0 : `x` croît vers la droite, `y` vers le bas. `MOVE_UP` et `BULLET_UP` diminuent `y` ; `MOVE_DOWN` et `BULLET_DOWN` l’augmentent. Les déplacements et tirs gauche/droite diminuent/augmentent `x`.
- Un tir est possible dans chacune des quatre directions, sans limite de munitions ni obstacle de décor. Tirer au bord vers l’extérieur crée un projectile qui quitte immédiatement le plateau. Les projectiles peuvent partager une case ; ils ne constituent pas un mur.
- Une action inconnue, un déplacement interdit, une erreur ou un timeout augmente le compteur d’actions interdites. Un timeout fait quand même avancer les projectiles du bot concerné ; il n’offre pas une pause tactique gratuite.
- Standard : 10 points de vie, 100 tours maximum, défaite à 10 actions interdites. Lis les limites reçues quand elles sont présentes.
- Les projectiles ennemis retirent un point de vie par impact. Les projectiles amis ne blessent pas leur propriétaire.
- Se déplacer sur un projectile est autorisé mais peut infliger des dégâts immédiatement. Plusieurs projectiles peuvent produire plusieurs impacts.
- Les deux actions sont demandées sur le même état du tour et exécutées selon l’ordre de réponse. `faster` décrit le passé et ne garantit pas l’ordre courant.
- Après une action, le moteur vérifie les impacts, déplace d’une case tous les projectiles du bot qui vient d’agir, puis vérifie de nouveau les impacts. Un tir crée un projectile sur la case du tireur : ce nouveau projectile avance donc lui aussi immédiatement d’une case dans cette phase. Un projectile qui sort du plateau est supprimé. Les projectiles des deux propriétaires ne se déplacent pas tous ensemble après chaque action.
- La partie peut s’arrêter après la première action. Si cette action provoque la défaite des deux bots, le premier acteur du tour perd : ne considère pas ce cas comme un match nul.
- À la limite des tours, la vie départage les bots, puis le nombre d’actions interdites ; égalité si les deux critères sont égaux.

## Zone rouge progressive

Les couronnes du plateau deviennent dangereuses de l’extérieur vers le centre.

| Couronne (distance au bord le plus proche) | Avertissement rouge, sans dégâts | Début des dégâts |
| --- | --- | --- |
| 0 : bord extérieur | Tour 70 | Tour 75 |
| 1 | Tour 80 | Tour 85 |
| 2 | Tour 90 | Tour 95 |
| 3 : quatre cases centrales | Tour 100 | Tour 105 |

Une couronne active reste dangereuse jusqu’à la fin de la partie. Après les actions
et les déplacements de projectiles des deux bots, chaque bot sur une case active
perd **1 PV par tour**, selon sa position finale. Les dégâts ne se cumulent pas
entre couronnes et les PV restent bornés à zéro. Un bot peut traverser une zone
ou en sortir : seuls les emplacements en fin de tour comptent. Une action interdite
ou un timeout n’exempte pas des dégâts de zone. Si une action termine déjà la
partie, la phase de zone n’est pas exécutée. Si les deux bots atteignent zéro à
cause de la zone, la règle existante s’applique : le premier acteur du tour perd.

Les seuils sont fixes, même en tournoi avec une limite de tours différente.
En standard (100 tours), les quatre cases centrales restent sans dégâts ; toute
la carte devient dangereuse au tour 105 seulement si la partie dure jusque-là.

Le champ `currentTurn` est le nombre de tours déjà terminés. Pour une case `(x,y)`,
la couronne vaut `min(x, y, 7-x, 7-y)`. Elle est annoncée à
`70 + 10 * couronne` et active à `75 + 10 * couronne`.
La prochaine action reçue via `/play` résout le tour `currentTurn + 1` : à
`currentTurn = 74`, le bot doit donc sortir du bord pour éviter les premiers dégâts.
Les zones se déduisent de ces informations, sans nouveau champ dans le JSON.

## Pièges visibles et neutres

La pose consomme l’unique action du bot, à la place d’un déplacement ou d’un tir :

```json
{"action":"PLACE_TRAP","coordinates":{"x":3,"y":4}}
```

- Première pose au **tour 10** : un appel avec `currentTurn = 9` résout le tour 10.
- Recharge de **10 tours par bot** : posé au tour 10, prochain piège possible au
  tour 20. La recharge est consommée uniquement par une pose valide, y compris un
  remplacement. Un déclenchement ne rend pas la recharge disponible plus tôt.
- Pose possible sur n’importe quelle case du plateau, même occupée par un bot,
  un projectile ou un piège. Il n’y a qu’un piège par case. Une pose remplace le
  piège existant, quel que soit son créateur, et réinitialise ses dates et sa couleur.
- Posé au tour `T`, le piège s’arme au début du tour `T+1` et reste actif pendant
  **les dix tours de `T+1` à `T+10` inclus**. Il disparaît après le tour `T+10`.
- **Après chaque action individuelle**, après les collisions et l’avancée des tirs,
  le moteur vérifie les pièges sous **les deux bots**. Tout bot vivant sur un piège
  armé perd **1 PV**, même le créateur. Le piège déclenché disparaît immédiatement :
  un même piège ne peut infliger qu’un seul dégât. Les timeouts et actions interdites
  déclenchent cette phase aussi. Un piège n’arrête pas les projectiles.
- Jouer en premier peut permettre de quitter un piège armé. Jouer en deuxième
  peut être trop tard : le piège sous le bot a pu se déclencher après l’action adverse.
- Un remplacement intervient pendant l’action, avant la vérification des pièges :
  il peut donc désarmer temporairement un piège sous un bot. Si les deux bots posent
  sur la même case au même tour, la dernière pose exécutée reste, et chacun consomme
  sa recharge. Aucun plafond supplémentaire de pièges par bot n’est appliqué.
- Après cette phase, les conditions de défaite sont vérifiées ; la seconde action
  n’est pas exécutée si le combat est fini. Si les deux bots perdent pendant la même
  action, le premier acteur du tour perd, conformément à la règle existante.
- Les dégâts de zone rouge restent appliqués **une seule fois en fin de tour global**,
  si le combat continue. Ils peuvent s’ajouter aux dégâts d’un piège.

### Informations reçues et représentation

Chaque case expose éventuellement `board[y][x].trap` (absent ou `null` sans piège) :

```json
{"placedBy":"FIRST_BOT","placedAtTurn":10,"armedFromTurn":11,"expiresAfterTurn":20}
```

`placedBy` sert à afficher le piège dans une nuance plus claire de la couleur du
bot qui l’a posé ; il ne donne **aucune immunité**. Un piège peut partager une case
avec un bot et des projectiles : ne le déduis pas du seul `content` ou de `items`.
Les pièges en armement sont affichés en pointillés, les pièges armés avec un contour
continu. Les tirs sont bleus pour `FIRST_BOT`, orange pour `SECOND_BOT`.

`bot.data.nextTrapTurn`, ainsi que les mêmes données dans `game.firstBot` et
`game.secondBot`, indique le prochain tour de pose autorisé. Pour les anciens
payloads où il est absent, la valeur initiale est 10. Une pose est disponible si
`currentTurn + 1 >= nextTrapTurn` et `currentTurn + 1 >= 10`.
L’historique `game.actions[].coordinates` conserve la cible d’une pose.
Les pièges, leurs dates et les recharges sont conservés lors d’une reprise de partie.
La pose avant le tour 10, pendant la recharge ou avec une cible absente,
partielle, non entière ou hors de `[0,7] × [0,7]` est une action interdite.
Les anciennes réponses `{"action":"MOVE_UP"}` ou `{"action":"SHOOT_LEFT"}` restent valides.

## Packaging cloud

Fournis un Dockerfile `linux/amd64`, léger, lançant le serveur sur `0.0.0.0`, avec `PORT` fourni par l’environnement (9000 par défaut). Budget : 512 Mo de mémoire et 0,5 vCPU. Prévois le démarrage à froid et les arrêts/redémarrages. Aucun secret, aucune base externe ni accès à l’API AXO/CLASH n’est nécessaire pour décider d’une action.

Le serveur à l’intérieur du conteneur peut servir HTTP : Scaleway termine HTTPS sur l’endpoint privé. La plateforme gère TLS et sa CA. N’ajoute pas de certificat auto-signé dans le bot et ne publie pas son endpoint sur Internet. Seule l’image OCI doit être publique et téléchargeable sans identifiant.

## Validation obligatoire avec le CLI

Démarre réellement le bot, puis utilise directement le binaire installé :

```sh
axo-clash version
axo-clash check-bot -url http://127.0.0.1:9000/api/v1/bots
axo-clash check-bot -url http://127.0.0.1:9000/api/v1/bots -repeat 5
```

L’option `-url` est la base complète : le CLI ajoute `/info` et `/play`.
N’utilise ni `go run`, ni `go build`, ni un chemin de dépôt pour lancer le CLI.
N’installe pas une autre version pour masquer un échec de compatibilité.

Utilise une version du CLI qui reconnaît `PLACE_TRAP` et ses coordonnées ; les anciens
binaires doivent être mis à jour avant de valider un bot utilisant les pièges.

La suite actuelle comporte 87 vérifications par passage : `/info` et 86 scénarios
`/play`, avec les deux sièges, champs optionnels absents ou nuls, projectiles,
bords, pièges (armement, recharge, remplacement), zone rouge, historique et variantes d’enums. Tous doivent réussir avec code de sortie
0 ; `-repeat 5` représente 435 vérifications sur cette version. Le CLI s’arrête
avec 1 si au moins une vérification échoue, et 2 si les arguments sont invalides.

Garde les budgets normaux : 30 secondes pour `/info`, 2 secondes pour `/play`.
Ne les augmente pas pour masquer un dépassement du délai. Si Docker est disponible,
exécute la même suite contre le conteneur final, démarré localement, pas uniquement
contre le serveur lancé depuis les sources. Exemple de contraintes pour ce test :

```sh
docker build --platform linux/amd64 -t mon-bot:local .
docker run --rm --name mon-bot-test --platform linux/amd64 \
  --memory 512000000 --cpus 0.5 -e PORT=9000 -p 127.0.0.1:9000:9000 mon-bot:local
# Dans un autre terminal :
axo-clash check-bot -url http://127.0.0.1:9000/api/v1/bots -repeat 5
```

Arrête d’abord le serveur précédent si le port 9000 est déjà occupé. Le CLI teste
le contrat et les réponses observées ; il ne mesure pas le taux de victoire.

Si `axo-clash` n’est pas disponible, indique que la validation est bloquée par
l’absence du binaire installé. Ne demande pas l’accès à un dépôt et n’invente
aucun résultat. Ne passe pas par le frontend ou le relais pour contourner cela.

## Publication de l’image

À la fin, si Docker est disponible, construis l’image `linux/amd64`, valide le
conteneur avec le CLI comme indiqué ci-dessus, puis pousse la même image publique
sur Docker Hub avec les deux tags :

- `nathanmittelette/axo-clash-${NOM_BOT}:1.0.0`
- `nathanmittelette/axo-clash-${NOM_BOT}:latest`

Par exemple, pour `NOM_BOT=toto-super-5.2` :

```sh
NOM_BOT=toto-super-5.2
docker build --platform linux/amd64 -t "nathanmittelette/axo-clash-${NOM_BOT}:1.0.0" .
# Valide cette image avec axo-clash check-bot avant de la publier.
docker tag "nathanmittelette/axo-clash-${NOM_BOT}:1.0.0" "nathanmittelette/axo-clash-${NOM_BOT}:latest"
docker push "nathanmittelette/axo-clash-${NOM_BOT}:1.0.0"
docker push "nathanmittelette/axo-clash-${NOM_BOT}:latest"
```

Vérifie que l’image publiée est téléchargeable sans authentification. Si Docker
est indisponible ou si l’authentification Docker Hub empêche la publication,
indique précisément ce qui reste bloqué et fournis les commandes restantes.
N’annonce une publication réussie qu’après la réussite effective des deux pushes.

## Résultat attendu

Livre le code complet, le Dockerfile, les commandes de lancement/build/publication,
les résultats réels de la validation fonctionnelle avec le CLI et les limites
connues. Indique les références des images publiées avec leurs deux tags, ou la
raison précise pour laquelle la construction, la validation ou la publication
n’a pas pu être réalisée. N’annonce pas de performances cloud ou de victoires
que tu n’as pas mesurées.
