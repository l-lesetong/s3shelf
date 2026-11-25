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

struct Transfer: Identifiable {
    enum Status: String { case queued = "排队中", running = "传输中", done = "完成", failed = "失败", cancelled = "已取消" }
    var id = UUID()
    let title: String
    let arguments: [String]
    let connection: Connection
    let streaming: Bool
    var output: URL?
    var staging: URL?
    var change: ObjectChange?
    var status = Status.queued
    var detail = ""
}

struct ObjectChange {
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

    @Published var destination = Destination.browse
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
    @Published var transfers: [Transfer] = []
    @Published private(set) var events: [S3Event] = []
    @Published var operation: Operation?
    @Published var parameters = "{}"
    @Published var apiResult = ""
    @Published var apiBusy = false
    @Published var apiPaginate = false
    @Published var apiQuery = ""
    @Published var inputFile: URL?
    @Published var outputFile: URL?
    @Published var bucketCursor: String?
    @Published private(set) var hasMoreObjects = false
    @Published private(set) var needsListingRefresh = false
    private var filteredItems: [S3Item] = []
    private var itemIndices: [String: Int] = [:]
    private var activeListing: ListingScope?
    private var firstPageLoadedAt: ContinuousClock.Instant?
    private var loadedPages = 0
    private var nextPage: ListingCursor?
    private var visitedCursors = Set<ListingCursor>()
    private var listingCache: [ListingScope: CachedListing] = [:]
    private var bucketTask: Task<Void, Never>?
    private var listingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var apiTask: Task<Void, Never>?
    private var transferTasks: [UUID: Task<Void, Never>] = [:]
    private var listGeneration = UUID()
    private var bucketGeneration = UUID()
    let operations: [Operation]
    private let templates: [String: [String: Any]]

    init(defaults: UserDefaults = .standard) {
        let catalog = Operation.load()
        operations = catalog.operations
        templates = catalog.templates
        if let data = defaults.data(forKey: "connections"), let saved = try? JSONDecoder().decode([Connection].self, from: data) {
            connections = saved
        }
    }

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
    var activeTransfers: Int { transfers.filter { $0.status == .queued || $0.status == .running }.count }

    func save(_ value: Connection, credentials: Credentials?) throws {
        if let credentials { try Keychain.save(credentials, for: value.id) }
        if value.auth != .keys, connections.contains(where: { $0.id == value.id && $0.auth == .keys }) { try Keychain.remove(value.id) }
        if let index = connections.firstIndex(where: { $0.id == value.id }) { connections[index] = value }
        else { connections.append(value) }
        UserDefaults.standard.set(try JSONEncoder().encode(connections), forKey: "connections")
        connect(value)
    }

    func removeConnection(_ value: Connection) throws {
        if value.auth == .keys { try Keychain.remove(value.id) }
        connections.removeAll { $0.id == value.id }
        UserDefaults.standard.set(try JSONEncoder().encode(connections), forKey: "connections")
        if value.id == connection?.id { connect(nil) }
    }

    func connect(_ value: Connection?) {
        bucketTask?.cancel()
        resetListing()
        activeListing = nil
        listingCache.removeAll()
        bucketGeneration = UUID()
        busyBuckets = false
        connection = value
        buckets = []
        bucketCursor = nil
        bucketError = nil
        destination = .browse
        let initial = value?.bucket ?? ""
        openBucket(initial.isEmpty ? nil : Bucket(Name: initial))
        if value != nil && initial.isEmpty { listBuckets() }
    }

    func listBuckets(more: Bool = false) {
        guard let connection else { return }
        bucketTask?.cancel()
        let generation = UUID()
        bucketGeneration = generation
        let cursor = more ? bucketCursor : nil
        busyBuckets = true
        bucketError = nil
        bucketTask = Task {
            defer { if generation == bucketGeneration { busyBuckets = false } }
            do {
                let base = ["s3api", "list-buckets", "--no-paginate"]
                var response: Buckets
                do {
                    var args = base + ["--max-buckets=1000"]
                    if let cursor { args.append("--continuation-token=\(cursor)") }
                    response = try await Engine.json(Buckets.self, args, connection: connection)
                } catch {
                    guard cursor == nil, !Task.isCancelled, !connection.endpoint.isEmpty else { throw error }
                    response = try await Engine.json(Buckets.self, base, connection: connection)
                }
                guard generation == bucketGeneration else { return }
                let returns = response.Buckets ?? []
                if more {
                    let seen = Set(buckets.map(\.id))
                    buckets += returns.filter { !seen.contains($0.id) }
                } else { buckets = returns }
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

    func openBucket(_ bucket: Bucket?) {
        self.bucket = bucket
        destination = .browse
        navigate(to: "", versions: false)
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
            defer { if generation == listGeneration { busy = false; listingTask = nil } }
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
        guard connection?.id == connectionID, !changes.isEmpty else { return }
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
        let writesPending = transfers.contains {
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
        if let bucket, operation.fields.contains("Bucket") { template["Bucket"] = bucket.Name }
        if operation.id == "s3api create-bucket", let connection, !connection.region.isEmpty,
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
        if field == "Bucket", let bucket { return bucket.Name }
        return templates[operation.id]?[field] ?? ""
    }

    func shortcut(_ command: String, fields: [String: Any] = [:]) {
        if let operation = operations.first(where: { $0.id == "s3api \(command)" }) { fill(operation, fields: fields) }
    }

    func execute() {
        guard let operation, let connection = currentConnection, !apiBusy else { return }
        let input = inputFile
        let output = outputFile
        do {
            guard let object = try JSONSerialization.jsonObject(with: Data(parameters.utf8)) as? [String: Any] else {
                throw ShelfError("参数必须是 JSON 对象。")
            }
            let missing = operation.required.filter { field in
                if field == operation.fileInput { return input == nil && (object[field] as? String ?? "").isEmpty }
                return object[field] == nil || object[field] is NSNull
            }
            guard missing.isEmpty else { throw ShelfError("请填写必填参数 \(missing.joined(separator: "、"))。") }
            guard !operation.fileOutput || output != nil else { throw ShelfError("请选择输出文件。") }
            var args = [operation.service] + operation.name.split(separator: " ").map(String.init)
            args.append("--output=json")
            if !apiPaginate { args.append("--no-paginate") }
            if !apiQuery.isEmpty { args.append("--query=\(apiQuery)") }
            if let field = operation.fileInput, let input { args.append("--\(Self.kebab(field))=\(input.path)") }
            let stage = output.map { $0.deletingLastPathComponent().appendingPathComponent(".s3-\(UUID().uuidString).download") }
            if let stage, operation.fileOutput {
                args += try Self.streamingArguments(object, allowed: operation.fields)
                args.append(stage.path)
            }
            if operation.fields.contains("RequestPayer"), object["RequestPayer"] == nil { args += payer(connection) }
            let data = operation.fileOutput ? nil : try JSONSerialization.data(withJSONObject: object)
            apiBusy = true
            apiResult = "正在运行 \(operation.id)…"
            let arguments = args
            apiTask = Task {
                defer {
                    apiBusy = false
                    if let stage { try? FileManager.default.removeItem(at: stage) }
                }
                do {
                    let response = try await Engine.run(arguments, connection: connection, inputJSON: data)
                    if let stage, let output { try Self.finalizeDownload(stage, to: output) }
                    let result = String(decoding: response, as: UTF8.self)
                    apiResult = result.isEmpty ? "\(operation.id) 已完成。" : result
                    record(S3Event(action: operation.id, resource: object["Bucket"] as? String ?? connection.name, success: true))
                    if operation.mutates && operation.service == "s3api" {
                        let targetBucket = object["Bucket"] as? String
                        if self.connection?.id == connection.id, operation.name == "create-bucket" || operation.name == "delete-bucket" {
                            listBuckets()
                            if operation.name == "delete-bucket", bucket?.Name == targetBucket {
                                openBucket(nil)
                                destination = .api
                            }
                        }
                        if let targetBucket {
                            let changes: [ObjectChange]
                            switch operation.name {
                            case "put-object", "copy-object", "complete-multipart-upload", "delete-object", "restore-object":
                                changes = [ObjectChange(bucket: targetBucket, key: object["Key"] as? String)]
                            case "rename-object", "delete-objects", "delete-bucket":
                                changes = [ObjectChange(bucket: targetBucket)]
                            default: changes = []
                            }
                            invalidateListings(changes, connectionID: connection.id)
                        }
                    }
                } catch is CancellationError { apiResult = "已取消等待。请刷新相关资源以确认 AWS 端的结果。" }
                catch {
                    apiResult = error.localizedDescription
                    record(S3Event(action: operation.id, resource: object["Bucket"] as? String ?? connection.name, success: false))
                }
            }
        } catch { apiResult = error.localizedDescription }
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

    func enqueue(_ transfer: Transfer) { transfers.insert(transfer, at: 0); startTransfers() }

    func cancel(_ id: UUID) {
        if let task = transferTasks[id] { task.cancel() }
        else if let index = transfers.firstIndex(where: { $0.id == id && $0.status == .queued }) {
            transfers[index].status = .cancelled
            if transfers[index].change != nil { scheduleListingRefresh() }
        }
    }

    func retry(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }), [.failed, .cancelled].contains(transfers[index].status) else { return }
        transfers[index].status = .queued
        transfers[index].detail = ""
        startTransfers()
    }

    private func startTransfers() {
        while transferTasks.count < 3, let index = transfers.lastIndex(where: { $0.status == .queued }) {
            transfers[index].status = .running
            let job = transfers[index]
            transferTasks[job.id] = Task { [self] in
                defer {
                    if let staging = job.staging { try? FileManager.default.removeItem(at: staging) }
                    transferTasks[job.id] = nil
                    startTransfers()
                    if let change = job.change {
                        if change.recursive || transfers.first(where: { $0.id == job.id })?.status == .done {
                            invalidateListings([change], connectionID: job.connection.id)
                        } else {
                            scheduleListingRefresh()
                        }
                    }
                }
                do {
                    let progress: OutputHandler = { [weak self] line in
                        Task { @MainActor in
                            guard let self, let index = self.transfers.firstIndex(where: { $0.id == job.id }),
                                  self.transfers[index].status == .running else { return }
                            self.transfers[index].detail = line
                        }
                    }
                    _ = try await Engine.run(job.arguments, connection: job.connection, progress: job.streaming ? progress : nil)
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
