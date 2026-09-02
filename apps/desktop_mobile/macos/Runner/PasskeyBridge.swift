import FlutterMacOS
import Foundation

/// macOS twin of `apps/desktop_mobile/ios/Runner/PasskeyBridge.swift` — see
/// that file for the full explanation. The only difference is how the
/// `FlutterBinaryMessenger` is obtained (`FlutterViewController.engine` here
/// vs. the implicit-engine bridge on iOS).
enum PasskeyBridge {
    static func register(with controller: FlutterViewController) {
        let channel = FlutterMethodChannel(name: "com.kavach.passkeys", binaryMessenger: controller.engine.binaryMessenger)
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
                if #available(macOS 14.0, *) {
                    Task {
                        try? await IdentityStoreSync.replaceAll(with: records)
                        result(nil)
                    }
                } else {
                    result(nil)
                }

            case "clearOnLock":
                try? keychain.deleteAll()
                if #available(macOS 14.0, *) {
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
