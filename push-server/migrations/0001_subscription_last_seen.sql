-- 0001: subscriptions.last_seen (epoch ms) for idle-subscription expiry
-- (see pruneSubscriptions in src/index.js).
-- Applied with `wrangler d1 migrations apply`, which records it in the
-- d1_migrations table so it runs exactly once per database. schema.sql stays
-- the v1 base (re-run on every deploy; SQLite has no ADD COLUMN IF NOT EXISTS).
ALTER TABLE subscriptions ADD COLUMN last_seen INTEGER NOT NULL DEFAULT 0;

-- Existing subscriptions count as seen (and active) at migration time, so
-- the upgrade drops nobody: they get the 3-day / 40-day rules from now on.
UPDATE subscriptions
SET last_seen = MAX(created_at + 1, CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER));
