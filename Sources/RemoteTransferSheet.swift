import SwiftUI

struct RemoteTransferForm: Identifiable {
    let id = UUID()
    let source: RemoteTransferLocation
}

@MainActor
final class TargetBucketDirectory: ObservableObject {
    @Published private(set) var buckets: [Bucket] = []
    @Published private(set) var cursor: String?
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    private(set) var connection: Connection?
    private var visited = Set<String>()
    private var task: Task<Void, Never>?

    func open(_ connection: Connection) {
        guard self.connection != connection else { return }
        refresh(connection)
    }

    func clear() {
        task?.cancel()
        task = nil
        connection = nil
        buckets = []
        cursor = nil
        loading = false
        failure = nil
        visited = []
    }

    func refresh(_ connection: Connection) {
        clear()
        self.connection = connection
        load(connection, cursor: nil)
    }

    func loadMore() {
        guard let connection, let cursor, !loading else { return }
        load(connection, cursor: cursor)
    }

    private func load(_ connection: Connection, cursor: String?) {
        loading = true
        failure = nil
        task = Task {
            defer {
                if !Task.isCancelled { loading = false; task = nil }
            }
            do {
                let page = try await Workspace.loadBucketPage(connection, cursor: cursor)
                try Task.checkCancellation()
                var seen = Set(buckets.map(\.id))
                buckets.append(contentsOf: (page.Buckets ?? []).filter { seen.insert($0.id).inserted })
                buckets.sort { $0.Name.localizedStandardCompare($1.Name) == .orderedAscending }
                if let cursor { visited.insert(cursor) }
                let next = page.ContinuationToken.flatMap { $0.isEmpty ? nil : $0 }
                if let next, visited.contains(next) {
                    self.cursor = nil
                    failure = "端点返回了重复的分页标记，请刷新存储桶清单。"
                } else {
                    self.cursor = next
                }
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
        }
    }
}

struct RemoteTransferSheet: View {
    @ObservedObject var model: Workspace
    let form: RemoteTransferForm

    @Environment(\.dismiss) private var dismiss
    @State private var mode = RemoteTransferMode.copy
    @State private var targetID: UUID
    @State private var bucket = ""
    @State private var prefix = ""
    @State private var metadata = true
    @State private var chunk = ""
    @State private var bandwidth = ""
    @State private var message: String?
    @State private var proposedSync: RemoteTransferJob?
    @State private var showingBuckets = false
    @StateObject private var directory = TargetBucketDirectory()

    init(model: Workspace, form: RemoteTransferForm) {
        self.model = model
        self.form = form
        let writable = model.connections.filter { $0.auth != .anonymous }
        _targetID = State(initialValue: form.source.connection.auth == .anonymous
                          ? writable.first?.id ?? form.source.connection.id : form.source.connection.id)
    }

    private var targets: [Connection] {
        var available = model.connections
        if !available.contains(where: { $0.id == form.source.connection.id }) { available.append(form.source.connection) }
        return available.filter { $0.auth != .anonymous }
    }

    private var target: Connection? { targets.first { $0.id == targetID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("S3 → S3", systemImage: "arrow.left.arrow.right")
                .font(.title2.bold()).accessibilityAddTraits(.isHeader)
            LabeledContent("源路径", value: form.source.display)
                .font(.callout).textSelection(.enabled)
            Divider()
            Picker("方式", selection: $mode) {
                ForEach(RemoteTransferMode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text(mode == .copy ? "复制新增或变化的对象，保留目标端的其他对象。"
                 : "使目标前缀与源一致。复制结束后会删除目标端多余的对象。")
                .font(.caption).foregroundStyle(mode == .sync ? Color.orange : .secondary)
            if targets.isEmpty {
                Text("请先添加具备写入权限的目标连接。").foregroundStyle(.secondary)
            } else {
                targetFields
            }
            Toggle("保留对象元数据", isOn: $metadata)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("分片大小（MiB）").font(.callout)
                    TextField("全局 \(model.transferPreferences.partMiB) MiB", text: $chunk).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("分片大小（MiB）")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("限速（MiB/s）").font(.callout)
                    TextField(model.transferPreferences.limitMiBPerSecond.map { "全局 \($0.formatted()) MiB/s" } ?? "不限速",
                              text: $bandwidth).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("限速（MiB/s）")
                }
            }
            if let message {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(mode == .sync ? "检查同步设置" : "加入传输队列", action: prepare)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(target == nil || bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 528)
        .alert("确认同步到目标路径？", isPresented: Binding(get: { proposedSync != nil }, set: { if !$0 { proposedSync = nil } }),
               presenting: proposedSync) { job in
            Button("取消", role: .cancel) {}
            Button("开始同步", role: .destructive) { enqueue(job) }
        } message: { job in
            Text("\(job.destination.display)\n源端没有的对象可能在此目标路径中被删除。")
        }
        .onChange(of: target) { _, _ in
            showingBuckets = false
            directory.clear()
            bucket = ""
            message = nil
        }
        .onDisappear { directory.clear() }
        .accessibilityIdentifier("remote-transfer-form")
    }

    private var targetFields: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker("目标连接", selection: $targetID) {
                ForEach(targets) { Text($0.name).tag($0.id) }
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("目标存储桶").font(.callout)
                    HStack(spacing: 6) {
                        TextField("输入桶名", text: $bucket).textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled().accessibilityLabel("目标存储桶")
                        Button("浏览…") {
                            guard let target else { return }
                            directory.open(target)
                            showingBuckets = true
                        }
                        .disabled(target == nil)
                        .accessibilityLabel("浏览目标存储桶")
                        .accessibilityIdentifier("remote-target-browse")
                        .popover(isPresented: $showingBuckets, arrowEdge: .bottom) {
                            if let target {
                                TargetBucketPicker(connection: target, directory: directory, selectedName: bucket) { picked in
                                    guard self.target == target, directory.connection == target else { return }
                                    bucket = picked.Name
                                    message = nil
                                    showingBuckets = false
                                }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("目标前缀").font(.callout)
                    TextField("留空使用存储桶根路径", text: $prefix).textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled().accessibilityLabel("目标前缀")
                }
            }
        }
    }

    private func prepare() {
        do {
            guard let connection = target else { return }
            let name = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentBucket = model.connection == connection
                ? model.buckets.first { $0.Name == name } ?? (model.bucket?.Name == name ? model.bucket : nil) : nil
            let listedBucket = directory.connection == connection ? directory.buckets.first { $0.Name == name } : nil
            let target = RemoteTransferLocation(connection: connection, bucket: name, prefix: try RemoteTransferLocation.folder(prefix),
                                                bucketRegion: listedBucket?.BucketRegion ?? currentBucket?.BucketRegion)
            let chunkText = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            let speedText = bandwidth.trimmingCharacters(in: .whitespacesAndNewlines)
            let chunkSize = Int(chunkText)
            let speed = Double(speedText)
            if !chunkText.isEmpty, chunkSize == nil { throw ShelfError("请输入整数分片大小。") }
            if !speedText.isEmpty, speed == nil { throw ShelfError("请输入有效的限速数值，例如 1.5。") }
            let job = RemoteTransferJob(mode: mode, source: form.source, destination: target,
                                        metadata: metadata, chunkMiB: chunkSize, bandwidthMiB: speed)
            try job.validate()
            if mode == .sync { proposedSync = job }
            else { enqueue(job) }
        } catch {
            message = error.localizedDescription
        }
    }

    private func enqueue(_ job: RemoteTransferJob) {
        do {
            try model.enqueueRemote(job)
            model.destination = .transfers
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct TargetBucketPicker: View {
    let connection: Connection
    @ObservedObject var directory: TargetBucketDirectory
    let selectedName: String
    let choose: (Bucket) -> Void
    @State private var search = ""

    private var matches: [Bucket] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? directory.buckets : directory.buckets.filter { $0.Name.localizedStandardContains(term) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(connection.name).font(.headline).lineLimit(1)
                Spacer()
                if directory.loading { ProgressView().controlSize(.small).accessibilityLabel("正在加载存储桶") }
                Button { directory.refresh(connection) } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(directory.loading).help("刷新存储桶").accessibilityLabel("刷新存储桶")
            }
            TextField("搜索已加载的存储桶", text: $search).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("remote-target-search")
            if let failure = directory.failure {
                Text("无法完整加载存储桶清单，可手动输入桶名。")
                    .font(.caption).foregroundStyle(.orange).help(failure)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(matches) { bucket in
                        Button { choose(bucket) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: bucket.Name == selectedName ? "checkmark.circle.fill" : "shippingbox")
                                    .foregroundStyle(bucket.Name == selectedName ? Color.accentColor : .secondary)
                                Text(bucket.Name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if let region = bucket.BucketRegion, !region.isEmpty {
                                    Text(region).font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if matches.isEmpty, !directory.loading, directory.failure == nil {
                        Text(search.isEmpty ? "没有可列出的存储桶" : "已加载的页面中没有匹配的存储桶")
                            .font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                }
            }.frame(height: 174)
            if directory.cursor != nil {
                Button("加载更多存储桶", action: directory.loadMore).disabled(directory.loading)
            }
        }
        .padding(12).frame(width: 335)
        .accessibilityIdentifier("remote-target-bucket-picker")
    }
}
