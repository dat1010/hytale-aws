### Hytale AWS TODO / Roadmap

### Goal (next)
Eliminate SSH for first-time Hytale authentication by **sending the auth URL/code to Discord** when the downloader requires device auth (“Plan A”).

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
  - A Discord message appears with **the auth URL + code**.
  - After you complete auth in the browser, the instance **finishes installing automatically** (no SSH).
- On subsequent boots:
  - No auth messages are sent (credentials persisted).

### Open questions to answer before coding
- What exact text does `hytale-downloader` print for device auth (URL/code format)?
- Where does the downloader store credentials under `HOME=/opt/hytale` (file path)? We’ll use that to detect “already authed”.
- Should auth notifications go to the existing webhook secret, or a separate secret?

