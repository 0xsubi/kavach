import 'package:freezed_annotation/freezed_annotation.dart';

part 'vault_index.freezed.dart';
part 'vault_index.g.dart';

/// One row of the vault-wide index stored (encrypted) at `.kavach/index.json.enc`
/// (plan §2). Lets a device enumerate/search items and detect changes without
/// decrypting every item file.
@freezed
class VaultIndexEntry with _$VaultIndexEntry {
  const factory VaultIndexEntry({
    required String id,
    required String type,
    required int version,
    required DateTime updatedAt,
    required String updatedByDevice,
    @Default(false) bool deleted,
    required String path,
  }) = _VaultIndexEntry;

  factory VaultIndexEntry.fromJson(Map<String, dynamic> json) =>
      _$VaultIndexEntryFromJson(json);
}

@freezed
class VaultIndex with _$VaultIndex {
  const factory VaultIndex({
    @Default(<VaultIndexEntry>[]) List<VaultIndexEntry> entries,
  }) = _VaultIndex;

  factory VaultIndex.fromJson(Map<String, dynamic> json) => _$VaultIndexFromJson(json);
}
