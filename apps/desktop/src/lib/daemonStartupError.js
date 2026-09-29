import { t } from "./i18n.js";

const MIGRATION_MISMATCH = /migration .*missing in the resolved migrations/i;

export function startupFailureText(stderr) {
  const detail = String(stderr || "").trim();
  const guidance = MIGRATION_MISMATCH.test(detail)
    ? t("ui.startup_migration_guidance")
    : "";

  return [guidance, detail].filter(Boolean).join("\n");
}
