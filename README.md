# stash-infra

Production orchestration for the complete Stash stack. By default, development
builds use sibling checkouts of `stash-db`, `stash-bff`, `stash-ui`, and
`stash-scraper-worker`. PostgreSQL, the API, and the worker remain private;
only the UI is published.

## Architecture

The stack contains five services managed by one Compose project:

| Service | Runtime | Responsibility | Publicly exposed |
| --- | --- | --- | --- |
| `db` | PostgreSQL | Users, products, prices, sessions, and notifications | No |
| `scraper-worker` | Python, FastAPI, Playwright | Downloads and extracts product pages | No |
| `bff` | Node.js | Authentication, watchlists, notifications, and product orchestration | No |
| `price-refresher` | Node.js background process | Periodically refreshes saved products | No |
| `ui` | Next.js | Web application and same-origin API proxy | Yes |

The browser communicates only with the UI. Next.js proxies `/api/*` requests
to the private BFF container:

```text
Browser or phone
       |
       | http(s)://host:UI_PORT
       v
  Next.js UI
       |
       | /api/* -> http://bff:3000/*
       v
     BFF API
       |
       +----------> PostgreSQL
       |
       +----------> Scraper worker
```

This same-origin proxy is important. A browser-visible API address such as
`http://localhost:3000` would resolve to the phone itself when the application
is opened from a phone. `/api` always uses the same host that served the UI.

## Repository layout

For local builds, keep the repositories as siblings:

```text
stash/
|-- stash-infra/
|-- stash-db/
|-- stash-bff/
|-- stash-ui/
`-- stash-scraper-worker/
```

`docker-compose.yml` uses these sibling directories as its default build
contexts. On Ubuntu, `deploy.bash` replaces the contexts with Git repository
URLs, so only `stash-infra` needs to be cloned on the server.

## Configuration

Copy `.env.example` to `.env` before starting the stack:

```powershell
Copy-Item .env.example .env
```

```bash
cp .env.example .env
```

`.env.example` is the complete configuration contract for the Compose stack.
The real `.env` contains secrets and is ignored by Git. Each application also
has its own `.env.example` for running that application outside Compose.

### Required secrets

Replace every `change-me` value:

- `POSTGRES_PASSWORD`: password used by PostgreSQL and the BFF.
- `JWT_SECRET`: signs access tokens; use at least 32 random bytes.
- `SCRAPER_SERVICE_TOKEN`: shared secret used by the BFF and scraper worker.
- `GEMINI_API_KEY`: Gemini extraction key. Leave it empty only when AI
  extraction is intentionally unavailable.

Generate strong secrets on Linux with:

```bash
openssl rand -base64 48
```

### Network and browser settings

- `UI_BIND_ADDRESS=0.0.0.0` exposes the UI on all host interfaces, including
  the local LAN. Use `127.0.0.1` behind a production reverse proxy.
- `UI_PORT=3000` selects the host port used to reach the UI.
- `REFRESH_COOKIE_SECURE=false` supports local HTTP. Set it to `true` when the
  public site uses HTTPS.
- `CORS_ORIGINS` optionally restricts direct BFF origins. Normal web traffic
  uses the same-origin UI proxy and does not require a separate CORS origin.
- `ALLOWED_DEV_ORIGINS` is used only by Next.js development mode. It accepts a
  comma-separated list of LAN IP addresses or hostnames.

### Authentication settings

- `ACCESS_TOKEN_EXPIRES_IN` controls access-token lifetime, for example `15m`.
- `REFRESH_TOKEN_EXPIRES_DAYS` controls refresh-session lifetime.
- `REFRESH_COOKIE_NAME` sets the refresh cookie name.

### Scraping and refresh settings

- `SCRAPER_MAX_CONCURRENCY` limits simultaneous browser jobs.
- `SCRAPER_PROXY_URL` optionally routes scraper traffic through an HTTP proxy.
- `INTEGRATION_TIMEOUT_MS` limits a product extraction request.
- `INTEGRATION_MAX_HTML_BYTES` caps downloaded page size.
- `PRICE_REFRESH_INTERVAL_MS` controls the background refresh interval.
- `PRICE_REFRESH_BATCH_SIZE` controls products selected in each cycle.
- `PRICE_REFRESH_CONCURRENCY` limits concurrent scheduled refreshes.

## Startup order and health checks

Compose starts services according to their health dependencies:

```text
db healthy + scraper-worker healthy
                 |
                 v
              bff healthy
                 |
                 +----> ui
                 `----> price-refresher
```

The BFF runs `prisma migrate deploy` before starting the API. If the database,
migration, scraper, or BFF health check fails, dependent services stay stopped
instead of starting in a partially working state.

Inspect current state with:

```powershell
docker compose --project-directory .\stash-infra --env-file .\stash-infra\.env ps
```

From inside `stash-infra`, the shorter form is:

```bash
docker compose ps
```

## Deploy

### Windows / Docker Desktop

Compose is the only local launcher. From `stash-infra`, start the production
images with:

```powershell
docker compose up -d --build
```

For development with file watching and hot reload, use:

```powershell
docker compose -f docker-compose.yml -f docker-compose.dev.yml up --watch --build
```

After the development images have been built once, `--build` is optional.
Other devices on the same network can open
`http://<windows-laptop-ip>:<UI_PORT>`.

### One-command Ubuntu deployment

On Ubuntu, clone this repository, create `.env`, then run:

```bash
bash deploy.bash
```

The script installs missing requirements through `apt` (`git`, OpenSSH,
GitHub CLI, Docker Engine, and Compose v2). On its first run, it then
authenticates the GitHub CLI if necessary,
generates `~/.ssh/stash_build`, registers its public key with GitHub, verifies
access to every source repository, updates `stash-infra`, builds the latest
`main` sources, and restarts the stack. Later deployments use the existing key
and require only the same command.

The GitHub account used by `gh auth login` must have read access to all four
source repositories. Optional overrides are `GITHUB_OWNER`, `DEPLOY_BRANCH`,
and `STASH_SSH_KEY_PATH`.

For standalone deployment with only `stash-infra` cloned, set the four build
contexts in `.env` to their Git URLs. Docker BuildKit pulls them for free when
the repositories are public. Pin tags or full commits for stable releases:

```dotenv
DB_BUILD_CONTEXT=https://github.com/Raymoun17/stash-db.git#v1.0.0
BFF_BUILD_CONTEXT=https://github.com/Raymoun17/stash-bff.git#v1.0.0
UI_BUILD_CONTEXT=https://github.com/Raymoun17/stash-ui.git#v1.0.0
SCRAPER_BUILD_CONTEXT=https://github.com/Raymoun17/stash-scraper-worker.git#v1.0.0
```

Leave these variables unset during local development to use the sibling paths.

### Private GitHub build contexts

Use SSH authentication rather than putting a personal access token in `.env`.
Add the generated public key to a dedicated GitHub machine-user account that
has read access to the four source repositories. GitHub deploy keys are scoped
to one repository and cannot be reused, so using deploy keys instead requires
four distinct keys and SSH host aliases.

On the Ubuntu host:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/stash_build -C stash-build -N ''
cat ~/.ssh/stash_build.pub
ssh-keyscan github.com >> ~/.ssh/known_hosts
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/stash_build
ssh -T git@github.com
```

Set the build contexts in `.env` to SSH Git URLs:

```dotenv
DB_BUILD_CONTEXT=git@github.com:Raymoun17/stash-db.git#main
BFF_BUILD_CONTEXT=git@github.com:Raymoun17/stash-bff.git#main
UI_BUILD_CONTEXT=git@github.com:Raymoun17/stash-ui.git#main
SCRAPER_BUILD_CONTEXT=git@github.com:Raymoun17/stash-scraper-worker.git#main
```

Forward the loaded key to BuildKit when rebuilding:

```bash
docker compose build --pull --ssh default
docker compose up -d --remove-orphans
```

The SSH key is used only to fetch the private build contexts and is not copied
into the resulting images. A shell started later must start an agent and run
`ssh-add ~/.ssh/stash_build` again; alternatively, configure a persistent user
SSH agent service.

Open `http://localhost:3000`, or the port selected with `UI_PORT`. Database
migrations run before the API starts and data persists in a named Docker volume.

## Development watch mode

With the four repositories checked out as sibling directories, start the stack
in watch mode from `stash-infra`:

```powershell
docker compose -f docker-compose.yml -f docker-compose.dev.yml watch
```

Changes in `stash-ui`, `stash-bff`, and `stash-scraper-worker/app` are synced
into their development containers. Their framework development servers reload
the changed application automatically. Dependency, Prisma, and Python
requirements changes trigger an image rebuild. Press `Ctrl+C` to stop the
stack.

For HTTPS behind a reverse proxy, route traffic to `UI_PORT` and set
`UI_BIND_ADDRESS=127.0.0.1` and `REFRESH_COOKIE_SECURE=true`. Both Windows and
Ubuntu use the same `docker-compose.yml` and `.env` schema; `deploy.bash` only
changes the build contexts to Git repositories.

```powershell
docker compose logs -f
docker compose up -d --build
docker compose down
```

`docker compose down -v` permanently deletes the database volume.

## Networking details

Compose creates a private project network named `stash_default`. Docker DNS
allows containers to use service names instead of host IP addresses:

| Connection | Internal address |
| --- | --- |
| BFF to database | `db:5432` |
| BFF to scraper | `scraper-worker:8000` |
| UI to BFF | `bff:3000` |

Only `${UI_BIND_ADDRESS}:${UI_PORT}` is published to the host. PostgreSQL, the
BFF, and scraper worker do not need public ports. Keeping those ports private
reduces exposure and avoids CORS and cookie differences between environments.

For LAN access on Windows:

1. Keep `UI_BIND_ADDRESS=0.0.0.0`.
2. Find the laptop IPv4 address with `ipconfig`.
3. Open `http://<laptop-ip>:<UI_PORT>` from the other device.
4. If the connection is blocked, allow the selected TCP port through Windows
   Defender Firewall and ensure both devices are on the same network.

## Persistent data and migrations

PostgreSQL data is stored in the named `postgres-data` volume. Rebuilding
images, recreating containers, or running `docker compose down` does not remove
the volume.

Every BFF startup applies committed Prisma migrations before launching the API.
Schema changes should therefore be committed as Prisma migration files in
`stash-bff`; no manual production schema command is normally required.

To stop containers and preserve data:

```bash
docker compose down
```

To deliberately delete all database data:

```bash
docker compose down -v
```

The `-v` operation is destructive and cannot be undone without a backup.

## Production HTTPS

On an Ubuntu server, place Nginx, Caddy, Traefik, or another reverse proxy in
front of the UI. Recommended production values are:

```dotenv
UI_BIND_ADDRESS=127.0.0.1
UI_PORT=3000
REFRESH_COOKIE_SECURE=true
```

The reverse proxy should terminate TLS and forward traffic to
`http://127.0.0.1:3000`. All `/api` requests continue through Next.js to the
private BFF, so no separate public API host is required.

## Routine operations

Run these commands from `stash-infra` unless otherwise noted.

Show container status:

```bash
docker compose ps
```

Follow all logs:

```bash
docker compose logs -f
```

Follow one service:

```bash
docker compose logs -f bff
```

Rebuild and restart after source or Dockerfile changes:

```bash
docker compose build
docker compose up -d --remove-orphans
```

Restart one service without rebuilding:

```bash
docker compose restart bff
```

Display the fully resolved configuration without exposing it publicly:

```bash
docker compose config
```

Do not paste `docker compose config` output into public issues because it can
contain expanded secrets from `.env`.

## Troubleshooting

### A service is unhealthy

Start with status and logs:

```bash
docker compose ps -a
docker compose logs --tail 200 <service-name>
```

Typical causes are invalid database credentials, placeholder secrets, failed
migrations, unavailable external APIs, or an image built from stale source.

### The UI starts but API requests return 404

Confirm `NEXT_PUBLIC_API_URL` is `/api` at build time and
`BFF_INTERNAL_URL=http://bff:3000` is available to the UI container. Then check:

```bash
docker compose logs --tail 200 ui bff
```

Do not configure a browser-facing API URL with `localhost` for LAN clients.

### The BFF cannot connect to PostgreSQL

Confirm the database is healthy and that `POSTGRES_USER`, `POSTGRES_PASSWORD`,
and `POSTGRES_DB` are consistent in `.env`:

```bash
docker compose ps db
docker compose logs --tail 200 db bff
```

### A build uses stale output

Force a clean image rebuild:

```bash
docker compose build --no-cache <service-name>
docker compose up -d --force-recreate <service-name>
```

The infrastructure stack uses `*-runtime:local` image names so standalone
development images cannot accidentally replace production runtime images.

### Ubuntu deployment cannot access GitHub

Verify GitHub CLI and SSH access:

```bash
gh auth status --hostname github.com
ssh -T git@github.com
```

The authenticated GitHub account and deployment key must be able to read all
four source repositories.

## Security checklist

Before exposing Stash to the internet:

- Replace every placeholder secret in `.env`.
- Set `UI_BIND_ADDRESS=127.0.0.1` behind the reverse proxy.
- Set `REFRESH_COOKIE_SECURE=true` when using HTTPS.
- Expose only the reverse proxy ports, normally 80 and 443.
- Keep `.env` out of Git and backups with inappropriate access.
- Pin deployment branches to tags or commit SHAs when reproducibility matters.
- Back up the PostgreSQL volume before upgrades or destructive migrations.
