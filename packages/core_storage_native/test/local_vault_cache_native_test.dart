import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kavach_core/kavach_core.dart';
import 'package:kavach_core_storage_native/kavach_core_storage_native.dart';

VaultItem _item(String id, int version, {bool deleted = false}) => VaultItem(
      id: id,
      version: version,
      updatedAt: DateTime.utc(2026, 1, 1),
      updatedByDevice: 'device-1',
      deleted: deleted,
      data: VaultItemData.password(name: 'Item $id', username: 'user', password: 'pw'),
    );

void main() {
  late VaultDatabase db;
  late LocalVaultCacheNative cache;

  setUp(() {
    db = VaultDatabase(NativeDatabase.memory());
    cache = LocalVaultCacheNative(db);
  });

  tearDown(() => db.close());

  test('put and read back an item', () async {
    await cache.putItem(_item('a', 1), dirty: false);
    final read = await cache.getItem('a');
    expect(read, isNotNull);
    expect(read!.version, 1);
    expect((read.data as PasswordItemData).name, 'Item a');
  });

  test('dirtyItems only returns items marked dirty', () async {
    await cache.putItem(_item('a', 1), dirty: true);
    await cache.putItem(_item('b', 1), dirty: false);

    final dirty = await cache.dirtyItems();
    expect(dirty.map((e) => e.id), ['a']);
  });

  test('markSynced clears the dirty flag', () async {
    await cache.putItem(_item('a', 1), dirty: true);
    await cache.markSynced('a');

    expect(await cache.dirtyItems(), isEmpty);
    expect((await cache.getItem('a'))!.version, 1);
  });

  test('putItem upserts by id', () async {
    await cache.putItem(_item('a', 1), dirty: false);
    await cache.putItem(_item('a', 2), dirty: true);

    final all = await cache.allItems();
    expect(all, hasLength(1));
    expect(all.single.version, 2);
  });

  test('last synced commit sha round-trips', () async {
    expect(await cache.lastSyncedCommitSha, isNull);
    await cache.setLastSyncedCommitSha('abc123');
    expect(await cache.lastSyncedCommitSha, 'abc123');
  });

  test('blob sha cache round-trips as a map', () async {
    expect(await cache.cachedBlobShas(), isEmpty);
    await cache.setCachedBlobShas({'items/aa/aaa.json.enc': 'sha1', 'items/bb/bbb.json.enc': 'sha2'});
    expect(await cache.cachedBlobShas(), {
      'items/aa/aaa.json.enc': 'sha1',
      'items/bb/bbb.json.enc': 'sha2',
    });
  });
}
