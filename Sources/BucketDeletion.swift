import SwiftUI

struct BucketDeletionRequest: Identifiable {
    let id = UUID()
    let connection: Connection
    let target: Connection
    let operation: String
    let arguments: [String]
    let input: Data
    let resource: String
    let name: String
    var accountID: String?
    var fromWorkbench = false

    var isS3Bucket: Bool { operation == "s3api delete-bucket" }

    func matches(_ input: String) -> Bool {
        !name.isEmpty && name.utf8.elementsEqual(input.utf8)
    }
}

struct BucketDeletionFeedback {
    let title: String
    let message: String
    var details = ""
    var removed = false

    var text: String {
        [title, message, details].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

struct BucketDeletionSheet: View {
    @ObservedObject var model: Workspace
    let request: BucketDeletionRequest
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var typedName = ""
    @State private var submitting = false
    @State private var feedback: BucketDeletionFeedback?

    private var matches: Bool { request.matches(typedName) }
    private var activeConnection: Bool { model.connection == request.connection }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("删除存储桶", systemImage: "trash")
                .font(.title2.bold()).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("目标连接", value: request.connection.name)
                LabeledContent("端点", value: request.connection.endpoint.isEmpty ? "Amazon S3" : request.connection.endpoint)
                LabeledContent("存储桶名称", value: request.name).font(.body.monospaced())
                if request.resource != request.name { LabeledContent("资源", value: request.resource) }
                if let accountID = request.accountID { LabeledContent("账号 ID", value: accountID) }
            }.textSelection(.enabled)
            Divider()
            if submitting {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("正在删除「\(request.name)」…").font(.callout)
                }
            } else if let feedback {
                result(feedback)
            } else {
                confirmation
            }
            Divider()
            HStack {
                Spacer()
                if feedback != nil {
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(submitting)
                    Button("永久删除", role: .destructive, action: submit)
                        .buttonStyle(.bordered).tint(.red)
                        .disabled(submitting || !matches || !activeConnection || !model.canDeleteBucket)
                        .accessibilityIdentifier("bucket-delete-confirm")
                }
            }
        }
        .padding(24).frame(width: 480)
        .interactiveDismissDisabled(submitting)
        .onAppear { nameFocused = true }
        .accessibilityIdentifier("bucket-delete-sheet")
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("删除存储桶后无法恢复。", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            if request.isS3Bucket {
                Text("只能删除空桶。请先处理桶内的对象、历史版本和删除标记。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("再次输入完整的存储桶名称").font(.callout.weight(.medium))
            TextField("在此输入桶名", text: $typedName)
                .textFieldStyle(.roundedBorder).monospaced().autocorrectionDisabled()
                .focused($nameFocused).accessibilityLabel("再次输入存储桶名称")
                .accessibilityIdentifier("bucket-delete-name")
            if !activeConnection {
                Text("当前连接已变更。请在目标连接中重新打开删除确认。")
                    .font(.caption).foregroundStyle(.orange)
            } else if !typedName.isEmpty && !matches {
                Text("输入的名称与目标桶名不一致。").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func result(_ feedback: BucketDeletionFeedback) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(feedback.title, systemImage: feedback.removed ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.headline).foregroundStyle(feedback.removed ? Color.primary : Color.orange)
                .accessibilityIdentifier("bucket-delete-status")
            Text(feedback.message).font(.callout).foregroundStyle(.secondary)
            if !feedback.details.isEmpty {
                DisclosureGroup("技术详情") {
                    ScrollView {
                        Text(feedback.details).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 76)
                    Button("复制详情") { copy(feedback.details) }.buttonStyle(.link)
                }.font(.callout)
            }
        }
    }

    private func submit() {
        guard !submitting, matches, activeConnection else { return }
        submitting = true
        let confirmation = typedName
        Task {
            feedback = await model.deleteBucket(request, confirmedName: confirmation)
            if feedback == nil {
                feedback = .init(title: "未提交删除请求", message: "请核对目标连接和操作状态后重新确认。")
            }
            submitting = false
        }
    }
}
