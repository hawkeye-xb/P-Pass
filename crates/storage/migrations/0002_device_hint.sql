-- DEV-01: reinstall fingerprint on the device row.
-- `device_hint` = SHA-256(Build.MODEL + ANDROID_ID) first 8 bytes hex,
-- stored when the joining client sends it (owner enabled 重装识别).
-- NULL = pre-DEV-01 client or hint disabled — pairing works identically.
ALTER TABLE device ADD COLUMN device_hint TEXT;
