-- #1272: how the phone came to send this item — 'auto' (the backup rule) or
-- 'picked' (the user picked it once in the system photo picker). Phones that
-- predate the field never send it, so every existing row is 'auto'.
ALTER TABLE flow_delivery ADD COLUMN source TEXT NOT NULL DEFAULT 'auto';
