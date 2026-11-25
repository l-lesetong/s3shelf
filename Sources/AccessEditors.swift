import SwiftUI

struct AccessManagementPane: View {
    let client: InspectorClient
    let tagsOnly: Bool
    @State private var ownership: InspectorReading<String?>?
    @State private var publicPolicy: InspectorReading<Bool?>?
    @State private var ownershipRevision = 0
    @State private var policyRevision = 0
    @State private var refreshingOwnership = false
    @State private var refreshingPolicyStatus = false
    @State private var ownershipRefreshError: String?
    @State private var policyRefreshError: String?

    private var canWrite: Bool { client.connection.auth != .anonymous }
    private var resourceName: String { client.isBucket ? "存储桶" : client.target.object?.version == nil ? "对象" : "对象版本" }
    private var location: String {
        if client.isBucket { return Engine.s3URI(client.target.bucket.Name) }
        if let version = client.target.object?.version { return "\(client.target.location)   版本 \(version)" }
        return client.target.location
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                if client.target.item?.kind == .folder {
                    Text("前缀没有独立的权限或标签。请选择存储桶或单个对象。").foregroundStyle(.secondary)
                } else if client.target.item?.kind == .deleteMarker {
                    Text("删除标记没有可管理的权限或标签。").foregroundStyle(.secondary)
                } else if tagsOnly {
                    tagsSection
                } else {
                    aclSection
                    if client.isBucket {
                        Divider()
                        policySection
                        Divider()
                        accessBlockSection
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 17).padding(.vertical, 10)
        }
        .task(id: ownershipRevision) {
            guard !tagsOnly && client.target.supportsAccessManagement else { return }
            do {
                let reading = try await client.readOwnership(fresh: ownershipRevision > 0)
                try Task.checkCancellation()
                ownership = reading
                ownershipRefreshError = nil
            } catch {
                guard !Task.isCancelled else { return }
                if refreshingOwnership { ownershipRefreshError = error.localizedDescription }
            }
            refreshingOwnership = false
        }
        .task(id: policyRevision) {
            guard !tagsOnly && client.isBucket else { return }
            do {
                let reading = try await client.readPolicyStatus(fresh: policyRevision > 0)
                try Task.checkCancellation()
                publicPolicy = reading
                policyRefreshError = nil
            } catch {
                guard !Task.isCancelled else { return }
                if refreshingPolicyStatus { policyRefreshError = error.localizedDescription }
                else { publicPolicy = nil }
            }
            refreshingPolicyStatus = false
        }
    }

    private var tagsSection: some View {
        ManagedSection(title: "\(resourceName)标签", location: location, read: client.readTags, write: client.writeTags,
                       readOnlyReason: { _ in canWrite ? nil : "匿名连接只可查看。" },
                       validate: { $0.validation(limit: client.tagLimit) },
                       confirmation: { tags in tags.entries.isEmpty ? "删除此资源的全部标签？" : nil }) { tags in
            if tags.entries.isEmpty { Text("暂无标签").foregroundStyle(.secondary) }
            else {
                VStack(spacing: 0) {
                    ForEach(tags.entries) { tag in
                        accessRow(tag.key, tag.value.isEmpty ? "（空值）" : tag.value)
                        Divider()
                    }
                }
            }
        } editor: { draft in
            TagsEditor(draft: draft, limit: client.tagLimit)
        }
    }

    private var aclSection: some View {
        let ownership = self.ownership
        let refreshingOwnership = self.refreshingOwnership
        let ownershipRefreshError = self.ownershipRefreshError
        return ManagedSection(title: "\(resourceName) ACL", location: location, read: client.readACL, write: client.writeACL,
                       readOnlyReason: { value in
                           if ownership?.value == "BucketOwnerEnforced" { return "存储桶启用了 Bucket owner enforced，ACL 已禁用。" }
                           if !canWrite { return "匿名连接只可查看。" }
                           if !value.hasOwnerID { return "端点未返回所有者 Canonical ID，ACL 无法编辑。" }
                           return nil
                       }, validate: { $0.validation(isBucket: client.isBucket) },
                       confirmation: { _ in "保存会替换此资源的 ACL。确认应用更改？" }) { acl in
            if let date = ownership?.cachedAt {
                InspectorCacheTimestamp(date: date, source: "对象所有权", refreshLabel: "刷新对象所有权",
                                        isRefreshing: refreshingOwnership) {
                    self.refreshingOwnership = true
                    self.ownershipRefreshError = nil
                    ownershipRevision += 1
                }
            }
            if let ownershipRefreshError { Text(ownershipRefreshError).font(.caption).foregroundStyle(.secondary) }
            accessRow("所有者", acl.owner?.description ?? "端点未提供所有者信息")
            if acl.grants.isEmpty { Text("暂无授权").foregroundStyle(.secondary) }
            else {
                ForEach(acl.grants) { grant in
                    let principal = S3ACL.groups.first { $0.uri == grant.grantee.identifier }?.title ?? grant.grantee.label
                    accessRow(grant.permission, principal.isEmpty ? "\(grant.grantee.type) · 端点未提供主体标识" : principal)
                }
            }
        } editor: { draft in
            ACLEditor(draft: draft, isBucket: client.isBucket)
        }
    }

    private var policySection: some View {
        let publicPolicy = self.publicPolicy
        let refreshingPolicyStatus = self.refreshingPolicyStatus
        let policyRefreshError = self.policyRefreshError
        return ManagedSection(title: "存储桶策略", location: location, read: client.readBucketPolicy, write: client.writeBucketPolicy,
                       readOnlyReason: { _ in canWrite ? nil : "匿名连接只可查看。" },
                       validate: { policy in
                           guard let text = policy.text else { return nil }
                           do { _ = try BucketPolicy.normalized(text); return nil }
                           catch { return error.localizedDescription }
                       }, confirmation: { $0.text == nil ? "删除此存储桶的策略？" : "应用此存储桶策略？" },
                       didSave: { policyRevision += 1 }) { policy in
            if let date = publicPolicy?.cachedAt {
                InspectorCacheTimestamp(date: date, source: "公开状态", refreshLabel: "刷新策略公开状态",
                                        isRefreshing: refreshingPolicyStatus) {
                    self.refreshingPolicyStatus = true
                    self.policyRefreshError = nil
                    policyRevision += 1
                }
            }
            if let policyRefreshError { Text(policyRefreshError).font(.caption).foregroundStyle(.secondary) }
            if let isPublic = publicPolicy?.value { accessRow("策略公开状态", isPublic ? "公开" : "非公开") }
            if let text = policy.text {
                DisclosureGroup("查看策略 JSON") {
                    Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
            } else { Text("未设置存储桶策略").foregroundStyle(.secondary) }
        } editor: { draft in
            BucketPolicyEditor(draft: draft)
        }
    }

    private var accessBlockSection: some View {
        ManagedSection(title: "存储桶公开访问阻止", location: location, read: client.readPublicAccessBlock,
                       write: client.writePublicAccessBlock, readOnlyReason: { _ in canWrite ? nil : "匿名连接只可查看。" },
                       validate: { _ in nil }, confirmation: { $0 == nil ? "删除此存储桶的公开访问阻止设置？" : "应用公开访问阻止设置？" }) { settings in
            if let settings {
                accessRow("阻止新的公开 ACL", settings.blockPublicACLs ? "开启" : "关闭")
                accessRow("忽略公开 ACL", settings.ignorePublicACLs ? "开启" : "关闭")
                accessRow("阻止新的公开策略", settings.blockPublicPolicy ? "开启" : "关闭")
                accessRow("限制公开存储桶访问", settings.restrictPublicBuckets ? "开启" : "关闭")
            } else { Text("未设置存储桶级配置").foregroundStyle(.secondary) }
        } editor: { draft in
            PublicAccessBlockEditor(draft: draft)
        }
    }
}

private func accessRow(_ title: String, _ value: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
        Text(title).foregroundStyle(.secondary).frame(width: 170, alignment: .leading).textSelection(.enabled)
        Text(value).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }.font(.callout).padding(.vertical, 4)
}

private struct ManagedSection<Value: Equatable, Summary: View, Editor: View>: View {
    let title: String
    let location: String
    let read: @MainActor (_ fresh: Bool) async throws -> InspectorReading<Value>
    let write: @MainActor (Value) async throws -> Void
    let readOnlyReason: (Value) -> String?
    let validate: (Value) -> String?
    let confirmation: (Value) -> String?
    var didSave: () -> Void = {}
    @ViewBuilder let summary: (Value) -> Summary
    @ViewBuilder let editor: (Binding<Value>) -> Editor
    @State private var value: Value?
    @State private var cachedAt: Date?
    @State private var message: String?
    @State private var editing: Snapshot?
    @State private var loadRevision = 0

    private struct Snapshot: Identifiable {
        let id = UUID()
        let value: Value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if let value {
                    Button("编辑") { editing = Snapshot(value: value) }
                        .disabled(readOnlyReason(value) != nil)
                        .help(readOnlyReason(value) ?? "编辑\(title)")
                }
            }
            if let value {
                if let cachedAt {
                    InspectorCacheTimestamp(date: cachedAt, refreshLabel: "刷新\(title)") {
                        self.value = nil
                        self.cachedAt = nil
                        message = nil
                        loadRevision += 1
                    }
                }
                summary(value)
                if let reason = readOnlyReason(value) { Text(reason).font(.caption).foregroundStyle(.secondary) }
            } else if message == nil { ProgressView().controlSize(.small).accessibilityLabel("正在读取\(title)") }
            if let message { Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .task(id: loadRevision) {
            do {
                let loaded = try await read(loadRevision > 0)
                try Task.checkCancellation()
                value = loaded.value
                cachedAt = loaded.cachedAt
            } catch is CancellationError {} catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
        .sheet(item: $editing) { snapshot in
            MetadataEditSheet(title: "编辑\(title)", location: location, original: snapshot.value,
                              validate: validate, confirmation: confirmation, save: { draft in
                if let reason = readOnlyReason(snapshot.value) { throw ShelfError(reason) }
                try await saveMetadata(draft, original: snapshot.value, read: { try await read(true).value }, write: write)
                cachedAt = nil
                do {
                    let latest = try await read(true).value
                    value = latest
                    message = latest == draft ? nil : "端点返回的设置与提交值不同，已显示端点当前返回的内容。"
                } catch {
                    value = draft
                    message = "已提交，重新读取确认失败。\n\(error.localizedDescription)"
                }
                didSave()
            }, editor: editor)
        }
    }
}

@MainActor
func saveMetadata<Value: Equatable>(_ draft: Value, original: Value, read: @MainActor () async throws -> Value,
                                    write: @MainActor (Value) async throws -> Void) async throws {
    guard draft != original else { return }
    let current = try await read()
    guard current == original else { throw ShelfError("端点上的设置已被其他操作修改。请复制或记录草稿，关闭编辑窗口并刷新后再应用。") }
    try await write(draft)
}

private struct MetadataEditSheet<Value: Equatable, Editor: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let location: String
    let original: Value
    let validate: (Value) -> String?
    let confirmation: (Value) -> String?
    let save: @MainActor (Value) async throws -> Void
    @ViewBuilder let editor: (Binding<Value>) -> Editor
    @State private var draft: Value
    @State private var busy = false
    @State private var prompt = false
    @State private var error: String?

    init(title: String, location: String, original: Value, validate: @escaping (Value) -> String?,
         confirmation: @escaping (Value) -> String?, save: @escaping @MainActor (Value) async throws -> Void,
         @ViewBuilder editor: @escaping (Binding<Value>) -> Editor) {
        self.title = title
        self.location = location
        self.original = original
        self.validate = validate
        self.confirmation = confirmation
        self.save = save
        self.editor = editor
        _draft = State(initialValue: original)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title).font(.title2.bold())
            Text(location).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            editor($draft).disabled(busy)
            if let problem = error ?? (draft == original ? nil : validate(draft)) {
                Label(problem, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small).accessibilityLabel("正在保存") }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("保存") {
                    if confirmation(draft) == nil { apply() } else { prompt = true }
                }.keyboardShortcut(.defaultAction).disabled(busy || draft == original || validate(draft) != nil)
            }
        }.padding(22).frame(width: 650)
            .background(Color(nsColor: .windowBackgroundColor))
            .interactiveDismissDisabled(busy)
            .alert("确认更改", isPresented: $prompt) {
                Button("取消", role: .cancel) {}
                Button("应用") { apply() }
            } message: { Text(confirmation(draft) ?? "") }
    }

    private func apply() {
        guard !busy, draft != original, validate(draft) == nil else { return }
        let submitted = draft
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await save(submitted); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct TagsEditor: View {
    @Binding var draft: S3Tags
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("键").frame(maxWidth: .infinity, alignment: .leading)
                Text("值").frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 17)
            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 7) {
                    ForEach($draft.entries) { $row in
                        HStack(spacing: 8) {
                            TextField("标签键", text: $row.key).accessibilityLabel("标签键")
                            TextField("值（可留空）", text: $row.value).accessibilityLabel("标签值")
                            removeRow("移除标签") { draft.entries.removeAll { $0.id == row.id } }
                        }.textFieldStyle(.roundedBorder)
                    }
                }.padding(1)
            }.frame(height: min(CGFloat(max(draft.entries.count, 1)) * 32, 255))
            HStack {
                Button("添加标签", systemImage: "plus") { draft.entries.append(S3Tag()) }.disabled(draft.entries.count >= limit)
                Spacer()
                if !draft.entries.isEmpty { Button("移除全部", role: .destructive) { draft.entries.removeAll() } }
                Text("\(draft.entries.count) / \(limit)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ACLEditor: View {
    @Binding var draft: S3ACL
    let isBucket: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            accessRow("所有者", draft.owner?.description ?? "端点未提供所有者信息")
            ScrollView {
                VStack(spacing: 7) {
                    ForEach($draft.grants) { $grant in
                        let selectedType = grant.grantee.type
                        HStack(spacing: 8) {
                            Picker("主体类型", selection: Binding(get: { grant.grantee.type }, set: { newType in
                                grant.grantee.type = newType
                                grant.grantee.identifier = ""
                            })) {
                                Text("Canonical ID").tag("CanonicalUser")
                                Text("S3 群组").tag("Group")
                                if selectedType == "AmazonCustomerByEmail" { Text("邮箱（旧授权）").tag("AmazonCustomerByEmail") }
                            }.labelsHidden().frame(width: 125)
                            if selectedType == "Group" {
                                Picker("S3 群组", selection: $grant.grantee.identifier) {
                                    Text("选择群组").tag("")
                                    ForEach(S3ACL.groups, id: \.uri) { group in Text(group.title).tag(group.uri) }
                                    if !grant.grantee.identifier.isEmpty && !S3ACL.groups.contains(where: { $0.uri == grant.grantee.identifier }) {
                                        Text(grant.grantee.identifier).tag(grant.grantee.identifier)
                                    }
                                }.labelsHidden().frame(maxWidth: .infinity)
                            } else {
                                TextField(selectedType == "AmazonCustomerByEmail" ? "邮箱" : "Canonical ID", text: $grant.grantee.identifier)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Picker("权限", selection: $grant.permission) {
                                ForEach(S3ACL.permissions(isBucket: isBucket), id: \.self) { value in Text(value).tag(value) }
                            }.labelsHidden().frame(width: 126)
                            removeRow("移除授权") { draft.grants.removeAll { $0.id == grant.id } }
                        }
                    }
                }.padding(1)
            }.frame(height: min(CGFloat(max(draft.grants.count, 1)) * 32, 255))
            HStack {
                Button("添加授权", systemImage: "plus") { draft.grants.append(S3ACL.Grant()) }.disabled(draft.grants.count >= 100)
                Spacer()
                Text("\(draft.grants.count) / 100").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

private struct BucketPolicyEditor: View {
    @Binding var draft: BucketPolicy
    @State private var previousText: String?
    private let template = "{\n  \"Version\": \"2012-10-17\",\n  \"Statement\": []\n}"

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if draft.text != nil {
                TextEditor(text: Binding(get: { draft.text ?? "" }, set: { draft.text = $0 }))
                    .font(.system(.body, design: .monospaced)).frame(height: 250).accessibilityLabel("存储桶策略 JSON")
            } else { Text("未设置存储桶策略").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 85, alignment: .leading) }
            HStack {
                if let text = draft.text {
                    Button("格式化 JSON") { if let formatted = try? BucketPolicy.normalized(text) { draft.text = formatted } }
                    Button("复制 JSON") { copy(text) }
                    Spacer()
                    Button("移除策略", role: .destructive) { previousText = draft.text; draft.text = nil }
                } else {
                    Button(previousText == nil ? "添加策略" : "恢复草稿") { draft.text = previousText ?? template }
                }
            }
        }
    }
}

private struct PublicAccessBlockEditor: View {
    @Binding var draft: PublicAccessBlock?
    @State private var previous: PublicAccessBlock?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if draft != nil {
                Toggle("阻止新的公开 ACL", isOn: flag(\.blockPublicACLs))
                Toggle("忽略公开 ACL", isOn: flag(\.ignorePublicACLs))
                Toggle("阻止新的公开策略", isOn: flag(\.blockPublicPolicy))
                Toggle("限制公开存储桶访问", isOn: flag(\.restrictPublicBuckets))
                Button("移除存储桶级配置", role: .destructive) { previous = draft; draft = nil }
            } else {
                Text("未设置存储桶级配置").foregroundStyle(.secondary)
                Button(previous == nil ? "添加配置" : "恢复配置草稿") { draft = previous ?? PublicAccessBlock() }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func flag(_ path: WritableKeyPath<PublicAccessBlock, Bool>) -> Binding<Bool> {
        Binding(get: { draft?[keyPath: path] ?? false }, set: { draft?[keyPath: path] = $0 })
    }
}

private func removeRow(_ label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: "minus.circle") }
        .buttonStyle(.borderless).help(label).accessibilityLabel(label)
}
