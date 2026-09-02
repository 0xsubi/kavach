import type {
  FillRequestMessage,
  FillResponseMessage,
  RequestMatchesMessage,
  ShellMessage,
} from '../messages';

/**
 * Kavach's background service worker. Two responsibilities:
 *
 *  1. Relay: content-script <-> Flutter (offscreen document + side panel)
 *     message passing for autofill (plan §7). MV3 workers are
 *     non-persistent and can be killed between events at any time, so this
 *     file must never hold vault state across messages — every handler
 *     reacts to exactly one incoming message and is done.
 *
 *  2. Storage proxy: Chrome restricts offscreen documents to the `runtime`
 *     API only (no `chrome.storage`), so `SecureKeyStoreWeb` on the Dart
 *     side always asks the background to read/write `chrome.storage.local`
 *     on its behalf — the one extension API surface every context can
 *     reach. Used the same way from the side panel too, for one code path
 *     regardless of which Flutter surface is asking.
 *
 * It also keeps an offscreen document alive running the same Flutter app
 * as the side panel — the thing that actually makes autofill work without
 * the user ever opening the panel. A locked/never-visited side panel can't
 * answer a query it never received; an always-running offscreen document
 * can, as soon as the vault has been unlocked once (its cached key lives
 * in chrome.storage.local, shared across every surface via the proxy
 * above).
 */

// The query string is a marker the Flutter side reads (see
// `extension/flutter_popup/lib/main.dart`) to tell whether this load is the
// offscreen document rather than the side panel — both load the exact same
// popup/index.html, but only the offscreen document should register as an
// AutofillResponder. Otherwise every `kavach:matches-requested` broadcast
// gets answered twice (once from each surface), and whichever answer
// happens to still be mid-unlock at that instant can race the other one and
// clobber a correct result with an empty one.
const OFFSCREEN_URL = 'popup/index.html?context=offscreen';

chrome.sidePanel?.setPanelBehavior({ openPanelOnActionClick: true }).catch(() => {
  // Older Chrome without chrome.sidePanel support — nothing to fall back
  // to; the toolbar icon just won't do anything on that Chrome version.
});

async function ensureOffscreenDocument(): Promise<void> {
  if (await chrome.offscreen.hasDocument()) return;
  await chrome.offscreen.createDocument({
    url: OFFSCREEN_URL,
    reasons: [chrome.offscreen.Reason.DOM_SCRAPING],
    justification:
      'Runs the same Flutter vault app as the side panel so autofill queries can be answered ' +
      '(the vault decrypted and the matching credential looked up) without requiring the user ' +
      'to have the side panel open. No page content is scraped; this is the closest available ' +
      'Reason enum value to "keep an already-unlocked vault available in the background".',
  });
}

// Created once at service worker startup and again after every wake-up —
// MV3 workers restart often, and there is no persistent "did I already do
// this" flag worth keeping (ensureOffscreenDocument is idempotent).
ensureOffscreenDocument().catch(() => {
  // Retried lazily by every handler below that needs it, so a failure here
  // (e.g. no user gesture yet on stricter Chrome versions) isn't fatal.
});

chrome.runtime.onMessage.addListener((message: ShellMessage, sender, sendResponse) => {
  switch (message.type) {
    case 'kavach:request-matches':
      handleRequestMatches(message, sender.tab?.id);
      return false;

    case 'kavach:matches-response':
      chrome.tabs.sendMessage(message.tabId, message).catch(() => {});
      return false;

    case 'kavach:fill-request':
      handleFillRequest(message, sender.tab?.id);
      return false;

    case 'kavach:fill-response':
      handleFillResponse(message);
      return false;

    case 'kavach:storage-get':
      chrome.storage.local.get(message.key).then((result) => sendResponse(result[message.key] ?? null));
      return true;

    case 'kavach:storage-set':
      chrome.storage.local.set({ [message.key]: message.value }).then(() => sendResponse(undefined));
      return true;

    case 'kavach:storage-remove':
      chrome.storage.local.remove(message.key).then(() => sendResponse(undefined));
      return true;

    case 'kavach:storage-clear':
      chrome.storage.local.clear().then(() => sendResponse(undefined));
      return true;

    default:
      return false;
  }
});

async function handleRequestMatches(message: RequestMatchesMessage, tabId: number | undefined): Promise<void> {
  if (tabId === undefined) return;
  await ensureOffscreenDocument();
  chrome.runtime.sendMessage({ type: 'kavach:matches-requested', origin: message.origin, tabId }).catch(() => {
    // Nothing listening yet (offscreen document still booting its Dart VM
    // on a cold start) — there is no queued-retry here deliberately; the
    // user can just click the field again, which is simpler than building
    // a message queue for what is, in practice, a sub-second race.
  });
}

async function handleFillRequest(message: FillRequestMessage, tabId: number | undefined): Promise<void> {
  if (tabId === undefined) return;
  await ensureOffscreenDocument();
  chrome.runtime.sendMessage({ type: 'kavach:fill-requested', itemId: message.itemId, tabId }).catch(() => {});
}

function handleFillResponse(message: FillResponseMessage): void {
  chrome.tabs.sendMessage(message.tabId, message).catch(() => {
    // Tab navigated away or closed between the user picking a credential
    // and this message landing — nothing to fill anymore.
  });
}
