# stash-infra

Production orchestration for the complete Stash stack. By default, development
builds use sibling checkouts of `stash-db`, `stash-bff`, `stash-ui`, and
`stash-scraper-worker`. PostgreSQL, the API, and the worker remain private;
only the UI is published.

## Deploy

From this directory:

```powershell
Copy-Item .env.example .env
# Replace every change-me value in .env.
docker compose up -d --build
docker compose ps
```

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
`REFRESH_COOKIE_SECURE=true`.

```powershell
docker compose logs -f
docker compose up -d --build
docker compose down
```

`docker compose down -v` permanently deletes the database volume.
