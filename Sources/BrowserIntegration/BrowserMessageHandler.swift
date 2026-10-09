import Domain
import Foundation

/// Answers KeePassXC-Browser requests. Each socket connection is one browser with its own session keys.
public actor BrowserMessageHandler {
    private struct Session {
        let clientPublicKey: Data
        let keyPair: NaClKeyPair
        var isAssociated = false
        var seenNonces: Set<Data> = []
    }

    private typealias JSON = [String: Any]

    private var sessions: [Int: Session] = [:]
    /// One generator window at a time, as in KeePassXC.
    private var isGeneratingPassword = false
    private weak var provider: (any BrowserVaultProviding)?

    public init(provider: any BrowserVaultProviding) {
        self.provider = provider
    }

    public func endSession(_ connection: Int) {
        sessions[connection] = nil
    }

    /// Unencrypted notification sent to every connected browser, like KeePassXC does.
    public nonisolated static func signal(_ action: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["action": action])) ?? Data()
    }

    /// Returns the reply to one message from `connection`.
    public func handle(_ data: Data, from connection: Int) async -> Data {
        let reply: JSON
        if let request = try? JSONSerialization.jsonObject(with: data) as? JSON, !request.isEmpty {
            reply = await self.reply(to: request, from: connection)
        } else {
            reply = Self.error("", .emptyMessageReceived)
        }
        return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
    }

    private func reply(to request: JSON, from connection: Int) async -> JSON {
        let action = request["action"] as? String ?? ""
        guard !action.isEmpty else {
            return Self.error(action, .incorrectAction)
        }
        if action == BrowserAction.changePublicKeys {
            return changePublicKeys(request, action: action, connection: connection)
        }

        guard let provider else {
            return Self.error(action, .databaseNotOpened)
        }
        guard let session = sessions[connection] else {
            return Self.error(action, .clientPublicKeyNotReceived)
        }
        guard await provider.isVaultUnlocked else {
            if request["triggerUnlock"] as? String == "true" {
                await provider.showUnlockForBrowser()
            }
            return Self.error(action, .databaseNotOpened)
        }
        guard let (message, nonce) = decrypt(request, session: session, connection: connection) else {
            return Self.error(action, .cannotDecryptMessage)
        }

        switch action {
        case BrowserAction.getDatabaseHash:
            guard message["action"] as? String == action else {
                return Self.error(action, .cannotDecryptMessage)
            }
            guard let hash = await provider.browserDatabaseHash() else {
                return Self.error(action, .databaseHashNotReceived)
            }
            return encrypt(["hash": hash], action: action, nonce: nonce, session: session)

        case BrowserAction.associate:
            guard let key = message["key"] as? String, Data(base64Encoded: key) == session.clientPublicKey else {
                return Self.error(action, .associationFailed)
            }
            let identificationKey = (message["idKey"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
            guard let id = await provider.associateBrowser(identificationKey: identificationKey),
                  let hash = await provider.browserDatabaseHash() else {
                return Self.error(action, .actionCancelledOrDenied)
            }
            markAssociated(connection, session: session)
            return encrypt(["hash": hash, "id": id], action: action, nonce: nonce, session: session)

        case BrowserAction.testAssociate:
            guard let id = message["id"] as? String, !id.isEmpty,
                  let key = message["key"] as? String, !key.isEmpty else {
                return Self.error(action, .databaseNotOpened)
            }
            guard let stored = await provider.browserAssociationKey(for: id), stored == key,
                  let hash = await provider.browserDatabaseHash() else {
                return Self.error(action, .associationFailed)
            }
            markAssociated(connection, session: session)
            return encrypt(["hash": hash, "id": id], action: action, nonce: nonce, session: session)

        case BrowserAction.getLogins:
            guard sessions[connection]?.isAssociated == true else {
                return Self.error(action, .associationFailed)
            }
            guard let url = message["url"] as? String, !url.isEmpty else {
                return Self.error(action, .noURLProvided)
            }
            guard await hasConnectedKey(message["keys"], provider: provider) else {
                return Self.error(action, .noLoginsFound)
            }
            let query = BrowserLoginQuery(
                siteURL: url,
                formURL: message["submitUrl"] as? String ?? "",
                httpAuth: message["httpAuth"] as? String == "true"
            )
            let logins = await provider.browserLogins(for: query)
            guard !logins.isEmpty, let hash = await provider.browserDatabaseHash() else {
                return Self.error(action, .noLoginsFound)
            }
            return encrypt(
                [
                    "count": logins.count,
                    "entries": logins.map(Self.json),
                    "hash": hash,
                    "id": message["id"] as? String ?? ""
                ],
                action: action,
                nonce: nonce,
                session: session
            )

        case BrowserAction.getTOTP:
            guard sessions[connection]?.isAssociated == true else {
                return Self.error(action, .associationFailed)
            }
            guard message["action"] as? String == action else {
                return Self.error(action, .incorrectAction)
            }
            guard let id = (message["uuid"] as? String).flatMap(UUID.init(browserHex:)) else {
                return Self.error(action, .noValidUUIDProvided)
            }
            let totp = await provider.browserTOTP(forEntry: id) ?? ""
            return encrypt(["totp": totp], action: action, nonce: nonce, session: session)

        case BrowserAction.setLogin:
            guard sessions[connection]?.isAssociated == true else {
                return Self.error(action, .associationFailed)
            }
            guard let url = message["url"] as? String, !url.isEmpty else {
                return Self.error(action, .noURLProvided)
            }
            let login = message["login"] as? String ?? ""
            let password = message["password"] as? String ?? ""
            if Self.containsPlaceholder(login) || Self.containsPlaceholder(password) {
                return Self.error(action, .cannotUseReferences)
            }
            var entryID: UUID?
            if let uuid = message["uuid"] as? String, !uuid.isEmpty {
                guard let id = UUID(browserHex: uuid) else {
                    return Self.error(action, .noValidUUIDProvided)
                }
                entryID = id
            }
            let groupID = (message["group"] as? String).flatMap { $0.isEmpty ? nil : $0 } != nil
                ? (message["groupUuid"] as? String).flatMap(UUID.init(browserHex:))
                : nil
            let saved = await provider.saveBrowserLogin(BrowserSaveRequest(
                siteURL: url,
                formURL: message["submitUrl"] as? String ?? "",
                login: login,
                password: password,
                entryID: entryID,
                groupID: groupID,
                downloadFavicon: message["downloadFavicon"] as? String == "true"
            ))
            let hash = await provider.browserDatabaseHash() ?? ""
            return encrypt(
                ["count": NSNull(), "entries": NSNull(), "error": saved ? "success" : "error", "hash": hash],
                action: action,
                nonce: nonce,
                session: session
            )

        case BrowserAction.getDatabaseGroups:
            guard sessions[connection]?.isAssociated == true else {
                return Self.error(action, .associationFailed)
            }
            guard message["action"] as? String == action else {
                return Self.error(action, .incorrectAction)
            }
            guard let root = await provider.browserGroups() else {
                return Self.error(action, .noGroupsFound)
            }
            return encrypt(["groups": ["groups": [Self.json(root)]]], action: action, nonce: nonce, session: session)

        case BrowserAction.createNewGroup:
            guard sessions[connection]?.isAssociated == true else {
                return Self.error(action, .associationFailed)
            }
            guard message["action"] as? String == action else {
                return Self.error(action, .incorrectAction)
            }
            guard let path = message["groupName"] as? String, !path.isEmpty,
                  let group = await provider.createBrowserGroup(path: path) else {
                return Self.error(action, .cannotCreateNewGroup)
            }
            return encrypt(["name": group.title, "uuid": group.id.browserHex], action: action, nonce: nonce, session: session)

        case BrowserAction.generatePassword:
            let requestID = request["requestID"] as? String ?? message["requestID"] as? String
            guard !isGeneratingPassword else {
                return Self.error(action, .actionCancelledOrDenied, requestID: requestID)
            }
            isGeneratingPassword = true
            let password = await provider.generateBrowserPassword()
            isGeneratingPassword = false
            guard let password else {
                return Self.error(action, .actionCancelledOrDenied, requestID: requestID)
            }
            return encrypt(["password": password], action: action, nonce: nonce, session: session)

        case BrowserAction.lockDatabase:
            guard message["action"] as? String == action else {
                return Self.error(action, .databaseHashNotReceived)
            }
            await provider.lockForBrowser()
            return encrypt([:], action: action, nonce: nonce, session: session)

        default:
            return Self.error(action, .incorrectAction)
        }
    }

    private func changePublicKeys(_ request: JSON, action: String, connection: Int) -> JSON {
        guard let clientKey = (request["publicKey"] as? String).flatMap({ Data(base64Encoded: $0) }),
              clientKey.count == NaClBox.keyBytes,
              let nonce = (request["nonce"] as? String).flatMap({ Data(base64Encoded: $0) }),
              nonce.count == NaClBox.nonceBytes else {
            return Self.error(action, .clientPublicKeyNotReceived)
        }
        let keyPair = NaClKeyPair.generate()
        sessions[connection] = Session(clientPublicKey: clientKey, keyPair: keyPair)
        return [
            "action": action,
            "version": BrowserProtocol.compatibleVersion,
            "success": "true",
            "nonce": NaClBox.increment(nonce).base64EncodedString(),
            "publicKey": keyPair.publicKey.base64EncodedString()
        ]
    }

    /// Only marks the session whose keys the request came with; the browser may have rekeyed meanwhile.
    private func markAssociated(_ connection: Int, session: Session) {
        guard sessions[connection]?.keyPair.publicKey == session.keyPair.publicKey else {
            return
        }
        sessions[connection]?.isAssociated = true
    }

    private func hasConnectedKey(_ value: Any?, provider: any BrowserVaultProviding) async -> Bool {
        let pairs = (value as? [JSON] ?? []).compactMap { pair -> (String, String)? in
            guard let id = pair["id"] as? String, let key = pair["key"] as? String, !id.isEmpty, !key.isEmpty else {
                return nil
            }
            return (id, key)
        }
        for (id, key) in pairs {
            if await provider.browserAssociationKey(for: id) == key {
                return true
            }
        }
        return false
    }

    private func decrypt(_ request: JSON, session: Session, connection: Int) -> (JSON, Data)? {
        guard let nonce = (request["nonce"] as? String).flatMap({ Data(base64Encoded: $0) }),
              nonce.count == NaClBox.nonceBytes,
              let box = (request["message"] as? String).flatMap({ Data(base64Encoded: $0) }),
              box.count <= BrowserProtocol.maximumMessageSize,
              !session.seenNonces.contains(nonce),
              let plain = NaClBox.open(box, nonce: nonce, publicKey: session.clientPublicKey, secretKey: session.keyPair.secretKey),
              let message = try? JSONSerialization.jsonObject(with: plain) as? JSON else {
            return nil
        }
        sessions[connection]?.seenNonces.insert(nonce)
        return (message, nonce)
    }

    private func encrypt(_ parameters: JSON, action: String, nonce: Data, session: Session) -> JSON {
        let replyNonce = NaClBox.increment(nonce)
        var message = parameters
        message["version"] = BrowserProtocol.compatibleVersion
        message["success"] = "true"
        message["nonce"] = replyNonce.base64EncodedString()
        guard let plain = try? JSONSerialization.data(withJSONObject: message),
              let box = NaClBox.seal(plain, nonce: replyNonce, publicKey: session.clientPublicKey, secretKey: session.keyPair.secretKey) else {
            return Self.error(action, .cannotEncryptMessage)
        }
        return [
            "action": action,
            "message": box.base64EncodedString(),
            "nonce": replyNonce.base64EncodedString()
        ]
    }

    private static func error(_ action: String, _ code: BrowserErrorCode, requestID: String? = nil) -> JSON {
        var reply: JSON = ["action": action, "errorCode": String(code.rawValue), "error": code.message]
        if let requestID, !requestID.isEmpty {
            reply["requestID"] = requestID
        }
        return reply
    }

    private static let staticPlaceholders: Set<String> = [
        "TITLE", "USERNAME", "PASSWORD", "URL", "NOTES", "TOTP", "UUID", "GROUP", "GROUP_PATH", "GROUP_NOTES",
        "DB_PATH", "DB_DIR", "DB_NAME", "DB_BASENAME", "DB_EXT", "ENV_DIRSEP", "ENV_PROGRAMFILES_X86",
        "CLIPBOARD", "PICKCHARS", "HMACOTP", "TIMEOTP"
    ]
    private static let dynamicPlaceholders = ["REF:", "S:", "URL:", "CMD:", "T-REPLACE-RX:", "T-CONV:", "PICKCHARS:", "PICKFIELD", "DT_", "ENV:"]

    /// Known KeePass placeholders and references (`{USERNAME}`, `{REF:…}`) aren't saved from the browser;
    /// other text in braces is an ordinary password.
    private static func containsPlaceholder(_ value: String) -> Bool {
        var rest = value[...]
        while let open = rest.firstIndex(of: "{") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else {
                return false
            }
            let name = rest[afterOpen..<close].uppercased()
            if staticPlaceholders.contains(name) || dynamicPlaceholders.contains(where: { name.hasPrefix($0) }) {
                return true
            }
            rest = rest[afterOpen...]
        }
        return false
    }

    private static func json(_ group: VaultBrowserGroup) -> JSON {
        ["name": group.title, "uuid": group.id.browserHex, "children": group.children.map(json)]
    }

    private static func json(_ login: BrowserLogin) -> JSON {
        var entry: JSON = [
            "login": login.login,
            "password": login.password,
            "name": login.name,
            "uuid": login.uuid.browserHex,
            "group": login.group,
            "stringFields": login.stringFields.map { [$0.key: $0.value] }
        ]
        if let totp = login.totp {
            entry["totp"] = totp
        }
        if login.isExpired {
            entry["expired"] = "true"
        }
        if let skipAutoSubmit = login.skipAutoSubmit {
            entry["skipAutoSubmit"] = skipAutoSubmit ? "true" : "false"
        }
        return entry
    }
}
