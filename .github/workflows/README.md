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
| `.github/actions/ecr-build-push/` | Composite action — ECR login, image tag, native build, push |
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
      version:        ${{ needs.build.outputs.version }}
      release_tag:    ${{ needs.build.outputs.tag }}
    secrets: inherit
```

> **Pin `@v1`, never `@main`.** A bug in a workflow referenced by `@main` breaks
> every repo's deploy at once. Tags are moved deliberately, after a pilot repo
> has deployed successfully.

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
