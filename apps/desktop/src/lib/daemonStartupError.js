import { t } from "./i18n.js";

/**
 * daemon 起不来时向导红条的文字（#1044）。
 *
 * `failure` 是壳的 `daemon_startup_error` 给的 `{ key, detail }`：`key` 是
 * daemon 自己认出的已知原因（i18n key，例如库比本版本新），`detail` 是 stderr
 * 原文。这里不再用正则去猜原文——认原因是 daemon 的事。
 *
 * @param {{key?: string|null, detail?: string}|null} failure
 */
export function startupFailureText(failure) {
  const detail = String(failure?.detail || "").trim();
  const guidance = failure?.key ? t(failure.key) : "";
  return [guidance, detail].filter(Boolean).join("\n");
}
