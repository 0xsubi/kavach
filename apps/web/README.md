# kavach_web

Kavach's standalone web vault — the full vault UI (create/unlock a vault,
add/edit/search passwords, the generator, multi-device approval and
invites) running in any browser, no extension or app install required.

It shares `packages/core`, `packages/core_storage_web` and
`packages/neopop_theme` with the native apps and the browser extension.
Unlike the extension popup, it has no `chrome.*` runtime to lean on — key
material is kept in this origin's own IndexedDB instead of
`chrome.storage.local` (see `SecureKeyStoreIndexedDb` in
`packages/core_storage_web`). **Read the security note below before
deploying this somewhere multiple people can reach it.**

Every API call goes straight from the browser to whatever kavach-storage
instance you configure in Settings — this app never proxies through its
own server, so it can point at *any* self-hosted kavach-storage, not just
one this deployment happens to know about.

## Local development

```
cd apps/web
flutter run -d chrome
```

## Production build

```
cd apps/web
flutter build web --release
```

Output lands in `build/web` — any static file host works, but the two
things it actually needs are documented below (CORS, and serving `/join`
as `index.html`) since a generic static host won't get those right by
default.

## Docker + nginx deployment

```
cd apps/web
docker compose up -d --build
```

Serves on `http://localhost:8081`. The build context is the *repo root*,
not `apps/web` — this is a melos monorepo and `kavach_web` resolves
`kavach_core`, `kavach_core_storage_web` and `neopop_theme` via relative
`path:` deps in its `pubspec.yaml`, so the Docker build needs those
sibling package directories; see the comment at the top of `Dockerfile`.

`nginx.conf` handles three things a plain static-file host would get
wrong for this specific app:
- **SPA fallback** (`try_files ... /index.html`) — a scanned device-invite
  QR code lands on `/join?v=1&url=…`, a path with no matching file. Only
  client-side code (`Uri.base`, read once at startup — see
  `lib/main.dart`) knows what to do with it.
- **`.wasm` served as `application/wasm`** — both Flutter's CanvasKit
  renderer and the bundled libsodium build need this; served as
  `application/octet-stream` instead, the app silently fails to boot.
- A **CSP** and a handful of other security headers appropriate for a
  page that briefly holds decrypted secrets in memory. `connect-src` is
  intentionally left open (`*`) — see the comment in `nginx.conf` for why.

### Wiring up kavach-storage

The browser calls kavach-storage directly, so kavach-storage needs to
allow this origin via CORS:

```
# on the kavach-storage host
export KAVACH_STORAGE_CORS_ORIGINS=https://kavach.example.com
```

Comma-separate multiple origins if more than one web deployment (or a
`localhost` dev origin) needs access. Leave it unset if you're not
running the web app — native apps and the browser extension ignore it
entirely.

### TLS

This container serves plain HTTP on port 80 (mapped to 8081 by default).
Put a TLS-terminating reverse proxy (Caddy, Traefik, an existing nginx)
in front for anything beyond LAN-only use — this repo doesn't attempt
ACME/Let's Encrypt automation here, since that's inherently tied to a
domain and infrastructure this repo can't assume anything about.

## Security note: browser storage vs. an extension or native app

The native apps use the OS Keychain/Keystore; the browser extension uses
`chrome.storage.local`, sandboxed per-extension-id from ordinary web page
JS. A plain website has neither — IndexedDB, scoped to this origin, is
the only persistence available, and *anything with script execution in
this origin can read it*. Concretely: a successful XSS against this
specific deployment could read the device's cached vault key and private
key straight out of storage.

This is not a bug in the IndexedDB adapter — it's the inherent ceiling of
running a password manager as a website rather than a browser extension
or native app, and it's the same tradeoff Vaultwarden's own web vault
makes. What actually matters for it in practice:
- Keep this deployment's dependency surface small (it already pulls in
  almost nothing beyond Flutter/Dart + libsodium).
- The CSP in `nginx.conf` is a real mitigation, not decoration — it blocks
  the two things an XSS would need (arbitrary script execution, exfil via
  fetch/img to a non-self origin for anything the CSP does constrain).
- Prefer the native apps or the browser extension where installing one is
  an option; treat this as the "access it from a machine you don't own /
  don't want to install anything on" fallback, not the primary way to use
  Kavach day to day.
