import Foundation
import SwiftUI

struct TransferPreferences: Equatable, Sendable {
    static let defaultPartMiB = 8
    static let partRange = 5...5120
    static let speedRange = 0.01...1_000_000.0

    var limitMiBPerSecond: Double?
    var partMiB = Self.defaultPartMiB

    init(limitMiBPerSecond: Double? = nil, partMiB: Int = Self.defaultPartMiB) {
        self.limitMiBPerSecond = limitMiBPerSecond
        self.partMiB = partMiB
    }

    init(defaults: UserDefaults) {
        let limit = defaults.double(forKey: "transferLimitMiBPerSecond")
        let part = defaults.integer(forKey: "transferPartMiB")
        self.init(limitMiBPerSecond: Self.speedRange.contains(limit) ? limit : nil,
                  partMiB: Self.partRange.contains(part) ? part : Self.defaultPartMiB)
    }

    var bytesPerSecond: Int64? { limitMiBPerSecond.map { Int64($0 * 1_048_576) } }

    func save(to defaults: UserDefaults) {
        defaults.set(limitMiBPerSecond, forKey: "transferLimitMiBPerSecond")
        defaults.set(partMiB, forKey: "transferPartMiB")
    }
}

struct TransferSettings: View {
    @ObservedObject var model: Workspace
    @State private var limit: String
    @State private var part: String
    @State private var error: String?

    init(model: Workspace) {
        self.model = model
        let settings = model.transferPreferences
        _limit = State(initialValue: settings.limitMiBPerSecond.map { String($0) } ?? "")
        _part = State(initialValue: String(settings.partMiB))
    }

    var body: some View {
        Form {
            Section {
                TextField("全局限速（MiB/s）", text: $limit, prompt: Text("不限速"))
                    .accessibilityIdentifier("transfer-global-limit")
                TextField("分片大小（MiB）", text: $part, prompt: Text("8"))
                    .accessibilityIdentifier("transfer-part-size")
            } footer: {
                Text("限速留空为不限速。开启后，队列逐项传输。S3 → S3 可单独指定分片大小，限速取全局和任务设置中较低的一项。设置在下一个任务开始时生效。")
                    .foregroundStyle(.secondary)
            }
            HStack {
                if let error {
                    Text(error).foregroundStyle(.orange).font(.caption)
                }
                Spacer()
                Button("应用", action: apply)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .onSubmit(apply)
        .onChange(of: limit) { _, _ in error = nil }
        .onChange(of: part) { _, _ in error = nil }
    }

    private func apply() {
        let rawLimit = limit.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPart = part.trimmingCharacters(in: .whitespacesAndNewlines)
        let speed = Double(rawLimit)
        if !rawLimit.isEmpty, speed.map(TransferPreferences.speedRange.contains) != true {
            error = "请填写 0.01–1000000 MiB/s，或留空。"
            return
        }
        let size = rawPart.isEmpty ? TransferPreferences.defaultPartMiB : Int(rawPart)
        guard let size, TransferPreferences.partRange.contains(size) else {
            error = "请填写 5–5120 MiB 的整数。"
            return
        }
        model.configureTransfers(.init(limitMiBPerSecond: speed, partMiB: size))
        part = String(size)
        error = nil
    }
}
