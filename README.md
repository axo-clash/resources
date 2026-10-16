# AXO Clash — ressources communes

Ce dépôt regroupe les spécifications, les guides de déploiement, les maquettes
HTML et le compose de développement local.

- `docs/specifications/` : architecture, publication des bots et laboratoire.
- `docs/deployment/` : préparation du déploiement et procédures Scaleway.
- `designs/` : maquettes HTML et leurs dépendances locales.
- `docker-compose.yml` : stack locale.
- `openapi.json` : contrat historique, à comparer à l'OpenAPI généré par le backend courant.

Le code applicatif et son infrastructure restent dans les dépôts
[application-backend](https://github.com/axo-clash/application-backend) et
[application-frontend](https://github.com/axo-clash/application-frontend).
Le worker de publication est versionné avec le backend ; le bot de diagnostic
réseau est versionné dans [bots](https://github.com/axo-clash/bots).

Les commandes des guides utilisent un répertoire de travail commun contenant
`application-backend/`, `application-frontend/`, `bots/`, `cli/`, `templates/`
et `resources/`. Exécuter ces commandes depuis ce répertoire parent, sauf
indication contraire. Le CLI doit être publié dans le dépôt `axo-clash/cli`.

Pour utiliser le compose depuis le répertoire parent :

```sh
docker compose -f resources/docker-compose.yml up -d
```

Les guides décrivent aussi des opérations de déploiement manuel. Leur présence
dans Git ne signifie pas que les ressources cloud ont été créées ou validées.
