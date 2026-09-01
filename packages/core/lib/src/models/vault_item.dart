import 'package:freezed_annotation/freezed_annotation.dart';

part 'vault_item.freezed.dart';
part 'vault_item.g.dart';

/// A single, uniquely-identified custom field on a password item.
@freezed
class CustomField with _$CustomField {
  const factory CustomField({
    required String label,
    required String value,
    @Default(false) bool isSecret,
  }) = _CustomField;

  factory CustomField.fromJson(Map<String, dynamic> json) => _$CustomFieldFromJson(json);
}

/// A previous value of a password item's `password` field, kept so users can
/// recover from an accidental overwrite.
@freezed
class PasswordHistoryEntry with _$PasswordHistoryEntry {
  const factory PasswordHistoryEntry({
    required String password,
    required DateTime replacedAt,
  }) = _PasswordHistoryEntry;

  factory PasswordHistoryEntry.fromJson(Map<String, dynamic> json) =>
      _$PasswordHistoryEntryFromJson(json);
}

/// The type-specific payload of a vault item. See plan §2 for the on-disk
/// (pre-encryption) shape this mirrors.
@Freezed(unionKey: 'type', unionValueCase: FreezedUnionCase.snake)
sealed class VaultItemData with _$VaultItemData {
  const factory VaultItemData.password({
    required String name,
    required String username,
    required String password,
    @Default(<String>[]) List<String> uris,
    String? totpSeed,
    @Default('') String notes,
    String? folderId,
    @Default(false) bool favorite,
    @Default(<CustomField>[]) List<CustomField> customFields,
    @Default(<PasswordHistoryEntry>[]) List<PasswordHistoryEntry> history,
  }) = PasswordItemData;

  const factory VaultItemData.passkey({
    required String rpId,
    required String rpName,
    required String userHandle,
    required String userName,
    required String credentialId,
    /// PKCS8-encoded P-256 private key, base64.
    required String privateKey,
    /// COSE-encoded public key, base64.
    required String publicKeyCose,
    @Default(0) int signCount,
    @Default(true) bool discoverable,
    required DateTime createdAt,
  }) = PasskeyItemData;

  factory VaultItemData.fromJson(Map<String, dynamic> json) => _$VaultItemDataFromJson(json);
}

/// Envelope around [VaultItemData] carrying the sync/versioning metadata
/// that every item needs regardless of type. This is exactly what gets
/// JSON-encoded and then sealed by [VaultCrypto] before being written to
/// `items/<shard>/<id>.json.enc` in the GitHub repo (plan §2).
@freezed
class VaultItem with _$VaultItem {
  const factory VaultItem({
    required String id,
    required int version,
    required DateTime updatedAt,
    required String updatedByDevice,
    @Default(false) bool deleted,
    required VaultItemData data,
  }) = _VaultItem;

  factory VaultItem.fromJson(Map<String, dynamic> json) => _$VaultItemFromJson(json);
}
