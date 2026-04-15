# WebArena Reddit (Postmill) — Setup Notes

## Stack

| Item | Value |
|---|---|
| Port | 9999 |
| Apptainer instance | `webarena_reddit` |
| App | Postmill (Symfony/PHP Reddit clone) |
| Database | PostgreSQL 14.7 |
| Services | `postgres`, `php-fpm`, `nginx` (3 total) |

No MySQL, Redis, or Elasticsearch — reddit is simpler than the shopping services.

---

## Fresh-State Design

`run_reddit.sh` uses the same fresh-state design as all other services. On every start it:

1. Wipes `/tmp/webarena_runtime_reddit/`
2. Extracts `pgsql/` (PostgreSQL data) and `postmill_var/` (Symfony cache/sessions) from the SIF
3. Clears the Symfony cache immediately after extraction
4. Binds all mutable paths from `/tmp/webarena_runtime_reddit/` — nothing runs from NFS

This eliminates all NFS lock problems:

| Potential problem | How it's resolved |
|---|---|
| PHP-FPM accept mutex | `/tmp` inside container maps to node-local `/tmp/webarena_runtime_reddit/tmp` — locking works |
| PostgreSQL `fcntl()` WAL locks | Data dir is on node-local SSD, not NFS |
| Stale `postmaster.pid` | Impossible — data dir is freshly extracted from SIF on every start |
| Stale Symfony cache | Cleared immediately after extraction (`rm -rf postmill_var/cache/*`) |

---

## PostgreSQL Authentication

`pg_hba.conf` has two different auth methods:

```
local   all   all                 trust     # Unix socket — no password needed
host    all   all   127.0.0.1/32  password  # TCP — password required
```

**Always connect via Unix socket** (omit `-h`):

```bash
apptainer exec instance://webarena_reddit psql -U postmill -d postmill -c "SELECT 1"
```

Do NOT use `-h 127.0.0.1` — it requires a password and will hang waiting for input.

---

## Postmill URL Structure

Postmill's URL conventions differ from standard Reddit and from what you might guess:

| Page | URL |
|---|---|
| Homepage | `/` |
| Login | `/login` (redirects first — see below) |
| Registration | `/registration` (NOT `/register`) |
| Community | `/f/<name>` (NOT `/+<name>` or `/r/<name>`) |
| Hot sort | `/?sort=hot` |
| New sort | `/?sort=new` |
| Login form POST | `/login_check` |

### Login Flow (Postmill cookie-check mechanism)

Postmill's login has a multi-step flow:

1. `GET /login` → 302 to `/login?_cookie_check=<nonce>`
2. `GET /login?_cookie_check=<nonce>` → sets `PHPSESSID` cookie, redirects back to `/login`
3. `GET /login` (with cookie) → 200, returns login form with `_csrf_token`
4. `POST /login_check` with `_username`, `_password`, `_csrf_token` → 302 to `/` (success) or 302 to `/login` (failure)

**Critical pitfall:** Do NOT use `curl -L` on the POST to `/login_check`.
- On failure (wrong credentials), `/login_check` redirects back to `/login`
- curl with `-L` resubmits the POST method to `/login`, which returns `405 Method Not Allowed`
- This masks the real result (credentials rejected) with a misleading 405 error
- Instead: POST without `-L`, then inspect the `Location:` header directly

---

## Dataset Contents

| Table | Count |
|---|---|
| `users` | 661,782 |
| `forums` | 95 |
| `submissions` | 127,391 |

Known forums (community names) in this dataset:
`AskReddit`, `Art`, `DIY`, `Documentaries`, `EarthPorn`, `Futurology`, `GetMotivated`,
`IAmA`, `Jokes`, `LifeProTips`, `MachineLearning`, `Maine`, and ~83 others.

WebArena test user: **`MarvelsGrantMan136`** / password **`test1234`**

---

## Test Script: `test_reddit.sh`

Usage:
```bash
bash reddit/test_reddit.sh [HOST] [PORT]
# HOST auto-detected from homepage/.reddit_node if not given
# Default port: 9999
```

| Section | What is tested |
|---|---|
| **1. Apptainer instance** | `webarena_reddit` appears in `apptainer instance list` |
| **2. Supervisord** | All 3 services RUNNING: `nginx`, `php-fpm`, `postgres` |
| **3. PostgreSQL** | Accepts connections (Unix socket); user count >0; forum count >0; submission count >0 |
| **4. HTTP endpoints** | Homepage (200); login page (2xx/3xx); registration page (200); communities `/f/AskReddit`, `/f/DIY`, `/f/MachineLearning` (200); hot sort (200); new sort (200) |
| **5. Login** | CSRF token extracted from login form; POST to `/login_check` succeeds (302 to `/`, not back to `/login`) |

Expected result: **18/18 tests pass** on a healthy reddit node.

---

## Port Conflicts

Reddit only uses PostgreSQL (5432) and PHP-FPM (9000). It does NOT conflict with:
- Shopping (MySQL 3306, ES 9200, Redis 6379, PHP-FPM 9000) — **PHP-FPM port 9000 conflicts**
- Shopping Admin — same PHP-FPM conflict

**Reddit cannot share a node with shopping or shopping_admin.** Stop other Magento instances
before starting reddit, or use separate SLURM nodes.
