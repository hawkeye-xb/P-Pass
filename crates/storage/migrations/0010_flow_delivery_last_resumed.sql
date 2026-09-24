-- #413 §6: an active grant that nobody resumes for too long must stop
-- protecting its desktop-side partial from GC. `last_resumed_ms` is the last
-- time the phone offered (or a status poll respawned) this exact tuple.
-- Existing rows start "now": their true age is unknown, and expiring them on
-- the first sweep after upgrade would throw away partials a phone may still
-- resume.
ALTER TABLE flow_delivery ADD COLUMN last_resumed_ms INTEGER NOT NULL DEFAULT 0;
UPDATE flow_delivery SET last_resumed_ms = CAST(strftime('%s', 'now') AS INTEGER) * 1000;
