# CI für PR #8 aktivieren — Schritte (in dieser Reihenfolge)

GitHub zeigt für den Fork **null** Workflow-Läufe (`actions/runs`
total_count 0), obwohl alle vier Workflows (`test`, `build`,
`PR Agent`, `refresh star history`) als `active` gemeldet werden und
`test.yml` auf `pull_request` ohne Branch-Filter triggert — der PR
müsste also laufen. Die Workflow-Dateien selbst sind korrekt (YAML
valid, gepinnte Flutter-Version, keine Secrets für `test.yml`
erforderlich, `permissions: contents: read` vorhanden). Das Problem
liegt daher mit hoher Wahrscheinlichkeit in den
Repository-Einstellungen, nicht in den Dateien.

## 1. Actions-Tab öffnen und Workflows aktivieren

Repo öffnen → Tab **Actions**. Zeigt GitHub einen Banner
„Get started with GitHub Actions" / „Workflows aren't being run on
this fork" mit einem **„I understand my workflows, go ahead and enable
them"**-Knopf: klicken. (Forks zeigen diesen Banner, bis Actions
einmal explizit aktiviert wurden — der häufigste Grund für null Runs.)

## 2. Settings → Actions → General prüfen

- **Actions permissions**: „Allow all actions and reusable workflows"
  (oder mindestens die benutzten Aktionen erlauben:
  `actions/checkout`, `subosito/flutter-action`).
- **Workflow permissions**: „Read repository contents" genügt für
  `test.yml` (`contents: read`).
- **Fork-Pull-Request-Approval**: falls „Require approval for first
  contribution from a new contributor" an ist — Commits im selben Fork
  sind keine „outside contributions", das sollte nicht greifen; wenn
  doch: den wartenden Lauf im Actions-Tab manuell approven.
- **Spending-Limit** (Settings → Billing): ein komplett gesperrtes
  Budget zeigt ebenfalls null Runs ohne Fehlermeldung im PR.

## 3. Den `test`-Workflow einmal manuell starten

Tab **Actions** → links Workflow **test** → rechts **Run workflow** →
Branch `vibe/oura-spo2-historical-path-d6f8ca` → **Run workflow**.
Das ist `workflow_dispatch`, der einzige Trigger, der ohne PR-Ereignis
läuft. Ergebnis im Actions-Tab ablesen.

## 4. Danach: einen Commits pushen (oder den PR aktualisieren)

Wenn der manuelle Lauf funktioniert, triggert der nächste
`synchronize`-Push automatisch `pull_request` + den Lauf im PR.

## Was mir zurückmelden

- **Grüner Lauf**: „test workflow grün auf Commit <SHA>" — dann sind
  die Sandbox-Ergebnisse von CI bestätigt.
- **Roter Lauf**: den Job-Namen, die **erste fehlende Zeile** im Log
  (nicht nur die Zusammenfassung) und den Commit-SHA. Ich behebe am
  Quellcode — Erwartungen werden nicht angepasst.
- **Lauf startet nicht** (gar kein Run erscheint): was genau in
  Settings → Actions → General steht (Screenshot reicht), ob der
  Aktivierungs-Banner in Schritt 1 vorhanden war, und ob unter
  Billing ein Spending-Limit gesetzt ist.
- **Wartender Lauf mit „approval required"**: den Lauf approven oder
  mir die Meldung zurückgeben.

Hinweis: `pr-agent.yml` benötigt das Secret `PR_AGENT_API_KEY`; fehlt
es, fällt nur dieser Workflow auf, `test` bleibt unberührt.
