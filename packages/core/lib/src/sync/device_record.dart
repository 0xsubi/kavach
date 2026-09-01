/// A device's approval state within a vault, stored plaintext at
/// `.kavach/devices/<device-id>.json` (plan §2/§5) — plaintext is
/// unavoidable since a brand-new pending device has no vault key yet to
/// encrypt anything with.
enum DeviceStatus { pending, approved, revoked }

class DeviceRecord {
  const DeviceRecord({
    required this.deviceId,
    required this.publicKey,
    required this.status,
    required this.platform,
  });

  final String deviceId;

  /// Base64-encoded X25519 public key.
  final String publicKey;
  final DeviceStatus status;
  final String platform;

  DeviceRecord copyWith({DeviceStatus? status}) => DeviceRecord(
        deviceId: deviceId,
        publicKey: publicKey,
        status: status ?? this.status,
        platform: platform,
      );

  factory DeviceRecord.fromJson(Map<String, dynamic> json) => DeviceRecord(
        deviceId: json['device_id'] as String,
        publicKey: json['public_key'] as String,
        status: DeviceStatus.values.byName(json['status'] as String),
        platform: json['platform'] as String? ?? 'unknown',
      );

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'public_key': publicKey,
        'status': status.name,
        'platform': platform,
      };
}
