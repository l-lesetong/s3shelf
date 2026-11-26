import AppKit
import SwiftUI

struct Operation: Identifiable, Decodable, Sendable {
    let service: String
    let name: String
    let summary: String
    let required: [String]
    let fields: [String]
    let fileInput: String?
    let fileOutput: Bool
    let mutates: Bool
    var id: String { "\(service) \(name)" }
    var createsBucket: Bool { service == "s3api" && name == "create-bucket" }
    var bucketDeletionFields: [String] {
        switch id {
        case "s3api delete-bucket", "s3control delete-bucket": ["Bucket"]
        case "s3tables delete-table-bucket": ["tableBucketARN"]
        case "s3vectors delete-vector-bucket": ["vectorBucketName", "vectorBucketArn"]
        default: []
        }
    }
    var deletesBucket: Bool { !bucketDeletionFields.isEmpty }

    static func load() -> (operations: [Operation], templates: [String: [String: Any]]) {
        guard let url = Bundle.main.url(forResource: "operations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let operations = try? JSONDecoder().decode([Operation].self, from: data),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return ([], [:]) }
        let templates = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, [String: Any])? in
            guard let service = row["service"] as? String, let name = row["name"] as? String,
                  let template = row["template"] as? [String: Any] else { return nil }
            return ("\(service) \(name)", template)
        })
        return (operations, templates)
    }
}

struct Bucket: Identifiable, Decodable, Hashable {
    let Name: String
    var BucketRegion: String?
    var id: String { Name }
}

struct Buckets: Decodable {
    let Buckets: [Bucket]?
    let ContinuationToken: String?
}

struct S3Item: Identifiable, Hashable {
    enum Kind: String { case folder, object, version, deleteMarker }
    let key: String
    let kind: Kind
    var size: Int64?
    var date: String?
    var storage: String?
    var version: String?
    var latest: Bool?
    let id: String

    init(key: String, kind: Kind, size: Int64? = nil, date: String? = nil, storage: String? = nil,
         version: String? = nil, latest: Bool? = nil) {
        self.key = key
        self.kind = kind
        self.size = size
        self.date = date
        self.storage = storage
        self.version = version
        self.latest = latest
        id = "\(kind.rawValue):\(Data(key.utf8).base64EncodedString()):\(version ?? "")"
    }
    var icon: String {
        switch kind {
        case .folder: "folder.fill"
        case .object: "doc"
        case .version: "clock.arrow.circlepath"
        case .deleteMarker: "trash"
        }
    }
}

struct ObjectPage: Decodable {
    struct Entry: Decodable {
        let Key: String
        let Size: Int64?
        let LastModified: String?
        let StorageClass: String?
        let VersionId: String?
        let IsLatest: Bool?
        func item(_ kind: S3Item.Kind) -> S3Item {
            .init(key: Key, kind: kind, size: Size, date: LastModified, storage: StorageClass,
                  version: VersionId, latest: IsLatest)
        }
    }
    struct Folder: Decodable { let Prefix: String }
    let Contents: [Entry]?
    let Versions: [Entry]?
    let DeleteMarkers: [Entry]?
    let CommonPrefixes: [Folder]?
    let NextContinuationToken: String?
    let NextKeyMarker: String?
    let NextVersionIdMarker: String?

    var items: [S3Item] {
        (CommonPrefixes ?? []).map { S3Item(key: $0.Prefix, kind: .folder) }
        + (Contents ?? []).map { $0.item(.object) }
        + (Versions ?? []).map { $0.item(.version) }
        + (DeleteMarkers ?? []).map { $0.item(.deleteMarker) }
    }
}

struct Transfer: Identifiable, Codable {
    enum Status: String, Codable { case queued = "排队中", running = "传输中", done = "完成", failed = "失败", cancelled = "已取消" }
    var id = UUID()
    let title: String
    let arguments: [String]
    let connection: Connection
    let streaming: Bool
    var output: URL?
    var staging: URL?
    var change: ObjectChange?
    var remote: RemoteTransferJob?
    var remoteStats: RemoteTransferStats?
    var status = Status.queued
    var detail = ""

    func conflicts(with other: Self) -> Bool {
        if let remote, let peer = other.remote {
            return remote.destination.overlaps(peer.destination) || remote.destination.overlaps(peer.source) ||
                remote.source.overlaps(peer.destination)
        }
        if let remote { return other.writes(to: remote.source) || other.writes(to: remote.destination) }
        if let peer = other.remote { return writes(to: peer.source) || writes(to: peer.destination) }
        return false
    }

    private func writes(to location: RemoteTransferLocation) -> Bool {
        connection.id == location.connection.id && change?.affects(bucket: location.bucket, prefix: location.prefix) == true
    }
}

struct ObjectChange: Codable {
    let bucket: String
    var key: String?
    var recursive = false

    func affects(bucket: String, prefix: String) -> Bool {
        guard self.bucket == bucket else { return false }
        guard let key else { return true }
        return key.utf8.starts(with: prefix.utf8) || (recursive && prefix.utf8.starts(with: key.utf8))
    }
}

@MainActor
final class Workspace: ObservableObject {
    enum Destination: Hashable { case browse, api, transfers }
    struct BrowserLocation: Equatable {
        let connectionRevision: UUID
        let bucket: String?
        let prefix: Data
        let versions: Bool
    }
    private struct ListingScope: Hashable {
        let bucket: String
        let prefixBytes: Data
        let versions: Bool
        var prefix: String { String(decoding: prefixBytes, as: UTF8.self) }
    }

    private struct ListingCursor: Hashable {
        let key: String
        var version: String?
    }

    private struct CachedListing {
        let items: [S3Item]
        let cursors: Set<ListingCursor>
        let next: ListingCursor?
        let loadedAt: ContinuousClock.Instant
        let pageCount: Int
    }

    @Published private var windowDestination = Destination.browse
    var destination: Destination {
        get { transferQueue.windowDestination }
        set {
            let owner = transferQueue
            guard owner.windowDestination != newValue else { return }
            owner.windowDestination = newValue
            if newValue == .browse {
                for pane in owner.openPanes { pane.scheduleListingRefresh() }
            }
        }
    }
    @Published var connections: [Connection] = []
    @Published var connection: Connection?
    @Published var buckets: [Bucket] = []
    @Published var bucket: Bucket?
    @Published var prefix = ""
    @Published private(set) var versions = false
    @Published private(set) var items: [S3Item] = []
    @Published var selected = Set<String>()
    @Published var search = "" {
        didSet {
            guard search != oldValue else { return }
            filteredItems = search.isEmpty ? [] : items.filter { $0.key.localizedStandardContains(search) }
        }
    }
    @Published var busyBuckets = false
    @Published var busy = false
    @Published var error: String?
    @Published var bucketError: String?
    @Published private(set) var bucketCreationFeedback: BucketCreationFeedback?
    @Published private(set) var bucketDeletionRunning = false
    @Published var transfers: [Transfer] = []
    @Published private(set) var events: [S3Event] = []
    @Published var operation: Operation?
    @Published var parameters = "{}" {
        didSet { if apiRequestError != nil { apiRequestError = nil } }
    }
    @Published private(set) var apiRequestError: String?
    @Published var apiResult = ""
    @Published var apiBusy = false
    @Published var apiPaginate = false
    @Published var apiQuery = ""
    @Published var inputFile: URL?
    @Published var outputFile: URL?
    @Published var bucketCursor: String?
    @Published private(set) var hasMoreObjects = false
    @Published private(set) var needsListingRefresh = false
    @Published private(set) var inspectorCachePolicy: InspectorCachePolicy
    @Published private(set) var transferPreferences: TransferPreferences
    private var filteredItems: [S3Item] = []
    private var itemIndices: [String: Int] = [:]
    private var activeListing: ListingScope?
    private var firstPageLoadedAt: ContinuousClock.Instant?
    private var loadedPages = 0
    private var nextPage: ListingCursor?
    private var visitedCursors = Set<ListingCursor>()
    private var listingCache: [ListingScope: CachedListing] = [:]
    private var bucketTask: Task<Void, Never>?
    private var bucketCreationTask: Task<Void, Never>?
    private var bucketsAddedWhileListing: [Bucket] = []
    private var bucketsRemovedWhileListing: Set<String> = []
    private var listingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var apiTask: Task<Void, Never>?
    private var apiCreatingBucket = false
    private var transferTasks: [UUID: Task<Void, Never>] = [:]
    private var transferAttempts: [UUID: UUID] = [:]
    private var globallyLimitedTransfer: UUID?
    private var listGeneration = UUID()
    private var bucketGeneration = UUID()
    private(set) var connectionRevision = UUID()
    let inspectorCache: InspectorCache
    let operations: [Operation]
    private let defaults: UserDefaults
    private let templates: [String: [String: Any]]
    private let windowWorkspace: Workspace?
    private let additionalPanes = NSHashTable<Workspace>.weakObjects()
    private let implicitConnection: Connection = {
        var connection = Connection()
        connection.name = "AWS 默认配置"
        return connection
    }()

    var transferQueue: Workspace { windowWorkspace ?? self }
    var defaultConnection: Connection { transferQueue.implicitConnection }
    private var openPanes: [Workspace] { [self] + additionalPanes.allObjects }

    init(defaults: UserDefaults = .standard) {
        windowWorkspace = nil
        self.defaults = defaults
        let policy = InspectorCachePolicy(defaults: defaults)
        inspectorCachePolicy = policy
        inspectorCache = InspectorCache(policy: policy)
        transferPreferences = TransferPreferences(defaults: defaults)
        let catalog = Operation.load()
        operations = catalog.operations
        templates = catalog.templates
        if let data = defaults.data(forKey: "connections"), let saved = try? JSONDecoder().decode([Connection].self, from: data) {
            connections = saved
        }
        if let data = defaults.data(forKey: "remoteTransferHistory"), let saved = try? JSONDecoder().decode([Transfer].self, from: data) {
            transfers = saved.map {
                var transfer = $0
                if transfer.status == .running || transfer.status == .queued {
                    transfer.status = .cancelled
                    transfer.detail = "应用已退出，可以重新提交。"
                }
                return transfer
            }
        }
    }

    private init(windowWorkspace: Workspace) {
        self.windowWorkspace = windowWorkspace
        defaults = windowWorkspace.defaults
        inspectorCache = windowWorkspace.inspectorCache
        inspectorCachePolicy = windowWorkspace.inspectorCachePolicy
        transferPreferences = windowWorkspace.transferPreferences
        operations = windowWorkspace.operations
        templates = windowWorkspace.templates
        connections = windowWorkspace.connections
    }

    func duplicateBrowser() -> Workspace {
        let owner = transferQueue
        let pane = Workspace(windowWorkspace: owner)
        owner.additionalPanes.add(pane)
        pane.connection = connection
        pane.buckets = buckets
        pane.bucketCursor = bucketCursor
        pane.bucketError = bucketError
        pane.bucket = bucket
        pane.prefix = prefix
        pane.versions = versions
        pane.activeListing = activeListing
        if !busy, error == nil, !needsListingRefresh, isFresh(firstPageLoadedAt) {
            pane.items = items
            pane.itemIndices = itemIndices
            pane.firstPageLoadedAt = firstPageLoadedAt
            pane.loadedPages = loadedPages
            pane.visitedCursors = visitedCursors
            pane.setNextPage(nextPage)
        } else if let activeListing {
            pane.requestPage(activeListing, cursor: nil)
        }
        if busyBuckets && buckets.isEmpty { pane.listBuckets() }
        return pane
    }

    func closeBrowser() {
        transferQueue.additionalPanes.remove(self)
        apiTask?.cancel()
        resetConnection(nil)
    }

    var browserLocation: BrowserLocation {
        BrowserLocation(connectionRevision: connectionRevision, bucket: bucket?.Name,
                        prefix: Data(prefix.utf8), versions: versions)
    }

    func matches(_ location: BrowserLocation) -> Bool { browserLocation == location }

    var currentConnection: Connection? {
        guard var connection else { return nil }
        if let region = bucket?.BucketRegion, !region.isEmpty { connection.region = region }
        return connection
    }
    var visibleItems: [S3Item] { search.isEmpty ? items : filteredItems }
    var selection: [S3Item] { selectedItems(selected) }
    func selectedItems(_ ids: Set<String>) -> [S3Item] {
        ids.compactMap { itemIndices[$0] }.sorted().compactMap { index in
            let item = items[index]
            return search.isEmpty || item.key.localizedStandardContains(search) ? item : nil
        }
    }
    var canWrite: Bool { connection != nil && connection?.auth != .anonymous }
    var canCreateBucket: Bool { canWrite && bucketCreationFeedback?.isRunning != true && !apiCreatingBucket && !bucketDeletionRunning }
    var canDeleteBucket: Bool { canCreateBucket }

    func canDelete(_ bucket: Bucket) -> Bool {
        canDeleteBucket && !bucket.Name.isEmpty && !bucket.Name.contains(":") && !bucket.Name.contains("/")
    }
    var activeTransfers: Int { transfers.filter { $0.status == .queued || $0.status == .running }.count }
    var hasRunningTransfers: Bool { transfers.contains { $0.status == .running } }

    func save(_ value: Connection, credentials: Credentials?) throws {
        let owner = transferQueue
        if let credentials { try Keychain.save(credentials, for: value.id) }
        var updated = owner.connections
        if value.auth != .keys, updated.contains(where: { $0.id == value.id && $0.auth == .keys }) { try Keychain.remove(value.id) }
        if let index = updated.firstIndex(where: { $0.id == value.id }) { updated[index] = value }
        else { updated.append(value) }
        defaults.set(try JSONEncoder().encode(updated), forKey: "connections")
        inspectorCache.invalidate(connectionID: value.id)
        for pane in owner.openPanes { pane.connections = updated }
        for pane in owner.openPanes where pane !== self && pane.connection?.id == value.id {
            pane.reloadConnection(value)
        }
        connect(value)
    }

    func removeConnection(_ value: Connection) throws {
        if value.auth == .keys { try Keychain.remove(value.id) }
        let owner = transferQueue
        let updated = owner.connections.filter { $0.id != value.id }
        defaults.set(try JSONEncoder().encode(updated), forKey: "connections")
        inspectorCache.invalidate(connectionID: value.id)
        for pane in owner.openPanes {
            pane.connections = updated
            if value.id == pane.connection?.id { pane.resetConnection(nil) }
        }
    }

    func configureInspectorCache(_ policy: InspectorCachePolicy) {
        if let windowWorkspace { windowWorkspace.configureInspectorCache(policy); return }
        guard policy != inspectorCachePolicy else { return }
        inspectorCache.configure(policy)
        for pane in openPanes { pane.inspectorCachePolicy = policy }
        policy.save(to: defaults)
    }

    func configureTransfers(_ preferences: TransferPreferences) {
        if let windowWorkspace { windowWorkspace.configureTransfers(preferences); return }
        guard preferences != transferPreferences else { return }
        for pane in openPanes { pane.transferPreferences = preferences }
        preferences.save(to: defaults)
        startTransfers()
    }

    func connect(_ value: Connection?) {
        resetConnection(value)
        destination = .browse
        let initial = value?.bucket ?? ""
        openBucket(initial.isEmpty ? nil : Bucket(Name: initial))
        if value != nil && initial.isEmpty { listBuckets() }
    }

    func reloadAuthenticatedConnection(_ value: Connection) {
        inspectorCache.invalidate(connectionID: value.id)
        for pane in transferQueue.openPanes where pane.connection == value {
            pane.reloadConnection(value)
        }
    }

    private func reloadConnection(_ value: Connection) {
        let openBucket = bucket
        let openPrefix = prefix
        let showVersions = versions
        resetConnection(value)
        bucket = openBucket.map { Bucket(Name: $0.Name) }
        navigate(to: openPrefix, versions: showVersions)
        if value.bucket.isEmpty { listBuckets() }
    }

    private func resetConnection(_ value: Connection?) {
        bucketTask?.cancel()
        resetListing()
        activeListing = nil
        listingCache.removeAll()
        connectionRevision = UUID()
        bucketGeneration = UUID()
        busyBuckets = false
        bucketsAddedWhileListing = []
        bucketsRemovedWhileListing = []
        connection = value
        bucket = nil
        prefix = ""
        versions = false
        search = ""
        buckets = []
        bucketCursor = nil
        bucketError = nil
    }

    func listBuckets(more: Bool = false) {
        guard let connection else { return }
        bucketTask?.cancel()
        let generation = UUID()
        bucketGeneration = generation
        let cursor = more ? bucketCursor : nil
        busyBuckets = true
        bucketError = nil
        bucketsAddedWhileListing = []
        bucketsRemovedWhileListing = []
        bucketTask = Task {
            defer {
                if generation == bucketGeneration {
                    bucketsAddedWhileListing = []
                    bucketsRemovedWhileListing = []
                    busyBuckets = false
                }
            }
            do {
                let response = try await Self.loadBucketPage(connection, cursor: cursor)
                guard generation == bucketGeneration else { return }
                let returns = (response.Buckets ?? []).filter { !bucketsRemovedWhileListing.contains($0.Name) }
                let base = more ? buckets : returns
                let seen = Set(base.map(\.id))
                let additions = more ? returns : bucketsAddedWhileListing
                buckets = base + additions.filter { !seen.contains($0.id) }
                if let bucket, bucket.BucketRegion == nil, let match = buckets.first(where: { $0.id == bucket.id }) {
                    self.bucket = match
                }
                bucketCursor = response.ContinuationToken
                record(S3Event(action: "list-buckets", resource: connection.name, success: true))
            } catch is CancellationError {} catch {
                if generation == bucketGeneration {
                    bucketError = error.localizedDescription
                    record(S3Event(action: "list-buckets", resource: connection.name, success: false))
                }
            }
        }
    }

    static func loadBucketPage(_ connection: Connection, cursor: String?) async throws -> Buckets {
        let base = ["s3api", "list-buckets", "--no-paginate"]
        var arguments = base + ["--max-buckets=1000"]
        if let cursor { arguments.append("--continuation-token=\(cursor)") }
        do {
            return try await Engine.json(Buckets.self, arguments, connection: connection)
        } catch {
            guard cursor == nil, !Task.isCancelled, !connection.endpoint.isEmpty else { throw error }
            let detail = error.localizedDescription
            let unsupported = ["(InvalidArgument)", "(InvalidRequest)", "(InvalidMaxBuckets)", "(NotImplemented)", "(NotSupported)", "(400)", "(501)"]
            guard unsupported.contains(where: detail.contains) else { throw error }
            return try await Engine.json(Buckets.self, base, connection: connection)
        }
    }

    func openBucket(_ bucket: Bucket?, prefix: String = "") {
        self.bucket = bucket
        destination = .browse
        navigate(to: bucket == nil ? "" : prefix, versions: false)
    }

    func go(_ prefix: String) { navigate(to: prefix, versions: versions) }

    func setVersions(_ value: Bool) { navigate(to: prefix, versions: value) }

    private func navigate(to prefix: String, versions: Bool) {
        let scope = bucket.map { ListingScope(bucket: $0.Name, prefixBytes: Data(prefix.utf8), versions: versions) }
        if let scope, scope == activeListing, busy || isFresh(firstPageLoadedAt) && !needsListingRefresh { return }
        if scope != activeListing { cacheActiveListing() }
        resetListing()
        activeListing = scope
        self.prefix = prefix
        self.versions = versions
        search = ""
        guard let scope else { return }
        if let cached = listingCache.removeValue(forKey: scope), isFresh(cached.loadedAt) {
            appendItems(cached.items)
            firstPageLoadedAt = cached.loadedAt
            loadedPages = cached.pageCount
            visitedCursors = cached.cursors
            setNextPage(cached.next)
        } else { requestPage(scope, cursor: nil) }
    }

    private func isFresh(_ time: ContinuousClock.Instant?) -> Bool {
        guard let time else { return false }
        return time.duration(to: .now) < .seconds(45)
    }

    private func cacheActiveListing() {
        guard let activeListing, let firstPageLoadedAt, isFresh(firstPageLoadedAt),
              !needsListingRefresh, error == nil, items.count <= 6_000 else { return }
        listingCache = listingCache.filter { isFresh($0.value.loadedAt) }
        listingCache[activeListing] = CachedListing(items: items, cursors: visitedCursors, next: nextPage,
                                                    loadedAt: firstPageLoadedAt, pageCount: loadedPages)
        var total = listingCache.values.reduce(0) { $0 + $1.items.count }
        for entry in listingCache.sorted(by: { $0.value.loadedAt < $1.value.loadedAt }) {
            guard listingCache.count > 12 || total > 18_000 else { break }
            total -= entry.value.items.count
            listingCache[entry.key] = nil
        }
    }

    private func resetListing() {
        listingTask?.cancel()
        refreshTask?.cancel()
        listingTask = nil
        refreshTask = nil
        listGeneration = UUID()
        busy = false
        error = nil
        items = []
        filteredItems = []
        itemIndices = [:]
        selected = []
        firstPageLoadedAt = nil
        loadedPages = 0
        visitedCursors = []
        setNextPage(nil)
        needsListingRefresh = false
    }

    func list(more: Bool = false) {
        guard let scope = activeListing, !busy else { return }
        if more {
            guard let nextPage, !needsListingRefresh else { return }
            requestPage(scope, cursor: nextPage)
        } else {
            listingCache[scope] = nil
            resetListing()
            requestPage(scope, cursor: nil)
        }
    }

    private func setNextPage(_ cursor: ListingCursor?) {
        nextPage = cursor
        hasMoreObjects = cursor != nil
    }

    private func appendItems(_ entries: [S3Item]) {
        var additions: [S3Item] = []
        let offset = items.count
        for item in entries {
            let id = item.id
            guard itemIndices[id] == nil else { continue }
            itemIndices[id] = offset + additions.count
            additions.append(item)
        }
        if !search.isEmpty { filteredItems += additions.filter { $0.key.localizedStandardContains(search) } }
        items += additions
    }

    private func requestPage(_ scope: ListingScope, cursor: ListingCursor?) {
        guard let connection = currentConnection else { return }
        let generation = UUID()
        listGeneration = generation
        error = nil
        busy = true
        let command = scope.versions ? "list-object-versions" : "list-objects-v2"
        let prefix = scope.prefix
        listingTask = Task {
            defer {
                if generation == listGeneration {
                    busy = false
                    listingTask = nil
                    scheduleListingRefresh()
                }
            }
            do {
                var args = ["s3api", command, "--bucket=\(scope.bucket)", "--prefix=\(prefix)",
                            "--delimiter=/", "--max-keys=1000", "--no-paginate"] + payer(connection)
                if let cursor {
                    args.append(scope.versions ? "--key-marker=\(cursor.key)" : "--continuation-token=\(cursor.key)")
                    if scope.versions, let version = cursor.version { args.append("--version-id-marker=\(version)") }
                }
                let response = try await Engine.json(ObjectPage.self, args, connection: connection)
                guard generation == listGeneration else { return }
                if let cursor { visitedCursors.insert(cursor) }
                if firstPageLoadedAt == nil { firstPageLoadedAt = .now }
                loadedPages += 1
                appendItems(response.items)
                let next = scope.versions
                    ? response.NextKeyMarker.map { ListingCursor(key: $0, version: response.NextVersionIdMarker) }
                    : response.NextContinuationToken.flatMap { $0.isEmpty ? nil : ListingCursor(key: $0) }
                if let next, visitedCursors.contains(next) {
                    setNextPage(nil)
                    error = "端点返回了重复的分页标记。刷新清单后可重新加载。"
                } else { setNextPage(next) }
                record(S3Event(action: command, resource: Engine.s3URI(scope.bucket, prefix), success: true))
            } catch is CancellationError {} catch {
                if generation == listGeneration {
                    self.error = error.localizedDescription
                    record(S3Event(action: command, resource: Engine.s3URI(scope.bucket, prefix), success: false))
                }
            }
        }
    }

    private func invalidateListings(_ changes: [ObjectChange], connectionID: UUID) {
        guard !changes.isEmpty else { return }
        inspectorCache.invalidate(changes: changes, connectionID: connectionID)
        for pane in transferQueue.openPanes where pane.connection?.id == connectionID {
            pane.invalidateListingPages(changes)
        }
    }

    private func invalidateListingPages(_ changes: [ObjectChange]) {
        func affected(_ scope: ListingScope) -> Bool {
            let prefix = scope.prefix
            return changes.contains { $0.affects(bucket: scope.bucket, prefix: prefix) }
        }
        listingCache = listingCache.filter { !affected($0.key) }
        guard let activeListing, affected(activeListing) else { return }
        needsListingRefresh = true
        scheduleListingRefresh()
    }

    private func scheduleListingRefresh() {
        guard needsListingRefresh, let activeListing, let connectionID = connection?.id else { return }
        refreshTask?.cancel()
        guard destination == .browse, loadedPages <= 1, !busy else { return }
        let prefix = activeListing.prefix
        let writesPending = transferQueue.transfers.contains {
            ($0.status == .running || $0.status == .queued) && $0.connection.id == connectionID &&
            $0.change?.affects(bucket: activeListing.bucket, prefix: prefix) == true
        }
        guard !writesPending else { return }
        refreshTask = Task {
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            if destination == .browse, self.activeListing == activeListing, !busy, loadedPages <= 1 { list() }
        }
    }

    func payer(_ connection: Connection) -> [String] { connection.requesterPays ? ["--request-payer=requester"] : [] }

    func record(_ event: S3Event) {
        events.insert(event, at: 0)
        if events.count > 200 { events.removeLast() }
    }

    func fill(_ operation: Operation, fields: [String: Any] = [:]) {
        self.operation = operation
        inputFile = nil
        outputFile = nil
        apiPaginate = false
        apiQuery = ""
        if !apiBusy { apiResult = "" }
        let available = templates[operation.id] ?? [:]
        var template = available.filter { operation.required.contains($0.key) }
        if let bucket, !operation.createsBucket, operation.fields.contains("Bucket") { template["Bucket"] = bucket.Name }
        if operation.createsBucket, let connection, !connection.region.isEmpty,
           connection.region != "us-east-1", connection.endpoint.isEmpty {
            template["CreateBucketConfiguration"] = ["LocationConstraint": connection.region]
        }
        template.merge(fields) { _, value in value }
        parameters = Self.pretty(template)
        destination = .api
    }

    static func pretty(_ dictionary: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    func defaultValue(for field: String, in operation: Operation) -> Any {
        if field == "Bucket", let bucket, !operation.createsBucket { return bucket.Name }
        return templates[operation.id]?[field] ?? ""
    }

    func shortcut(_ command: String, fields: [String: Any] = [:]) {
        if let operation = operations.first(where: { $0.id == "s3api \(command)" }) { fill(operation, fields: fields) }
    }

    static func bucketNameError(_ name: String, aws: Bool) -> String? {
        if name.isEmpty { return "请输入存储桶名称。" }
        if !(3...63).contains(name.count) { return "存储桶名称需要 3–63 个字符。" }
        if name.range(of: #"\A[a-z0-9][a-z0-9.-]*[a-z0-9]\z"#, options: .regularExpression) == nil {
            return "请以小写字母或数字开头和结尾，中间可使用小写字母、数字、连字符或英文句点。"
        }
        if name.contains("..") { return "存储桶名称不能有连续的英文句点。" }
        if name.range(of: #"\A(?:[0-9]{1,3}\.){3}[0-9]{1,3}\z"#, options: .regularExpression) != nil {
            return "请使用存储桶名称，不能使用 IP 地址格式。"
        }
        if aws && (["xn--", "sthree-", "amzn-s3-demo-"].contains(where: name.hasPrefix) ||
                   ["-s3alias", "--ol-s3", ".mrap", "--x-s3", "--table-s3", "-an"].contains(where: name.hasSuffix)) {
            return "该前缀或后缀由 Amazon S3 保留，请换一个名称。"
        }
        return nil
    }

    static func bucketRegionError(_ region: String) -> String? {
        let value = region.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.range(of: #"\A[a-z]{2}(?:-[a-z0-9]+)+-[0-9]+\z"#, options: .regularExpression) != nil {
            return nil
        }
        return "请输入 AWS 区域代码，例如 ap-southeast-1。"
    }

    func resetBucketCreation() {
        if bucketCreationFeedback?.isRunning != true { bucketCreationFeedback = nil }
    }

    func clearBucketCreationFailure() {
        if bucketCreationFeedback?.phase == .failed { bucketCreationFeedback = nil }
    }

    func createBucket(_ name: String, awsRegion: String, connection: Connection) {
        guard self.connection == connection, canCreateBucket else { return }
        let aws = connection.endpoint.isEmpty
        if let message = Self.bucketNameError(name, aws: aws) ?? (aws ? Self.bucketRegionError(awsRegion) : nil) {
            bucketCreationFeedback = .init(phase: .failed, title: "请检查创建信息", message: message)
            return
        }
        if let existing = buckets.first(where: { $0.Name == name }) {
            bucketCreationFeedback = .init(phase: .available, title: "已有存储桶「\(name)」",
                                           message: "此连接的侧栏清单中已有同名存储桶，可以直接打开。", bucket: existing)
            return
        }
        bucketCreationFeedback = .init(phase: .creating, title: "正在创建「\(name)」",
                                       message: "等待「\(connection.name)」返回结果。")
        bucketCreationTask = Task {
            defer { bucketCreationTask = nil }
            var target = connection
            var parameters: [String: Any] = ["Bucket": name]
            do {
                if aws {
                    let requestedRegion = awsRegion.trimmingCharacters(in: .whitespacesAndNewlines)
                    let region = try await Self.resolveBucketRegion(requestedRegion, connection: connection)
                    target.region = region
                    if region != "us-east-1" {
                        parameters["CreateBucketConfiguration"] = ["LocationConstraint": region]
                    }
                }
                try Task.checkCancellation()
                let input = try JSONSerialization.data(withJSONObject: parameters)
                let createdRegion = aws ? target.region : nil
                let (feedback, _) = await runBucketCreation(["s3api", "create-bucket", "--output=json"], input: input,
                                                           name: name, target: target, connection: connection, createdRegion: createdRegion) {
                    self.bucketCreationFeedback = .init(phase: .checking, title: "正在核对「\(name)」",
                                                        message: "创建响应需要核对，正在查询存储桶清单。")
                }
                bucketCreationFeedback = feedback
            } catch is CancellationError {
                bucketCreationFeedback = .init(phase: .failed, title: "已停止创建", message: "请求尚未发送，可以重新提交。")
            } catch {
                bucketCreationFeedback = .init(phase: .failed, title: "无法准备创建请求",
                                               message: "请检查连接的 AWS 区域设置。", details: error.localizedDescription)
            }
        }
    }

    private static func resolveBucketRegion(_ requested: String, connection: Connection) async throws -> String {
        if !requested.isEmpty { return requested }
        if !connection.region.isEmpty { return connection.region }
        let environment = Engine.profileEnvironment()
        if let region = [environment["AWS_REGION"], environment["AWS_DEFAULT_REGION"]].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
            return region
        }
        if connection.auth == .profile {
            let profile = connection.profile.isEmpty ? [] : ["--profile=\(connection.profile)"]
            do {
                let region = try await Engine.run(["configure", "get", "region"] + profile)
                let value = String(decoding: region, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            } catch let error as ShelfError where error.message == "AWS CLI 退出状态码 1。" {
                // A configured profile can omit the region.
            }
        }
        return "us-east-1"
    }

    func cancelBucketCreation() { bucketCreationTask?.cancel() }

    func recheckBucketCreation(_ name: String, connection: Connection) {
        guard self.connection == connection, canCreateBucket, let previous = bucketCreationFeedback,
              previous.phase == .uncertain else { return }
        bucketCreationFeedback = .init(phase: .checking, title: "正在核对「\(name)」",
                                       message: "正在查询「\(connection.name)」的存储桶清单。")
        bucketCreationTask = Task {
            defer { bucketCreationTask = nil }
            bucketCreationFeedback = await checkBucketCreation(name, connection: connection, cursor: previous.cursor,
                                                               details: previous.details)
        }
    }

    private func addCreatedBucket(_ bucket: Bucket, connection: Connection) {
        for pane in transferQueue.openPanes where pane.connection == connection { pane.insertBucket(bucket) }
    }

    private func insertBucket(_ bucket: Bucket) {
        if let index = buckets.firstIndex(where: { $0.Name == bucket.Name }) {
            if buckets[index].BucketRegion == nil, bucket.BucketRegion != nil { buckets[index] = bucket }
        } else { buckets.append(bucket) }
        if busyBuckets && !bucketsAddedWhileListing.contains(where: { $0.Name == bucket.Name }) {
            bucketsAddedWhileListing.append(bucket)
        }
    }

    private func runBucketCreation(_ arguments: [String], input: Data?, name: String, target: Connection,
                                   connection: Connection, createdRegion: String? = nil,
                                   onCheck: () -> Void) async -> (BucketCreationFeedback, Data?) {
        let capture = ResponseCapture()
        do {
            let output = try await Engine.run(arguments, connection: target, inputJSON: input, maxAttempts: 1,
                                              response: { capture.set($0) })
            let http = capture.get()
            let created = Bucket(Name: name, BucketRegion: createdRegion)
            addCreatedBucket(created, connection: connection)
            record(S3Event(action: "s3api create-bucket", resource: name, success: true,
                           requestID: http?.requestID, status: http?.status))
            let location = createdRegion.map { "，区域为 \($0)" } ?? ""
            return (.init(phase: .created, title: "已创建「\(name)」",
                          message: "目标连接「\(connection.name)」\(location)。", bucket: created), output)
        } catch {
            let http = capture.get()
            let cancelled = error is CancellationError || Task.isCancelled
            let cliError = error.localizedDescription
            let status = http?.operationStatus
            let details = cancelled ? "" : [http.map(Self.bucketResponseDiagnostics), cliError]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            record(S3Event(action: "s3api create-bucket", resource: name, success: false,
                           requestID: http?.requestID ?? http?.header("x-request-id"), status: http?.status))
            if cancelled {
                return (.init(phase: .uncertain, title: "已停止等待",
                              message: "端点可能已收到创建请求。请先核对存储桶清单。"), nil)
            }
            let needsVerification: Bool
            if let status {
                // A failed CLI command can follow a successful HTTP exchange and leave the bucket on the server.
                needsVerification = (200..<300).contains(status) || (500..<600).contains(status)
            } else {
                needsVerification = cliError.range(of: #"^aws: \[ERROR\]: An error occurred \(5[0-9]{2}\) when calling the CreateBucket operation\b"#,
                                                   options: .regularExpression) != nil
            }
            if needsVerification {
                onCheck()
                return (await checkBucketCreation(name, connection: connection, cursor: nil, details: details), nil)
            }
            if http?.errorCode == "BucketAlreadyOwnedByYou" {
                let existing = buckets.first { self.connection == connection && $0.Name == name } ?? Bucket(Name: name)
                addCreatedBucket(existing, connection: connection)
                return (.init(phase: .available, title: "已有存储桶「\(name)」",
                              message: "端点确认当前账号拥有这个存储桶，可以直接打开。", details: details, bucket: existing), nil)
            }
            let message: String
            switch http?.errorCode {
            case "BucketAlreadyExists":
                message = "名称已被占用。请换一个存储桶名称。"
            case "InvalidBucketName":
                message = "端点拒绝了此名称。请检查存储桶命名规则。"
            case "IllegalLocationConstraintException", "InvalidLocationConstraint", "AuthorizationHeaderMalformed":
                message = "请检查 AWS 区域与目标端点的配置。"
            case "TooManyBuckets":
                message = "账号已达到存储桶数量上限。"
            default:
                if status == 401 || status == 403 {
                    message = "请检查连接凭证，以及账号是否具备创建存储桶的权限。"
                } else if status == nil || status == 408 {
                    return (.init(phase: .uncertain, title: "无法确认创建结果",
                                  message: "请检查连接、凭证或证书设置，再核对存储桶清单。", details: details), nil)
                } else {
                    message = "端点拒绝了创建请求。请查看技术详情。"
                }
            }
            return (.init(phase: .failed, title: "无法创建「\(name)」", message: message, details: details), nil)
        }
    }

    private func checkBucketCreation(_ name: String, connection: Connection, cursor: String?,
                                     details: String) async -> BucketCreationFeedback {
        do {
            let page = try await Self.loadBucketPage(connection, cursor: cursor)
            if let match = page.Buckets?.first(where: { $0.Name == name }) {
                addCreatedBucket(match, connection: connection)
                return .init(phase: .available, title: "存储桶清单中已找到「\(name)」",
                             message: "可以打开清单中的同名存储桶，避免重复创建。", details: details, bucket: match)
            }
            if let next = page.ContinuationToken, !next.isEmpty {
                if next == cursor {
                    return .init(phase: .uncertain, title: "无法继续核对存储桶清单",
                                 message: "端点返回了重复的分页标记。可以重新查询清单或查看端点日志。", details: details)
                }
                return .init(phase: .uncertain, title: "本页未找到「\(name)」",
                             message: "存储桶清单还有后续页面，可以继续核对。", details: details, cursor: next)
            }
            return .init(phase: .uncertain, title: "清单中未找到「\(name)」",
                         message: "当前账号可见的清单无法确认创建结果。请核对端点日志或稍后再查。", details: details)
        } catch is CancellationError {
            return .init(phase: .uncertain, title: "已停止核对",
                         message: "创建结果仍待确认。可以重新查询存储桶清单。", details: details, cursor: cursor)
        } catch {
            return .init(phase: .uncertain, title: "无法核对存储桶清单",
                         message: "请检查连接和列出存储桶的权限，或从端点日志核对创建结果。",
                         details: details, verificationDetails: error.localizedDescription, cursor: cursor)
        }
    }

    func bucketDeletionRequest(for bucket: Bucket) -> BucketDeletionRequest? {
        guard let connection, canDelete(bucket) else { return nil }
        return try? Self.makeBucketDeletionRequest(service: "s3api", command: "delete-bucket",
                                                   resource: bucket.Name, connection: connection, region: bucket.BucketRegion,
                                                   parameters: ["Bucket": bucket.Name])
    }

    func workbenchBucketDeletionRequest() -> BucketDeletionRequest? {
        guard let operation, operation.deletesBucket, let connection, canDeleteBucket,
              let parameters = validatedAPIRequest() else { return nil }
        let resources = operation.bucketDeletionFields.compactMap { parameters[$0] }
        guard resources.count == 1, let resource = resources.first as? String, !resource.isEmpty,
              resource == resource.trimmingCharacters(in: .whitespacesAndNewlines) else {
            apiRequestError = "请填写一个有效的存储桶名称或 ARN。"
            return nil
        }
        let region = operation.service == "s3api"
            ? buckets.first(where: { $0.Name == resource })?.BucketRegion ?? (bucket?.Name == resource ? bucket?.BucketRegion : nil)
            : nil
        do {
            return try Self.makeBucketDeletionRequest(service: operation.service, command: operation.name,
                                                      resource: resource, connection: connection, region: region,
                                                      parameters: parameters, fromWorkbench: true)
        } catch {
            apiRequestError = error.localizedDescription
            return nil
        }
    }

    private static func makeBucketDeletionRequest(service: String, command: String, resource: String, connection: Connection,
                                                  region: String?, parameters: [String: Any],
                                                  fromWorkbench: Bool = false) throws -> BucketDeletionRequest {
        var target = connection
        if let region, !region.isEmpty { target.region = region }
        let name: String
        if resource.hasPrefix("arn:") {
            let arn = resource.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
            let components = arn.last?.split(separator: "/", omittingEmptySubsequences: false)
            guard arn.count == 6, let components, components.dropLast().last == "bucket",
                  let last = components.last, !last.isEmpty else {
                throw ShelfError("请输入存储桶的 ARN。")
            }
            name = String(last)
        } else {
            name = resource
        }
        guard !name.utf8.contains(0), !name.contains(":"), !name.contains("/") else {
            throw ShelfError("请输入有效的存储桶名称。")
        }
        let input = try JSONSerialization.data(withJSONObject: parameters)
        return .init(connection: connection, target: target, operation: "\(service) \(command)",
                     arguments: [service, command, "--output=json", "--no-paginate"], input: input,
                     resource: resource, name: name,
                     accountID: (parameters["AccountId"] ?? parameters["ExpectedBucketOwner"]) as? String,
                     fromWorkbench: fromWorkbench)
    }

    func deleteBucket(_ request: BucketDeletionRequest, confirmedName: String) async -> BucketDeletionFeedback? {
        guard request.matches(confirmedName), connection == request.connection, canDeleteBucket else { return nil }
        bucketDeletionRunning = true
        defer { bucketDeletionRunning = false }
        let capture = ResponseCapture()
        let result: BucketDeletionFeedback
        do {
            _ = try await Engine.run(request.arguments, connection: request.target, inputJSON: request.input,
                                     maxAttempts: 1, response: { capture.set($0) })
            result = .init(title: "已删除「\(request.name)」", message: "存储桶已从「\(request.connection.name)」删除。", removed: true)
        } catch {
            result = Self.bucketDeletionFailure(request, response: capture.get(), error: error)
        }
        let http = capture.get()
        record(S3Event(action: request.operation, resource: request.resource, success: result.removed,
                       requestID: http?.requestID ?? http?.header("x-request-id"), status: http?.status))
        if result.removed, request.isS3Bucket {
            for pane in transferQueue.openPanes where pane.connection == request.connection {
                pane.removeBucket(request.name, resource: request.resource)
            }
            inspectorCache.invalidate(changes: [ObjectChange(bucket: request.name)], connectionID: request.connection.id)
        }
        if request.fromWorkbench { apiResult = result.text }
        return result
    }

    private func removeBucket(_ name: String, resource: String) {
        if bucket?.Name == name || bucket?.Name == resource {
            bucket = nil
            navigate(to: "", versions: false)
        }
        buckets.removeAll { $0.Name == name }
        bucketsAddedWhileListing.removeAll { $0.Name == name }
        if busyBuckets { bucketsRemovedWhileListing.insert(name) }
        listingCache = listingCache.filter { $0.key.bucket != name && $0.key.bucket != resource }
    }

    private static func bucketDeletionFailure(_ request: BucketDeletionRequest, response: S3HTTPResponse?,
                                              error: any Error) -> BucketDeletionFeedback {
        let cliError = error.localizedDescription
        let details = [response.map(Self.bucketResponseDiagnostics), cliError]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let status = response?.operationStatus
        let title = "无法删除「\(request.name)」"
        switch response?.errorCode {
        case "NoSuchBucket":
            return .init(title: "「\(request.name)」已不存在", message: "端点报告找不到此存储桶。", details: details, removed: true)
        case "BucketNotEmpty":
            return .init(title: title, message: "存储桶仍有内容。请处理全部对象、历史版本和删除标记后，再输入桶名确认删除。", details: details)
        default:
            if status == 401 || status == 403 {
                return .init(title: title, message: "请核对目标账号、连接凭证和删除存储桶的权限。", details: details)
            }
            if status == 409 {
                return .init(title: title, message: "端点报告资源冲突。请检查存储桶是否为空，并查看技术详情。", details: details)
            }
            if let status, (400..<500).contains(status), status != 408, !(error is CancellationError) {
                return .init(title: title, message: "端点拒绝了删除请求。请查看技术详情。", details: details)
            }
            return .init(title: "删除结果待确认", message: "请刷新目标连接的存储桶清单，或通过端点日志核对删除结果。", details: details)
        }
    }

    func validatedAPIRequest() -> [String: Any]? {
        guard let operation, !apiBusy else { return nil }
        do {
            let object = try Self.decodeAPIRequest(parameters)
            if operation.createsBucket {
                guard let name = object["Bucket"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ShelfError("请在 Bucket 中填写新存储桶的名称。")
                }
            }
            let missing = operation.required.filter { field in
                if field == operation.fileInput { return inputFile == nil && (object[field] as? String ?? "").isEmpty }
                return object[field] == nil || object[field] is NSNull
            }
            guard missing.isEmpty else { throw ShelfError("请填写必填参数 \(missing.joined(separator: "、"))。") }
            guard !operation.fileOutput || outputFile != nil else { throw ShelfError("请选择输出文件。") }
            apiRequestError = nil
            return object
        } catch {
            apiRequestError = error.localizedDescription
            return nil
        }
    }

    func execute() {
        guard let operation, !operation.deletesBucket, let connection = operation.createsBucket ? self.connection : currentConnection,
              !apiBusy, !bucketDeletionRunning, !operation.mutates || canWrite, !operation.createsBucket || canCreateBucket,
              let object = validatedAPIRequest() else { return }
        let input = inputFile
        let output = outputFile
        do {
            var args = [operation.service] + operation.name.split(separator: " ").map(String.init)
            args.append("--output=json")
            if !apiPaginate { args.append("--no-paginate") }
            if !apiQuery.isEmpty { args.append("--query=\(apiQuery)") }
            if let field = operation.fileInput, let input { args.append("--\(Self.kebab(field))=\(input.path)") }
            let stage = output.map { $0.deletingLastPathComponent().appendingPathComponent(".s3-\(UUID().uuidString).download") }
            var literalObjectKey: String?
            if let stage, operation.fileOutput {
                var arguments = object
                if let key = object["Key"] as? String {
                    guard !key.utf8.contains(0) else { throw ShelfError("对象键不能包含空字符。") }
                    if key.utf8.contains(where: { $0 >= 128 }) {
                        literalObjectKey = key
                        arguments["Key"] = nil
                    }
                }
                args += try Self.streamingArguments(arguments, allowed: operation.fields)
                args.append(stage.path)
            }
            if operation.fields.contains("RequestPayer"), object["RequestPayer"] == nil { args += payer(connection) }
            let data = operation.fileOutput ? nil : try JSONSerialization.data(withJSONObject: object)
            let arguments = args
            if operation.createsBucket, let name = object["Bucket"] as? String {
                apiCreatingBucket = true
                apiBusy = true
                apiResult = "正在通过「\(connection.name)」创建「\(name)」…"
                apiTask = Task {
                    defer { apiCreatingBucket = false; apiBusy = false }
                    let (feedback, output) = await runBucketCreation(arguments, input: data, name: name, target: connection,
                                                                    connection: connection) {
                        self.apiResult = "创建响应需要核对，正在查询存储桶清单…"
                    }
                    apiResult = feedback.text
                    if let output, !output.isEmpty { apiResult += "\n\n" + String(decoding: output, as: UTF8.self) }
                }
                return
            }
            apiBusy = true
            apiResult = "正在运行 \(operation.id)…"
            let details = inspectorCache
            apiTask = Task {
                defer {
                    apiBusy = false
                    if let stage { try? FileManager.default.removeItem(at: stage) }
                    if operation.service == "s3api", operation.mutates, let bucket = object["Bucket"] as? String {
                        details.invalidateMutation(operation.name, change: ObjectChange(bucket: bucket, key: object["Key"] as? String),
                                                   connectionID: connection.id)
                    }
                }
                do {
                    let response = try await Engine.run(arguments, connection: connection, inputJSON: data,
                                                        literalObjectKey: literalObjectKey)
                    if let stage, let output { try Self.finalizeDownload(stage, to: output) }
                    let result = String(decoding: response, as: UTF8.self)
                    apiResult = result.isEmpty ? "\(operation.id) 已完成。" : result
                    record(S3Event(action: operation.id, resource: object["Bucket"] as? String ?? connection.name,
                                   success: true))
                    if operation.mutates && operation.service == "s3api" {
                        let targetBucket = object["Bucket"] as? String
                        if let targetBucket {
                            let changes: [ObjectChange]
                            switch operation.name {
                            case "put-object", "copy-object", "complete-multipart-upload", "delete-object", "restore-object":
                                changes = [ObjectChange(bucket: targetBucket, key: object["Key"] as? String)]
                            case "rename-object", "delete-objects":
                                changes = [ObjectChange(bucket: targetBucket)]
                            default: changes = []
                            }
                            invalidateListings(changes, connectionID: connection.id)
                        }
                    }
                } catch is CancellationError {
                    apiResult = operation.mutates ? "已停止等待。请刷新相关资源以确认目标端点的处理结果。" : "已停止等待。"
                }
                catch {
                    apiResult = "执行 \(operation.name) 失败。\n\n\(error.localizedDescription)"
                    record(S3Event(action: operation.id, resource: object["Bucket"] as? String ?? connection.name, success: false))
                }
            }
        } catch {
            apiRequestError = error.localizedDescription
            apiResult = ""
        }
    }

    private static func bucketResponseDiagnostics(_ response: S3HTTPResponse) -> String {
        var lines: [String] = []
        if let status = response.status { lines.append("网关响应 HTTP \(status)") }
        if let status = response.sdkStatus { lines.append("AWS CLI 将响应按服务错误处理（\(status)）") }
        if let code = response.errorCode { lines.append("S3 错误码 \(code)") }
        if let id = response.requestID { lines.append("S3 请求 ID \(id)") }
        else if let id = response.header("x-request-id") { lines.append("端点请求 ID \(id)") }
        if let server = response.header("server") { lines.append("Server \(server)") }
        if let contentType = response.header("content-type") { lines.append("Content-Type \(contentType)") }
        return lines.joined(separator: "\n")
    }

    private static func decodeAPIRequest(_ text: String) throws -> [String: Any] {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        } catch {
            let details = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            var message = "请求 JSON 格式错误。"
            if text.contains("“") || text.contains("”") {
                message += "字段名和字符串两端请使用英文直双引号（\"）。"
            }
            if let details { message += "\n\(details)" }
            throw ShelfError(message)
        }
        guard let object = parsed as? [String: Any] else { throw ShelfError("请求参数必须是 JSON 对象，例如 {\"Bucket\": \"example-bucket\"}。") }
        return object
    }

    func cancelAPI() { apiTask?.cancel() }

    static func streamingArguments(_ input: [String: Any], allowed: [String]) throws -> [String] {
        try input.keys.sorted().map { key in
            guard allowed.contains(key), let value = input[key], !(value is NSNull) else {
                throw ShelfError("无效的参数 \(key)。")
            }
            let encoded: String
            if let string = value as? String { encoded = string }
            else { encoded = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self) }
            return "--\(kebab(key))=\(encoded)"
        }
    }

    func upload(_ urls: [URL]) {
        guard let bucket, let connection = currentConnection, canWrite else { return }
        for url in urls where url.isFileURL {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let key = prefix + url.lastPathComponent + (isDirectory ? "/" : "")
            let args = ["s3", "cp", url.path, Engine.s3URI(bucket.Name, key), "--progress-frequency=1"]
                + (isDirectory ? ["--recursive", "--no-follow-symlinks"] : []) + payer(connection)
            enqueue(.init(title: "上传 \(url.lastPathComponent)", arguments: args, connection: connection, streaming: true,
                          change: ObjectChange(bucket: bucket.Name, key: key, recursive: isDirectory)))
        }
    }

    func sync(_ folder: URL, upload: Bool) {
        guard let connection = currentConnection, let bucket, !upload || canWrite else { return }
        let remote = Engine.s3URI(bucket.Name, prefix)
        let paths = upload ? [folder.path, remote] : [remote, folder.path]
        let options = upload ? ["--no-follow-symlinks"] : []
        let arguments = ["s3", "sync"] + paths + ["--progress-frequency=1"] + options + payer(connection)
        enqueue(.init(title: "\(upload ? "上传" : "下载")同步 · \(folder.lastPathComponent)", arguments: arguments,
                      connection: connection, streaming: true,
                      change: upload ? ObjectChange(bucket: bucket.Name, key: prefix, recursive: true) : nil))
    }

    func copyObject(_ item: S3Item, to key: String) {
        guard let connection = currentConnection, let bucket, canWrite, item.kind == .object,
              !key.isEmpty, key != item.key else { return }
        let source = Engine.s3URI(bucket.Name, item.key)
        let target = Engine.s3URI(bucket.Name, key)
        enqueue(.init(title: "复制 \(item.key)", arguments: ["s3", "cp", source, target, "--progress-frequency=1"] + payer(connection),
                      connection: connection, streaming: true, change: ObjectChange(bucket: bucket.Name, key: key)))
    }

    func download(_ item: S3Item, to url: URL) {
        guard let bucket, let connection = currentConnection, item.kind != .deleteMarker else { return }
        let stage = item.kind == .folder ? nil : url.deletingLastPathComponent().appendingPathComponent(".s3-\(UUID().uuidString).download")
        let path = (stage ?? url).path
        var arguments: [String]
        if let version = item.version {
            arguments = ["s3api", "get-object", "--bucket=\(bucket.Name)", "--key=\(item.key)", "--version-id=\(version)", path]
        } else {
            arguments = ["s3", "cp", Engine.s3URI(bucket.Name, item.key), path, "--progress-frequency=1"]
            if item.kind == .folder { arguments.append("--recursive") }
        }
        enqueue(.init(title: "下载 \(item.key)", arguments: arguments + payer(connection), connection: connection,
                      streaming: item.version == nil, output: stage == nil ? nil : url, staging: stage))
    }

    func delete(_ items: [S3Item]) {
        let files = items.filter { $0.kind != .folder }
        guard !files.isEmpty, let bucket, let connection = currentConnection, canWrite else { return }
        let records = files.map { item -> [String: String] in
            var record = ["Key": item.key]
            record["VersionId"] = item.version
            return record
        }
        Task {
            var failures: [String] = []
            for index in stride(from: 0, to: records.count, by: 1000) {
                let batch = Array(records[index..<min(index + 1000, records.count)])
                do {
                    let payload: [String: Any] = ["Bucket": bucket.Name, "Delete": ["Objects": batch, "Quiet": true]]
                    let raw = try await Engine.run(["s3api", "delete-objects", "--output=json"] + payer(connection),
                                                   connection: connection, inputJSON: try JSONSerialization.data(withJSONObject: payload))
                    if let result = try JSONSerialization.jsonObject(with: raw) as? [String: Any], let errors = result["Errors"] as? [[String: Any]] {
                        failures += errors.map { "\($0["Key"] ?? "") · \($0["Code"] ?? "") · \($0["Message"] ?? "")" }
                    }
                } catch { failures.append(error.localizedDescription) }
            }
            record(S3Event(action: "delete-objects", resource: bucket.Name, success: failures.isEmpty))
            invalidateListings(files.map { ObjectChange(bucket: bucket.Name, key: $0.key) }, connectionID: connection.id)
            if self.connection?.id == connection.id && self.bucket?.id == bucket.id {
                if !failures.isEmpty { error = failures.joined(separator: "\n") }
            }
        }
    }

    func enqueue(_ transfer: Transfer) {
        let queue = transferQueue
        queue.transfers.insert(transfer, at: 0)
        queue.startTransfers()
    }

    func enqueueRemote(_ job: RemoteTransferJob) throws {
        if let windowWorkspace { try windowWorkspace.enqueueRemote(job); return }
        try job.validate()
        try validateTransferConnections(job)
        transfers.insert(.init(title: "S3 → S3 · \(job.mode.title)", arguments: [], connection: job.destination.connection,
                               streaming: false, change: ObjectChange(bucket: job.destination.bucket,
                                                                      key: job.destination.prefix, recursive: true),
                               remote: job), at: 0)
        saveRemoteTransferHistory()
        startTransfers()
    }

    private func validateTransferConnections(_ job: RemoteTransferJob) throws {
        for connection in [job.source.connection, job.destination.connection] {
            if connections.first(where: { $0.id == connection.id }) == connection || self.connection == connection { continue }
            if connection.auth == .profile, connection.name == "AWS 默认配置", connection.endpoint.isEmpty,
               connection.profile.isEmpty { continue }
            throw ShelfError("连接「\(connection.name)」已变更。请按当前配置重新建立传输任务。")
        }
    }

    private func saveRemoteTransferHistory() {
        let remote = transfers.lazy.filter { $0.remote != nil }
        let records = remote.reduce(into: [Transfer]()) { history, transfer in
            if history.count < 100 || transfer.status == .queued || transfer.status == .running { history.append(transfer) }
        }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: "remoteTransferHistory") }
    }

    func cancel(_ id: UUID) {
        if let task = transferTasks[id] { task.cancel() }
        else if let index = transfers.firstIndex(where: { $0.id == id && $0.status == .queued }) {
            transfers[index].status = .cancelled
            if transfers[index].remote != nil { saveRemoteTransferHistory() }
            if transfers[index].change != nil {
                for pane in openPanes { pane.scheduleListingRefresh() }
            }
        }
    }

    func retry(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }), [.failed, .cancelled].contains(transfers[index].status) else { return }
        transfers[index].status = .queued
        transfers[index].detail = ""
        transfers[index].remoteStats = nil
        if transfers[index].remote != nil { saveRemoteTransferHistory() }
        startTransfers()
    }

    private func startTransfers() {
        let preferences = transferPreferences
        let limited = preferences.bytesPerSecond != nil
        guard globallyLimitedTransfer == nil else { return }
        while transferTasks.count < (limited ? 1 : 3) {
            let running = transfers.filter { $0.status == .running }
            guard let index = transfers.lastIndex(where: { candidate in
                candidate.status == .queued && !running.contains(where: { candidate.conflicts(with: $0) })
            }) else { return }
            transfers[index].status = .running
            let job = transfers[index]
            if limited { globallyLimitedTransfer = job.id }
            let attempt = UUID()
            transferAttempts[job.id] = attempt
            if job.remote != nil { saveRemoteTransferHistory() }
            transferTasks[job.id] = Task { [self] in
                let remoteLog = job.remote.map { _ in RcloneLog() }
                defer {
                    if let staging = job.staging { try? FileManager.default.removeItem(at: staging) }
                    if let stats = remoteLog?.stats, let index = transfers.firstIndex(where: { $0.id == job.id }) {
                        transfers[index].remoteStats = stats
                    }
                    if job.remote != nil { saveRemoteTransferHistory() }
                    transferAttempts[job.id] = nil
                    transferTasks[job.id] = nil
                    if globallyLimitedTransfer == job.id { globallyLimitedTransfer = nil }
                    startTransfers()
                    if let change = job.change {
                        if change.recursive || transfers.first(where: { $0.id == job.id })?.status == .done {
                            invalidateListings([change], connectionID: job.connection.id)
                        } else {
                            for pane in openPanes { pane.scheduleListingRefresh() }
                        }
                    }
                }
                do {
                    if let remote = job.remote, let remoteLog {
                        try validateTransferConnections(remote)
                        try await RcloneEngine.run(remote, preferences: preferences, log: remoteLog) { [weak self] stats in
                            Task { @MainActor in
                                guard let self, self.transferAttempts[job.id] == attempt,
                                      let index = self.transfers.firstIndex(where: { $0.id == job.id && $0.status == .running }) else { return }
                                self.transfers[index].remoteStats = stats
                            }
                        }
                        try Task.checkCancellation()
                        updateTransfer(job.id, status: .done)
                        return
                    }
                    let progress: OutputHandler = { [weak self] line in
                        Task { @MainActor in
                            guard let self, self.transferAttempts[job.id] == attempt,
                                  let index = self.transfers.firstIndex(where: { $0.id == job.id }),
                                  self.transfers[index].status == .running else { return }
                            self.transfers[index].detail = line
                        }
                    }
                    try await runTransfer(job, preferences: preferences, progress: progress)
                    try Task.checkCancellation()
                    if let stage = job.staging, let output = job.output {
                        try Self.finalizeDownload(stage, to: output)
                    }
                    updateTransfer(job.id, status: .done)
                } catch is CancellationError { updateTransfer(job.id, status: .cancelled) }
                catch { updateTransfer(job.id, status: .failed, detail: error.localizedDescription) }
            }
        }
    }

    private func runTransfer(_ job: Transfer, preferences: TransferPreferences, progress: @escaping OutputHandler) async throws {
        var arguments = job.arguments
        var settings: [String: String] = [:]
        var throttledDownload: (file: URL, bytesPerSecond: Int64)?
        if arguments.first == "s3" {
            if job.change != nil { settings["multipart_chunksize"] = "\(preferences.partMiB)MB" }
            if let limit = preferences.bytesPerSecond { settings["max_bandwidth"] = "\(limit)B/s" }
            if !settings.isEmpty { settings["preferred_transfer_client"] = "classic" }
        } else if let stage = job.staging, let limit = preferences.bytesPerSecond,
                  arguments.starts(with: ["s3api", "get-object"]), let output = arguments.firstIndex(of: stage.path) {
            // The low-level version download bypasses the high-level CLI transfer manager.
            arguments[output] = "/dev/stdout"
            arguments.append("--output=off")
            throttledDownload = (stage, limit)
        }
        _ = try await Engine.run(arguments, connection: job.connection, transferSettings: settings,
                                 throttledDownload: throttledDownload, progress: job.streaming ? progress : nil)
    }

    private func updateTransfer(_ id: UUID, status: Transfer.Status, detail: String? = nil) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].status = status
        if let detail { transfers[index].detail = detail }
        if status == .done || status == .failed {
            record(S3Event(action: "传输", resource: transfers[index].title, success: status == .done))
        }
    }

    private static func finalizeDownload(_ staging: URL, to output: URL) throws {
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: output)
        }
    }

    static func kebab(_ value: String) -> String {
        value.replacingOccurrences(of: "([A-Z]+)([A-Z][a-z])", with: "$1-$2", options: .regularExpression)
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1-$2", options: .regularExpression).lowercased()
    }
}
