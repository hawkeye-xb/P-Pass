const MIGRATION_MISMATCH = /migration .*missing in the resolved migrations/i;

export function startupFailureText(stderr) {
  const detail = String(stderr || "").trim();
  const guidance = MIGRATION_MISMATCH.test(detail)
    ? "这个版本比你的照片库旧。请装回新版本。"
    : "";

  return [guidance, detail].filter(Boolean).join("\n");
}
