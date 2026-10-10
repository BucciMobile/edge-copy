#!/usr/bin/env bash
# Nightly: pull report METADATA (never blobs) from the admin API into a local SQLite file.
# Config in /etc/openstrap-report-backup.env: REPORT_ADMIN_TOKEN=..., optional REPORT_URL, BACKUP_DB.
set -euo pipefail
URL="${REPORT_URL:-https://reports.openstrap.wtf}"
DB="${BACKUP_DB:-/var/lib/openstrap-reports/meta.sqlite}"
mkdir -p "$(dirname "$DB")"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
curl -fsS --max-time 60 -H "Authorization: Bearer ${REPORT_ADMIN_TOKEN:?set REPORT_ADMIN_TOKEN}" \
  "$URL/v1/admin/reports?since=1970-01-01T00:00:00Z" -o "$tmp"
python3 - "$tmp" "$DB" <<'PY'
import json, sqlite3, sys
rows = json.load(open(sys.argv[1]))["reports"]
c = sqlite3.connect(sys.argv[2])
c.execute("""CREATE TABLE IF NOT EXISTS reports (id TEXT PRIMARY KEY, install_id, created_at, category, title,
  description, meta, blob_bytes, has_db, github_issue_url, blob_expired INTEGER, first_seen TEXT DEFAULT CURRENT_TIMESTAMP)""")
c.executemany("""INSERT INTO reports (id,install_id,created_at,category,title,description,meta,blob_bytes,has_db,github_issue_url,blob_expired)
  VALUES (:id,:install_id,:created_at,:category,:title,:description,:meta,:blob_bytes,:has_db,:github_issue_url,:blob_expired)
  ON CONFLICT(id) DO UPDATE SET blob_bytes=excluded.blob_bytes, github_issue_url=excluded.github_issue_url, blob_expired=excluded.blob_expired""",
  [{**r, "blob_expired": int(r.get("blob_key") is None)} for r in rows])
c.commit()
print(f"backed up {len(rows)} reports")
PY
