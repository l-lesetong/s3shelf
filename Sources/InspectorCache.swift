import Foundation

enum InspectorCacheKind: Hashable {
    case tags, headers, acl, policy, accessBlock, ownership, policyStatus

    static let permissions: Set<Self> = [.acl, .policy, .accessBlock, .ownership, .policyStatus]
}

struct InspectorReading<Value> {
    let value: Value
    var cachedAt: Date? = nil
}

struct InspectorCachePolicy: Equatable {
    static let lifetimes = [0, 5, 15, 30, 45, 60, 120, 300, 900, 1800, 3600]
    static let capacities = [64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
    private static let defaultLifetime = 30
    private static let defaultCapacity = 32 * 1024

    let lifetimeSeconds: Int
    let capacityKiB: Int
    var capacityBytes: Int { capacityKiB * 1024 }

    private static let lifetimeKey = "tagCacheLifetimeSeconds"
    private static let capacityKey = "tagCacheCapacityKiB"

    init(lifetimeSeconds: Int, capacityKiB: Int) {
        self.lifetimeSeconds = Self.lifetimes.contains(lifetimeSeconds) ? lifetimeSeconds : Self.defaultLifetime
        self.capacityKiB = Self.capacities.contains(capacityKiB) ? capacityKiB : Self.defaultCapacity
    }

    init(defaults: UserDefaults) {
        self.init(lifetimeSeconds: defaults.object(forKey: Self.lifetimeKey) as? Int ?? Self.defaultLifetime,
                  capacityKiB: defaults.object(forKey: Self.capacityKey) as? Int ?? Self.defaultCapacity)
    }

    func save(to defaults: UserDefaults) {
        defaults.set(lifetimeSeconds, forKey: Self.lifetimeKey)
        defaults.set(capacityKiB, forKey: Self.capacityKey)
    }
}

@MainActor
final class InspectorCache {
    private struct Resource: Hashable {
        let kind: InspectorCacheKind
        let bucket: String
        let key: Data?
        let version: Data?

        init(_ target: InspectorTarget, kind: InspectorCacheKind) {
            self.kind = kind
            bucket = target.bucket.Name
            let object = kind == .ownership ? nil : target.object
            key = object.map { Data($0.key.utf8) }
            version = object?.version.map { Data($0.utf8) }
        }

        func isAffected(by change: ObjectChange) -> Bool {
            guard bucket == change.bucket else { return false }
            guard let changedKey = change.key else { return true }
            guard let key else { return false }
            return change.recursive ? key.starts(with: changedKey.utf8) : key.elementsEqual(changedKey.utf8)
        }
    }

    private struct Entry {
        let reading: Any
        let loadedAt: ContinuousClock.Instant
        let cost: Int
        var hits = 1
        var lastAccess: ContinuousClock.Instant
    }

    private var entries: [Resource: Entry] = [:]
    private var reads: [Resource: UUID] = [:]
    private var usedBytes = 0
    private var policy: InspectorCachePolicy

    init(policy: InspectorCachePolicy) { self.policy = policy }

    func configure(_ policy: InspectorCachePolicy) {
        let now = ContinuousClock.now
        // Extending the lifetime must not revive entries that have already expired.
        removeExpired(at: now)
        self.policy = policy
        removeExpired(at: now)
        trim(to: policy.capacityBytes)
        if policy.lifetimeSeconds == 0 { reads.removeAll() }
    }

    private func cached<Value>(_ resource: Resource) -> InspectorReading<Value>? {
        guard var entry = entries[resource] else { return nil }
        let now = ContinuousClock.now
        guard isFresh(entry, at: now) else {
            remove(resource)
            return nil
        }
        entry.hits += 1
        entry.lastAccess = now
        entries[resource] = entry
        return entry.reading as? InspectorReading<Value>
    }

    func load<Value>(_ target: InspectorTarget, kind: InspectorCacheKind, fresh: Bool = false,
                     fetch: @MainActor () async throws -> (value: Value, bytes: Int?)) async throws -> InspectorReading<Value> {
        try Task.checkCancellation()
        let resource = Resource(target, kind: kind)
        if !fresh, let cached: InspectorReading<Value> = cached(resource) { return cached }
        guard policy.lifetimeSeconds > 0 else {
            let result = try await fetch()
            try Task.checkCancellation()
            return InspectorReading(value: result.value)
        }
        let token = UUID()
        reads[resource] = token
        defer { if reads[resource] == token { reads[resource] = nil } }

        do {
            let result = try await fetch()
            try Task.checkCancellation()
            // A refresh, mutation or newer read can overtake a pending request.
            if reads[resource] == token {
                if let bytes = result.bytes { store(result.value, bytes: bytes, for: resource) }
                else { remove(resource) }
            }
            return InspectorReading(value: result.value)
        } catch {
            if !Task.isCancelled, reads[resource] == token { remove(resource) }
            throw error
        }
    }

    func invalidate(_ target: InspectorTarget, kinds: Set<InspectorCacheKind>) {
        for kind in kinds {
            let resource = Resource(target, kind: kind)
            remove(resource)
            reads[resource] = nil
        }
    }

    func invalidate(changes: [ObjectChange], kinds: Set<InspectorCacheKind>? = nil) {
        func isAffected(_ resource: Resource) -> Bool {
            (kinds?.contains(resource.kind) ?? true) && changes.contains(where: resource.isAffected)
        }
        for resource in entries.keys where isAffected(resource) { remove(resource) }
        reads = reads.filter { !isAffected($0.key) }
    }

    func invalidateMutation(_ command: String, change: ObjectChange) {
        switch command {
        case "put-bucket-tagging", "delete-bucket-tagging", "put-object-tagging", "delete-object-tagging":
            invalidate(changes: [change], kinds: [.tags, .headers])
        case "put-bucket-acl", "put-object-acl", "put-bucket-policy", "delete-bucket-policy",
             "put-public-access-block", "delete-public-access-block",
             "put-bucket-ownership-controls", "delete-bucket-ownership-controls":
            invalidate(changes: [change])
        default: break
        }
    }

    private func store<Value>(_ value: Value, bytes: Int, for resource: Resource) {
        let now = ContinuousClock.now
        removeExpired(at: now)
        let resourceBytes = resource.bucket.utf8.count + (resource.key?.count ?? 0) + (resource.version?.count ?? 0)
        let cost = 256 + resourceBytes + bytes
        let hits = entries[resource]?.hits ?? 1
        remove(resource)
        guard cost <= policy.capacityBytes else { return }
        trim(to: policy.capacityBytes - cost)
        entries[resource] = Entry(reading: InspectorReading(value: value, cachedAt: Date()),
                                  loadedAt: now, cost: cost, hits: hits, lastAccess: now)
        usedBytes += cost
    }

    private func isFresh(_ entry: Entry, at now: ContinuousClock.Instant) -> Bool {
        entry.loadedAt.duration(to: now) < .seconds(policy.lifetimeSeconds)
    }

    private func removeExpired(at now: ContinuousClock.Instant) {
        for (resource, entry) in entries where !isFresh(entry, at: now) { remove(resource) }
    }

    private func trim(to bytes: Int) {
        guard usedBytes > bytes else { return }
        let coldestFirst = entries.sorted { lhs, rhs in
            if lhs.value.hits != rhs.value.hits { return lhs.value.hits < rhs.value.hits }
            return lhs.value.lastAccess < rhs.value.lastAccess
        }
        for (resource, _) in coldestFirst {
            remove(resource)
            if usedBytes <= bytes { break }
        }
    }

    private func remove(_ resource: Resource) {
        if let entry = entries.removeValue(forKey: resource) { usedBytes -= entry.cost }
    }
}
