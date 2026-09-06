@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kavach_core_storage_web/kavach_core_storage_web.dart';

void main() {
  test('write/read/delete round-trip through real IndexedDB', () async {
    final store = await SecureKeyStoreIndexedDb.open();

    expect(await store.read('missing'), isNull);

    await store.write('kavach.device.id', 'device-1');
    expect(await store.read('kavach.device.id'), 'device-1');

    await store.write('kavach.device.id', 'device-2');
    expect(await store.read('kavach.device.id'), 'device-2');

    await store.delete('kavach.device.id');
    expect(await store.read('kavach.device.id'), isNull);
  });

  test('deleteAll clears every key, not just one', () async {
    final store = await SecureKeyStoreIndexedDb.open();

    await store.write('a', '1');
    await store.write('b', '2');
    await store.deleteAll();

    expect(await store.read('a'), isNull);
    expect(await store.read('b'), isNull);
  });

  test('delete of a missing key does not throw', () async {
    final store = await SecureKeyStoreIndexedDb.open();
    await store.delete('never-written');
  });
}
