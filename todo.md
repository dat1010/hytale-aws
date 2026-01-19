### Hytale AWS TODO / Roadmap

### Goal (next)
Eliminate SSH for first-time Hytale authentication by **sending the auth URL/code to Discord** when auth is required (“Plan A”), while still supporting a **no-Discord / SSM-only** workflow (“Plan B”).

### Plan A — Send auth URL/code to Discord (no SSH)

- **Detect auth-required state**
  - Capture the exact downloader output when auth is required (URL + code text).
  - Decide on a reliable detection method:
    - Parse stdout/stderr for known markers (preferred if stable).
    - Or detect a “not authenticated” exit code + follow-up output.

- **Add a notifier path during bootstrap**
  - Update `/opt/hytale/bin/hytale-update.sh` logic to:
    - Run the downloader with output captured to a log file.
    - If auth is required, extract URL + code and trigger a Discord notification.
    - Exit clearly (so the update service shows “waiting for auth”) and allow reruns.

- **Deliver Discord webhook to the instance**
  - Reuse Secrets Manager (same webhook secret or a dedicated “bootstrap notifications” secret).
  - Grant the EC2 instance role permission to read that secret:
    - `secretsmanager:GetSecretValue` for the secret ARN.
  - In the updater script, retrieve the webhook URL and `curl` POST the message.

- **Make Discord optional**
  - Keep the SSM/logs workflow as a first-class path.
  - Support disabling Discord integration entirely at deploy/synth time.

- **Retry strategy (so auth completion continues install automatically)**
  - Option A: keep `hytale-update.service` as-is and let operator rerun by restarting the service.
  - Option B (recommended): add a `systemd timer` that retries the updater every N minutes until it succeeds.

- **Discord message content**
  - Include:
    - Auth URL (and/or device code)
    - Instance endpoint (`public-ip:5520`) if available; otherwise note that it may take a minute
    - A short explanation: “complete once; creds persist on `/opt/hytale`”

### Acceptance criteria
- When a fresh instance boots and auth is needed:
  - A Discord message appears with **the auth URL + code** (best-effort extraction).
  - After you complete auth in the browser, the instance **finishes installing automatically** (no SSH).
- On subsequent boots:
  - No auth messages are sent (credentials persisted).

- If Discord is not configured/disabled:
  - The instance can still be operated entirely via **SSM + logs**.
  - Docs explain both auth paths clearly, including that auth may be required **twice** on first deploy.

---

### Next (after auth): Make backups easy to restore to a new instance

### Goal
After `cdk destroy HytaleServerStack` + redeploy, restoring your latest good server state should be **one command** and **low risk**.

### Restore plan

- **Confirm backup format + restore target paths**
  - Determine what Hytale writes into `--backup-dir` (zip vs directory; what top-level paths exist).
  - Confirm the live data paths we need to restore:
    - `universe/` (world + player data) location for our setup (likely under `/opt/hytale/server/Server/`).
    - server config files (`config.json`, `permissions.json`, `whitelist.json`, etc.) if they’re included in backups.
    - mods/plugins if applicable.

- **Add an instance-side restore script**
  - Create `/opt/hytale/bin/hytale-restore.sh` that:
    - stops `hytale` (and pauses update timer if needed)
    - downloads a selected backup from S3 to `/opt/hytale/tmp/`
    - restores (extracts/copies) into the correct live directory
    - fixes ownership (`hytale:hytale`)
    - starts `hytale`
  - Support restore selectors:
    - default: **latest** backup in `s3://$bucket/hytale/backups/`
    - optional: restore by backup name / timestamp
  - Safety:
    - keep a local pre-restore copy (rename to `universe.bak.<ts>` or similar)
    - refuse to restore while server is running (unless it can stop it)

- **Add Makefile helpers**
  - `make restore-latest` (runs the restore script via SSM)
  - optionally `make restore BACKUP=<name>` and `make list-backups`

- **Docs**
  - Add “Restore from S3 backup after redeploy” section with:
    - prerequisites (instance running, server installed)
    - the restore command(s)
    - how to pick a backup
    - what gets restored (and what doesn’t)

### Acceptance criteria (restore)
- After destroying/redeploying `HytaleServerStack`, you can run `make restore-latest` and:
  - the server starts successfully
  - the world/player state matches the chosen backup
  - permissions/admin setup is preserved (if included in backup), or documented if not

### Open questions to answer before coding
- What exact text does `hytale-downloader` print for device auth (URL/code format)?
- Where does the downloader store credentials under `HOME=/opt/hytale` (file path)? We’ll use that to detect “already authed”.
- Should auth notifications go to the existing webhook secret, or a separate secret?

