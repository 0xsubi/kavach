import Flutter
import Foundation

/// Dart<->Swift bridge for the passkey side of plan §6: `VaultRepository`
/// calls into this (via `MethodChannel('com.kavach.passkeys')`) whenever the
/// set of unlocked passkeys changes, so the shared Keychain and the OS
/// identity store stay in sync with what the vault currently holds — and
/// drains whatever the credential-provider extension created since the app
/// last ran.
enum PasskeyBridge {
    static func register(with engineBridge: FlutterImplicitEngineBridge) {
        let messenger = engineBridge.applicationRegistrar.messenger()
        let channel = FlutterMethodChannel(name: "com.kavach.passkeys", binaryMessenger: messenger)
        let keychain = KeychainStore()
        let outbox = PasskeyOutbox()

        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "syncUnlocked":
                guard let records = (call.arguments as? [[String: Any]])?.compactMap(decodeRecord) else {
                    result(FlutterError(code: "bad_args", message: "expected a list of passkey records", details: nil))
                    return
                }
                do {
                    try records.forEach { try keychain.upsert($0) }
                } catch {
                    result(FlutterError(code: "keychain_error", message: "\(error)", details: nil))
                    return
                }
                if #available(iOS 17.0, *) {
                    Task {
                        try? await IdentityStoreSync.replaceAll(with: records)
                        result(nil)
                    }
                } else {
                    result(nil)
                }

            case "clearOnLock":
                try? keychain.deleteAll()
                if #available(iOS 17.0, *) {
                    Task {
                        try? await IdentityStoreSync.clearAll()
                        result(nil)
                    }
                } else {
                    result(nil)
                }

            case "drainOutbox":
                let records = (try? outbox.drain()) ?? []
                result(records.map(encodeRecord))

            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}

private func decodeRecord(_ dict: [String: Any]) -> PasskeyRecord? {
    guard let rpId = dict["rpId"] as? String,
          let rpName = dict["rpName"] as? String,
          let userHandle = dict["userHandle"] as? String,
          let userName = dict["userName"] as? String,
          let credentialId = dict["credentialId"] as? String,
          let privateKey = dict["privateKey"] as? String,
          let publicKeyCose = dict["publicKeyCose"] as? String,
          let signCount = dict["signCount"] as? Int,
          let discoverable = dict["discoverable"] as? Bool,
          let createdAtEpochMs = dict["createdAtEpochMs"] as? Int64
    else { return nil }
    return PasskeyRecord(
        rpId: rpId,
        rpName: rpName,
        userHandle: userHandle,
        userName: userName,
        credentialId: credentialId,
        privateKey: privateKey,
        publicKeyCose: publicKeyCose,
        signCount: UInt32(signCount),
        discoverable: discoverable,
        createdAtEpochMs: createdAtEpochMs
    )
}

private func encodeRecord(_ record: PasskeyRecord) -> [String: Any] {
    [
        "rpId": record.rpId,
        "rpName": record.rpName,
        "userHandle": record.userHandle,
        "userName": record.userName,
        "credentialId": record.credentialId,
        "privateKey": record.privateKey,
        "publicKeyCose": record.publicKeyCose,
        "signCount": Int(record.signCount),
        "discoverable": record.discoverable,
        "createdAtEpochMs": record.createdAtEpochMs,
    ]
}
