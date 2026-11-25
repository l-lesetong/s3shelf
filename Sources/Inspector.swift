import AppKit
import ImageIO
import SwiftUI

struct S3Event: Identifiable {
    let id = UUID()
    let time = Date()
    let action: String
    let resource: String
    let success: Bool
    var requestID: String? = nil
    var status: Int? = nil
}

struct InspectorTarget: Hashable {
    let connectionID: UUID
    let bucket: Bucket
    let item: S3Item?
    let prefix: String

    var identifier: String { item?.key ?? bucket.Name }
    var location: String { Engine.s3URI(bucket.Name, item?.key ?? prefix) }
    var object: S3Item? { item?.kind == .folder ? nil : item }
    var supportsAccessManagement: Bool { item?.kind != .folder && item?.kind != .deleteMarker }
    var scope: String {
        switch item?.kind {
        case .folder: "前缀"
        case .deleteMarker: "删除标记"
        case .version: "对象版本"
        case .object: "对象"
        case nil: "存储桶"
        }
    }
    var objectArguments: [String] {
        guard let object else { return [] }
        return ["--key=\(object.key)"] + (object.version.map { ["--version-id=\($0)"] } ?? [])
    }
}

@MainActor
struct InspectorClient {
    let model: Workspace
    let target: InspectorTarget
    let connection: Connection
    let inspectorCache: InspectorCache

    init(model: Workspace, target: InspectorTarget, connection: Connection) {
        self.model = model
        self.target = target
        self.connection = connection
        inspectorCache = model.inspectorCache
    }

    struct Result {
        var data = Data()
        var response: S3HTTPResponse?
        var error: String?

        var fields: [String: Any] {
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
    }

    func fetch(_ command: String, args: [String] = [], requesterPays: Bool = false,
               headers: Bool = false, inputJSON: Data? = nil) async throws -> Result {
        let capture = ResponseCapture()
        let callback: ResponseHandler? = headers ? { @Sendable in capture.set($0) } : nil
        let options = requesterPays ? model.payer(connection) : []
        var result: Result
        do {
            let data = try await Engine.run(["s3api", command, "--bucket=\(target.bucket.Name)", "--no-paginate", "--output=json"] + args + options,
                                            connection: connection, inputJSON: inputJSON, response: callback)
            try Task.checkCancellation()
            result = Result(data: data, response: capture.get())
        } catch {
            try Task.checkCancellation()
            result = Result(response: capture.get(), error: error.localizedDescription)
        }
        model.record(S3Event(action: command, resource: target.identifier, success: result.error == nil,
                             requestID: result.response?.requestID, status: result.response?.status))
        return result
    }

    func head(headers: Bool = false) async throws -> Result {
        if target.object != nil {
            return try await fetch("head-object", args: target.objectArguments, requesterPays: true, headers: headers)
        }
        return try await fetch("head-bucket", headers: headers)
    }

    func readHeaders() async throws -> InspectorReading<Result> {
        try await inspectorCache.load(target, kind: .headers) {
            let result: Result
            if let object = target.object {
                // Preserve the exact UTF-8 object key in the request.
                var parameters = ["Key": object.key]
                parameters["VersionId"] = object.version
                let data = try JSONSerialization.data(withJSONObject: parameters)
                result = try await fetch("head-object", requesterPays: true, headers: true, inputJSON: data)
            } else {
                result = try await head(headers: true)
            }
            guard result.error == nil, let response = result.response, !response.headers.isEmpty else {
                return (result, nil)
            }
            let bytes = response.headers.reduce(result.data.count + (response.url?.utf8.count ?? 0)) {
                $0 + 64 + $1.key.utf8.count + $1.value.utf8.count
            }
            return (result, bytes)
        }
    }

    func versions(after cursor: VersionCursor?) async throws -> (items: [S3Item], next: VersionCursor?) {
        let key = target.object?.key ?? target.item?.key ?? target.prefix
        var args = ["--max-keys=100", "--prefix=\(key)"]
        if target.object == nil { args.append("--delimiter=/") }
        if let cursor {
            args.append("--key-marker=\(cursor.key)")
            if let version = cursor.version { args.append("--version-id-marker=\(version)") }
        }
        let result = try await fetch("list-object-versions", args: args, requesterPays: true)
        if let error = result.error { throw ShelfError(error) }
        let page = try JSONDecoder().decode(ObjectPage.self, from: result.data)
        let entries = page.items.filter { entry in
            entry.kind != .folder && (target.object == nil || entry.key.utf8.elementsEqual(key.utf8))
        }.sorted { (lhs, rhs) in
            if lhs.latest == true && rhs.latest != true { return true }
            if rhs.latest == true && lhs.latest != true { return false }
            return (lhs.date ?? "") > (rhs.date ?? "")
        }
        let next = page.NextKeyMarker.flatMap { marker -> VersionCursor? in
            guard target.object == nil || marker.utf8.elementsEqual(key.utf8) else { return nil }
            return VersionCursor(key: marker, version: page.NextVersionIdMarker)
        }
        return (entries, cursor == next ? nil : next)
    }

    func preview() async throws -> InspectorPreview {
        let head = try await head()
        if let error = head.error { throw ShelfError(error) }
        guard let size = (head.fields["ContentLength"] as? NSNumber)?.int64Value, size >= 0 else {
            throw ShelfError("端点未返回对象大小，无法按范围读取预览。")
        }
        if size == 0 { return .text("空对象（0 字节）", truncated: false) }
        let contentType = (head.fields["ContentType"] as? String) ?? ""
        let pathExtension = (target.identifier as NSString).pathExtension.lowercased()
        let image = contentType.hasPrefix("image/") || ["jpg", "jpeg", "png", "gif", "webp", "heic", "tiff", "bmp"].contains(pathExtension)
        let imageLimit = 8 * 1024 * 1024
        let limit = image && size <= imageLimit ? size : min(size, 256 * 1024)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("preview")
        var arguments = target.objectArguments + ["--range=bytes=0-\(limit - 1)"]
        if let etag = head.fields["ETag"] as? String { arguments.append("--if-match=\(etag)") }
        let result = try await fetch("get-object", args: arguments + [file.path], requesterPays: true)
        if let error = result.error { throw ShelfError(error) }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let data = try input.read(upToCount: Int(limit)) ?? Data()
        try Task.checkCancellation()
        if image, size <= imageLimit, data.count == size,
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: 1400
           ] as CFDictionary) {
            return .image(NSImage(cgImage: bitmap, size: .zero))
        }
        if let text = Self.decodeText(data, truncated: size > limit) { return .text(text, truncated: size > limit) }
        return .hex(Self.hex(data.prefix(4096)), truncated: size > 4096)
    }

    static func decodeText(_ data: Data, truncated: Bool) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        let isText = data.prefix(4096).allSatisfy { $0 >= 32 || [9, 10, 13].contains($0) }
        guard isText else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        if truncated {
            for trim in 1...min(max(1, data.count), 3) {
                if let text = String(data: data.dropLast(trim), encoding: .utf8) { return text }
            }
        }
        return nil
    }

    static func hex(_ data: Data) -> String {
        stride(from: 0, to: data.count, by: 16).map { offset in
            let row = data.dropFirst(offset).prefix(16)
            let bytes = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = String(decoding: row.map { (32...126).contains($0) ? $0 : 46 }, as: UTF8.self)
            return String(format: "%08X", offset) + "  " + bytes.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + ascii
        }.joined(separator: "\n")
    }
}

struct VersionCursor: Equatable { let key: String; let version: String? }

enum InspectorPreview {
    case text(String, truncated: Bool)
    case hex(String, truncated: Bool)
    case image(NSImage)
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case properties = "属性", headers = "响应头", permissions = "权限", tags = "标签"
    case preview = "预览", versions = "版本", tasks = "任务", events = "事件日志"
    var id: Self { self }
    var needsRequest: Bool { self != .tasks && self != .events }
    var cacheKinds: Set<InspectorCacheKind> {
        switch self {
        case .permissions: InspectorCacheKind.permissions
        case .headers: [.headers]
        case .tags: [.tags]
        default: []
        }
    }
    var requiresAccessTarget: Bool { self == .permissions || self == .tags }
}

struct InspectorCacheTimestamp: View {
    let date: Date
    var source = ""
    let refreshLabel: String
    var isRefreshing = false
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label("\(source)缓存 · \(date.formatted(date: .numeric, time: .standard))", systemImage: "clock")
                .foregroundStyle(.secondary)
                .help("从服务端读取的时间")
            Button("刷新", action: refresh)
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .disabled(isRefreshing)
                .accessibilityLabel(refreshLabel)
                .help("\(refreshLabel)，从服务端重新读取")
        }
        .font(.caption)
    }
}

struct InspectorPane: View {
    @ObservedObject var model: Workspace
    let target: InspectorTarget
    @Binding var tab: InspectorTab
    @Binding var requestedTarget: InspectorTarget?
    let download: (S3Item) -> Void
    @State private var reload = 0

    var body: some View {
        let hasMultipleSelection = tab.requiresAccessTarget && model.selection.count > 1
        let isCachedTab = !tab.cacheKinds.isEmpty
        let shouldLoad = tab.needsRequest && (isCachedTab || requestedTarget == target) && !hasMultipleSelection
        let refreshLabel = isCachedTab ? "强制刷新\(tab.rawValue)" : "刷新详情"
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Label(target.scope, systemImage: target.item?.icon ?? "shippingbox")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(target.location).font(.system(.caption, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 0)
                Button { copy(target.location) } label: { Image(systemName: "document.on.document") }
                    .buttonStyle(.borderless).help("复制 S3 URI")
                if shouldLoad && (!tab.requiresAccessTarget || target.supportsAccessManagement) {
                    Button(action: refreshCurrentTab) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(refreshLabel)
                        .help(isCachedTab ? "\(refreshLabel)，从服务端重新读取" : refreshLabel)
                }
            }.padding(.horizontal, 17).padding(.top, 10).padding(.bottom, 8)
            Picker("详情", selection: Binding(get: { tab }, set: { selection in
                tab = selection
                requestedTarget = selection.needsRequest && selection.cacheKinds.isEmpty ? target : nil
            })) {
                ForEach(InspectorTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 17).padding(.bottom, 9)
            Divider()
            switch tab {
            case .tasks:
                TransfersView(model: model, compact: true)
            case .events:
                events
            default:
                if hasMultipleSelection {
                    Text("选择单个资源后可管理权限和标签。").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(17)
                } else if shouldLoad, let connection = model.currentConnection {
                    let client = InspectorClient(model: model, target: target, connection: connection)
                    Group {
                        if tab == .permissions || tab == .tags { AccessManagementPane(client: client, tagsOnly: tab == .tags) }
                        else { InspectorContent(client: client, tab: tab, download: download, refresh: refreshCurrentTab) }
                    }.id(ContentID(target: target, tab: tab, reload: reload,
                                   cacheSession: isCachedTab ? ObjectIdentifier(client.inspectorCache) : nil,
                                   cacheEnabled: isCachedTab && model.inspectorCachePolicy.lifetimeSeconds > 0))
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        if let item = target.item {
                            HStack(spacing: 14) {
                                if let size = item.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                                if let storage = item.storage { Text(storage) }
                                if let date = item.date { Text(date) }
                            }.font(.caption).foregroundStyle(.secondary)
                        } else if let region = target.bucket.BucketRegion {
                            Text(region).font(.caption).foregroundStyle(.secondary)
                        }
                        Button("加载\(tab.rawValue)") { requestedTarget = target }
                    }.padding(.horizontal, 17).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }.background(Color(nsColor: .controlBackgroundColor))
            .onChange(of: target) { _, newTarget in
                if requestedTarget != newTarget { requestedTarget = nil }
            }
    }

    private func refreshCurrentTab() {
        model.inspectorCache.invalidate(target, kinds: tab.cacheKinds)
        reload += 1
    }

    private struct ContentID: Hashable {
        let target: InspectorTarget
        let tab: InspectorTab
        let reload: Int
        let cacheSession: ObjectIdentifier?
        let cacheEnabled: Bool
    }

    private var events: some View {
        ScrollView {
            HStack {
                Text("本次会话 · 最近 \(model.events.count) 条").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("复制日志") {
                    copy(model.events.map { event in
                        let status = event.status.map { "HTTP \($0)" } ?? (event.success ? "成功" : "失败")
                        return [event.time.formatted(), status, event.action, event.resource, event.requestID ?? ""].joined(separator: "\t")
                    }.joined(separator: "\n"))
                }.disabled(model.events.isEmpty)
            }.padding(.bottom, 5)
            if model.events.isEmpty {
                Text("本次会话暂无 S3 操作。")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.events) { event in
                    HStack(spacing: 10) {
                        Image(systemName: event.success ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(event.success ? Color.secondary : Color.orange)
                        Text(event.time, style: .time).monospacedDigit().frame(width: 76, alignment: .leading)
                        Text(event.action).fontWeight(.medium)
                        Text(event.resource).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let status = event.status { Text("HTTP \(status)").foregroundStyle(.secondary) }
                        if let id = event.requestID { Text(id).textSelection(.enabled).foregroundStyle(.secondary).lineLimit(1) }
                    }.font(.system(.caption, design: .monospaced)).padding(.vertical, 5)
                    Divider()
                }
            }
        }.padding(.horizontal, 17).padding(.vertical, 8)
    }
}

private struct InspectorContent: View {
    let client: InspectorClient
    let tab: InspectorTab
    let download: (S3Item) -> Void
    let refresh: () -> Void
    @State private var sections: [DetailsSection] = []
    @State private var headersCachedAt: Date?
    @State private var preview: InspectorPreview?
    @State private var versions: [S3Item] = []
    @State private var cursor: VersionCursor?
    @State private var page = 0
    @State private var busy = false
    @State private var error: String?

    private var target: InspectorTarget { client.target }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let headersCachedAt {
                    InspectorCacheTimestamp(date: headersCachedAt, refreshLabel: "刷新响应头", refresh: refresh)
                }
                ForEach(sections) { section in sectionView(section) }
                if let preview { previewView(preview) }
                if tab == .versions { versionRows }
                if let error { message(error, icon: "exclamationmark.circle", warning: true) }
                if busy { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(8) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 17).padding(.vertical, 9)
        }.task(id: page) { await load() }
    }

    private func sectionView(_ section: DetailsSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(section.title).font(.subheadline.weight(.semibold))
                Spacer()
                if !section.rows.isEmpty {
                    Button("复制") { copy(section.rows.map { "\($0.name)\t\($0.value)" }.joined(separator: "\n")) }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
            if let detail = section.note { message(detail, icon: section.error ? "exclamationmark.circle" : nil, warning: section.error) }
            VStack(spacing: 0) {
                ForEach(section.rows.indices, id: \.self) { index in
                    let row = section.rows[index]
                    HStack(alignment: .top, spacing: 12) {
                        Text(row.name).foregroundStyle(.secondary).frame(width: 214, alignment: .leading)
                        Text(row.value).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.font(.system(.caption, design: .monospaced)).padding(.vertical, 4)
                    if index + 1 < section.rows.count { Divider() }
                }
            }
        }
    }

    private func message(_ text: String, icon: String?, warning: Bool) -> some View {
        HStack(alignment: .top, spacing: 7) {
            if let icon { Image(systemName: icon).foregroundStyle(warning ? Color.orange : Color.secondary) }
            Text(text).textSelection(.enabled)
        }.font(.callout).foregroundStyle(.secondary).padding(.vertical, 3)
    }

    @ViewBuilder private func previewView(_ preview: InspectorPreview) -> some View {
        switch preview {
        case .image(let image):
            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 630, maxHeight: 300)
                .frame(maxWidth: .infinity).accessibilityLabel("对象图片预览")
        case .text(let content, let truncated):
            previewText(content, caption: truncated ? "文本 · 前 256 KiB" : "文本")
        case .hex(let content, let truncated):
            previewText(content, caption: truncated ? "十六进制 · 前 4 KiB" : "十六进制")
        }
    }

    private func previewText(_ content: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("复制预览") { copy(content) }.buttonStyle(.borderless)
            }
            Text(content).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var versionRows: some View {
        VStack(alignment: .leading, spacing: 5) {
            if versions.isEmpty && cursor == nil && !busy && error == nil {
                Text("当前范围内没有版本记录。") .foregroundStyle(.secondary)
            }
            ForEach(versions) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.icon).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(target.object == nil ? item.key : item.version ?? "null").fontWeight(.medium).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        if target.object == nil { Text(item.version ?? "null").foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    Spacer(minLength: 4)
                    if item.kind == .deleteMarker { Text("删除标记").foregroundStyle(.orange) }
                    if item.latest == true { Text("当前").foregroundStyle(.secondary) }
                    if let date = item.date { Text(date).foregroundStyle(.secondary).lineLimit(1) }
                    if item.kind != .deleteMarker {
                        Button { download(item) } label: { Image(systemName: "arrow.down.to.line") }
                            .buttonStyle(.borderless).help("下载这个版本")
                    }
                    if let version = item.version {
                        Button { copy(version) } label: { Image(systemName: "document.on.document") }
                            .buttonStyle(.borderless).help("复制版本 ID")
                    }
                }.font(.system(.caption, design: .monospaced)).padding(.vertical, 3)
                Divider()
            }
            if cursor != nil { Button("加载下 100 条") { page += 1 }.disabled(busy) }
        }
    }

    private func load() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            switch tab {
            case .properties: sections = try await properties()
            case .headers:
                let reading = try await client.readHeaders()
                try Task.checkCancellation()
                headersCachedAt = reading.cachedAt
                let result = reading.value
                let title = result.response?.status.map { "HTTP \($0)" } ?? "HTTP 响应头"
                let headers = result.response?.headers ?? [:]
                let address = result.response?.url.map { [DetailsRow(name: "请求 URL", value: $0)] } ?? []
                sections = [DetailsSection(title: title, rows: address + rows(headers),
                                           note: result.error ?? (headers.isEmpty ? "端点未返回可显示的响应头。" : nil), error: result.error != nil)]
            case .preview:
                if let object = target.object, object.kind != .deleteMarker { preview = try await client.preview() }
                else { error = target.object == nil ? "选择一个对象以查看预览。" : "删除标记没有可预览的内容。" }
            case .versions:
                let result = try await client.versions(after: cursor)
                let known = Set(versions.map(\.id))
                versions += result.items.filter { !known.contains($0.id) }
                cursor = result.next
            case .permissions, .tags, .tasks, .events: break
            }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func properties() async throws -> [DetailsSection] {
        var fields: [String: Any] = ["Bucket": target.bucket.Name]
        if let item = target.item {
            fields[item.kind == .folder ? "Prefix" : "Key"] = item.key
            fields["ContentLength"] = item.size
            fields["LastModified"] = item.date
            fields["StorageClass"] = item.storage
            fields["VersionId"] = item.version
            fields["IsLatest"] = item.latest
            if item.kind == .deleteMarker {
                fields["DeleteMarker"] = true
                return [DetailsSection(title: "删除标记", rows: rows(fields))]
            }
        } else if !target.prefix.isEmpty { fields["Prefix"] = target.prefix }
        fields["BucketRegion"] = target.bucket.BucketRegion
        let result = try await client.head()
        var returned = result.fields
        let metadata = returned.removeValue(forKey: "Metadata") as? [String: Any] ?? [:]
        fields.merge(returned) { _, value in value }
        var sections = [DetailsSection(title: target.object == nil ? "存储桶属性" : "对象属性", rows: rows(fields),
                                       note: result.error, error: result.error != nil)]
        if !metadata.isEmpty { sections.append(DetailsSection(title: "自定义元数据", rows: rows(metadata))) }
        if target.object == nil {
            var commands = [("get-bucket-versioning", "版本控制"), ("get-bucket-encryption", "默认加密"),
                ("get-object-lock-configuration", "对象锁定"), ("get-bucket-ownership-controls", "对象所有权")
            ]
            if fields["BucketRegion"] == nil { commands.insert(("get-bucket-location", "存储桶位置"), at: 0) }
            sections += try await bucketSections(commands)
        }
        return sections
    }

    private func bucketSections(_ commands: [(String, String)]) async throws -> [DetailsSection] {
        var sections: [DetailsSection] = []
        for (command, title) in commands {
            let result = try await client.fetch(command)
            var fields = result.fields
            if let policy = fields["Policy"] as? String, let json = try? JSONSerialization.jsonObject(with: Data(policy.utf8)) as? [String: Any] {
                fields["Policy"] = Workspace.pretty(json)
            }
            let missing = ["NoSuchPublicAccessBlockConfiguration", "NoSuchBucketPolicy", "ServerSideEncryptionConfigurationNotFoundError",
                           "ObjectLockConfigurationNotFoundError", "OwnershipControlsNotFoundError"].contains { result.error?.contains("(\($0))") == true }
            sections.append(DetailsSection(title: title, rows: rows(fields),
                                           note: missing || (result.error == nil && fields.isEmpty) ? "未设置" : result.error,
                                           error: result.error != nil && !missing))
        }
        return sections
    }

    private func rows(_ fields: [String: Any]) -> [DetailsRow] {
        fields.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { key in
            guard let value = fields[key], !(value is NSNull) else { return nil }
            if let string = value as? String { return DetailsRow(name: key, value: string) }
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return DetailsRow(name: key, value: data.map { String(decoding: $0, as: UTF8.self) } ?? String(describing: value))
        }
    }
}

private struct DetailsSection: Identifiable {
    var id: String { title }
    let title: String
    var rows: [DetailsRow] = []
    var note: String?
    var error = false
}

private struct DetailsRow { let name: String; let value: String }
