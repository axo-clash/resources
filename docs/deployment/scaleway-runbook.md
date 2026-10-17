# Scaleway deployment runbook

This runbook prepares a deployable configuration. It deliberately stops before
cloud mutation. The operator supplies an existing Project UUID, protected
credentials and already owned domains when those are needed.

## Bootstrap and local review

For the complete first rollout with two independent S3 states and native S3
locking, follow `docs/deployment/first-deployment.md` in the workspace root.
CI validation keeps `init -backend=false`; real deployment initializes the
S3 backend configured directly in `backend.tf` before planning.

1. Create the private versioned Object Storage state bucket and initialize the S3 backend as described in the first-deployment guide. The stack is
   under `application-backend/infrastructure/`. Do not put
   `terraform.tfvars`, provider credentials, API keys, registry passwords or
   worker tokens in Git.
2. Copy `application-backend/infrastructure/terraform.tfvars.example` to a protected tfvars file.
   Set `project_id`, `organization_id`, `region = "fr-par"`, immutable API and
   worker image digests, and every sizing/environment input explicitly from the
   example. OpenTofu generates the worker token and injects it into the API and
   both Jobs; no token or JDBC override is a root input. The backend stack does not own frontend Object Storage or Edge
   resources; configure those separately in
   `application-frontend/infrastructure/`.
3. Because the first full graph requires image digests that do not exist until
   the private namespaces exist, bootstrap only those prerequisites with a
   reviewed targeted plan/apply (for example, `-target=module.registries` and
   `-target=module.iam`). Do not use targets for the steady-state rollout:
   build and push both images, capture their immutable digests, update the
   tfvars, then run a full `tofu plan` and full `tofu apply`. Targets are an
   operator bootstrap step and were not executed by this delivery.
4. Run `tofu fmt -check -recursive`, `tofu init -backend=false` and `tofu
   validate` from `application-backend/infrastructure/`. These checks do not
   apply resources.
5. Configure CI variables for the protected tfvars and the IAM bootstrap
   credential. Use a short-lived operator token where the provider supports it;
   rotate all generated keys after bootstrap.

The frontend stack is bootstrapped independently from
`application-frontend/infrastructure/`. Its local checks are documented in
that stack's README and its workflow runs `fmt`, `init -backend=false` and
`validate` only. Set `VITE_API_URL` manually from the deployed backend endpoint
(`api_container_endpoint` with `/api/v1`), rather than coupling the two local
states.

## Image before container

The API and worker images must be built for `linux/amd64`, pushed to the
private `api` namespace, and addressed by their resulting `@sha256:` digest
before any container or Job is created. The publication worker itself copies
untrusted public source images into the private `bots` namespace, using the
stable repository `bot-<botId>` and the immutable revision tag. The importer
refuses credentials in source references, private or special-use DNS results,
oversized layers, unsupported platforms, and overwriting a destination tag with
a different digest.

The API image digest is set in `api_image`; the worker image digest is set in
`worker_image`. A changed digest is a revision event. Keep the old digest and
destination tag until active game reservations are released and rollback has
been verified.

The production GitHub environment used by
`.github/workflows/build-and-publish.yml` needs these protected values:

| Kind | Name | Purpose |
| --- | --- | --- |
| variable | `SCW_REGION` | `fr-par` provider region |
| variable | `SCW_API_REGISTRY_ENDPOINT` | endpoint of the private `api` registry namespace |
| variable | `SCW_API_CONTAINER_ID` | existing managed API Container UUID |
| variable | `SCW_API_SMOKE_URL` | HTTPS health URL, with no secret in the URL |
| variable | `SCW_PUBLICATION_JOB_DEFINITION_ID` | existing publication-import Job definition UUID from the `publication_job_definition_id` OpenTofu output |
| variable | `SCW_GAME_JOB_DEFINITION_ID` | existing game-keepalive Job definition UUID from the `game_keepalive_job_definition_id` OpenTofu output |
| secret | `SCW_REGISTRY_PUSH_SECRET_KEY` | protected registry push credential used only by CI |
| secret | `SCW_CONTAINER_MANAGER_SECRET_KEY` | manager credential for the v1 Container and alpha2 Job image patch/redeploy |

Scaleway fr-par may expose PN resources late during container startup. The prod
profile retries Flyway JDBC connections ten times, with a maximum five-second
backoff interval. The smoke test pauses its disposable database for 35 seconds
and requires actual connection retries before validating AOT and verified TLS.
This handles transient startup failures; it does not prove or repair the cloud
routing path. See [Scaleway PN startup troubleshooting](https://www.scaleway.com/en/docs/serverless-containers/troubleshooting/container-private-network-connectivity/).

The workflow runs `mvn -Pprod clean verify` before publishing.
`scripts/build-image.sh` generates Spring AOT initialization classes with the
`prod` profile and builds a linux/amd64 JVM image with a Java 25 runtime generated
by `jdeps` and `jlink`. The entrypoint enables `-Dspring.aot.enabled=true`;
startup must report `Starting AOT-processed AxoclashApplication`. This requires
rebuilding and publishing the image, then deploying its new digest: an
infrastructure apply alone cannot add the generated classes to an older image. The final Alpine
image runs as a non-root user and contains the runtime, certificates and layered
Spring Boot application. Before pushing, `smoke-image.py` starts the JVM
against disposable PostgreSQL with certificate-verified TLS on an internal Docker
network, verifies the AOT startup message, runs migrations
and checks health, public settings and Jakarta Validation's HTTP 400 response.
`docker push` only publishes after these checks succeed. It pushes both images
to the Scaleway namespace under `sha-<commit>` and records immutable registry
digests. It patches the API Container to its own digest, waits for it to
become `ready`, performs an explicit redeploy for compatibility with
pre-v1beta1 containers, verifies the returned digest, and calls the smoke URL.
Only after that API rollout does it patch both existing alpha2 Job definitions,
identified by the two protected repository variables above, to the worker
`repository@sha256:<64 hex>`. The workflow does not write OpenTofu state; after
a release, update the `worker_image` and `api_image` inputs with the captured
digests and run the full infrastructure plan/apply so desired state and the
live Job definitions remain aligned.

## Identity and secret matrix

| Identity | Scope | Used by |
| --- | --- | --- |
| `importer` | project Container Registry access (the provider permission set is currently project-wide) | publication Job only |
| `manager` | project Containers/VPC/Registry read/Jobs/Secret Manager | backend API provisioning |
| `axo_clash` SQL user | application PostgreSQL database only, non-admin, DDL for Flyway | API JDBC over verified TLS |

The worker receives only its dedicated backend token and destination registry
write key. It never receives `ContainersPrivateAccess`, the manager key, the
invoker key, a database credential, or a player token. The API container gets
its private JDBC URL, PostgreSQL credential and CA through secret environment
variables. Protect the OpenTofu state because sensitive variables and generated
resource IDs can still be represented there.

The relevant Scaleway permission sets currently scope registry and container
operations at the Project level; this configuration does not pretend to limit
them to one namespace. Keep this Project dedicated to the application where
possible, and rely on the separate API/bots namespaces, backend resource
checks, reservations and the private-network isolation gate. Recheck provider IAM
conditions before enabling this stack in a shared Project.

The API backend must set these protected application properties (or the exact
aliases documented by its deployment profile):

```text
APPLICATION_CLOUD_PROJECT_ID
APPLICATION_CLOUD_REGION=fr-par
APPLICATION_CLOUD_BOTS_NAMESPACE_ID
APPLICATION_CLOUD_BOTS_REGISTRY_NAMESPACE_ID
APPLICATION_CLOUD_BOTS_REGISTRY_ENDPOINT
APPLICATION_CLOUD_MANAGER_SECRET_KEY
APPLICATION_CLOUD_PRIVATE_NETWORKING_ENABLED=true
APPLICATION_CLOUD_BOT_VPC_ID
APPLICATION_CLOUD_API_PRIVATE_NETWORK_ID
APPLICATION_CLOUD_NETWORK_NAME_PREFIX
APPLICATION_CLOUD_PRIVATE_ENDPOINT_CA_PEM
APPLICATION_CLOUD_JOBS_ENABLED=true
```

Bot invocation sends no Scaleway key. Private networking is required for publication.
The IAM privacy policy is `public`, the private endpoint is enabled, and the default
public endpoint is disabled. The manager key authenticates control-plane requests
only; the historical invoker identity is removed and revoked by the infrastructure apply.
See the workspace private-network migration guide for the rollout and witness checks.

## API, database and frontend

Apply the database before the API if a staged rollout is needed. The Serverless
Private PostgreSQL endpoint and verified TLS JDBC URL must be supplied to the API profile with the
runtime identity; do not use a long-lived database password in a normal
environment variable. Confirm the API points at the selected Project and
region, is HTTPS-only, and has `min_scale=0`, `max_scale=1`.
Keep the API request timeout at `3600` seconds (the Serverless Containers
maximum) so a bounded 55-minute game run can keep one request open; the backend
must enforce its own 3300-second run deadline.

The generated JDBC URL appends `sslmode=verify-full` and
`sslfactory=org.postgresql.ssl.DefaultJavaSSLFactory`; keep the IAM application
ID and API key in separate protected JDBC username/password properties. This
preserves hostname verification and prevents the key from being embedded in a
URL or log line. Do not replace this with a plaintext database connection.

The frontend upload is a static Object Storage website managed by the separate
`application-frontend/infrastructure/` stack. Bootstrap that stack, upload the
SPA assets after its bucket exists, set `index.html` as both index and error
document, then publish its Edge pipeline. The error document is required for
client-side deep links. DNS records and custom domain ownership remain an
operator step. Its outputs map to the frontend workflow variables
`FRONTEND_BUCKET_NAME`, `SCW_EDGE_PIPELINE_ID` and the website/Edge endpoint
observability values; no backend state is consumed automatically.

## Publication and game validation

The backend persists a submission, atomically claims it with a lease, and
starts one import Job with contextual variables `WORKER_MODE=import`,
`PUBLICATION_SUBMISSION_ID=<opaque id>` and a fresh `WORKER_ID=<UUID>`; the
game Job receives `WORKER_MODE=game-keepalive`, `GAME_RUN_ID=<opaque id>` and
the same kind of execution ID. Use `replicas=1` for each start. The worker
reports the source and destination digest. The Job API has no definition-level
global concurrency field in the pinned provider schema, so the backend's
database claim/lease is the authoritative global-one guard and every retry
must use that atomic claim.

The publication definition also has a UTC `0 * * * *` trigger (configurable
as `publication_reconcile_cron`). It wakes a generic import worker with no
submission ID so a lost post-commit event or a scale-to-zero API cannot strand
the queue. The trigger's extra latency is up to one hour; the database
claim remains the global concurrency-one guard. A worker that receives an
empty `204` claim response exits successfully, while a claimed submission
continues through the same lease and digest checks.

The backend then uses the manager identity to create or update one private bot
container. Every bot container must be read back from Scaleway with exactly
`memory_limit_bytes=512000000`, `mvcpu_limit=500`, `sandbox=v2`,
`privacy=public`, default public endpoint disabled, private endpoint enabled, `min_scale=0`, and `max_scale=1`.

Before `READY`, the backend reserves the bot, provisions/reuses its dedicated
network and ACLs, makes credential-free `/info` and `/play` calls over private TLS,
and records the private endpoint and observed limits. A failed witness leaves
the revision rejected or unavailable and releases the reservation. Bot
outbound Internet remains possible in this provider mode; do not document it
as blocked.

Cloud/cloud and relay-backed games start the `game-keepalive` Job with a
`GAME_RUN_ID`. The Job makes one HTTP request to the API and remains invoked
until the persisted run is terminal. A detached Java thread or a short polling
loop is not deployment evidence.

## Rollback and purge

The owner can disable new selections with `PATCH /api/v1/bots/{id}/suspension`
and `{ "suspended": true }`; imports and rollbacks never clear this manual flag.
Platform operators use the separate internal operations token and endpoint
(documented in `implementation.md`); an owner cannot undo an operator suspension.

`POST /api/v1/bots/{id}/publications/{publicationId}/rollback` restores a previously
`READY` publication as a new durable submission. It reuses the already copied
internal digest, without resolving the original mutable tag or pulling its source
again, and re-runs the deployment read-back and the full INFO/PLAY contract suite.
Idempotent replay returns the existing submission. Resume new selections only
after the resulting publication is `READY`.

To roll back, first disable new selections for the bot, wait for its active
reservations and long game invocations to finish, then restore the previously
verified image digest and revision metadata through the backend manager. Read
back the container configuration and repeat the private endpoint and isolation checks
before re-enabling it. Keep the rejected digest and audit data for the agreed
retention period; remove registry blobs and old container revisions only after
no reservation, diagnosis, or rollback refers to them.

The generic cron first calls `/internal/publications/reconcile`. This bounded
maintenance inventories only the configured bots namespace, adopts missing DB
checkpoints for known internal bot IDs, and reports unknown IDs without deleting
them. It reserves each known bot before checking its resource, disables it on a
non-transient mismatch, and never promotes an unvalidated image to `READY`.
A failed first-publication container may be removed after
`application.publication.failed-resource-retention` (default `P7D`, minimum one
day), only with no active revision, no pending publication and an exclusive
reservation. `maintenance-batch-size` defaults to 20. Review the explicit OpenTofu inputs
`failed_resource_retention` and `resource_maintenance_batch_size` before apply.
A DELETE acceptance only sets `DELETING`; the provider ID stays persisted until
a later read confirms its disappearance. Untracked bot IDs and configuration
drift are reported as bounded WARN messages, with counts in the cron logs. Validated and rollback
images are retained; registry image purge remains an operator action after
reference/reservation checks. Choose Cockpit log retention explicitly for the
Project before opening third-party submissions; container stdout is managed by
Scaleway, not a local API log file.

For a failed bootstrap, revoke the affected IAM key, rotate the worker token
and registry secret, and remove only resources proven to be owned by this
environment. Keep the frontend stack's `force_destroy = false` in production.
Never use a broad registry purge or Project destroy as cleanup.

## Evidence required before production

Record the provider region, Project ID, image digests, IAM policy IDs, database
endpoint identity, Job IDs, and container IDs. Attach the read-back values for
bot memory/CPU/privacy/sandbox/scale, rejected Internet invocation, accepted
anonymous private invocation, absence of credentials and network isolation, source and destination digest
equality, lease recovery after a killed Job, reservation exclusivity, frontend
deep-link loading, and a real long-running cloud/cloud game. Local OpenTofu
validation and unit tests prove configuration and code paths only; they do not
prove quotas, billing, cold starts, provider IAM behavior or production
liveness.

## Idle resource costs

The API scales to zero after 15 minutes without requests. A recovery Job every
five minutes prevents this; use `publication_reconcile_cron = "0 * * * *"` for
hourly fallback recovery. Publication submission still dispatches immediately;
only lost dispatch recovery may wait up to one hour. Existing protected tfvars
must be updated and applied explicitly: changing the variable default alone does
not replace a configured schedule.

Production Hikari keeps zero minimum idle connections, releases idle connections
after 30 seconds, disables keepalive probes and retires connections after four
minutes. The relay expiry scheduler checks memory before opening a transaction;
it only queries SQL while a relay socket is connected. Expired inactive sessions
are cleaned when a session is created or the API restarts. An open relay keeps
an API invocation active until disconnect or expiry (30 minutes by default).

Managed PostgreSQL remains provisioned and billed while idle. Avoid external
polling of the aggregate `/actuator/health` endpoint, which includes a database
check; use `/actuator/health/liveness` for a process-only probe. The lab refreshes pairing while its page is visible and a
session has not expired, and stops refreshing when hidden or when leaving it.

Reference: [container autoscaling](https://www.scaleway.com/en/docs/serverless-containers/reference-content/containers-autoscaling/).
The [managed PostgreSQL reset procedure](managed-postgres-reset.md) describes the
single-apply replacement and deletion of the former SQL database and its IAM identity.

## Bot INFO timeout

Bot metadata requests to `/info` allow 30 seconds. `/play` retains the game action
budget (2 seconds under standard rules). The engine, relay protocol, local CLI,
connection checker and publication validator apply these separate budgets.
New or updated managed bot containers are configured with a 30-second provider
request limit. Existing bot containers keep their previous provider limit until
their configuration is updated; deploying only the new API image does not change
already-deployed bot containers. Republish the bot or set its request timeout to
30 seconds before testing metadata calls longer than the previous provider limit.
