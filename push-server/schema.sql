-- D1 schema for the AR Farm Timer push server (v1 base, idempotent; re-run
-- on every deploy). Later changes are in migrations/ and are applied with
-- `wrangler d1 migrations apply DB` (0001 adds subscriptions.last_seen).
CREATE TABLE IF NOT EXISTS subscriptions (
  id TEXT PRIMARY KEY,          -- random token returned to the app
  endpoint TEXT NOT NULL UNIQUE,
  p256dh TEXT NOT NULL,
  auth TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS alerts (
  sub_id TEXT NOT NULL,
  id TEXT NOT NULL,             -- "<timerId>:<notificationId>" from the app
  fire_at INTEGER NOT NULL,     -- epoch ms (UTC)
  title TEXT NOT NULL,
  body TEXT NOT NULL DEFAULT '',
  url TEXT,
  attempts INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (sub_id, id)
);

CREATE INDEX IF NOT EXISTS alerts_fire_at ON alerts (fire_at);

-- Delivery log for latency diagnosis (kept 7 days; no message content).
CREATE TABLE IF NOT EXISTS deliveries (
  sub_id   TEXT NOT NULL,
  alert_id TEXT NOT NULL,
  fire_at  INTEGER NOT NULL,   -- scheduled time (ms)
  sent_at  INTEGER NOT NULL,   -- when the push service answered (ms)
  status   INTEGER NOT NULL,   -- push service HTTP status (0 = network error)
  push_ms  INTEGER NOT NULL,   -- push service round trip (ms)
  via      TEXT NOT NULL       -- 'alarm' | 'cron'
);
CREATE INDEX IF NOT EXISTS deliveries_sent_at ON deliveries (sent_at);
