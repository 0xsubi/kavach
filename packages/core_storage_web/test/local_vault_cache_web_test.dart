@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kavach_core/kavach_core.dart';
import 'package:kavach_core_storage_web/kavach_core_storage_web.dart';

VaultItem _item(String id, {bool deleted = false}) => VaultItem(
      id: id,
      version: 1,
      updatedAt: DateTime.utc(2026),
      updatedByDevice: 'device-1',
      deleted: deleted,
      data: VaultItemData.password(name: 'Example $id', username: 'user@example.com', password: 'hunter2'),
    );

void main() {
  test('put/get/allItems/dirtyItems/markSynced round-trip through real IndexedDB', () async {
    final cache = await LocalVaultCacheWeb.open();

    expect(await cache.allItems(), isEmpty);
    expect(await cache.dirtyItems(), isEmpty);
    expect(await cache.getItem('missing'), isNull);

    await cache.putItem(_item('a'), dirty: true);
    await cache.putItem(_item('b'), dirty: false);

    final all = await cache.allItems();
    expect(all.map((i) => i.id).toSet(), {'a', 'b'});

    final dirty = await cache.dirtyItems();
    expect(dirty.map((i) => i.id).toList(), ['a']);

    final fetched = await cache.getItem('a');
    expect(fetched, isNotNull);
    expect((fetched!.data as PasswordItemData).username, 'user@example.com');

    await cache.markSynced('a');
    expect(await cache.dirtyItems(), isEmpty);
  });

  test('lastSyncedCommitSha round-trips', () async {
    final cache = await LocalVaultCacheWeb.open();
    expect(await cache.lastSyncedCommitSha, isNull);
    await cache.setLastSyncedCommitSha('abc123');
    expect(await cache.lastSyncedCommitSha, 'abc123');
  });

  test('cachedBlobShas round-trips', () async {
    final cache = await LocalVaultCacheWeb.open();
    expect(await cache.cachedBlobShas(), isEmpty);
    await cache.setCachedBlobShas({'items/01/x.json.enc': 'sha-1', 'items/02/y.json.enc': 'sha-2'});
    expect(await cache.cachedBlobShas(), {'items/01/x.json.enc': 'sha-1', 'items/02/y.json.enc': 'sha-2'});
  });
}
