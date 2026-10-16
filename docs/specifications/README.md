# Hébergement des bots et labo distant

Spécification du 11 octobre 2026. Ces documents décrivent la cible ; ils ne signifient pas que les fonctionnalités sont déjà implémentées ou déployées.

## Documents

- [Décisions et architecture](01-decisions-et-architecture.md) : périmètre accepté, contraintes, limites et points ouverts.
- [Publication et exploitation Scaleway](02-publication-scaleway.md) : import d'image, provisionnement, authentification, ressources et disponibilité.
- [Labo cloud et relais WebSocket en Go](03-labo-websocket.md) : parcours utilisateur, identité des connexions, protocole et intégration au moteur.

## Choix confirmés

| Sujet | Décision |
| --- | --- |
| API | Scaleway Serverless Containers |
| Base | Serverless Database |
| Front | Object Storage et Edge Services, publié par pipeline |
| Autoscaling des containers | Minimum 0, maximum 1, API comprise |
| Ressources de chaque bot cloud | 512 Mo, 0,5 vCPU |
| Utilisation d'un bot | Un seul combat à la fois |
| Publication | Référence d'image Docker/OCI, recopiée dans le registry de la plateforme et figée par digest |
| Activation | Après contrôles automatiques, sans revue manuelle obligatoire |
| Archives `.tar` | Hors périmètre de la première version |
| Réseau sortant des bots | Autorisé dans cette première version ; aucune promesse de blocage Internet |
| Tests locaux | Interface cloud et moteur cloud ; CLI Go ouvrant un relais WebSocket sortant |
| Combinaisons du labo | Local/cloud et local/local, avec un ou deux CLI |
| Résultats du labo | Aucun impact sur l'ELO ou les statistiques compétitives |

Les contrats détaillés, noms de commandes et valeurs opérationnelles proposés dans les documents restent des propositions d'implémentation. Les décisions utilisateur ci-dessus sont acquises.
