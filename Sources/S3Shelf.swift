import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct S3Shelf: App {
    @StateObject private var model = Workspace()
    @AppStorage("appearance") private var appearance = ShelfAppearance.system

    var body: some Scene {
        Window("s3Shelf", id: "workspace") {
            ShelfWindow(model: model)
                .frame(minWidth: 900, minHeight: 590)
                .preferredColorScheme(appearance.colorScheme)
                .onChange(of: appearance, initial: true) { _, value in value.apply() }
        }
        .defaultSize(width: 1170, height: 750)
        .windowToolbarStyle(.unified)

        Settings {
            ShelfSettings(model: model, appearance: $appearance)
        }
    }
}

struct ShelfSettings: View {
    let model: Workspace
    @Binding var appearance: ShelfAppearance

    var body: some View {
        TabView {
            AppearanceSettings(appearance: $appearance)
                .tabItem { Label("外观", systemImage: "circle.lefthalf.filled") }
            InspectorCacheSettings(model: model)
                .tabItem { Label("详情缓存", systemImage: "internaldrive") }
        }
        .frame(width: 480, height: 215)
        .preferredColorScheme(appearance.colorScheme)
        .onChange(of: appearance, initial: true) { _, value in value.apply() }
    }
}

struct AppearanceSettings: View {
    @Binding var appearance: ShelfAppearance

    var body: some View {
        Form {
            Picker("外观", selection: $appearance) {
                ForEach(ShelfAppearance.allCases) { option in
                    Label(option.title, systemImage: option.symbol).tag(option)
                }
            }.pickerStyle(.segmented)
        }
        .formStyle(.grouped)
    }
}

struct InspectorCacheSettings: View {
    @ObservedObject var model: Workspace

    var body: some View {
        Form {
            Section {
                Picker("缓存时间", selection: lifetime) {
                    ForEach(InspectorCachePolicy.lifetimes, id: \.self) { seconds in
                        Text(lifetimeLabel(seconds)).tag(seconds)
                    }
                }
                Picker("缓存空间上限", selection: capacity) {
                    ForEach(InspectorCachePolicy.capacities, id: \.self) { kiB in
                        Text(kiB >= 1024 ? "\(kiB / 1024) MiB" : "\(kiB) KiB").tag(kiB)
                    }
                }.disabled(model.inspectorCachePolicy.lifetimeSeconds == 0)
            } footer: {
                Text(model.inspectorCachePolicy.lifetimeSeconds == 0
                     ? "每次加载标签、权限或响应头时都向服务端请求。"
                     : "标签、权限和响应头共用内存缓存。到期后，下次查看会重新请求。空间按缓存记录估算。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var lifetime: Binding<Int> {
        Binding(get: { model.inspectorCachePolicy.lifetimeSeconds }, set: { seconds in
            model.configureInspectorCache(.init(lifetimeSeconds: seconds, capacityKiB: model.inspectorCachePolicy.capacityKiB))
        })
    }

    private var capacity: Binding<Int> {
        Binding(get: { model.inspectorCachePolicy.capacityKiB }, set: { kiB in
            model.configureInspectorCache(.init(lifetimeSeconds: model.inspectorCachePolicy.lifetimeSeconds, capacityKiB: kiB))
        })
    }

    private func lifetimeLabel(_ seconds: Int) -> String {
        if seconds == 0 { return "从不缓存" }
        if seconds < 60 { return "\(seconds) 秒" }
        return "\(seconds / 60) 分钟"
    }
}

enum ShelfAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

private struct ConnectionEdit: Identifiable {
    var value: Connection
    let existing: Bool
    var id: UUID { value.id }
}

private struct Prompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: () -> Void
    var destructive = true
    var buttonTitle: String? = nil
}

private struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

struct ShelfWindow: View {
    @ObservedObject var model: Workspace
    @State private var edit: ConnectionEdit?
    @State private var confirmation: Prompt?
    @State private var notice: Notice?
    @State private var accessing = false
    @State private var dropTarget = false
    @State private var manualBucket = false
    @State private var createBucketConnection: Connection?
    @State private var bucketDeletion: BucketDeletionRequest?
    @State private var bucketText = ""
    @State private var copying: S3Item?
    @State private var copyKey = ""
    @State private var showInspector = true
    @State private var inspectorTab = InspectorTab.properties
    @State private var inspectorRequest: InspectorTarget?

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 192, ideal: 226, max: 308)
        } detail: {
            Group {
                switch model.destination {
                case .browse: browser
                case .api: APIView(model: model, confirm: { confirmation = $0 }, showBucketCreation: showBucketCreation,
                                   showBucketDeletion: { bucketDeletion = $0 })
                case .transfers: TransfersView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: model.destination) { _, destination in
            if destination != .browse { inspectorRequest = nil }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.destination == .browse, model.bucket != nil {
                    Button { upload() } label: {
                        Label("上传", systemImage: "square.and.arrow.up")
                    }.disabled(!model.canWrite).help("上传文件或文件夹")
                    Button { if let item = model.selection.first { download(item) } } label: {
                        Label("下载", systemImage: "square.and.arrow.down")
                    }.disabled(model.selection.count != 1 || model.selection.first?.kind == .deleteMarker).help("下载所选对象")
                    Button {
                        showInspector.toggle()
                        if !showInspector { inspectorRequest = nil }
                    } label: {
                        Label(showInspector ? "隐藏详情" : "显示详情", systemImage: "rectangle.bottomthird.inset.filled")
                    }.keyboardShortcut("i", modifiers: [.command, .option])
                        .help(showInspector ? "隐藏详情" : "显示详情")
                }
                Button { edit = ConnectionEdit(value: Connection(), existing: false) } label: {
                    Label("新建连接", systemImage: "plus.circle")
                }.keyboardShortcut("n", modifiers: [.command, .shift]).help("新建连接")
            }
        }
        .sheet(item: $edit) { editor in ConnectionEditor(model: model, draft: editor.value, existing: editor.existing) }
        .sheet(item: $createBucketConnection) { connection in
            BucketCreationSheet(model: model, connection: connection)
        }
        .sheet(item: $bucketDeletion) { request in
            BucketDeletionSheet(model: model, request: request)
        }
        .sheet(isPresented: $manualBucket) {
            VStack(alignment: .leading, spacing: 14) {
                Text("打开存储桶").font(.title2.bold())
                TextField("存储桶名称或访问点 ARN", text: $bucketText).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("取消") { manualBucket = false }.keyboardShortcut(.cancelAction)
                    Button("打开") { openEnteredBucket(); manualBucket = false }.keyboardShortcut(.defaultAction)
                        .disabled(bucketText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 430)
        }
        .sheet(item: $copying) { item in
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: "在存储桶内复制", subtitle: item.key)
                TextField("目标对象键", text: $copyKey).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("取消") { copying = nil }.keyboardShortcut(.cancelAction)
                    Button("复制") {
                        let target = copyKey
                        copying = nil
                        confirmation = Prompt(title: "复制对象？", message: "如果目标对象已存在，S3 将按存储桶的版本设置处理覆盖。") {
                            model.copyObject(item, to: target)
                        }
                    }.keyboardShortcut(.defaultAction).disabled(copyKey.isEmpty || copyKey == item.key)
                }
            }.padding(25).frame(width: 470)
        }
        .alert(item: $confirmation) { prompt in
            let label = Text(prompt.buttonTitle ?? (prompt.destructive ? "确认" : "继续"))
            return Alert(title: Text(prompt.title), message: Text(prompt.message),
                         primaryButton: prompt.destructive ? .destructive(label, action: prompt.action) : .default(label, action: prompt.action),
                         secondaryButton: .cancel(Text("取消")))
        }
        .sheet(item: $notice) { notice in
            VStack(alignment: .leading, spacing: 13) {
                Text(notice.title).font(.title2.bold())
                ScrollView { Text(notice.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 150)
                Button("完成") { self.notice = nil }.keyboardShortcut(.defaultAction)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(23).frame(width: 470)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 3) {
                sidebarHeading("工作区")
                sidebarRow("对象浏览", "tablecells", selected: model.destination == .browse) { model.destination = .browse }
                sidebarRow("API 工作台", "chevron.left.forwardslash.chevron.right", selected: model.destination == .api) { model.destination = .api }
                sidebarRow("传输队列", "arrow.up.arrow.down", selected: model.destination == .transfers,
                           trailing: model.activeTransfers == 0 ? nil : String(model.activeTransfers),
                           showsActivity: model.hasRunningTransfers) { model.destination = .transfers }
                SettingsLink {
                    Label {
                        Text("配置")
                    } icon: {
                        Image(systemName: "gearshape")
                            .frame(width: 17)
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                    .padding(.horizontal, 7)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).help("打开软件配置").accessibilityIdentifier("app-configuration")
            }.padding(.horizontal, 10)
            connectionsPane
            bucketsPane
            if let connection = model.connection {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: model.bucketError == nil ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(model.bucketError == nil ? Color.secondary : Color(nsColor: .systemOrange))
                        Text(connection.region.isEmpty ? connection.auth.title : connection.region).lineLimit(1)
                        Spacer(minLength: 4)
                        Button { edit = ConnectionEdit(value: connection, existing: model.connections.contains(where: { $0.id == connection.id })) } label: {
                            Image(systemName: "gearshape")
                        }.buttonStyle(.borderless).help("连接设置").accessibilityLabel("连接设置")
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 15).frame(height: 36)
                }.background(.bar)
            }
        }
        .padding(.top, 9)
        .background(.regularMaterial)
    }

    private var connectionsPane: some View {
        let rowCount = min(max(model.connections.count, 1), 5)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                sidebarHeading("连接")
                Spacer()
                Button { edit = ConnectionEdit(value: Connection(), existing: false) } label: {
                    Image(systemName: "plus")
                }.buttonStyle(.borderless).help("新建连接").accessibilityLabel("新建连接")
            }.padding(.trailing, 15)
            ScrollView {
                LazyVStack(spacing: 4) {
                    if model.connections.isEmpty {
                        sidebarRow("AWS 默认配置", "person.crop.circle", selected: model.connection?.name == "AWS 默认配置") {
                            var local = Connection()
                            local.name = "AWS 默认配置"
                            model.connect(local)
                        }
                    }
                    ForEach(model.connections) { connection in
                        sidebarRow(connection.name, connection.endpoint.isEmpty ? "cloud" : "server.rack",
                                   selected: connection.id == model.connection?.id) { model.connect(connection) }
                        .contextMenu {
                            Button("编辑连接") { edit = ConnectionEdit(value: connection, existing: true) }
                            if connection.auth == .profile {
                                Button("IAM Identity Center 登录") { login(connection) }
                            }
                            Divider()
                            Button("移除连接", role: .destructive) {
                                confirmation = Prompt(title: "移除连接？", message: connection.name) {
                                    do { try model.removeConnection(connection) }
                                    catch { notice = Notice(title: "无法移除连接", body: error.localizedDescription) }
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 10)
            }
            .frame(height: CGFloat(rowCount * 32 - 4))
            .scrollIndicators(.visible)
            .accessibilityLabel("连接清单")
        }
    }

    private var bucketsPane: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                sidebarHeading("存储桶")
                Spacer()
                if model.busyBuckets { ProgressView().controlSize(.mini) }
                Button(action: showBucketCreation) {
                    Image(systemName: "plus")
                }.buttonStyle(.borderless)
                    .disabled(!model.canCreateBucket)
                    .help(model.connection?.auth == .anonymous ? "匿名连接无法创建存储桶" : "创建存储桶")
                    .accessibilityLabel("创建存储桶")
                    .accessibilityIdentifier("sidebar-create-bucket")
                Menu {
                    Button("刷新存储桶", systemImage: "arrow.clockwise") { model.listBuckets() }
                    Button("按名称或 ARN 打开", systemImage: "arrow.up.right.square") { bucketText = ""; manualBucket = true }
                    Button("创建存储桶", systemImage: "plus", action: showBucketCreation).disabled(!model.canCreateBucket)
                    if let bucket = model.bucket {
                        Divider()
                        Button("删除当前存储桶…", systemImage: "trash", role: .destructive) { showBucketDeletion(bucket) }
                            .disabled(!model.canDelete(bucket))
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(model.connection == nil).help("存储桶操作").accessibilityLabel("存储桶操作")
            }.padding(.trailing, 15)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if let bucket = model.bucket, !model.buckets.contains(where: { $0.id == bucket.id }) { bucketRow(bucket) }
                    ForEach(model.buckets.sorted { $0.Name.localizedStandardCompare($1.Name) == .orderedAscending }) { bucketRow($0) }
                    if model.bucketCursor != nil {
                        Button("加载更多存储桶") { model.listBuckets(more: true) }.buttonStyle(.link).disabled(model.busyBuckets)
                            .padding(7)
                    }
                    if let error = model.bucketError {
                        Button { notice = Notice(title: "无法列出存储桶", body: error) } label: {
                            Label("查看连接错误", systemImage: "exclamationmark.circle").foregroundStyle(Color(nsColor: .systemOrange))
                        }.buttonStyle(.plain).padding(7)
                    }
                }.padding(.horizontal, 10).padding(.bottom, 5)
            }
            .id(model.connection?.id)
            .frame(maxHeight: .infinity)
            .scrollIndicators(.visible)
            .accessibilityLabel("存储桶清单")
        }
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .padding(.leading, 17).accessibilityAddTraits(.isHeader)
    }

    private func sidebarRow(_ title: String, _ symbol: String, selected: Bool, trailing: String? = nil,
                            showsActivity: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 17)
                    .foregroundStyle(selected ? Color.accentColor : Color(nsColor: .secondaryLabelColor))
                Text(title).foregroundStyle(Color(nsColor: .labelColor))
                    .fontWeight(selected ? .semibold : .regular).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if showsActivity { TransferActivityIndicator() }
                if let trailing { Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(Color(nsColor: .secondaryLabelColor)) }
            }.padding(.horizontal, 7).frame(minHeight: 28).contentShape(Rectangle())
                .background(selected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(title).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func bucketRow(_ bucket: Bucket) -> some View {
        sidebarRow(bucket.Name, "shippingbox", selected: model.bucket?.id == bucket.id && model.destination == .browse) { model.openBucket(bucket) }
            .contextMenu {
                Button("删除存储桶…", systemImage: "trash", role: .destructive) { showBucketDeletion(bucket) }
                    .disabled(!model.canDelete(bucket))
            }
    }

    @ViewBuilder private var browser: some View {
        if let bucket = model.bucket {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    SectionHeading(title: bucket.Name, subtitle: bucket.BucketRegion ?? model.currentConnection.flatMap { $0.region.isEmpty ? nil : $0.region } ?? "Amazon S3")
                    Spacer(minLength: 12)
                    if model.busy { ProgressView().controlSize(.small).accessibilityLabel("正在加载对象") }
                    Menu {
                        Button("删除所选对象", systemImage: "trash", role: .destructive) { confirmDelete(model.selection) }
                            .disabled(!model.canWrite || model.selection.isEmpty || model.selection.contains(where: { $0.kind == .folder }))
                        Menu("同步", systemImage: "arrow.triangle.2.circlepath") {
                            Button("本地文件夹 → S3") { sync(upload: true) }.disabled(!model.canWrite)
                            Button("S3 → 本地文件夹") { sync(upload: false) }
                        }
                    } label: { Label("对象操作", systemImage: "ellipsis.circle") }.fixedSize()
                    Menu {
                        Button("版本控制") { model.shortcut("get-bucket-versioning") }
                        Button("生命周期") { model.shortcut("get-bucket-lifecycle-configuration") }
                        Button("存储桶策略") { model.shortcut("get-bucket-policy") }
                        Button("默认加密") { model.shortcut("get-bucket-encryption") }
                        Button("阻止公开访问") { model.shortcut("get-public-access-block") }
                        Button("跨区域复制") { model.shortcut("get-bucket-replication") }
                        Button("对象锁定") { model.shortcut("get-object-lock-configuration") }
                        Button("CORS") { model.shortcut("get-bucket-cors") }
                        Button("存储桶标签") { model.shortcut("get-bucket-tagging") }
                        Divider()
                        Button("删除存储桶…", systemImage: "trash", role: .destructive) { showBucketDeletion(bucket) }
                            .disabled(!model.canDelete(bucket))
                    } label: { Label("存储桶设置", systemImage: "slider.horizontal.3") }.fixedSize()
                }.padding(.horizontal, 20).padding(.top, 15).padding(.bottom, 13)
                HStack(spacing: 10) {
                    Button {
                        model.go(ObjectPath.levels(in: model.prefix).dropLast().last?.prefix ?? "")
                    } label: { Image(systemName: "arrow.up") }.disabled(model.prefix.isEmpty).help("上一级")
                    Button { model.list() } label: { Image(systemName: "arrow.clockwise") }.keyboardShortcut("r", modifiers: .command).help("刷新")
                    PathBar(prefix: model.prefix, navigate: openPath)
                        .id("\(model.connection?.id.uuidString ?? "")/\(bucket.id)")
                    FilterField("筛选已加载对象", text: $model.search).frame(width: 170)
                    Toggle("版本", isOn: Binding(get: { model.versions }, set: { model.setVersions($0) })).toggleStyle(.checkbox)
                }.padding(.horizontal, 20).padding(.bottom, 11)
                Divider()
                if let error = model.error {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        ScrollView { Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 84)
                        Button("重试") { model.list(more: model.hasMoreObjects && !model.needsListingRefresh) }.disabled(model.busy)
                    }.padding(12)
                    Divider()
                }
                VSplitView {
                    Table(model.visibleItems, selection: $model.selected) {
                        TableColumn("名称") { item in
                            Label {
                                Text(display(item)).lineLimit(1).truncationMode(.middle)
                            } icon: { Image(systemName: item.icon).foregroundStyle(item.kind == .folder ? Color.accentColor : Color.secondary) }
                        }.width(min: 160, ideal: 310)
                        TableColumn("大小") { item in
                            Text(item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }.width(min: 70, ideal: 85)
                        TableColumn("存储类别") { item in Text(item.storage ?? "—").foregroundStyle(.secondary).lineLimit(1) }.width(min: 85, ideal: 110)
                        TableColumn("更新时间") { item in
                            Text(item.date.map { String($0.prefix(19)).replacingOccurrences(of: "T", with: " ") + " UTC" } ?? "—")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        }.width(min: 130, ideal: 150)
                    }.contextMenu(forSelectionType: String.self) { selected in
                        let items = model.selectedItems(selected)
                        if let item = items.first, items.count == 1 {
                            if item.kind == .folder { Button("打开文件夹") { model.go(item.key) } }
                            if item.kind != .deleteMarker {
                                Button("下载到…") { download(item) }
                            }
                            if item.kind == .object || item.kind == .version {
                                Button("对象属性") { openInspector(.properties, item: item) }
                                Button("对象标签") { openInspector(.tags, item: item) }
                                Button("对象 ACL") { openInspector(.permissions, item: item) }
                                Button("预览") { openInspector(.preview, item: item) }
                                Button("恢复归档对象") { itemAPI("restore-object", item) }.disabled(!model.canWrite)
                                if item.kind == .object {
                                    Button("复制到同一存储桶…") { copyKey = item.key; copying = item }.disabled(!model.canWrite)
                                    Button("复制预签名下载链接") { presign(item) }.disabled(!model.canWrite)
                                }
                            }
                            Button("复制对象键") { copy(item.key) }
                            if let version = item.version { Button("复制版本 ID") { copy(version) } }
                            Button("复制 S3 URI") { copy(Engine.s3URI(bucket.Name, item.key)) }
                        }
                        if model.canWrite && !items.isEmpty && items.allSatisfy({ $0.kind != .folder }) {
                            Divider()
                            Button("删除", role: .destructive) { confirmDelete(items) }
                        }
                    } primaryAction: { selected in
                        guard selected.count == 1, let item = model.selectedItems(selected).first else { return }
                        if item.kind == .folder { model.go(item.key) }
                        else { openInspector(.properties, item: item) }
                    }
                    .overlay {
                        if model.visibleItems.isEmpty && !model.busy && model.error == nil {
                            ContentUnavailableView(model.search.isEmpty ? "此处没有对象" : "没有匹配的对象",
                                                   systemImage: model.search.isEmpty ? "tray" : "magnifyingglass")
                                .controlSize(.small).allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 110)
                    if showInspector, let connection = model.currentConnection {
                        let selected = model.selection
                        let target = InspectorTarget(connectionID: connection.id, bucket: bucket,
                                                     item: selected.count == 1 ? selected.first : nil, prefix: model.prefix)
                        InspectorPane(model: model, target: target, tab: $inspectorTab, requestedTarget: $inspectorRequest, download: download)
                            .frame(minHeight: 130, idealHeight: 253)
                    }
                }
                Divider()
                HStack {
                    Text(model.search.isEmpty ? "已加载 \(model.items.count) 项" : "已加载的 \(model.items.count) 项中匹配 \(model.visibleItems.count) 项")
                    if !model.selection.isEmpty { Text("· 已选 \(model.selection.count) 项") }
                    Spacer()
                    if model.needsListingRefresh {
                        Button("清单有更新 · 刷新") { model.list() }.disabled(model.busy)
                    } else if model.hasMoreObjects {
                        Button("加载下一页") { model.list(more: true) }.disabled(model.busy)
                    }
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).frame(height: 35)
                    .background(.bar)
            }.dropDestination(for: URL.self) { urls, _ in
                guard model.canWrite, urls.contains(where: \.isFileURL) else { return false }
                model.upload(urls)
                return true
            } isTargeted: { dropTarget = $0 && model.canWrite }
            .overlay { if dropTarget { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor, lineWidth: 3).allowsHitTesting(false) } }
        } else {
            ContentUnavailableView {
                if model.connection == nil {
                    VStack(spacing: 12) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit()
                            .frame(width: 72, height: 72).accessibilityHidden(true)
                        Text("连接到对象存储")
                    }
                } else {
                    Label("打开存储桶", systemImage: "shippingbox")
                }
            } description: {
                Text(model.connection == nil ? "添加 Amazon S3 或兼容端点。" : "在侧栏选择存储桶，或直接输入名称或 ARN。")
            } actions: {
                if model.connection == nil {
                    Button("新建连接") { edit = ConnectionEdit(value: Connection(), existing: false) }.buttonStyle(.borderedProminent)
                } else {
                    HStack {
                        TextField("存储桶名称或访问点 ARN", text: $bucketText).textFieldStyle(.roundedBorder).frame(width: 280)
                            .onSubmit { openEnteredBucket() }
                        Button("打开") { openEnteredBucket() }.buttonStyle(.borderedProminent)
                    }
                    if model.canWrite {
                        Button("创建存储桶", action: showBucketCreation).disabled(!model.canCreateBucket)
                    } else {
                        Text("匿名连接可浏览有访问权限的存储桶。创建存储桶需要登录。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.bucketError {
                        Button("查看存储桶列表错误") { notice = Notice(title: "无法列出存储桶", body: error) }.buttonStyle(.link)
                    }
                }
            }
        }
    }

    private func display(_ item: S3Item) -> String {
        let name = item.key.hasPrefix(model.prefix) ? String(item.key.dropFirst(model.prefix.count)) : item.key
        if item.kind == .deleteMarker { return "\(name) · 删除标记" }
        if item.kind == .version { return "\(name) · \(item.latest == true ? "当前版本" : "历史版本")" }
        return name.isEmpty ? item.key : name
    }

    private func openEnteredBucket() {
        let name = bucketText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        model.openBucket(Bucket(Name: name))
        bucketText = ""
    }

    private func showBucketCreation() {
        guard model.canCreateBucket, let connection = model.connection else { return }
        model.resetBucketCreation()
        createBucketConnection = connection
    }

    private func showBucketDeletion(_ bucket: Bucket) {
        bucketDeletion = model.bucketDeletionRequest(for: bucket)
    }

    private func openPath(_ path: ObjectPath) {
        if let name = path.bucket, name != model.bucket?.Name {
            let destination = model.buckets.first { $0.Name == name } ?? Bucket(Name: name)
            model.openBucket(destination, prefix: path.prefix)
        } else {
            model.go(path.prefix)
        }
    }

    private func sync(upload: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = !upload
        panel.prompt = "选择文件夹"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            confirmation = Prompt(title: upload ? "同步到 S3？" : "同步到本地？",
                                  message: "同步会新增或更新目标端的文件。", action: { model.sync(url, upload: upload) }, destructive: false)
        }
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "上传"
        panel.begin { result in if result == .OK { model.upload(panel.urls) } }
    }

    private func download(_ item: S3Item) {
        let key = item.key
        let name = key.split(separator: "/").last.map(String.init) ?? "S3 对象"
        if item.kind == .folder {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "下载到此文件夹"
            panel.begin { result in if result == .OK, let url = panel.url { model.download(item, to: url) } }
        } else {
            chooseSave(name: name) { model.download(item, to: $0) }
        }
    }

    private func confirmDelete(_ items: [S3Item]) {
        confirmation = Prompt(title: "删除 \(items.count) 项？",
                              message: model.versions ? "所选历史版本或删除标记将从 S3 移除。" : "S3 将根据存储桶的版本控制设置处理删除。") { model.delete(items) }
    }

    private func itemAPI(_ command: String, _ item: S3Item) {
        var fields = ["Key": item.key]
        if let version = item.version { fields["VersionId"] = version }
        model.shortcut(command, fields: fields)
    }

    private func openInspector(_ tab: InspectorTab, item: S3Item) {
        model.selected = [item.id]
        inspectorTab = tab
        if tab.needsRequest, tab.cacheKinds.isEmpty, let bucket = model.bucket, let connection = model.currentConnection {
            inspectorRequest = InspectorTarget(connectionID: connection.id, bucket: bucket, item: item, prefix: model.prefix)
        } else {
            inspectorRequest = nil
        }
        showInspector = true
    }

    private func login(_ connection: Connection) {
        guard !accessing else { return }
        accessing = true
        Task {
            defer { accessing = false }
            do {
                _ = try await Engine.run(["sso", "login"], connection: connection, endpointOverride: false)
                if model.connection?.id == connection.id { model.connect(connection) }
                notice = Notice(title: "IAM Identity Center", body: "登录完成。")
            } catch { notice = Notice(title: "登录失败", body: error.localizedDescription) }
        }
    }

    private func presign(_ item: S3Item) {
        guard let bucket = model.bucket, let connection = model.currentConnection else { return }
        Task {
            do {
                let data = try await Engine.run(["s3", "presign", Engine.s3URI(bucket.Name, item.key), "--expires-in=3600"], connection: connection)
                copy(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                notice = Notice(title: "已复制下载链接", body: "签名有效期为 1 小时，临时凭证提前过期时链接也会失效。")
            } catch { notice = Notice(title: "无法创建下载链接", body: error.localizedDescription) }
        }
    }
}

private struct SectionHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

private struct FilterField: View {
    let title: String
    @Binding var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(title, text: $text).textFieldStyle(.plain).accessibilityLabel(title)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("清除筛选")
            }
        }
        .padding(.horizontal, 7).frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)).allowsHitTesting(false) }
    }
}

private struct ConnectionEditor: View {
    @ObservedObject var model: Workspace
    @Environment(\.dismiss) private var dismiss
    @State var draft: Connection
    let existing: Bool
    @State private var credentials = Credentials()
    @State private var feedback = ""
    @State private var profiles: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            SectionHeading(title: existing ? "编辑连接" : "新建连接", subtitle: "Amazon S3 和兼容对象存储")
            Form {
                TextField("连接名称", text: $draft.name)
                Picker("身份验证", selection: $draft.auth) {
                    ForEach(Connection.Auth.allCases) { auth in Text(auth.title).tag(auth) }
                }
                if draft.auth == .profile {
                    LabeledContent("AWS Profile") {
                        HStack {
                            TextField("默认配置或 Profile 名称", text: $draft.profile)
                            if !profiles.isEmpty {
                                Menu { ForEach(profiles, id: \.self) { profile in Button(profile) { draft.profile = profile } } }
                                label: { Image(systemName: "person.crop.circle") }.menuStyle(.borderlessButton).fixedSize()
                            }
                        }
                    }
                }
                if draft.auth == .keys {
                    TextField("Access Key ID", text: $credentials.access)
                    SecureField("Secret Access Key", text: $credentials.secret)
                    SecureField("Session Token（可选）", text: $credentials.token)
                }
                TextField("区域", text: $draft.region, prompt: Text("沿用 AWS 配置，例如 us-east-1"))
                TextField("自定义端点", text: $draft.endpoint, prompt: Text("可选，https://…"))
                    .onChange(of: draft.endpoint) { oldValue, newValue in
                        if oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            != newValue.trimmingCharacters(in: .whitespacesAndNewlines) {
                            draft.skipTLSVerification = nil
                        }
                    }
                TextField("首选存储桶 / ARN", text: $draft.bucket, prompt: Text("可选，直接进入该存储桶"))
                LabeledContent("自定义 CA") {
                    HStack {
                        Text(draft.caBundle.isEmpty ? "沿用系统配置" : URL(fileURLWithPath: draft.caBundle).lastPathComponent).lineLimit(1).foregroundStyle(.secondary)
                        Button("选择…") { chooseOpen { draft.caBundle = $0.path } }
                        if !draft.caBundle.isEmpty { Button("清除") { draft.caBundle = "" } }
                    }
                }
                .disabled(draft.hasHTTPSOverride && draft.skipTLSVerification == true)
                Toggle("忽略 TLS 证书验证", isOn: Binding(
                    get: { draft.hasHTTPSOverride && draft.skipTLSVerification == true },
                    set: { draft.skipTLSVerification = $0 }
                ))
                .disabled(!draft.hasHTTPSOverride)
                .help("仅适用于此连接的自定义 HTTPS 端点")
                if draft.hasHTTPSOverride && draft.skipTLSVerification == true {
                    Text("连接仍会加密，但无法验证服务器身份。请仅用于可信测试环境。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle("强制使用路径式地址", isOn: $draft.pathStyle)
                Toggle("Requester Pays（由请求方付费）", isOn: $draft.requesterPays)
            }.textFieldStyle(.roundedBorder)
            if !feedback.isEmpty { Text(feedback).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并连接") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(25).frame(width: 540)
            .task {
                if existing && draft.auth == .keys {
                    do { credentials = try Keychain.read(draft.id) }
                    catch { feedback = error.localizedDescription }
                }
                if let result = try? await Engine.run(["configure", "list-profiles"]) {
                    profiles = String(decoding: result, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
                }
            }
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.region = draft.region.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.profile = draft.profile.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.endpoint = draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.bucket = draft.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        credentials.access = credentials.access.trimmingCharacters(in: .whitespacesAndNewlines)
        credentials.secret = credentials.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        credentials.token = credentials.token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard !draft.name.isEmpty else { throw ShelfError("请输入连接名称。") }
            if !draft.endpoint.isEmpty && draft.endpointURL == nil {
                throw ShelfError("请输入有效的 HTTP 或 HTTPS 端点。")
            }
            if !draft.hasHTTPSOverride { draft.skipTLSVerification = nil }
            if draft.auth == .keys && (credentials.access.isEmpty || credentials.secret.isEmpty) {
                throw ShelfError("请输入 Access Key ID 和 Secret Access Key。")
            }
            try model.save(draft, credentials: draft.auth == .keys ? credentials : nil)
            dismiss()
        } catch { feedback = error.localizedDescription }
    }
}

private struct APIView: View {
    @ObservedObject var model: Workspace
    let confirm: (Prompt) -> Void
    let showBucketCreation: () -> Void
    let showBucketDeletion: (BucketDeletionRequest) -> Void
    @State private var service = "s3api"
    @State private var filter = ""

    private let services = ["s3api", "s3control", "s3files", "s3outposts", "s3tables", "s3vectors"]
    private var results: [Operation] {
        model.operations.filter { operation in
            filter.isEmpty ? operation.service == service : operation.id.localizedStandardContains(filter)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                SectionHeading(title: "API 工作台", subtitle: model.connection?.name ?? "先从侧边栏选择连接")
                Spacer()
                Text("\(model.operations.count) 项 AWS CLI 命令").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 15)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 9) {
                    Picker("服务", selection: $service) { ForEach(services, id: \.self) { Text($0).tag($0) } }.labelsHidden()
                    FilterField("搜索全部命令", text: $filter)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(results) { operation in
                                Button { model.fill(operation) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(operation.name).font(.system(.caption, design: .monospaced)).lineLimit(2)
                                        if !filter.isEmpty { Text(operation.service).font(.caption2).foregroundStyle(.secondary) }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(7)
                                        .background(model.operation?.id == operation.id ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(model.apiBusy)
                            }
                            if results.isEmpty { Text("没有匹配的命令").font(.caption).foregroundStyle(.secondary).padding(8) }
                        }
                    }
                }.padding(12).frame(width: 226)
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                if let operation = model.operation {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(operation.name).font(.system(.headline, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button("AWS 文档") { openDocumentation(operation) }.buttonStyle(.link)
                        }
                        if !operation.summary.isEmpty { Text(operation.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
                        if operation.createsBucket {
                            HStack {
                                Text("常规创建可在表单中填写存储桶名称和目标位置。")
                                    .font(.callout).foregroundStyle(.secondary)
                                Spacer()
                                Button("打开创建表单", action: showBucketCreation).buttonStyle(.link).disabled(!model.canCreateBucket)
                            }
                        }
                        if model.connection == nil || operation.mutates && !model.canWrite {
                            Text(model.connection == nil ? "请从侧栏选择目标连接后执行。" : "匿名连接无法执行写入操作。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("请求 JSON").font(.subheadline.weight(.semibold))
                            Spacer()
                            if !operation.fields.isEmpty {
                                Menu("插入参数") {
                                    let groups = stride(from: 0, to: operation.fields.count, by: 17).map { Array(operation.fields[$0..<min($0 + 17, operation.fields.count)]) }
                                    ForEach(groups, id: \.self) { fields in
                                        if groups.count == 1 { fieldButtons(fields, operation) }
                                        else if let first = fields.first, let last = fields.last { Menu("\(first) … \(last)") { fieldButtons(fields, operation) } }
                                    }
                                }.fixedSize().disabled(model.apiBusy)
                            }
                        }
                        JSONRequestEditor(text: $model.parameters)
                            .padding(6)
                            .frame(minHeight: 85).modifier(CodeSurface()).disabled(model.apiBusy)
                        if let requestError = model.apiRequestError {
                            Label(requestError, systemImage: "exclamationmark.circle")
                                .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                        }
                        if !operation.required.isEmpty {
                            Text("必填  " + operation.required.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if operation.fileInput != nil || operation.fileOutput {
                            HStack {
                                if let field = operation.fileInput {
                                    Button { chooseOpen { model.inputFile = $0 } } label: { Label(model.inputFile?.lastPathComponent ?? "选择 \(field) 文件", systemImage: "doc.badge.plus") }
                                    if model.inputFile != nil { Button("清除") { model.inputFile = nil }.buttonStyle(.link) }
                                }
                                if operation.fileOutput {
                                    Button { chooseSave(name: "S3 输出") { model.outputFile = $0 } } label: { Label(model.outputFile?.lastPathComponent ?? "选择输出文件", systemImage: "square.and.arrow.down") }
                                }
                            }.disabled(model.apiBusy)
                        }
                        HStack {
                            Text("响应").font(.subheadline.weight(.semibold))
                            if model.apiBusy { ProgressView().controlSize(.small) }
                            Spacer()
                            if model.apiBusy { Button("停止等待") { model.cancelAPI() } }
                            Button("复制") { copy(model.apiResult) }.disabled(model.apiResult.isEmpty || model.apiBusy)
                            Button(operation.deletesBucket ? "确认删除…" : "执行") { execute(operation) }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.apiBusy || model.bucketDeletionRunning || model.connection == nil ||
                                          operation.mutates && !model.canWrite || operation.createsBucket && !model.canCreateBucket ||
                                          operation.deletesBucket && !model.canDeleteBucket)
                        }
                        HStack {
                            Toggle("自动分页", isOn: $model.apiPaginate).toggleStyle(.checkbox)
                            TextField("可选 JMESPath 查询", text: $model.apiQuery).textFieldStyle(.roundedBorder)
                        }.disabled(model.apiBusy)
                        ScrollView {
                            Text(model.apiResult.isEmpty ? "执行后显示响应。" : model.apiResult)
                                .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }.frame(minHeight: 78).modifier(CodeSurface())
                    }.padding(18)
                } else {
                    ContentUnavailableView("选择 AWS 操作", systemImage: "terminal",
                                           description: Text("按服务浏览，或搜索命令。"))
                }
            }
        }
        .onAppear { if let operation = model.operation { service = operation.service } }
        .onChange(of: model.operation?.id) { _, _ in if let operation = model.operation { service = operation.service } }
    }

    private func execute(_ operation: Operation) {
        if operation.deletesBucket {
            if let request = model.workbenchBucketDeletionRequest() { showBucketDeletion(request) }
            return
        }
        guard let connection = model.connection, let request = model.validatedAPIRequest() else { return }
        if operation.createsBucket, let name = request["Bucket"] as? String {
            confirm(Prompt(title: "创建存储桶「\(name)」？", message: "目标连接「\(connection.name)」。",
                           action: model.execute, destructive: false, buttonTitle: "创建"))
        } else if operation.mutates {
            confirm(Prompt(title: "执行 \(operation.name)？",
                           message: "此操作可能修改「\(connection.name)」中的资源。请核对请求参数。", action: model.execute))
        } else { model.execute() }
    }

    private func openDocumentation(_ operation: Operation) {
        let path = operation.name.replacingOccurrences(of: " ", with: "/")
        if let url = URL(string: "https://docs.aws.amazon.com/cli/latest/reference/\(operation.service)/\(path).html") {
            NSWorkspace.shared.open(url)
        }
    }

    private func fieldButtons(_ fields: [String], _ operation: Operation) -> some View {
        ForEach(fields, id: \.self) { field in
            Button(field) {
                guard let parsed = try? JSONSerialization.jsonObject(with: Data(model.parameters.utf8)),
                      var input = parsed as? [String: Any], input[field] == nil else { return }
                input[field] = model.defaultValue(for: field, in: operation)
                model.parameters = Workspace.pretty(input)
            }
        }
    }
}

private struct CodeSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)).allowsHitTesting(false) }
    }
}

struct TransfersView: View {
    @ObservedObject var model: Workspace
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !compact {
                SectionHeading(title: "传输队列", subtitle: "\(model.activeTransfers) 项进行中 · 最多同时运行 3 项任务")
                    .padding(.horizontal, 20).padding(.vertical, 15)
                Divider()
            }
            if model.transfers.isEmpty {
                if compact {
                    Text("暂无传输任务").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("暂无传输任务", systemImage: "arrow.up.arrow.down",
                                           description: Text("上传和下载进度会显示在这里。"))
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.transfers) { transfer in
                            HStack(spacing: 14) {
                                Image(systemName: transfer.title.hasPrefix("上传") ? "arrow.up.circle" : "arrow.down.circle")
                                    .font(.title2).foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(transfer.title).font(.headline).lineLimit(1).truncationMode(.middle)
                                    if !transfer.detail.isEmpty {
                                        Text(transfer.detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                            .lineLimit(4)
                                    }
                                }
                                Spacer(minLength: 8)
                                HStack(spacing: 6) {
                                    if transfer.status == .running { TransferActivityIndicator() }
                                    Text(transfer.status.rawValue).font(.callout).foregroundStyle(transfer.status == .failed ? Color.red : .secondary)
                                }
                                if transfer.status == .running || transfer.status == .queued {
                                    Button("取消") { model.cancel(transfer.id) }
                                }
                                if transfer.status == .failed || transfer.status == .cancelled {
                                    Button("重试") { model.retry(transfer.id) }
                                }
                            }.padding(.vertical, 10)
                            Divider()
                        }
                    }.padding(.horizontal, compact ? 17 : 20)
                }
            }
        }
    }
}

private struct TransferActivityIndicator: View {
    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.mini)
            .accessibilityLabel("传输中")
    }
}

@MainActor func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

@MainActor private func chooseOpen(_ selection: @escaping (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.begin { result in if result == .OK, let url = panel.url { selection(url) } }
}

@MainActor private func chooseSave(name: String, _ selection: @escaping (URL) -> Void) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = name
    panel.canCreateDirectories = true
    panel.begin { result in if result == .OK, let url = panel.url { selection(url) } }
}
