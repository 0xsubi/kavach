import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kavach_core/kavach_core.dart';

import '../state/vault_controller.dart';
import 'vault_repository.dart';

@JS('chrome.runtime.onMessage.addListener')
external void _addMessageListener(JSFunction callback);

@JS('chrome.runtime.sendMessage')
external JSPromise<JSAny?> _sendMessage(JSAny message);

/// Answers the background relay's `kavach:matches-requested` /
/// `kavach:fill-requested` broadcasts (plan §7) with real vault data, read
/// straight out of [container] — no screen needs to be mounted or watching
/// for this to work. That's what makes autofill work from the offscreen
/// document, which never builds any UI, the same way it works from the side
/// panel. Instantiate this once, eagerly, in `main()`, only in the offscreen
/// document (see `main.dart` — the side panel must not also register one, or
/// every query gets answered twice by two independently-unlocking vault
/// instances). See `extension/shell/src/messages.ts` for the shared message
/// shapes this must stay in sync with.
class AutofillResponder {
  AutofillResponder(this._container) {
    if (_hasChrome()) {
      _addMessageListener(_handleMessage.toJS);
    }
  }

  final ProviderContainer _container;

  bool _hasChrome() => globalContext.has('chrome');

  void _handleMessage(JSAny? message, JSAny? sender, JSAny? sendResponse) {
    if (message == null || message.isUndefinedOrNull) return;
    final obj = message as JSObject;
    switch (obj.getProperty<JSString?>('type'.toJS)?.toDart) {
      case 'kavach:matches-requested':
        unawaited(_respondToMatches(obj));
      case 'kavach:fill-requested':
        unawaited(_respondToFill(obj));
    }
  }

  /// Waits for the vault to finish its automatic quick-unlock attempt
  /// (`UnlockScreen._tryQuickUnlock`, triggered as soon as the widget tree
  /// mounts — there's no separate signal for "tried and gave up", so a
  /// bounded wait is the only way to tell "still booting" apart from
  /// "genuinely needs a master password"). The offscreen document is
  /// created lazily on the very first autofill query of a session, so that
  /// query would otherwise almost always race ahead of Flutter boot +
  /// sodium init + the chrome.storage round trips `tryQuickUnlock` makes,
  /// and see `locked`/`loading` instead of the `unlocked` state that's
  /// really only a few hundred ms away.
  Future<VaultState> _awaitUnlockedOrSettle() async {
    final current = _container.read(vaultControllerProvider);
    if (current.status == VaultStatus.unlocked) return current;

    final completer = Completer<VaultState>();
    late final ProviderSubscription<VaultState> subscription;
    subscription = _container.listen<VaultState>(vaultControllerProvider, (previous, next) {
      if (next.status == VaultStatus.unlocked && !completer.isCompleted) {
        completer.complete(next);
      }
    });

    final result = await completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => _container.read(vaultControllerProvider),
    );
    subscription.close();
    return result;
  }

  Future<void> _respondToMatches(JSObject obj) async {
    final origin = obj.getProperty<JSString?>('origin'.toJS)?.toDart;
    final tabId = obj.getProperty<JSNumber?>('tabId'.toJS)?.toDartDouble.toInt();
    if (origin == null || tabId == null) return;

    final state = await _awaitUnlockedOrSettle();
    final matches =
        state.status == VaultStatus.unlocked ? matchesForOrigin(state.items, origin) : const <VaultItem>[];

    final response = JSObject()
      ..setProperty('type'.toJS, 'kavach:matches-response'.toJS)
      ..setProperty('origin'.toJS, origin.toJS)
      ..setProperty('tabId'.toJS, tabId.toJS)
      ..setProperty('matches'.toJS, _summariesFor(matches));
    unawaited(_sendMessage(response).toDart);
  }

  Future<void> _respondToFill(JSObject obj) async {
    final itemId = obj.getProperty<JSString?>('itemId'.toJS)?.toDart;
    final tabId = obj.getProperty<JSNumber?>('tabId'.toJS)?.toDartDouble.toInt();
    if (itemId == null || tabId == null) return;

    final state = await _awaitUnlockedOrSettle();
    VaultItem? item;
    for (final candidate in state.items) {
      if (candidate.id == itemId) {
        item = candidate;
        break;
      }
    }
    final data = item?.data;
    if (data is! PasswordItemData) return;

    final response = JSObject()
      ..setProperty('type'.toJS, 'kavach:fill-response'.toJS)
      ..setProperty('tabId'.toJS, tabId.toJS)
      ..setProperty('username'.toJS, data.username.toJS)
      ..setProperty('password'.toJS, data.password.toJS);
    unawaited(_sendMessage(response).toDart);
  }

  JSArray _summariesFor(List<VaultItem> matches) {
    return matches
        .map((item) {
          final data = item.data as PasswordItemData;
          return JSObject()
            ..setProperty('id'.toJS, item.id.toJS)
            ..setProperty('name'.toJS, data.name.toJS)
            ..setProperty('username'.toJS, data.username.toJS);
        })
        .toList()
        .toJS;
  }
}
