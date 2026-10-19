// DESK-63 (#946): the desktop shell's view of the background service.
//
// The Rust side owns the state (`apps/desktop/src-tauri/src/service_state.rs`)
// and pushes transitions through the `service-state` event. This module is
// the pure presentation/decision layer the UI and its tests share.
//
// The rule that fixes #946: a data refresh result is NOT a service-state
// input. A failed `devices.list` is a data error; it must not turn a running
// service into "not running".

export const SERVICE_STATES = [
  "not_configured",
  "stopped",
  "starting",
  "running",
  "unreachable",
];

export function isServiceState(value) {
  return SERVICE_STATES.includes(value);
}

/** Extract a state from a Tauri `service-state` payload, or null. */
export function serviceStateFromEvent(payload) {
  const state = payload?.state;
  return isServiceState(state) ? state : null;
}

export function isServiceRunning(state) {
  return state === "running";
}

/** The service is down, but the user can bring it back from this screen. */
export function canStartService(state) {
  return state === "stopped" || state === "unreachable";
}

/** Stop is offered only while the service is actually there. */
export function canStopService(state) {
  return state === "running" || state === "starting";
}

/** i18n key for the sidebar pill / its title. Reuses existing dictionary
 *  entries — no new keys, so the i18n coverage and bundle copies stay put. */
export function serviceStateLabelKey(state) {
  switch (state) {
    case "running":
      return "ui.service_running_long";
    case "starting":
      return "ui.starting";
    case "stopped":
    case "unreachable":
    case "not_configured":
    default:
      return "ui.offline_banner";
  }
}

/** i18n key for the explanation under the badge. */
export function serviceStateActionKey(state) {
  return state === "stopped" ? "ui.service_stopped" : "ui.offline_action";
}

/**
 * DESK-63 contract, expressed as a function so the test documents it:
 * whatever the data layer did, the service state is unchanged here. The
 * Rust connection owner is the only thing allowed to move it.
 */
export function serviceStateAfterDataRefresh(state) {
  return state;
}
