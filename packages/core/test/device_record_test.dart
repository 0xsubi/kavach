import 'package:kavach_core/kavach_core.dart';
import 'package:test/test.dart';

void main() {
  test('DeviceRecord round-trips through JSON', () {
    const record = DeviceRecord(
      deviceId: 'device-1',
      publicKey: 'base64pubkey==',
      status: DeviceStatus.pending,
      platform: 'macos',
    );

    final roundTripped = DeviceRecord.fromJson(record.toJson());

    expect(roundTripped.deviceId, 'device-1');
    expect(roundTripped.publicKey, 'base64pubkey==');
    expect(roundTripped.status, DeviceStatus.pending);
    expect(roundTripped.platform, 'macos');
  });

  test('copyWith changes only status', () {
    const record = DeviceRecord(
      deviceId: 'device-1',
      publicKey: 'base64pubkey==',
      status: DeviceStatus.pending,
      platform: 'macos',
    );

    final approved = record.copyWith(status: DeviceStatus.approved);

    expect(approved.status, DeviceStatus.approved);
    expect(approved.deviceId, record.deviceId);
    expect(approved.publicKey, record.publicKey);
    expect(approved.platform, record.platform);
  });
}
