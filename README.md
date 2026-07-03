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
