import type { FillResponseMessage, MatchesResponseMessage, ShellMessage } from '../messages';

/**
 * Runs in the isolated content-script world on every page (plan §7).
 * Finds login-shaped forms, asks the background relay whether the vault
 * has anything for this origin when the user focuses a credential field,
 * and renders the answer as an in-page dropdown (Shadow DOM, so the host
 * page's CSS can't reach in and can't be reached by ours) — no side panel
 * interaction required, matching how Bitwarden/1Password's own autofill
 * works.
 */

/** The field the user actually focused — what the dropdown anchors to. */
let anchorField: HTMLInputElement | null = null;
/** Where a chosen credential gets written; may differ from the anchor. */
let fillUsernameField: HTMLInputElement | null = null;
let fillPasswordField: HTMLInputElement | null = null;

const usernameSelector =
  'input[type="email"], input[type="text"][autocomplete*="username"], ' +
  'input[type="text"][name*="user" i], input[type="email"][name*="email" i], input[autocomplete="username"], ' +
  'input[type="text"][id*="email" i], input[type="text"][id*="user" i]';

// Excludes display:none/detached decoy fields (many sites, Amazon included,
// ship a hidden password input as an autofill-suppression trick or as the
// second step of a split login form). Anchoring the dropdown to one of those
// would position it against a zero-sized rect in the page's top-left corner,
// and filling one would write the password somewhere the user can't see.
// Deliberately NOT using `offsetParent === null` for this — that also
// reports false for anything inside a `position: fixed` ancestor (a very
// common pattern for sign-in dialogs), which would wrongly exclude fields
// that are genuinely visible.
function isVisible(el: HTMLElement): boolean {
  return el.checkVisibility ? el.checkVisibility() : true;
}

function findPasswordFields(): HTMLInputElement[] {
  return Array.from(document.querySelectorAll<HTMLInputElement>('input[type="password"]')).filter(isVisible);
}

function findUsernameFields(): HTMLInputElement[] {
  return Array.from(document.querySelectorAll<HTMLInputElement>(usernameSelector)).filter(isVisible);
}

// Pairing is resolved at focus time, not at scan time — a page can have a
// username field with no password field yet (Amazon/Google-style split
// login: identifier on one page, password on the next) or a password field
// with no paired username field in scope. Computing it fresh means neither
// case ever prevents the other field from working.
function pairedFieldFor(field: HTMLInputElement, selector: string): HTMLInputElement | null {
  const scope = field.closest('form') ?? document;
  const candidates = Array.from(scope.querySelectorAll<HTMLInputElement>(selector));
  return candidates.find(isVisible) ?? null;
}

function setNativeValue(input: HTMLInputElement, value: string): void {
  // Frameworks like React track input state via their own synthetic event
  // system, which ignores a plain `input.value = x` assignment (it doesn't
  // fire the tracked event). Using the native value setter directly, then
  // dispatching real `input`/`change` events, is the standard workaround —
  // the same technique Bitwarden/1Password's own autofill uses.
  const nativeSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
  nativeSetter?.call(input, value);
  input.dispatchEvent(new Event('input', { bubbles: true }));
  input.dispatchEvent(new Event('change', { bubbles: true }));
}

// ---------------------------------------------------------------------
// In-page picker overlay (Shadow DOM)
// ---------------------------------------------------------------------

let shadowHost: HTMLDivElement | null = null;
let shadowRoot: ShadowRoot | null = null;
let panel: HTMLDivElement | null = null;

function ensureOverlay(): HTMLDivElement {
  if (panel) return panel;

  const host = document.createElement('div');
  host.id = 'kavach-autofill-root';
  host.style.all = 'initial';
  document.documentElement.appendChild(host);
  shadowHost = host;
  shadowRoot = host.attachShadow({ mode: 'closed' });

  const style = document.createElement('style');
  style.textContent = `
    .panel {
      position: fixed;
      z-index: 2147483647;
      min-width: 240px;
      max-width: 320px;
      background: #FFFFFF;
      border: 1px solid #E3E5E8;
      border-radius: 10px;
      box-shadow: 0 8px 24px rgba(0, 0, 0, 0.16);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      overflow: hidden;
      display: none;
    }
    .panel.open { display: block; }
    .row {
      display: flex;
      flex-direction: column;
      gap: 2px;
      padding: 10px 12px;
      cursor: pointer;
      border-bottom: 1px solid #E3E5E8;
    }
    .row:last-child { border-bottom: none; }
    .row:hover { background: #F5F6F7; }
    .name { font-size: 13px; font-weight: 600; color: #0F1115; }
    .username { font-size: 11px; color: #8A8F98; }
  `;
  shadowRoot.appendChild(style);

  panel = document.createElement('div');
  panel.className = 'panel';
  shadowRoot.appendChild(panel);

  // Scrolling/resizing moves the anchor, so follow it rather than hiding —
  // hiding here is what made the dropdown vanish the instant a page with
  // any scroll-driven layout work touched it.
  window.addEventListener('scroll', repositionOverlay, true);
  window.addEventListener('resize', repositionOverlay);

  // Clicking the field that opened the dropdown must not dismiss it: the
  // focus that opens it is itself part of a click, so treating that click as
  // "outside" closed the panel in the same gesture that opened it.
  document.addEventListener(
    'click',
    (event) => {
      const target = event.target;
      if (!(target instanceof Node)) return;
      if (target === anchorField) return;
      if (shadowHost?.contains(target)) return;
      hideOverlay();
    },
    true,
  );

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') hideOverlay();
  });

  return panel;
}

function isOpen(): boolean {
  return panel?.classList.contains('open') ?? false;
}

function hideOverlay(): void {
  panel?.classList.remove('open');
}

function repositionOverlay(): void {
  if (!panel || !anchorField || !isOpen()) return;

  const rect = anchorField.getBoundingClientRect();
  // A zero-sized rect means the anchor got hidden or detached (SPA
  // re-render); there is nothing sensible to anchor to anymore.
  if (rect.width === 0 && rect.height === 0) {
    hideOverlay();
    return;
  }

  panel.style.top = `${rect.bottom + 4}px`;
  panel.style.left = `${rect.left}px`;
  panel.style.minWidth = `${Math.max(rect.width, 240)}px`;
}

function showMatches(field: HTMLInputElement, matches: MatchesResponseMessage['matches']): void {
  const el = ensureOverlay();
  if (matches.length === 0) {
    hideOverlay();
    return;
  }

  anchorField = field;
  el.innerHTML = '';

  for (const match of matches) {
    const row = document.createElement('div');
    row.className = 'row';

    const name = document.createElement('div');
    name.className = 'name';
    name.textContent = match.name;

    const username = document.createElement('div');
    username.className = 'username';
    username.textContent = match.username;

    row.append(name, username);
    // Without this the row's mousedown blurs the input, and the resulting
    // focus/click churn can tear the panel down before `click` ever lands.
    row.addEventListener('mousedown', (event) => event.preventDefault());
    row.addEventListener('click', () => {
      chrome.runtime.sendMessage({ type: 'kavach:fill-request', itemId: match.id }).catch(() => {});
      hideOverlay();
    });
    el.appendChild(row);
  }

  el.classList.add('open');
  repositionOverlay();
}

// ---------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------

function requestMatchesForCurrentOrigin(): void {
  chrome.runtime.sendMessage({ type: 'kavach:request-matches', origin: location.origin }).catch(() => {});
}

function bind(field: HTMLInputElement, isPassword: boolean): void {
  if (field.dataset.kavachBound === '1') return;
  field.dataset.kavachBound = '1';

  field.addEventListener('focus', () => {
    anchorField = field;
    if (isPassword) {
      fillPasswordField = field;
      fillUsernameField = pairedFieldFor(field, usernameSelector);
    } else {
      fillUsernameField = field;
      fillPasswordField = pairedFieldFor(field, 'input[type="password"]');
    }
    requestMatchesForCurrentOrigin();
  });
}

function attachFieldListeners(): void {
  for (const field of findPasswordFields()) bind(field, true);
  for (const field of findUsernameFields()) bind(field, false);
}

chrome.runtime.onMessage.addListener((message: ShellMessage) => {
  if (message.type === 'kavach:matches-response') {
    if (message.origin !== location.origin) return;
    if (anchorField) showMatches(anchorField, message.matches);
    return;
  }

  if (message.type === 'kavach:fill-response') {
    const fill = message as FillResponseMessage;
    if (fillUsernameField) setNativeValue(fillUsernameField, fill.username);
    if (fillPasswordField) setNativeValue(fillPasswordField, fill.password);
  }
});

attachFieldListeners();

// Single-page apps render forms after the initial page load, so keep
// watching for newly-added password fields rather than only scanning once.
new MutationObserver(() => attachFieldListeners()).observe(document.documentElement, {
  childList: true,
  subtree: true,
});
