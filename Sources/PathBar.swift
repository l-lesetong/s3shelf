import AppKit
import SwiftUI

struct ObjectPath {
    struct Level: Identifiable {
        let id: Int
        let name: String
        let prefix: String
    }

    let bucket: String?
    let prefix: String

    static func parse(_ text: String) throws -> Self {
        if text.hasPrefix("s3://") {
            let address = String(text.dropFirst(5))
            let bucketEnd: String.Index
            if address.hasPrefix("arn:") {
                let pattern = #"^arn:[^:]+:(s3|s3-object-lambda|s3-outposts):[^:]*:[^:]+:(accesspoint/[^/]+|outpost/[^/]+/accesspoint/[^/]+)"#
                guard let arn = address.range(of: pattern, options: .regularExpression) else {
                    throw ShelfError("请输入有效的存储桶或访问点 S3 URI。")
                }
                bucketEnd = arn.upperBound
            } else {
                bucketEnd = address.utf8.firstIndex(of: 47) ?? address.endIndex
            }
            let bucket = String(address[..<bucketEnd])
            guard !bucket.isEmpty, !bucket.contains(where: \.isWhitespace) else { throw ShelfError("请输入 S3 URI 中的存储桶名称。") }
            let prefix = bucketEnd == address.endIndex ? "" : String(decoding: address.utf8.dropFirst(
                address.utf8.distance(from: address.utf8.startIndex, to: bucketEnd) + 1
            ), as: UTF8.self)
            return Self(bucket: bucket, prefix: folderPrefix(prefix))
        }
        guard text.utf8.first == 47 else { return Self(bucket: nil, prefix: text) }
        return Self(bucket: nil, prefix: folderPrefix(String(decoding: text.utf8.dropFirst(), as: UTF8.self)))
    }

    private static func folderPrefix(_ prefix: String) -> String {
        prefix.isEmpty || prefix.utf8.last == 47 ? prefix : prefix + "/"
    }

    static func levels(in prefix: String) -> [Level] {
        let bytes = prefix.utf8
        var start = bytes.startIndex
        var levels: [Level] = []
        for index in bytes.indices where bytes[index] == 47 {
            let end = bytes.index(after: index)
            levels.append(Level(id: levels.count, name: String(decoding: bytes[start..<index], as: UTF8.self),
                                prefix: String(decoding: bytes[..<end], as: UTF8.self)))
            start = end
        }
        if start != bytes.endIndex {
            levels.append(Level(id: levels.count, name: String(decoding: bytes[start...], as: UTF8.self), prefix: prefix))
        }
        return levels
    }
}

struct PathBar: View {
    let prefix: String
    let navigate: (ObjectPath) -> Void
    @State private var editing = false
    @State private var draft = ""
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if editing {
                    HStack(spacing: 5) {
                        PathInput(text: $draft, submit: submit, cancel: stopEditing)
                            .frame(maxWidth: .infinity, minHeight: 26)
                        Button { submit(draft) } label: { Image(systemName: "arrow.turn.down.left") }
                            .buttonStyle(.borderless).padding(.trailing, 7).help("跳转到路径").accessibilityLabel("跳转到路径")
                    }
                } else {
                    HStack(spacing: 0) {
                        let levels = ObjectPath.levels(in: prefix)
                        ViewThatFits(in: .horizontal) {
                            breadcrumb(levels).fixedSize(horizontal: true, vertical: false)
                            breadcrumb(levels, compact: true)
                        }
                        .layoutPriority(1)
                        Button(action: beginEditing) {
                            HStack {
                                Spacer(minLength: 5)
                                Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                            }.padding(.trailing, 8).frame(minWidth: 34, maxWidth: .infinity, minHeight: 26).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).keyboardShortcut("l", modifiers: .command)
                        .accessibilityLabel("编辑路径").help("编辑路径（⌘L）")
                    }
                    .padding(.leading, 4)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
        }
        .onChange(of: prefix) { _, _ in stopEditing() }
    }

    private func breadcrumb(_ levels: [ObjectPath.Level], compact: Bool = false) -> some View {
        HStack(spacing: 3) {
            Button {
                if prefix.isEmpty { beginEditing() } else { navigate(ObjectPath(bucket: nil, prefix: "")) }
            } label: {
                Image(systemName: "folder").padding(.horizontal, 5).frame(height: 23).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help("存储桶根路径").accessibilityLabel("存储桶根路径")
            if compact, levels.count > 1 {
                separator
                Menu {
                    ForEach(levels.dropLast()) { level in
                        Button(level.prefix) { navigate(ObjectPath(bucket: nil, prefix: level.prefix)) }
                    }
                } label: { Image(systemName: "ellipsis").padding(.horizontal, 2) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("上级路径").accessibilityLabel("上级路径")
            }
            ForEach(compact ? Array(levels.suffix(1)) : levels) { level in
                separator
                let current = level.id == levels.last?.id
                Button {
                    if current { beginEditing() } else { navigate(ObjectPath(bucket: nil, prefix: level.prefix)) }
                } label: {
                    Text(level.name.isEmpty ? "/" : level.name)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle).padding(.horizontal, 3).frame(height: 23).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(current ? Color.primary : Color.secondary)
                .help(current ? "编辑当前路径" : "前往 /\(level.prefix)")
                .accessibilityLabel(current ? "编辑当前路径 /\(level.prefix)" : "前往 /\(level.prefix)")
            }
        }
    }

    private var separator: some View {
        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary).accessibilityHidden(true)
    }

    private func beginEditing() {
        draft = "/" + prefix
        issue = nil
        editing = true
    }

    private func stopEditing() {
        editing = false
        issue = nil
    }

    private func submit(_ value: String) {
        do {
            let address = try ObjectPath.parse(value)
            stopEditing()
            if !value.utf8.elementsEqual(("/" + prefix).utf8) { navigate(address) }
        } catch { issue = error.localizedDescription }
    }
}

private struct PathInput: NSViewRepresentable {
    @Binding var text: String
    let submit: (String) -> Void
    let cancel: () -> Void

    func makeNSView(context: Context) -> AutoSelectingPathField {
        let field = AutoSelectingPathField(string: text)
        field.isEditable = true
        field.isSelectable = true
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.placeholderString = "/目录/ 或 s3://存储桶/目录/"
        field.setAccessibilityLabel("对象路径")
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: AutoSelectingPathField, context: Context) { context.coordinator.input = self }

    func makeCoordinator() -> Coordinator { Coordinator(input: self) }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var input: PathInput
        init(input: PathInput) { self.input = input }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { input.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            if command == #selector(NSResponder.insertNewline(_:)) { input.submit(textView.string); return true }
            if command == #selector(NSResponder.cancelOperation(_:)) { input.cancel(); return true }
            return false
        }
    }
}

private final class AutoSelectingPathField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            self.selectText(nil)
        }
    }
}
