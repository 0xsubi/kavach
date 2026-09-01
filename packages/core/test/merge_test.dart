import 'package:kavach_core/src/models/vault_item.dart';
import 'package:kavach_core/src/sync/merge.dart';
import 'package:test/test.dart';

VaultItem _passwordItem({
  required String id,
  required int version,
  required String device,
  required String name,
}) {
  return VaultItem(
    id: id,
    version: version,
    updatedAt: DateTime.utc(2026, 1, 1),
    updatedByDevice: device,
    data: VaultItemData.password(name: name, username: 'user', password: 'pw'),
  );
}

void main() {
  final now = DateTime.utc(2026, 9, 1, 12);

  test('fast-forwards when remote is at or behind the local edit base', () {
    final local = _passwordItem(id: 'a', version: 3, device: 'device-1', name: 'Local edit');
    final remote = _passwordItem(id: 'a', version: 2, device: 'device-2', name: 'Old remote');

    final result = resolveItemConflict(
      local: local,
      localBaseVersion: 2,
      remote: remote,
      conflictItemId: 'conflict-1',
      localDeviceId: 'device-1',
      now: now,
    );

    expect(result.outcome, MergeOutcome.fastForwardLocal);
    expect(result.conflictCopy, isNull);
  });

  test('produces a labeled conflict copy when remote advanced past the local base', () {
    final local = _passwordItem(id: 'a', version: 3, device: 'device-1', name: 'Local edit');
    final remote = _passwordItem(id: 'a', version: 5, device: 'device-2', name: 'Concurrent remote edit');

    final result = resolveItemConflict(
      local: local,
      localBaseVersion: 2,
      remote: remote,
      conflictItemId: 'conflict-1',
      localDeviceId: 'device-1',
      now: now,
    );

    expect(result.outcome, MergeOutcome.conflict);
    final copy = result.conflictCopy!;
    expect(copy.id, 'conflict-1');
    expect(copy.version, 1);
    expect(copy.updatedByDevice, 'device-1');
    final data = copy.data as PasswordItemData;
    expect(data.name, contains('Local edit'));
    expect(data.name, contains('conflicted copy from device-1'));
  });

  test('conflict copy preserves the original secret payload untouched', () {
    final local = _passwordItem(id: 'a', version: 3, device: 'device-1', name: 'Bank login');
    final remote = _passwordItem(id: 'a', version: 5, device: 'device-2', name: 'Bank login (renamed)');

    final result = resolveItemConflict(
      local: local,
      localBaseVersion: 2,
      remote: remote,
      conflictItemId: 'conflict-2',
      localDeviceId: 'device-1',
      now: now,
    );

    final data = result.conflictCopy!.data as PasswordItemData;
    expect(data.username, 'user');
    expect(data.password, 'pw');
  });
}
