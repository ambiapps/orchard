import CryptoKit
import Foundation

/// What a client sends with every request to its builder: its own secret token, and the code the
/// builder's user enters to approve it. Made on the client, one per builder.
struct ClientIdentity: Codable, Equatable, Sendable {
    var token: String
    /// Six digits, shown on the client while it waits for approval.
    var code: String
    /// This Mac's name, shown on the builder.
    var name: String

    static func new(name: String) -> ClientIdentity {
        ClientIdentity(token: BuilderLink.newToken(), code: String(format: "%06d", Int.random(in: 0..<1_000_000)),
                       name: name)
    }

    /// "123 456"
    var formattedCode: String { ClientIdentity.format(code) }

    static func format(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }
}

/// A Mac the builder's user approved. Only a hash of its token is kept.
struct ApprovedClient: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var tokenHash: String
    var approvedAt = Date()
}

/// A Mac that asked for the builder's builds and waits for its user to enter its code.
struct PairingRequest: Hashable, Sendable, Identifiable {
    /// The hash of the client's token.
    var id: String
    var name: String
    var code: String
    var address: String?
    var lastSeen: Date
}

/// Who may download a builder's builds. A client with an unknown token that sends its name and
/// code becomes a pairing request; it gets builds only once the builder's user enters that code.
/// Used from the server's queue and the main actor.
final class ClientAccess: @unchecked Sendable {
    enum Decision: Equatable {
        case allowed
        case pending
        case refused
    }

    /// A request whose client stopped asking (it polls every few seconds while waiting) is dropped.
    static let requestLifetime: TimeInterval = 120
    /// At most this many requests are kept; the oldest goes first.
    static let maxRequests = 10

    private let lock = NSLock()
    private var approved: [ApprovedClient]
    private var requests: [PairingRequest] = []
    /// Tokens the user declined, until Orchard quits; their client gets 401 instead of asking again.
    private var declined: Set<String> = []
    private let onChange: @Sendable (_ newRequest: PairingRequest?) -> Void

    init(approved: [ApprovedClient] = [], onChange: @escaping @Sendable (_ newRequest: PairingRequest?) -> Void = { _ in }) {
        self.approved = approved
        self.onChange = onChange
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var approvedClients: [ApprovedClient] { lock.withLock { approved } }
    var pairingRequests: [PairingRequest] { lock.withLock { requests } }

    /// Decides a request by its bearer `token`. An unknown token with a `name` and a six-digit
    /// `code` is a pairing request.
    func check(token: String?, name: String?, code: String?, address: String? = nil, now: Date = Date()) -> Decision {
        guard let token, !token.isEmpty else { return .refused }
        let hash = Self.hash(token)
        var added: PairingRequest?
        var changed = false
        let decision: Decision = lock.withLock {
            if approved.contains(where: { $0.tokenHash == hash }) { return .allowed }
            let before = requests.count
            requests.removeAll { now.timeIntervalSince($0.lastSeen) > Self.requestLifetime }
            changed = requests.count != before
            guard !declined.contains(hash), let code, code.count == 6, code.allSatisfy(\.isASCII), code.allSatisfy(\.isNumber),
                  let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
            else { return .refused }
            if let index = requests.firstIndex(where: { $0.id == hash }) {
                requests[index].lastSeen = now
                requests[index].address = address
                return .pending
            }
            let request = PairingRequest(id: hash, name: String(name.prefix(64)), code: code, address: address, lastSeen: now)
            requests.append(request)
            if requests.count > Self.maxRequests {
                requests.sort { $0.lastSeen > $1.lastSeen }
                requests.removeLast(requests.count - Self.maxRequests)
            }
            added = request
            return .pending
        }
        if added != nil || changed { onChange(added) }
        return decision
    }

    /// Approves `request` if `code` is the one its client shows. Spaces are ignored.
    @discardableResult
    func approve(_ request: PairingRequest.ID, code: String) -> Bool {
        let digits = code.filter { !$0.isWhitespace }
        let approvedNow: Bool = lock.withLock {
            guard let index = requests.firstIndex(where: { $0.id == request }), requests[index].code == digits
            else { return false }
            let request = requests.remove(at: index)
            approved.append(ApprovedClient(name: request.name, tokenHash: request.id))
            return true
        }
        if approvedNow { onChange(nil) }
        return approvedNow
    }

    func decline(_ request: PairingRequest.ID) {
        lock.withLock {
            requests.removeAll { $0.id == request }
            declined.insert(request)
        }
        onChange(nil)
    }

    /// Stops `client` from downloading builds. Asking again starts a new request.
    func remove(_ client: ApprovedClient.ID) {
        lock.withLock { approved.removeAll { $0.id == client } }
        onChange(nil)
    }
}
