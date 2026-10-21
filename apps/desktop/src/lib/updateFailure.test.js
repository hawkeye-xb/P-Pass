import { describe, expect, it } from "vitest";
import {
  RELEASES_URL,
  updateFailureBodyKey,
  updateFailureBodyParams,
  updateFailureServiceKey,
} from "./updateFailure.js";

describe("update failure banner", () => {
  it("links to the public releases page for manual download", () => {
    expect(RELEASES_URL).toBe("https://github.com/hawkeye-xb/P-Pass/releases/latest");
  });

  it("mentions the target version only when the marker has one", () => {
    expect(updateFailureBodyKey({ version: "0.10.1-dev.1012" })).toBe(
      "ui.update_failed_banner_body_version",
    );
    expect(updateFailureBodyParams({ version: "0.10.1-dev.1012" })).toEqual({
      version: "0.10.1-dev.1012",
    });
    expect(updateFailureBodyKey({})).toBe("ui.update_failed_banner_body");
    expect(updateFailureBodyParams({})).toEqual({});
  });

  it("tells restored versus user-stopped service apart, and pending while starting", () => {
    expect(updateFailureServiceKey({ service_restored: true }, true)).toBe(
      "ui.update_failed_service_restored",
    );
    expect(updateFailureServiceKey({ service_restored: true }, false)).toBe(
      "ui.update_failed_service_pending",
    );
    expect(updateFailureServiceKey({ service_restored: false }, true)).toBe(
      "ui.update_failed_service_stopped",
    );
    expect(updateFailureServiceKey({ service_restored: false }, false)).toBe(
      "ui.update_failed_service_stopped",
    );
  });
});
