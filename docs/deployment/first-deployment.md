# Premier déploiement depuis le poste

Ces commandes sont à exécuter manuellement, dans un même terminal, depuis la
racine `axo-clash`. Elles créent des ressources facturées. Elles n'ont pas été
exécutées sur Scaleway par cette livraison. Prérequis : OpenTofu >= 1.11,
AWS CLI v2, Docker avec Buildx, Java 25, Maven, Python 3 et Node/pnpm.
Docker doit être démarré. Buildx construit le runtime JVM linux/amd64 avec
`jlink`, y compris depuis un Mac ARM.

## 1. Configuration locale

Remplir `application-backend/infrastructure/credentials.env` et les deux
`infrastructure/terraform.tfvars` à partir des exemples. Dans le tfvars backend,
ajouter les identifiants Entra utilisés par le frontend :

```hcl
api_secret_environment_variables = {
  AZURE_TENANT_ID = "<tenant-id>"
  AZURE_CLIENT_ID = "<client-id>"
}
```

Le tfvars frontend sélectionne `frontend_bucket_name = "axo-clash-front-os"`.
Renseigner également `frontend_bucket_management_principals` avec l'identité
IAM propriétaire de la clé OpenTofu (`user_id:<UUID>` ou `application_id:<UUID>`),
et celle de la clé d'upload GitHub si elle diffère. Ces UUID sont ceux des
utilisateurs/applications IAM, pas la clé d'accès ni l'ID du projet. La policy
rend les fichiers du site lisibles anonymement et conserve les opérations
signées uniquement pour ces identités, sous réserve de leurs droits IAM.
Laisser `invocation_header_stripping_verified = false` avant le test réel
d'en-têtes du runbook. Ne jamais activer ce contrôle simplement pour contourner
une publication refusée. Ce premier déploiement lance l'API et le frontend ;
l'activation de bots attend cette preuve.

```sh
AXO_ROOT="$PWD"
source "$AXO_ROOT/application-backend/infrastructure/credentials.env"
export SCW_DEFAULT_PROJECT_ID='<project-id identique aux deux tfvars>'
export AWS_ACCESS_KEY_ID="${SCW_ACCESS_KEY}@${SCW_DEFAULT_PROJECT_ID}"
export AWS_SECRET_ACCESS_KEY="$SCW_SECRET_KEY"
export AWS_DEFAULT_REGION=fr-par
export AWS_PAGER=''
SCW_S3_ENDPOINT='https://s3.fr-par.scw.cloud'
AXO_STATE_BUCKET='axo-clash-tfstate'
umask 077
```

Le suffixe `@<project-id>` sélectionne explicitement le projet pour les appels
S3, indépendamment du projet préféré de la clé IAM. Il ne s'applique pas à
`SCW_ACCESS_KEY` utilisé par le provider.

## 2. Bucket privé des states et initialisation

Créer le bucket une seule fois, hors des deux stacks qui y stockeront leur
state. S'il existe déjà, vérifier son projet et ses permissions et sauter
uniquement la commande `create-bucket`. Ne pas ignorer une erreur de création.
Le bucket des states reste privé et distinct du bucket frontend.

```sh
aws s3api create-bucket --bucket "$AXO_STATE_BUCKET" --region fr-par \
  --create-bucket-configuration LocationConstraint=fr-par \
  --acl private --endpoint-url "$SCW_S3_ENDPOINT"

aws s3api put-bucket-versioning --bucket "$AXO_STATE_BUCKET" \
  --versioning-configuration Status=Enabled \
  --endpoint-url "$SCW_S3_ENDPOINT"

tofu -chdir=application-backend/infrastructure init -migrate-state

tofu -chdir=application-frontend/infrastructure init -migrate-state
```

Le bucket, la région et les clés sont déclarés directement dans chaque
`backend.tf`. Si le nom du bucket change, le modifier dans ces deux fichiers
avant `init`. Les clés sont `prod/api/terraform.tfstate` et
`prod/frontend/terraform.tfstate`. Chaque state possède son verrou S3
(`use_lockfile=true`). Si un state local existe, sauvegarder ce fichier avant
`init` et examiner la proposition de migration ; OpenTofu demande confirmation.
Sur un premier déploiement vide, le state sera écrit lors du premier apply.
Les clés d'accès viennent de l'environnement, jamais du fichier backend.

Références : [backend Scaleway épinglé](https://github.com/scaleway/terraform-provider-scaleway/blob/v2.84.0/docs/guides/backend_guide.md),
[backend S3 OpenTofu](https://opentofu.org/docs/language/settings/backends/s3/),
[sélection du projet S3](https://www.scaleway.com/en/docs/iam/api-cli/using-api-key-object-storage/).

## 3. Bootstrap des deux registries

Le ciblage est réservé à ce bootstrap : l'API et les Jobs ne peuvent pas être
créés avant que leurs images existent. Examiner le plan puis appliquer le plan
sauvegardé ; ne pas ajouter `-auto-approve`.

```sh
tofu -chdir=application-backend/infrastructure plan \
  -target=module.registries -out=registries.tfplan
tofu -chdir=application-backend/infrastructure show registries.tfplan
tofu -chdir=application-backend/infrastructure apply registries.tfplan

AXO_REGISTRY="$(tofu -chdir=application-backend/infrastructure output -raw registry_api_endpoint)"
printf '%s' "$SCW_SECRET_KEY" | docker login "$AXO_REGISTRY" \
  --username nologin --password-stdin
```

## 4. Construire et pousser API et worker

Le script `scripts/build-image.sh` produit un JAR Java 25 avec le profil prod,
puis construit une image linux/amd64 avec un runtime `jlink`. `jdeps` détermine
les modules requis ; les modules utilisés dynamiquement pour TLS, JDBC et
l'introspection sont ajoutés explicitement. Le runtime Alpine contient seulement
le runtime Java, les certificats et l'application en couches Spring Boot.
L'application utilise un utilisateur non-root. Le script construit localement ;
la commande `docker push` reste explicite.

Le test `smoke-image.py` démarre cette image avec un PostgreSQL jetable,
exécute les migrations et vérifie la santé, les paramètres publics et le rejet
HTTP 400 d'une pagination invalide. Le réseau Docker est interne, sans accès aux
ressources cloud. Ce test doit passer avant le push. Les logs sont conservés
après le nettoyage des conteneurs et du réseau de test.

Le premier déploiement publie l'état courant des fichiers locaux, même s'il
reste des changements non commités. Le tag horodaté est uniquement un repère ;
le déploiement sera épinglé aux digests obtenus après le push.

```sh
AXO_RELEASE="bootstrap-$(date -u +%Y%m%dT%H%M%SZ)"
AXO_API_TAG="$AXO_REGISTRY/api:$AXO_RELEASE"
AXO_WORKER_TAG="$AXO_REGISTRY/publication-worker:$AXO_RELEASE"

cd "$AXO_ROOT/application-backend"
mvn -Pprod clean verify
bash scripts/build-image.sh "$AXO_API_TAG"
python3 scripts/smoke-image.py "$AXO_API_TAG" --logs /private/tmp/axo-image-smoke.log
docker push "$AXO_API_TAG"

docker buildx build --platform linux/amd64 --provenance=false --sbom=false \
  --push --tag "$AXO_WORKER_TAG" publication-worker

AXO_API_DIGEST="$(docker buildx imagetools inspect "$AXO_API_TAG" --format '{{.Manifest.Digest}}')"
AXO_WORKER_DIGEST="$(docker buildx imagetools inspect "$AXO_WORKER_TAG" --format '{{.Manifest.Digest}}')"
export AXO_API_IMAGE="$AXO_REGISTRY/api@$AXO_API_DIGEST"
export AXO_WORKER_IMAGE="$AXO_REGISTRY/publication-worker@$AXO_WORKER_DIGEST"
cd "$AXO_ROOT"

python3 - <<'PY'
import os, re
from pathlib import Path
p = Path('application-backend/infrastructure/terraform.tfvars')
values = p.read_text()
for key, env in [('api_image', 'AXO_API_IMAGE'), ('worker_image', 'AXO_WORKER_IMAGE')]:
    image = os.environ[env]
    if not re.search(r'@sha256:[0-9a-f]{64}$', image):
        raise SystemExit('Digest invalide pour ' + key)
    values, count = re.subn(r'^' + key + r'\s*=.*$', key + ' = \"' + image + '\"', values, flags=re.M)
    if count != 1:
        raise SystemExit('Il faut exactement une affectation pour ' + key + ' dans terraform.tfvars')
p.write_text(values)
p.chmod(0o600)
PY
```

Le script met uniquement à jour `api_image` et `worker_image` dans le fichier
`terraform.tfvars` ignoré par Git. Toutes les variables backend doivent y être
renseignées explicitement à partir de l'exemple : aucune valeur par défaut n'est
cachée dans `variables.tf` ou les modules. Aucun override JDBC n'est accepté.
OpenTofu génère un token de 256 bits (`random_bytes.worker_token`), le conserve
sur le state et injecte la même valeur dans l'API et les deux Jobs, via Secret
Manager pour ces derniers. Aucun token n'est à saisir ou générer dans un script.
Si l'ancienne procédure a créé `runtime.auto.tfvars.json`, reporter ses digests
dans `terraform.tfvars` puis retirer ce fichier avant le plan pour éviter des
valeurs implicites et l'ancienne variable de token supprimée.

Pour une rotation explicite, utiliser `tofu plan -replace=random_bytes.worker_token`
puis appliquer le plan sauvegardé ; l'API et les deux Jobs reçoivent alors la
nouvelle valeur. Les versions Secret Manager sont mises à jour automatiquement.

## 5. Déployer le backend complet

```sh
tofu -chdir=application-backend/infrastructure plan -out=backend.tfplan
tofu -chdir=application-backend/infrastructure show backend.tfplan
tofu -chdir=application-backend/infrastructure apply backend.tfplan

AXO_API_ENDPOINT="$(tofu -chdir=application-backend/infrastructure output -raw api_container_endpoint)"
export VITE_API_URL="${AXO_API_ENDPOINT%/}/api/v1"
curl --fail --show-error --silent --retry 6 --retry-delay 10 \
  --retry-all-errors --max-time 90 "${AXO_API_ENDPOINT%/}/actuator/health"
```

Un endpoint de health valide le démarrage ; il ne prouve pas encore publication,
WSS, contrats bots ou comportement du fournisseur. En cas d'échec, lire les
logs API dans Cockpit avant de continuer. Le runbook détaille ces validations.

## 6. Déployer le frontend puis ses fichiers

```sh
tofu -chdir=application-frontend/infrastructure plan -out=frontend.tfplan
tofu -chdir=application-frontend/infrastructure show frontend.tfplan
tofu -chdir=application-frontend/infrastructure apply frontend.tfplan

AXO_FRONT_BUCKET="$(tofu -chdir=application-frontend/infrastructure output -raw frontend_bucket_name)"
export VITE_AZURE_TENANT_ID='<même tenant-id que le backend>'
export VITE_AZURE_CLIENT_ID='<même client-id que le backend>'

cd "$AXO_ROOT/application-frontend"
pnpm install --frozen-lockfile
pnpm check
pnpm lint
pnpm test
pnpm build

aws s3 sync build "s3://$AXO_FRONT_BUCKET" --delete --exclude '*.html' \
  --cache-control 'public,max-age=31536000,immutable' \
  --endpoint-url "$SCW_S3_ENDPOINT"
find build -type f -name '*.html' -print0 | while IFS= read -r -d '' file; do
  aws s3 cp "$file" "s3://$AXO_FRONT_BUCKET/${file#build/}" \
    --cache-control 'no-cache,no-store,must-revalidate' \
    --content-type 'text/html; charset=utf-8' --endpoint-url "$SCW_S3_ENDPOINT"
done

cd "$AXO_ROOT"
tofu -chdir=application-frontend/infrastructure output frontend_edge_endpoint
```

Le premier upload ne nécessite pas de purge d'un cache préexistant. Ajouter
l'origine HTTPS du frontend avec `/auth/callback` aux redirections SPA de
l'application Entra, vérifier l'accueil et une route profonde, puis la connexion.
Le paramétrage GitHub et les validations de publication/WSS restent décrits dans
`application-backend/docs/deployment/scaleway-runbook.md`. Le bucket des states,
créé hors des deux stacks, ne sera pas détruit par leur destruction.
