# Shared CI/CD for Uplift services

One place to change how services deploy. Before this existed, task-definition
logic lived in every service repo in one of five different shapes, duplicated
again inside each `scripts/deploy.sh` — so a single cross-cutting change (Traefik
router labels, secret backend, log config) had to be written ~10 times and drifted
every time.

## What lives here

| Path | What it is |
|---|---|
| `.github/workflows/ecs-deploy.yml` | Reusable workflow — task definition, Traefik labels, secrets, rollout, rollback, release tag |
| `.github/workflows/homelab-deploy.yml` | Reusable workflow — the home tier on `uplift-server-01`: branch gate, ssh deploy call, smoke test, release tag |
| `.github/actions/ecr-build-push/` | Composite action — ECR login, image tag, native build, push |
| `.github/actions/ecr-build-push-home/` | Composite action — the home-tier build: OIDC credentials, `linux/amd64`, `uat-<sha>` + `:uat`, local buildx cache |
| `.github/actions/uplift-version-bump/` | Composite action — next `vX.Y.Z` from git tags (the upliftcontrolversion convention) |

## Division of labour

```
caller repo   →  language setup, gates (lint/typecheck/tests), docker build, ECR push
this repo     →  task definition, Traefik labels, secrets, deployment config,
                 rollout, wait-for-stable, smoke test, automatic rollback
```

Build stays in the caller because it genuinely differs per language (Bun, Go,
Next.js, Prisma migrations). Everything below the image URI is identical
everywhere, so it lives here.

## Usage

```yaml
name: Deploy
on:
  push: { branches: [main] }
  workflow_dispatch:

concurrency:
  group: deploy-<service>-prod
  cancel-in-progress: false

jobs:
  build:
    runs-on: [self-hosted, linux, arm64, uplift-deploy]
    permissions: { contents: read, packages: read }
    outputs:
      image: ${{ steps.build.outputs.image }}
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }

      # ... repo-specific gates: install, typecheck, tests ...

      # Compute the version BEFORE the build so a frontend can bake it into the
      # bundle. Backends only need it at runtime, but computing it here keeps one
      # shape for both.
      - id: ver
        uses: uplift-technology-company-limited/.github/.github/actions/uplift-version-bump@v1
        with:
          bump: ${{ inputs.bump }}

      - id: build
        uses: uplift-technology-company-limited/.github/.github/actions/ecr-build-push@v1
        with:
          ecr_repo: <ecr-repo>
          aws_region: ${{ vars.AWS_REGION }}
          github_token_secret: "true"   # if the Dockerfile pulls @uplift-*/ packages
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

  deploy:
    needs: build
    permissions:
      contents: write        # required to push the release tag
    uses: uplift-technology-company-limited/.github/.github/workflows/ecs-deploy.yml@v1
    with:
      service:        <ecs-service>
      image:          ${{ needs.build.outputs.image }}
      container_port: <port>
      public_host:    <host>.uplifttech.co   # omit entirely for internal-only
      # public_host_aliases: other.example.co   # extra hostnames OR-ed onto the SAME router
      version:        ${{ needs.build.outputs.version }}
      release_tag:    ${{ needs.build.outputs.tag }}
    secrets: inherit
```

> **Pin `@v1`, never `@main`.** A bug in a workflow referenced by `@main` breaks
> every repo's deploy at once. Tags are moved deliberately, after a pilot repo
> has deployed successfully.

## The home tier: `homelab-deploy.yml`

`ecs-deploy.yml` deploys to ECS. `homelab-deploy.yml` deploys the UAT and dev
tiers that run on `uplift-server-01`, a home x86_64 box that also hosts a
self-hosted runner (`[self-hosted, uplift-server-01]`).

**Reach for it instead of `ecs-deploy.yml` whenever the target is that box.** The
two are not variants of each other and share no code, because on the home box CI
is deliberately powerless. The runner user (`ghrunner`) drives its own *rootless*
dockerd — a different image store from the system docker that runs the services —
is not in group `docker`, and is firewalled off from loopback, the LAN and the
docker bridges. It cannot see a running container, never mind restart one. There
is no task definition to register, nothing to roll back to, and no AWS API to
call.

The one channel from CI to the running services is ssh to the box's tailscale
address, landing on a restricted user whose key pins a **forced command**. That
command runs a root-owned script which validates its input and does, for exactly
one service:

```
docker compose -f /srv/stacks/<tier>/<service>.yml pull && up -d
```

The compose files are owned by a GitOps agent reconciling them from the `infra`
repo. **CI cannot edit them, and that is the point** — a compromised or careless
workflow cannot rewrite what the box runs, only ask it to re-pull a service it
already knows about. Because CI cannot edit the compose file, the compose file
pins the moving `:uat` tag and the box pulls it; **no image reference is ever
sent to the box**. Do not add one.

### Division of labour

```
caller repo   →  language setup, gates, build + push to the HOME-TIER ECR repo
this workflow →  branch gate, ssh deploy call, smoke test, release tag
```

### Usage

```yaml
name: Deploy UAT
on:
  push: { branches: [uat] }
  workflow_dispatch:

concurrency:
  group: deploy-<service>-uat
  cancel-in-progress: false

jobs:
  build:
    runs-on: [self-hosted, uplift-server-01]
    permissions:
      contents: read
      packages: read
      id-token: write          # required — the home runner has no AWS identity
    outputs:
      version: ${{ steps.ver.outputs.version }}
      tag:     ${{ steps.ver.outputs.tag }}
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }

      # ... repo-specific gates: install, typecheck, tests ...

      - id: ver
        uses: uplift-technology-company-limited/.github/.github/actions/uplift-version-bump@v1

      - uses: uplift-technology-company-limited/.github/.github/actions/ecr-build-push-home@v1
        with:
          ecr_repo:     <service>-uat          # NEVER a production repository
          aws_region:   ${{ vars.AWS_REGION }}
          aws_role_arn: ${{ vars.HOME_DEPLOY_ROLE_ARN }}
          cache_dir:    /var/lib/ghrunner-cache/<service>
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

  deploy:
    needs: build
    permissions:
      contents: write        # required to push the release tag
    uses: uplift-technology-company-limited/.github/.github/workflows/homelab-deploy.yml@v1
    with:
      service:     <service>
      tier:        uat
      public_host: <service>-uat.uplifttech.dev
      version:     ${{ needs.build.outputs.version }}
      release_tag: ${{ needs.build.outputs.tag }}
    secrets: inherit
```

The workflow needs three secrets — `DEPLOY_HOST` (the tailscale address, as
`user@host`, since the runner user is not the deploy user), `DEPLOY_SSH_KEY` and
`DEPLOY_HOST_KEY` (the box's public host key as a `known_hosts` line). They are
declared explicitly in the workflow rather than left to `inherit` alone, so the
contract is readable from the file.

> **Pin `@v1`, never `@main`** — the same rule as everywhere else in this repo.

### Things the home tier gets right that are easy to get wrong

- **The build pushes to a SEPARATE ECR repository under a `uat-` tag prefix.**
  `ecr-build-push` tags `:<short-sha>` and `:latest`; production builds arm64
  from `main` and the home tier builds amd64 from `uat`, so pointed at one
  repository the same commit's two architectures overwrite each other's `:<sha>`
  and contest `:latest` outright. That hands production an amd64 image that will
  not start on Graviton. Hence a second action and a second repository, not new
  inputs on the existing one.
- **The home runner has no AWS identity.** No instance profile, no metadata
  endpoint. `ecr-build-push-home` assumes a role through OIDC, so the calling job
  must grant `id-token: write`.
- **The buildx cache is `type=local` on NVMe, not `type=gha`.** The GHA cache
  backend is a download and (with `mode=max`) a full re-upload of every layer
  over a domestic ISP — the upload leg alone spends the entire reason for
  building on a 12-thread machine.
- **`tier` is validated against an allowlist of exactly `uat` and `dev`.** It is
  interpolated into the command sent over ssh; the far side validates too, but a
  workflow that can send arbitrary strings down a deploy channel is one typo from
  being an injection primitive.
- **Plain `ssh`, not `appleboy/ssh-action`.** The far side is a forced command,
  so the payload arrives as `$SSH_ORIGINAL_COMMAND` and its exact bytes are
  matched by a regex. An action that wraps the command in its own shell preamble
  sends something that regex rejects, and it fails looking like an auth problem.
- **The host key is pinned; `StrictHostKeyChecking=no` is never used.** A deploy
  channel that accepts any host key accepts a machine-in-the-middle, and we hold
  the real fingerprint.
- **The smoke test matches the version string in the body, not just a 200.**
  After a silent rollback or a no-op pull the old revision answers 200
  identically, for as long as you care to poll it. Matching the version is what
  proves the revision that just built is the one serving.

## Configuration lives in org variables, not in this repo

This repository is **public**. No account id, cluster name, region or hostname is
hardcoded anywhere in it. They come from organisation-level Actions variables,
which resolve against the *calling* repository's org:

| Variable | Purpose |
|---|---|
| `AWS_REGION` | Region for every AWS call |
| `AWS_ACCOUNT_ID` | Used to build ECR and SSM ARNs |
| `ECS_CLUSTER` | Target cluster |
| `INTERNAL_DOMAIN` | Suffix for the internal mesh hostname |
| `SSM_PREFIX` | Root of the Parameter Store hierarchy |

## Secrets: Parameter Store, addressed by path

`ecs-deploy` reads `<SSM_PREFIX>/<service>` recursively and generates the task
definition's `secrets` block from it. The env var name is the last path segment:

```
/uplift/account/DATABASE_URL   →   DATABASE_URL
/uplift/account/SERVICE_TOKEN  →   SERVICE_TOKEN
```

**Adding or rotating a secret is `aws ssm put-parameter` and a redeploy — no code
change, no pull request.**

One value per parameter: Parameter Store cannot address a single key inside a JSON
document the way Secrets Manager's `secret:name:KEY::` form can.

**Zero parameters at the path is not an error.** The live task definition's existing
`secrets` block is inherited unchanged, which is what makes repo-by-repo adoption
safe — a repo can move to this workflow before its secrets have been migrated.

The task **execution role** needs `ssm:GetParameters` on the path and `kms:Decrypt`
on the `aws/ssm` key.

## Plain environment

`environment` takes a JSON object upserted over whatever the live task definition
already carries:

```yaml
      environment: >-
        {"NODE_ENV":"production","OTEL_ENDPOINT":"http://tempo.internal.example:4318"}
```

Inheritance alone preserves such values but cannot **self-heal** one that went
missing, and gives no declarative way to change it. Several repos had grown a
hand-written "render task definition + re-assert config" step for exactly this
reason; that belongs here instead. Keys not listed are left untouched, so it
composes with inheritance rather than replacing it.

Secrets go through `ssm_path` / `shared_secrets`, never here — this block ends up
in plain `environment`, which is readable by anyone who can describe the task
definition.

## Versioning

`uplift-version-bump` encodes the upliftcontrolversion convention so it lives in
one place rather than ~20 hand-copied lines per repo:

- **The git tag is the source of truth**, not `package.json` — a tag created by
  the deploy itself cannot lie about what shipped.
- **`sort -V`, not `git describe --abbrev=0`.** Describe is topology-nearest and
  on a merge-heavy history can pick a lower base, producing a version that goes
  backwards.
- **Patch auto-bumps on every deploy** (a build counter); minor/major are for
  meaningful releases.
- **The tag is pushed only after the rollout AND the smoke test pass**, by
  `ecs-deploy` itself. A failed deploy therefore leaves no orphan tag and does
  not burn the counter.

The caller needs `fetch-depth: 0` on its checkout — the default shallow clone has
no tags, and versions would silently restart from `v0.0.1` forever. The action
warns if it detects that shape.

`version` feeds `APP_VERSION` and `OTEL_SERVICE_VERSION` in the task definition,
so telemetry and `/version` cannot drift from what actually shipped.

## Things this workflow gets right that are easy to get wrong

- **Containers are selected by name, not index.** Services with a firelens
  `logrouter` sidecar have the app at a non-zero index; patching `[0]` corrupts them.
- **Every Traefik router names its service explicitly.** Traefik's ECS provider only
  auto-links router→service when the container defines exactly one service. Adding a
  second (the internal-mesh router) makes every router lacking an explicit `.service`
  silently 404 — this took down ~11 public hosts at once on 2026-07-26.
- **`maximumPercent=200 / minimumHealthyPercent=100` is enforced.** At `100/0` ECS
  drains the old task before starting the new one; `samoe-dashboard` was down ~5
  minutes that way. Disable via `ensure_deployment_config: false` only for services
  pinned to a fixed host port, where two tasks cannot coexist.
- **`update-service` always passes `--task-definition`.** `--force-new-deployment`
  alone just redeploys the revision the service already points at.
- **Task definitions are inherit-and-patch, not rebuilt from scratch.** Roles,
  network mode, log config, sidecars and plain env survive; a heredoc that rebuilds
  the definition silently drops whatever it forgot.
- **Failure rolls back automatically** to the previously-live task definition.

## Adding a new service

1. `aws ssm put-parameter` each secret under `/uplift/<service>/<KEY>` as `SecureString`.
2. Grant the task execution role `ssm:GetParameters` + `kms:Decrypt`.
3. Copy the usage block above into `.github/workflows/deploy.yml`.

## Running off the EC2 runner (OIDC)

The example above has **no credential step anywhere**, and that is not an
omission: `ecr-build-push` and `ecs-deploy.yml` use whatever identity the runner
already holds, which on `[self-hosted, linux, arm64, uplift-deploy]` is the EC2
instance role. It is ambient, invisible in the YAML, and the reason moving these
jobs to any other runner makes every deploy fail outright rather than slowly.

To run them on a runner with no AWS identity of its own — `uplift-server-01`, or
a GitHub-hosted runner — pass `aws_role_arn` and both will authenticate through
GitHub OIDC instead. Leave it unset and nothing changes at all: the credential
step is skipped and the ambient chain is used exactly as before.

```yaml
jobs:
  build:
    runs-on: ${{ fromJSON(vars.BUILD_RUNNER || '["self-hosted","uplift-server-01"]') }}
    permissions:
      contents: read
      packages: read
      id-token: write        # REQUIRED whenever aws_role_arn is passed
    steps:
      - id: build
        uses: uplift-technology-company-limited/.github/.github/actions/ecr-build-push@v1
        with:
          ecr_repo:     <ecr-repo>
          aws_region:   ${{ vars.AWS_REGION }}
          aws_role_arn: ${{ vars.AWS_DEPLOY_ROLE_ARN }}

  deploy:
    needs: build
    permissions:
      contents: write        # required to push the release tag
      id-token: write        # REQUIRED — see below
    uses: uplift-technology-company-limited/.github/.github/workflows/ecs-deploy.yml@v1
    with:
      # ... the usual inputs ...
      aws_role_arn:  ${{ vars.AWS_DEPLOY_ROLE_ARN }}
      runner_labels: '["self-hosted","uplift-server-01"]'
```

Three things bite here, in order of how much time they cost:

1. **`id-token: write` must be granted by the CALLER.** Neither a composite action
   nor a called workflow can grant it to itself. Without it the token request
   fails with a bare 400 that reads like an AWS trust-policy problem and is not.

2. **Listing `permissions:` at all resets every unlisted one to none.** So on the
   `deploy` job, `id-token: write` has to be added *next to* the `contents: write`
   the release-tag step needs — replacing it silently breaks tagging instead.

3. **The role's trust policy must name the repo.** `github-actions-deploy` trusts
   an explicit list; a repo that is not on it gets `AssumeRoleWithWebIdentity`
   denied. Add repos pinned to a ref (`repo:ORG/NAME:ref:refs/heads/main`) rather
   than `:*`, which would let any PR branch assume a role that can deploy.

The ARN comes from an org variable because **this repository is public** — never
inline an account id or role ARN here.
