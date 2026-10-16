# Endpoints privés et bot témoin — vérification du 12 octobre 2026

L'implémentation est désormais disponible. La procédure d'activation et de migration
des bots existants se trouve dans [le guide de migration](private-bot-network-migration.md).

## Ce qui est supporté

Le provider Scaleway 2.84.0 présent dans le projet expose déjà
`private_network_id`, `enable_private_endpoint`,
`enable_default_public_endpoint` et `private_endpoint`.
L'API Containers v1 expose les mêmes options de création/mise à jour.

Pour un bot, les paramètres à tester sont :

```json
{
  "private_network_id": "UUID_DU_PRIVATE_NETWORK",
  "enable_private_endpoint": true,
  "enable_default_public_endpoint": false,
  "privacy": "public"
}
```

Le conteneur API peut être rattaché à un Private Network du même VPC en gardant
son accès public, nécessaire au frontend et aux callbacks des workers. Les
endpoints privés peuvent recevoir des appels des réseaux du même VPC ; il ne
faut pas confondre VPC, Private Network et frontière IAM.

Le VPC par défaut du projet peut être retenu, après avoir recensé les réseaux,
routes et ACL existants. Ne pas remplacer les ACL de ce VPC partagé sans
préserver les autres flux. Aucune création de Public Gateway n'est nécessaire
pour l'expérience. Son absence ne prouve pas que les conteneurs serverless
n'ont pas de sortie Internet : leur trafic public et privé emprunte des chemins
gérés différemment par Scaleway. Le témoin fournit les mesures réelles à collecter.

## Changements applicatifs avant migration de tous les bots

L'adaptateur utilise désormais le réseau privé et son endpoint. Les changements
implémentés et à vérifier en conditions réelles couvrent :

- OpenTofu : sélection du VPC existant, PN de l'API et des bots, rattachement API ;
- provisioning : flags d'endpoints et PN attendu pour chaque bot ;
- checkpoint/reconciliation : identité du PN et endpoint privé observé ;
- transport de validation ET transport des parties : usage de `private_endpoint` ;
- TLS : confiance dans la CA des endpoints privés, vérification du nom d'hôte,
  aucune désactivation de vérification de certificat ;
- invocation : aucun header IAM transmis aux bots, politique `privacy=public`
  avec endpoint public désactivé, révocation de la clé invoker historique ;
- rollback, reprise des publications et révisions existantes : ne pas réintroduire
  un endpoint public après une panne.

La CA est disponible via
`GET /containers/v1/regions/{region}/private-endpoint-ca`.
Le witness doit confirmer l'absence de credentials et l'isolation réseau réelle.
Les Jobs de publication peuvent continuer à copier les images et à appeler
l'API publique ; l'API reste l'acteur qui invoque les bots sur le réseau privé.

## Isolation entre bots

Un Private Network commun laisse les ressources communiquer entre elles.
Les Network ACLs Scaleway filtrent les flux entre Private Networks, pas les
flux internes au même PN ni le trafic Internet. Les règles sont stateless et
IPv4/IPv6 sont configurés séparément.

Pour viser une isolation réseau entre bots, étudier un PN par bot et un PN API,
avec un refus par défaut entre les réseaux bots, les seuls flux API→bot nécessaires
et les retours explicitement autorisés. Cette proposition doit être validée sur
les endpoints privés réels : les IP des instances serverless sont dynamiques.
Une règle autorisant des ports de retour n'est pas un pare-feu stateful.
Le nombre de PN et la limite de règles ACL doivent entrer dans le dimensionnement.

Les bots n'ont pas besoin d'une clé IAM pour deviner ou scanner des adresses à
partir de leur propre sous-réseau. Ne pas miser sur le secret des IP. Le témoin
ne fait aucun scan : les tests bot→bot doivent utiliser un second bot contrôlé
et une destination explicite.

## Headers du frontend

La chaîne actuelle Object Storage website → cache Edge → TLS ne possède pas
de stage de réécriture arbitraire des headers de réponse dans le provider/API
consultés. `Cache-Control` est configurable ; une métadonnée S3 arbitraire
`x-amz-meta-*` ne devient pas un vrai header CSP/HSTS/etc.

Pour définir tous les headers HTTP de sécurité, prévoir un origin HTTP qui les
émet (par exemple un frontend statique servi par nginx) ou un CDN offrant une
politique de headers de réponse. Une CSP ou referrer policy en balise meta peut
couvrir une partie du besoin, mais pas HSTS ni toutes les directives CSP.
Aucune modification des headers frontend ni de la topologie de production
n'a été appliquée pendant cette investigation.

## Sources officielles

- https://www.scaleway.com/en/docs/serverless-containers/reference-content/containers-private-networks/
- https://www.scaleway.com/en/developers/api/serverless-containers/containers
- https://www.scaleway.com/en/docs/serverless-containers/how-to/secure-a-container/
- https://www.scaleway.com/en/developers/api/serverless-containers/~endpoints
- https://www.scaleway.com/en/docs/vpc/reference-content/understanding-nacls/
- https://www.scaleway.com/en/docs/vpc/reference-content/understanding-routing/
- https://www.scaleway.com/en/developers/api/edge-services
- https://feature-request.scaleway.com/posts/1011/add-response-headers-on-edge-service

Bot et protocole de mesure : `bots/network-witness/README.md`.
Une image Docker locale et des tests locaux ne certifient pas le fonctionnement
sur Scaleway ; il reste à publier le témoin puis effectuer la matrice de mesures.
