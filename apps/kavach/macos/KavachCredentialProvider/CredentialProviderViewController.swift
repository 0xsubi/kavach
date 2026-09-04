import AuthenticationServices
import AppKit

/// macOS twin of `apps/kavach/ios/KavachCredentialProvider/CredentialProviderViewController.swift`
/// — same `ASCredentialProviderViewController` API surface (Apple ships it
/// identically on iOS 17+/macOS 14+), same `KavachSwiftCore` authenticator,
/// different only in using AppKit instead of UIKit for the (rare)
/// user-interaction screens.
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private let authenticator = PasskeyAuthenticator()
    private let keychain = KeychainStore()

    // MARK: - Registration

    override func prepareInterface(forPasskeyRegistration registrationRequest: ASCredentialRequest) {
        guard let request = registrationRequest as? ASPasskeyCredentialRequest,
              let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity
        else {
            cancel(.failed)
            return
        }

        presentConfirmation(
            title: "Create passkey",
            relyingParty: identity.relyingPartyIdentifier,
            userName: identity.userName,
            confirmTitle: "Create",
            onConfirm: { [weak self] in self?.completeRegistration(request: request, identity: identity) },
            onCancel: { [weak self] in self?.cancel(.userCanceled) }
        )
    }

    private func completeRegistration(request: ASPasskeyCredentialRequest, identity: ASPasskeyCredentialIdentity) {
        do {
            let result = try authenticator.register(
                rpId: identity.relyingPartyIdentifier,
                rpName: identity.relyingPartyIdentifier,
                userName: identity.userName,
                userHandle: identity.userHandle
            )
            let credential = ASPasskeyRegistrationCredential(
                relyingParty: identity.relyingPartyIdentifier,
                clientDataHash: request.clientDataHash,
                credentialID: result.credentialId,
                attestationObject: result.attestationObject
            )
            extensionContext.completeRegistrationRequest(using: credential, completionHandler: nil)
        } catch {
            cancel(.failed)
        }
    }

    // MARK: - Assertion (silent)

    override func provideCredentialWithoutUserInteraction(for credentialRequest: ASCredentialRequest) {
        guard let request = credentialRequest as? ASPasskeyCredentialRequest,
              let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity
        else {
            cancel(.failed)
            return
        }
        do {
            try completeAssertion(request: request, identity: identity)
        } catch {
            cancel(.userInteractionRequired)
        }
    }

    // MARK: - Assertion (with UI)

    override func prepareInterfaceToProvideCredential(for credentialRequest: ASCredentialRequest) {
        guard let request = credentialRequest as? ASPasskeyCredentialRequest,
              let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity
        else {
            cancel(.failed)
            return
        }

        presentConfirmation(
            title: "Sign in with passkey",
            relyingParty: identity.relyingPartyIdentifier,
            userName: identity.userName,
            confirmTitle: "Continue",
            onConfirm: { [weak self] in
                do {
                    try self?.completeAssertion(request: request, identity: identity)
                } catch {
                    self?.cancel(.credentialIdentityNotFound)
                }
            },
            onCancel: { [weak self] in self?.cancel(.userCanceled) }
        )
    }

    private func completeAssertion(request: ASPasskeyCredentialRequest, identity: ASPasskeyCredentialIdentity) throws {
        let result = try authenticator.assert(
            credentialId: identity.credentialID,
            rpId: identity.relyingPartyIdentifier,
            clientDataHash: request.clientDataHash
        )
        let credential = ASPasskeyAssertionCredential(
            userHandle: result.userHandle,
            relyingParty: identity.relyingPartyIdentifier,
            signature: result.signature,
            clientDataHash: request.clientDataHash,
            authenticatorData: result.authenticatorData,
            credentialID: identity.credentialID
        )
        extensionContext.completeAssertionRequest(using: credential, completionHandler: nil)
    }

    // MARK: - Discoverable-credential picker

    override func prepareCredentialList(
        for serviceIdentifiers: [ASCredentialServiceIdentifier],
        requestParameters: ASPasskeyCredentialRequestParameters
    ) {
        let rpId = requestParameters.relyingPartyIdentifier
        let matches = (try? keychain.findAll(rpId: rpId)) ?? []
        guard !matches.isEmpty else {
            cancel(.credentialIdentityNotFound)
            return
        }

        presentPicker(records: matches) { [weak self] record in
            guard let self, let credentialId = Data(base64Encoded: record.credentialId) else {
                self?.cancel(.failed)
                return
            }
            do {
                let result = try self.authenticator.assert(
                    credentialId: credentialId,
                    rpId: rpId,
                    clientDataHash: requestParameters.clientDataHash
                )
                let credential = ASPasskeyAssertionCredential(
                    userHandle: result.userHandle,
                    relyingParty: rpId,
                    signature: result.signature,
                    clientDataHash: requestParameters.clientDataHash,
                    authenticatorData: result.authenticatorData,
                    credentialID: credentialId
                )
                self.extensionContext.completeAssertionRequest(using: credential, completionHandler: nil)
            } catch {
                self.cancel(.failed)
            }
        }
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        cancel(.credentialIdentityNotFound)
    }

    // MARK: - Helpers

    private func cancel(_ code: ASExtensionError.Code) {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue))
    }

    private func presentConfirmation(
        title: String,
        relyingParty: String,
        userName: String,
        confirmTitle: String,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        show(ConfirmationViewController(
            title: title,
            relyingParty: relyingParty,
            userName: userName,
            confirmTitle: confirmTitle,
            onConfirm: onConfirm,
            onCancel: onCancel
        ))
    }

    private func presentPicker(records: [PasskeyRecord], onSelect: @escaping (PasskeyRecord) -> Void) {
        show(CredentialPickerViewController(records: records, onSelect: onSelect))
    }

    private func show(_ controller: NSViewController) {
        children.forEach { $0.removeFromParent() }
        view.subviews.forEach { $0.removeFromSuperview() }
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.width, .height]
        view.addSubview(controller.view)
    }
}
