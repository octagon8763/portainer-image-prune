# Portainer Image Prune

Scheduled Docker image pruning via the Portainer API — one script, any number of hosts, no extra dependencies.

Runs directly on each host as a system cron job. Uses only tools available on any standard Linux system:
`sh` · `wget` · `mkdir` · `date` · `hostname` · `grep` · `sed` · `awk`

---

## How it works

Each host runs the script on its own cron schedule. At runtime the script:

1. Reads `portainer-prune.conf` for the Portainer URL, API key, and endpoint ID mapping
2. Looks up its own endpoint ID using the system hostname
3. Calls `POST /api/endpoints/{id}/docker/images/prune` against your Portainer instance
4. Logs the result (and optionally sends a Discord embed) with space reclaimed in MB

Because the script reads its hostname at runtime, the **same file can be deployed to all hosts** — each one automatically picks up its own endpoint ID from the config.

---

## Directory layout

```
/opt/portainer-prune/         <- suggested install path (or any directory)
├── portainer-prune.sh        <- the script
├── portainer-prune.conf      <- your config (never commit this)
├── portainer-prune.conf.example
└── logs/
    └── portainer-prune.log
```

Alternatively, place the files on a shared NFS/CIFS mount so there is only one copy to maintain across all hosts.

---

## 1. Install

```sh
# Suggested path -- adjust to taste
sudo mkdir -p /opt/portainer-prune
sudo cp portainer-prune.sh /opt/portainer-prune/
sudo cp portainer-prune.conf.example /opt/portainer-prune/portainer-prune.conf
sudo chmod +x /opt/portainer-prune/portainer-prune.sh

# Lock down the config -- contains your API key
sudo chmod 600 /opt/portainer-prune/portainer-prune.conf
```

---

## 2. Generate a Portainer API key

1. Log in to Portainer
2. Click your avatar (top right) -> **My account**
3. Scroll to **Access tokens** -> **Add access token**
4. Give it a name (e.g. `image-prune`) and copy the token
5. Add to `portainer-prune.conf`:

```sh
PORTAINER_BASE_URL=https://portainer.yourdomain.com:9443
PORTAINER_API_KEY=ptr_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Set `PORTAINER_TLS_VERIFY=false` if Portainer uses a self-signed certificate.

---

## 3. Find your Portainer endpoint IDs

1. In Portainer, go to **Environments**
2. Click each environment name
3. Look at the URL: `.../#!/endpoints/`**2**`/docker/...` — the number is the ID
4. Add one entry per host to `portainer-prune.conf`:

```sh
PORTAINER_ENDPOINT__nas01=1
PORTAINER_ENDPOINT__nas02=2
PORTAINER_ENDPOINT__nas03=3
```

> Run `hostname` on each host to confirm the exact name.
> Hyphens and other non-alphanumeric characters become `_`
> (e.g. `nas-01` → `PORTAINER_ENDPOINT__nas_01`).

---

## 4. Choose what to prune

```sh
PRUNE_ALL_IMAGES=false   # default
```

| Value | Behaviour |
|-------|-----------|
| `false` | **Dangling only** — removes untagged/orphaned image layers (`<none>:<none>`). Safe, conservative. |
| `true` | **All unused** — removes any image not currently used by a running or stopped container. Reclaims much more space. |

---

## 5. Schedule with system cron

Create `/etc/cron.d/portainer-prune` on **each host**:

```
# Prune dangling Docker images via Portainer API daily at 2 AM
0 2 * * * root sh /opt/portainer-prune/portainer-prune.sh
```

Or add to root's crontab (`sudo crontab -e`):

```
0 2 * * * sh /opt/portainer-prune/portainer-prune.sh
```

---

## 6. Discord notifications (optional)

1. In Discord: **Server Settings -> Integrations -> Webhooks -> New Webhook**
2. Choose a channel, give it a name, click **Copy Webhook URL**
3. In `portainer-prune.conf`:

```sh
DISCORD_ENABLED=true
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
DISCORD_USERNAME=Portainer
```

You'll get a green embed on success (with MB reclaimed) and a red embed on failure.

---

## 7. Test before going live

```sh
# Dry run -- logs the URL that would be called, no actual API request
DRY_RUN=true sh /opt/portainer-prune/portainer-prune.sh

# Live run
sh /opt/portainer-prune/portainer-prune.sh
```

---

## 8. Watch the logs

```sh
# Follow the log
tail -f /opt/portainer-prune/logs/portainer-prune.log

# Errors only
grep "\[ERROR\]" /opt/portainer-prune/logs/portainer-prune.log

# Filter by host
grep "\[host:nas01\]" /opt/portainer-prune/logs/portainer-prune.log
```

---

## 9. Full config reference

| Variable | Default | Description |
|---|---|---|
| `PORTAINER_BASE_URL` | *(required)* | Base URL of your Portainer instance |
| `PORTAINER_API_KEY` | *(required)* | Portainer API access token |
| `PORTAINER_TLS_VERIFY` | `true` | Set to `false` for self-signed certs |
| `PRUNE_ENABLED` | `true` | Set to `false` to disable without removing the cron job |
| `PRUNE_ALL_IMAGES` | `false` | `true` = all unused; `false` = dangling only |
| `PORTAINER_ENDPOINT__<host>` | *(required per host)* | Portainer endpoint ID for that host |
| `LOG_FILE` | `./logs/portainer-prune.log` | Path to the log file |
| `MAX_LOG_SIZE_KB` | `10240` | Rotate log when it exceeds this size (KB) |
| `MAX_LOG_ARCHIVES` | `5` | Number of rotated archives to keep |
| `RETRY_ATTEMPTS` | `3` | API call attempts before giving up |
| `RETRY_DELAY` | `5` | Seconds between retries |
| `DRY_RUN_CONFIG` | `false` | Log only, no API calls (override with `DRY_RUN=true` env var) |
| `DISCORD_ENABLED` | `false` | Enable Discord notifications |
| `DISCORD_WEBHOOK_URL` | *(required if enabled)* | Your Discord webhook URL |
| `DISCORD_USERNAME` | `Portainer` | Bot display name in Discord |
