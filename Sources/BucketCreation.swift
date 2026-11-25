import AppKit
import SwiftUI

struct BucketCreationFeedback {
    enum Phase { case creating, checking, created, available, failed, uncertain }

    let phase: Phase
    let title: String
    var message = ""
    var details = ""
    var verificationDetails = ""
    var bucket: Bucket?
    var cursor: String?

    var isRunning: Bool { phase == .creating || phase == .checking }

    var technicalDetails: String {
        [details, verificationDetails].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var text: String {
        [title, message, technicalDetails].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

struct BucketCreationSheet: View {
    @ObservedObject var model: Workspace
    let connection: Connection
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name = ""
    @State private var region: String
    @State private var attempted = false
    @State private var stopping = false

    init(model: Workspace, connection: Connection) {
        self.model = model
        self.connection = connection
        _region = State(initialValue: connection.region)
    }

    private var feedback: BucketCreationFeedback? { model.bucketCreationFeedback }
    private var running: Bool { feedback?.isRunning == true }
    private var showsFields: Bool { feedback == nil || feedback?.phase == .failed }
    private var activeConnection: Bool { model.connection == connection }
    private var nameError: String? {
        attempted ? Workspace.bucketNameError(name, aws: connection.endpoint.isEmpty) : nil
    }
    private var regionError: String? {
        attempted && connection.endpoint.isEmpty ? Workspace.bucketRegionError(region) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("创建存储桶", systemImage: "shippingbox")
                .font(.title2.bold()).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 5) {
                LabeledContent("目标连接", value: connection.name)
                LabeledContent("端点", value: connection.endpoint.isEmpty ? "Amazon S3" : connection.endpoint)
                    .textSelection(.enabled)
            }.foregroundStyle(.secondary)
            Divider()
            if showsFields { fields }
            if let feedback { result(feedback) }
            if !activeConnection {
                Text("当前连接已变更。请关闭窗口后在目标连接上打开创建表单。").font(.callout).foregroundStyle(.orange)
            }
            Divider()
            HStack {
                Spacer()
                if running {
                    Button(stopping ? "正在停止…" : "停止等待") {
                        stopping = true
                        model.cancelBucketCreation()
                    }.keyboardShortcut(.cancelAction).disabled(stopping)
                } else if let bucket = feedback?.bucket {
                    Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("打开存储桶") {
                        if activeConnection {
                            model.openBucket(bucket)
                            dismiss()
                        }
                    }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!activeConnection)
                } else if let feedback, feedback.phase == .uncertain {
                    Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(feedback.cursor == nil ? "重新核对" : "核对下一页") {
                        stopping = false
                        model.recheckBucketCreation(name, connection: connection)
                    }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!activeConnection)
                } else {
                    Button(feedback == nil ? "取消" : "关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("创建存储桶", action: submit)
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .disabled(!activeConnection || !model.canCreateBucket)
                }
            }
        }
        .padding(24).frame(width: 480)
        .interactiveDismissDisabled(running)
        .onAppear { nameFocused = true }
        .onChange(of: name) { _, _ in model.clearBucketCreationFailure() }
        .onChange(of: region) { _, _ in model.clearBucketCreationFailure() }
        .accessibilityIdentifier("bucket-create-sheet")
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("存储桶名称").font(.callout.weight(.medium))
                TextField("例如 project-archive", text: $name)
                    .textFieldStyle(.roundedBorder).focused($nameFocused)
                    .accessibilityLabel("存储桶名称").accessibilityIdentifier("bucket-create-name")
                Text(nameError ?? "3–63 个字符，使用小写字母、数字、连字符或英文句点。")
                    .font(.caption).foregroundStyle(nameError == nil ? Color.secondary : Color.orange)
            }
            if connection.endpoint.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("AWS 区域").font(.callout.weight(.medium))
                    TextField("自动选择", text: $region).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("AWS 区域").accessibilityIdentifier("bucket-create-region")
                    Text(regionError ?? "留空时优先使用连接的 AWS 区域设置，缺省使用 us-east-1。")
                        .font(.caption).foregroundStyle(regionError == nil ? Color.secondary : Color.orange)
                }
            } else {
                Text("使用兼容端点的默认存储位置。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func result(_ feedback: BucketCreationFeedback) -> some View {
        HStack(alignment: .top, spacing: 9) {
            if feedback.isRunning {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            } else {
                Image(systemName: feedback.bucket == nil ? "exclamationmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(feedback.bucket == nil ? Color.orange : Color.green)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(feedback.title).font(.headline).accessibilityIdentifier("bucket-create-status")
                if !feedback.message.isEmpty {
                    Text(feedback.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !feedback.isRunning, !feedback.technicalDetails.isEmpty {
                    DisclosureGroup("技术详情") {
                        ScrollView {
                            Text(feedback.technicalDetails).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 76)
                        Button("复制详情") { copy(feedback.technicalDetails) }.buttonStyle(.link)
                    }.font(.callout)
                }
            }
            Spacer(minLength: 0)
        }.padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func submit() {
        attempted = true
        guard nameError == nil else { nameFocused = true; return }
        guard regionError == nil else { return }
        stopping = false
        model.createBucket(name, awsRegion: region, connection: connection)
    }
}
