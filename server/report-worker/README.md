# OpenStrap report worker

Cloudflare Worker behind "Report an issue" in the app. Contract: `~/.openstrap-research/REPORT_CONTRACT.md`.

## What it stores

- D1 `reports`: the plaintext meta the user saw (category, title, description, app/OS/device strings), install id, blob size, SHA-256 of the delete token, optional GitHub issue URL.
- R2: one encrypted blob per report (`OSR1`: ECDH P-256 + HKDF + AES-256-GCM, only our private key opens it). Keys `logs/<id>` (no database) or `db/<id>` (database attached).
- The delete token is never stored, only its hash. Blob contents never go to GitHub.

## Expiry and limits

| Thing | Rule |
|---|---|
| Blob without DB | deleted after 30 days |
| Blob with DB | deleted after 14 days |
| Metadata row | deleted after 90 days |
| Blob size | 2 MB, or 15 MB when `hasDatabase` |
| Rate limit | 3 reports per install id per UTC day (user-deleted reports still count) |
| Storage ceiling | DB reports get `507 storage_full` when stored bytes would exceed 8 GB |

A daily cron (03:17 UTC) enforces expiry and zeroes `blob_bytes` for removed blobs, so `SUM(blob_bytes)` is the live total. R2 lifecycle rules (below) are a second line of defence for the blobs only.

Free tier: Workers 100k requests/day, R2 10 GB, D1 5 GB / 100k writes per day. Each report is about 4 D1 writes and 1 R2 write; 3/day/install keeps this far from the limits. No KV.

## Deploy (nothing has been run yet)

```sh
cd server/report-worker
npm install
npx wrangler login

npx wrangler r2 bucket create openstrap-reports
npx wrangler r2 bucket lifecycle add openstrap-reports expire-logs --prefix logs/ --expire-days 30
npx wrangler r2 bucket lifecycle add openstrap-reports expire-db   --prefix db/   --expire-days 14

npx wrangler d1 create openstrap-reports          # copy database_id into wrangler.toml
npx wrangler d1 migrations apply openstrap-reports --remote

npx wrangler secret put ADMIN_TOKEN               # e.g. openssl rand -hex 32
# optional GitHub tracker (private repo, token with Issues: write only)
npx wrangler secret put GITHUB_TOKEN
npx wrangler secret put GITHUB_REPO               # OpenStrap/reports

npx wrangler deploy
```

Custom domain: Workers & Pages > openstrap-reports > Settings > Domains > add `reports.openstrap.wtf` (zone must be on Cloudflare), or uncomment `routes` in `wrangler.toml` and redeploy. Check `curl https://reports.openstrap.wtf/v1/health`.

## Fetch and decrypt a report

```sh
pip install cryptography
export REPORT_ADMIN_TOKEN=...
python3 tools/fetch_report.py OS-XXXXXX      # writes OS-XXXXXX.zip
```

Private key path: `REPORT_PRIVATE_KEY` (default `~/.openstrap-research/report-keys/report_private_key.pem`). Keep it out of every repo. `python3 tools/selfcheck.py` verifies the encrypt/decrypt round trip, including the real key pair when present.

Admin API: `GET /v1/admin/reports?since=ISO&after_id=ID` (metadata, 1000 per page, ordered by `created_at, id`) and `GET /v1/admin/reports/<id>/blob`, both with `Authorization: Bearer $ADMIN_TOKEN`.

## Metadata backup (Oracle/arm64 box, not deployed)

`tools/backup_to_oracle.sh` mirrors metadata (no blobs) into SQLite nightly. Needs `python3`. Each run pages the admin list with a `(created_at, id)` cursor and replaces the whole table in one transaction, so a report the user deleted (the Worker scrubs it and stops listing it) or that passed 90 days is gone from the backup the next night; it also purges rows older than 90 days locally. The backup never holds data longer than the policy.

```sh
sudo install -d /opt/openstrap-report-backup && sudo cp tools/backup_to_oracle.sh /opt/openstrap-report-backup/
echo 'REPORT_ADMIN_TOKEN=...' | sudo tee /etc/openstrap-report-backup.env && sudo chmod 600 /etc/openstrap-report-backup.env
sudo cp tools/openstrap-report-backup.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now openstrap-report-backup.timer
```

## Develop

`npm test` (vitest + `@cloudflare/vitest-plugin`, local miniflare D1/R2), `npm run typecheck`.
