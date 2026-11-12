import CryptoKit
import Foundation

/// How a client identifies itself to builders: its own secret token. Made once per client Mac;
/// a new one only when it asks again after a builder declined it.
struct ClientIdentity: Codable, Equatable, Sendable {
    var token: String
    /// This Mac's name, shown on the builder.
    var name: String

    static func new(name: String) -> ClientIdentity {
        ClientIdentity(token: BuilderLink.newToken(), name: name)
    }

    /// Six digits the builder's user enters to approve this Mac. Derived from the token, so it's
    /// never sent and another Mac can't ask with the same code.
    var code: String { ClientAccess.code(forToken: token) }

    /// "123 456"
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

/// Who may download a builder's builds. A client with an unknown token that sends its name
/// becomes a pairing request; it gets builds only once the builder's user enters the code it
/// shows. Used from the server's queue and the main actor.
final class ClientAccess: @unchecked Sendable {
    enum Decision: Equatable {
        case allowed
        case pending
        case declined
        case refused
    }

    /// A request whose client stopped asking (it polls every few seconds while waiting) is dropped.
    static let requestLifetime: TimeInterval = 120
    /// At most this many requests are kept; the oldest goes first.
    static let maxRequests = 10
    /// At most this many from one address, so one Mac can't push the others' requests out.
    static let maxRequestsPerAddress = 2
    static let maxDeclined = 200

    private let lock = NSLock()
    private var approved: [ApprovedClient]
    private var requests: [PairingRequest] = []
    /// Token hashes the user declined; their client gets 401 instead of asking again. Oldest first.
    private var declined: [String]
    private let onChange: @Sendable (_ newRequest: PairingRequest?) -> Void

    init(approved: [ApprovedClient] = [], declined: [String] = [],
         onChange: @escaping @Sendable (_ newRequest: PairingRequest?) -> Void = { _ in }) {
        self.approved = approved
        self.declined = declined
        self.onChange = onChange
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func code(forToken token: String) -> String {
        let digest = SHA256.hash(data: Data(("orchard-code:" + token).utf8))
        let number = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return String(format: "%06d", number % 1_000_000)
    }

    var approvedClients: [ApprovedClient] { lock.withLock { approved } }
    var pairingRequests: [PairingRequest] { lock.withLock { requests } }
    var declinedTokens: [String] { lock.withLock { declined } }

    /// Decides a request by its bearer `token`. An unknown token with a `name` is a pairing request.
    func check(token: String?, name: String?, address: String? = nil, now: Date = Date()) -> Decision {
        guard let token, !token.isEmpty else { return .refused }
        let hash = Self.hash(token)
        var added: PairingRequest?
        var pruned = false
        let decision: Decision = lock.withLock {
            if approved.contains(where: { $0.tokenHash == hash }) { return .allowed }
            if declined.contains(hash) { return .declined }
            pruned = pruneLocked(now: now)
            guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
            else { return .refused }
            if let index = requests.firstIndex(where: { $0.id == hash }) {
                requests[index].lastSeen = now
                requests[index].address = address
                return .pending
            }
            let request = PairingRequest(id: hash, name: String(name.prefix(64)), code: Self.code(forToken: token),
                                         address: address, lastSeen: now)
            if let address {
                let fromAddress = requests.filter { $0.address == address }.sorted { $0.lastSeen < $1.lastSeen }
                if fromAddress.count >= Self.maxRequestsPerAddress, let oldest = fromAddress.first {
                    requests.removeAll { $0.id == oldest.id }
                }
            }
            requests.append(request)
            if requests.count > Self.maxRequests {
                requests.sort { $0.lastSeen > $1.lastSeen }
                requests.removeLast(requests.count - Self.maxRequests)
            }
            added = request
            return .pending
        }
        if added != nil || pruned { onChange(added) }
        return decision
    }

    /// Drops requests whose client stopped asking.
    func prune(now: Date = Date()) {
        if lock.withLock({ pruneLocked(now: now) }) { onChange(nil) }
    }

    private func pruneLocked(now: Date) -> Bool {
        let before = requests.count
        requests.removeAll { now.timeIntervalSince($0.lastSeen) > Self.requestLifetime }
        return requests.count != before
    }

    /// Approves `request` if `code` is the one its client shows. Anything but digits is ignored.
    @discardableResult
    func approve(_ request: PairingRequest.ID, code: String) -> Bool {
        let digits = code.filter { $0.isASCII && $0.isNumber }
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
            declined.removeAll { $0 == request }
            declined.append(request)
            if declined.count > Self.maxDeclined { declined.removeFirst(declined.count - Self.maxDeclined) }
        }
        onChange(nil)
    }

    /// Stops `client` from downloading builds. Asking again starts a new request.
    func remove(_ client: ApprovedClient.ID) {
        lock.withLock { approved.removeAll { $0.id == client } }
        onChange(nil)
    }
}
