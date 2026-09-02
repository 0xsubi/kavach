/**
 * The one message protocol shared by every part of the shell (content
 * script, background relay, and the Flutter side running in both the side
 * panel and the offscreen document, which listen for these via
 * `chrome.runtime.onMessage` through their own JS interop). Kept in one
 * file so these contexts can never quietly drift out of sync on a shape.
 *
 * The background service worker is a *stateless relay only* (plan §7) — it
 * never inspects or stores credential data, just forwards these messages
 * between whichever tab triggered a request and whichever Flutter surface
 * (the always-alive offscreen document, or the side panel if also open)
 * answers it. `tabId` is never set by the content script itself (it has no
 * way to know its own tab id) — the background fills it in from
 * `sender.tab.id` when relaying a content-script message onward to Flutter,
 * so Flutter's eventual response can be routed back to the right tab.
 */

/** One matching credential's non-secret summary — enough to render an
 * in-page picker row without putting the password on the page until the
 * user actually picks it. */
export interface MatchSummary {
  id: string;
  name: string;
  username: string;
}

/** Content script -> background: "does the vault have anything for this
 * origin?" */
export interface RequestMatchesMessage {
  type: 'kavach:request-matches';
  origin: string;
}

/** Background -> Flutter: RequestMatchesMessage plus the routing tabId. */
export interface MatchesRequestedMessage {
  type: 'kavach:matches-requested';
  origin: string;
  tabId: number;
}

/** Flutter -> background -> content script: the answer, keyed by tabId +
 * origin so a slow response arriving after the user moved on doesn't
 * render onto the wrong page. */
export interface MatchesResponseMessage {
  type: 'kavach:matches-response';
  origin: string;
  tabId: number;
  matches: MatchSummary[];
}

/** Content script -> background: the user picked a match from the in-page
 * dropdown; asks for its actual credential. */
export interface FillRequestMessage {
  type: 'kavach:fill-request';
  itemId: string;
}

/** Background -> Flutter: FillRequestMessage plus the routing tabId. */
export interface FillRequestedMessage {
  type: 'kavach:fill-requested';
  itemId: string;
  tabId: number;
}

/** Flutter -> background -> content script: the credential to fill. */
export interface FillResponseMessage {
  type: 'kavach:fill-response';
  tabId: number;
  username: string;
  password: string;
}

/**
 * Storage proxy: `chrome.storage` is unavailable inside an offscreen
 * document (Chrome restricts offscreen documents to the `runtime` API
 * only), so `SecureKeyStoreWeb` on the Dart side never calls
 * `chrome.storage.local` directly — it always asks the background to do it,
 * which does have full API access. Used identically from the side panel
 * too, so there is exactly one code path regardless of which Flutter
 * surface is asking.
 */
export interface StorageGetMessage {
  type: 'kavach:storage-get';
  key: string;
}

export interface StorageSetMessage {
  type: 'kavach:storage-set';
  key: string;
  value: string;
}

export interface StorageRemoveMessage {
  type: 'kavach:storage-remove';
  key: string;
}

export interface StorageClearMessage {
  type: 'kavach:storage-clear';
}

export type ShellMessage =
  | RequestMatchesMessage
  | MatchesRequestedMessage
  | MatchesResponseMessage
  | FillRequestMessage
  | FillRequestedMessage
  | FillResponseMessage
  | StorageGetMessage
  | StorageSetMessage
  | StorageRemoveMessage
  | StorageClearMessage;
