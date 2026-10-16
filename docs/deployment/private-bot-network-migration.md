# Réseaux privés à la demande et invocation sans clé IAM

## Topologie

OpenTofu crée toujours un VPC dédié avec routage activé. Le réseau de l'API,
les ACL IPv4/IPv6 et les réseaux des bots utilisent exclusivement ce VPC. Le premier /24 du /16 `bot_network_ipv4_cidr` est réservé à
l'API : choisir une plage libre. Aucun Public Gateway n'est créé et la propagation
des routes par défaut est désactivée.

Le backend crée le réseau dédié à chaque bot lors de sa première publication,
avec adressage attribué par Scaleway, puis configure les ACL avant de rattacher
le conteneur. Il réutilise ce réseau pour les versions suivantes et les rollbacks.
Aucun pool inutilisé ni capacité fixe. Les quotas réseau Scaleway et la limite de
255 règles par famille IP restent applicables.

Un mutex PostgreSQL partagé entre les instances sérialise création et mise à jour
des ACL. L'affectation bot→réseau est persistée. Après une réponse ou transaction
perdue, une reprise retrouve le réseau par nom exact et tags de propriétaire.
Un nom ambigu, un autre projet/VPC, un réseau sans DHCP ou propagant les routes
par défaut sont refusés. Aucun recyclage vers un autre bot n'est automatique.
Les erreurs temporaires de provisioning sont reprises par la publication.

Le manager reçoit `VPCFullAccess` et `PrivateNetworksFullAccess` sur le projet
pour ce provisioning ; sa clé reste
dans l'API. Les ACL autorisent API↔réseaux puis refusent tout autre trafic privé
entrant/sortant des réseaux des bots. Elles conservent les règles existantes et
la politique par défaut. Elles sont stateless : tous les ports avec l'API sont
autorisés dans les deux sens, y compris des appels initiés par un bot.

Après initialisation, OpenTofu ignore les changements des règles ACL et de leur
politique (`ignore_changes`). Le backend gère les mises à jour dynamiques pour
éviter qu'un apply ultérieur supprime les règles des bots. Ne pas modifier ces
mêmes règles simultanément depuis un autre gestionnaire.

## Invocation sans secret

Les bots utilisent `privacy = public` (appels anonymes), **avec endpoint privé
activé et endpoint public par défaut désactivé**. Cette politique d'authentification
ne rend pas leur endpoint accessible sur Internet. Validation et parties n'envoient
ni `X-Auth-Token` ni clé Scaleway. La CA privée sert à TLS, avec vérification du nom
d'hôte. Aucun repli vers l'endpoint public n'est prévu.

L'apply supprime l'identité IAM invoker et révoque sa clé historique. Une clé vue
dans un bot est exposée : la révoquer avant de reprendre les parties, même si la
migration est différée. Le witness sert à vérifier réseau et absence de credentials ;
l'attestation de stripping de headers n'est plus une condition d'activation.

## Bascule et bots existants

1. Publier la nouvelle image backend et réserver une fenêtre sans parties/publications.
2. Vérifier VPC, routage, CIDR, réseaux/ACL existants et quotas. Si l'ancien pool a
   déjà été appliqué, conserver ses réseaux : après inventaire et sauvegarde,
   retirer leurs ressources du state avant la bascule. Examiner le plan pour
   exclure toute destruction de réseau portant un bot. Les affectations en base
   sont conservées.
3. Récupérer la CA via `GET /containers/v1/regions/{region}/private-endpoint-ca` et
   fournir son PEM dans `bot_private_endpoint_ca_pem`.
4. Activer `bot_private_networking_enabled = true`, appliquer infrastructure/backend,
   et vérifier la révocation de la clé invoker. L'API garde son endpoint public
   pour le frontend et les callbacks des Jobs.
5. Republier chaque bot actif : nouvelle version ou restauration d'une révision
   validée. La publication crée/réutilise le réseau, configure les ACL, PATCH le
   conteneur et valide le contrat avant d'enregistrer son URL privée.
6. Vérifier READY et le witness : accès API→bot sans token, refus depuis Internet,
   refus bot→autre bot, sorties Internet réelles.

Aucun changement du code/image des bots n'est nécessaire. Une nouvelle publication
migre automatiquement le conteneur après activation du backend et de l'infrastructure.
Le seul redéploiement du backend ne migre pas les anciens bots ; la maintenance
peut les désactiver s'ils restent non conformes. Un PATCH manuel seul ne met pas
à jour l'URL et l'affectation persistées.

Si une version échoue mais que le rollback est validé, la version précédente
redevient disponible avec son URL privée, y compris pendant une migration.

## Validation et limites

Tests : concurrence PostgreSQL, reprise après création et échec ACL partiel,
conservation des règles/default policy IPv4/IPv6, migration/rollback, absence des
headers d'authentification sur INFO/PLAY, TLS et authentification du management.
Tests OpenTofu simulés : réseau API et initialisation des ACL.

Ces tests locaux ne prouvent pas l'application des ACL aux endpoints privés réels.
Vérifier avec le witness dans le VPC. Aucun Public Gateway ne garantit pas le
blocage des sorties Internet des Serverless Containers. Les ressources autorisées
du réseau API et les opérateurs ayant accès au VPC peuvent également appeler les bots.
