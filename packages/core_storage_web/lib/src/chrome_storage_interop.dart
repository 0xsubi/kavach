import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Proxies `chrome.storage.local` reads/writes through the background
/// service worker via `chrome.runtime.sendMessage`, rather than calling
/// `chrome.storage.local` directly. This package's code also runs inside the
/// extension's offscreen document (the always-on surface behind
/// Bitwarden-style autofill — see `AutofillResponder` in
/// `extension/flutter_popup`), and Chrome restricts offscreen documents to
/// the `chrome.runtime` API only: `chrome.storage` itself is unreachable
/// there. The side panel could call `chrome.storage.local` directly, but
/// routing every surface through the same proxy keeps this package's
/// behavior identical regardless of which context it's running in. See
/// `extension/shell/src/messages.ts` and
/// `extension/shell/src/background/service-worker.ts` for the other end of
/// this protocol.
@JS('chrome.runtime.sendMessage')
external JSPromise<JSAny?> _sendMessage(JSAny message);

/// Thin, typed wrapper over the raw extern above so callers never touch
/// `JSObject`/`JSString` directly.
abstract final class ChromeStorageLocal {
  static Future<String?> get(String key) async {
    final message = JSObject()
      ..setProperty('type'.toJS, 'kavach:storage-get'.toJS)
      ..setProperty('key'.toJS, key.toJS);
    final result = await _sendMessage(message).toDart;
    if (result.isUndefinedOrNull) return null;
    return (result as JSString).toDart;
  }

  static Future<void> set(String key, String value) async {
    final message = JSObject()
      ..setProperty('type'.toJS, 'kavach:storage-set'.toJS)
      ..setProperty('key'.toJS, key.toJS)
      ..setProperty('value'.toJS, value.toJS);
    await _sendMessage(message).toDart;
  }

  static Future<void> remove(String key) async {
    final message = JSObject()
      ..setProperty('type'.toJS, 'kavach:storage-remove'.toJS)
      ..setProperty('key'.toJS, key.toJS);
    await _sendMessage(message).toDart;
  }

  static Future<void> clear() async {
    final message = JSObject()..setProperty('type'.toJS, 'kavach:storage-clear'.toJS);
    await _sendMessage(message).toDart;
  }
}
