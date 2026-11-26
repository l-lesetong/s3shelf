import Foundation

enum RemoteTransferMode: String, Codable, CaseIterable, Identifiable {
    case copy, sync
    var id: Self { self }
    var title: String { self == .copy ? "Copy 复制" : "Sync 同步" }
}

struct RemoteTransferLocation: Codable, Sendable {
    let connection: Connection
    let bucket: String
    let prefix: String
    var bucketRegion: String? = nil

    var uri: String { Engine.s3URI(bucket, prefix) }
    var display: String { "\(connection.name) · \(uri)" }
    var path: String { prefix.isEmpty ? bucket : "\(bucket)/\(prefix.dropLast())" }

    func overlaps(_ other: Self) -> Bool {
        guard bucket == other.bucket,
              connection.id == other.connection.id || endpointIdentity == other.endpointIdentity else { return false }
        return prefix.utf8.starts(with: other.prefix.utf8) || other.prefix.utf8.starts(with: prefix.utf8)
    }

    private var endpointIdentity: String {
        guard let endpoint = connection.endpointURL, let host = endpoint.host?.lowercased() else { return "aws" }
        if host.hasSuffix(".amazonaws.com") || host.hasSuffix(".amazonaws.com.cn") { return "aws" }
        let port = endpoint.port ?? (endpoint.scheme?.lowercased() == "https" ? 443 : 80)
        let path = endpoint.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(host):\(port)/\(path)"
    }

    static func folder(_ value: String) throws -> String {
        if value.isEmpty { return "" }
        let path = value.hasSuffix("/") ? value.dropLast() : value[...]
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !value.utf8.contains(0),
              segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ShelfError("前缀须使用完整的文件夹层级。请检查开头斜线、连续斜线及 . 或 .. 路径段。")
        }
        return "\(path)/"
    }
}

struct RemoteTransferJob: Codable, Sendable {
    let mode: RemoteTransferMode
    let source: RemoteTransferLocation
    let destination: RemoteTransferLocation
    var metadata = true
    var chunkMiB: Int?
    var bandwidthMiB: Double?

    func validate() throws {
        for location in [source, destination] {
            guard location.bucket.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._-]{0,254}\z"#, options: .regularExpression) != nil else {
                throw ShelfError("请输入存储桶名称。")
            }
            let normalized = try RemoteTransferLocation.folder(location.prefix)
            guard normalized == location.prefix else { throw ShelfError("请输入完整的文件夹前缀。") }
        }
        guard destination.connection.auth != .anonymous else { throw ShelfError("目标连接需要具备写入权限。") }
        guard !source.overlaps(destination) else { throw ShelfError("源和目标路径重叠。请选择另一个存储桶或不重叠的前缀。") }
        if let chunkMiB, !TransferPreferences.partRange.contains(chunkMiB) {
            throw ShelfError("分片大小须为 5–5120 MiB 的整数。")
        }
        if let bandwidthMiB, !TransferPreferences.speedRange.contains(bandwidthMiB) {
            throw ShelfError("限速须为 0.01–1000000 MiB/s。")
        }
    }
}

struct RemoteTransferStats: Codable, Sendable {
    let checks: Int64
    let totalChecks: Int64
    let transfers: Int64
    let totalTransfers: Int64
    let bytes: Int64
    let totalBytes: Int64
    let speed: Double
    let deletes: Int64
    let errors: Int64

    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, Double(bytes) / Double(totalBytes)))
    }

    func summary(running: Bool, syncing: Bool) -> String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .binary)
        var fields = ["对比 \(checks)/\(totalChecks)", "传输 \(transfers)/\(totalTransfers)", "\(size) / \(total)"]
        if running, speed.isFinite, speed > 0, speed < Double(Int64.max) {
            fields.append(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .binary) + "/s")
        }
        if syncing { fields.append("删除 \(deletes)") }
        if errors > 0 { fields.append("错误 \(errors)") }
        return fields.joined(separator: " · ")
    }
}

final class RcloneLog: @unchecked Sendable {
    private struct Entry: Decodable {
        let level: String?
        let msg: String?
        let stats: RemoteTransferStats?
    }

    private let lock = NSLock()
    private var latest: RemoteTransferStats?
    private var error: String?
    var stats: RemoteTransferStats? { lock.withLock { latest } }
    var lastError: String? { lock.withLock { error } }

    func consume(_ text: String) -> RemoteTransferStats? {
        guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(text.utf8)) else { return nil }
        return lock.withLock {
            if let stats = entry.stats { latest = stats; return stats }
            if entry.level == "error" || entry.level == "fatal", let message = entry.msg, !message.isEmpty {
                error = String(message.prefix(2000))
            }
            return nil
        }
    }
}

enum RcloneEngine {
    static func run(_ job: RemoteTransferJob, preferences: TransferPreferences, log: RcloneLog,
                    update: @escaping @Sendable (RemoteTransferStats) -> Void) async throws {
        try job.validate()
        guard let executable = Bundle.main.url(forResource: "rclone", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ShelfError("应用缺少 rclone，请使用完整的 s3Shelf 安装包。")
        }

        let base = Engine.profileEnvironment()
        var environment = base.filter { !$0.key.hasPrefix("RCLONE_") }
        // Application connections own endpoint selection, including when two profiles share an environment.
        environment["AWS_IGNORE_CONFIGURED_ENDPOINT_URLS"] = "true"
        let size = job.chunkMiB ?? preferences.partMiB
        let chunk = "\(size)M"
        let cutoff: String
        if job.chunkMiB != nil { cutoff = chunk }
        else { cutoff = try await uploadThreshold(for: job.destination.connection) }
        let source = try await remote(job.source, alias: "shelf_source", environment: &environment, base: base)
        let destination = try await remote(job.destination, alias: "shelf_target", environment: &environment, base: base,
                                           multipart: (chunk, cutoff, size > 32 ? 1 : 4))
        var arguments = [job.mode.rawValue, "--config=/dev/null", "--use-json-log", "--log-level=NOTICE",
                         "--stats=1s", "--stats-log-level=NOTICE", "--disable=Copy", "--s3-no-check-bucket",
                         "--multi-thread-streams=0"]
        if size > 128 { arguments.append("--transfers=1") }
        if job.metadata { arguments.append("--metadata") }
        if job.mode == .sync { arguments.append("--delete-after") }
        let taskLimit = job.bandwidthMiB.map { Int64($0 * 1_048_576) }
        if let bytes = [preferences.bytesPerSecond, taskLimit].compactMap({ $0 }).min() {
            arguments.append("--bwlimit=\(bytes)B")
        }
        arguments += ["--", source, destination]
        let launchArguments = arguments
        let launchEnvironment = environment
        let child = Child()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await Task.detached(priority: .userInitiated) {
                do {
                    _ = try child.run(executable, launchArguments, launchEnvironment, nil, errorProgress: {
                        if let stats = log.consume($0) { update(stats) }
                    })
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw ShelfError(log.lastError ?? "rclone \(error.localizedDescription)")
                }
            }.value
        } onCancel: {
            child.stop()
        }
    }

    private static func remote(_ location: RemoteTransferLocation, alias: String, environment: inout [String: String],
                               base: [String: String], multipart: (chunk: String, cutoff: String, concurrency: Int)? = nil) async throws -> String {
        let connection = location.connection
        let region = try await resolvedRegion(location, environment: base)
        let pathStyle: Bool
        if connection.pathStyle { pathStyle = true }
        else { pathStyle = try await profileValue("s3.addressing_style", for: connection) == "path" }
        var options = [
            "TYPE": "s3", "PROVIDER": connection.endpoint.isEmpty ? "AWS" : "Other",
            "ENV_AUTH": String(connection.auth == .profile), "REGION": region, "ENDPOINT": connection.endpoint,
            "FORCE_PATH_STYLE": String(pathStyle), "REQUESTER_PAYS": String(connection.requesterPays),
            "ACCESS_KEY_ID": "", "SECRET_ACCESS_KEY": "", "SESSION_TOKEN": ""
        ]
        if connection.auth == .profile, !connection.profile.isEmpty { options["PROFILE"] = connection.profile }
        if connection.auth == .keys {
            let key = try Keychain.read(connection.id)
            options["ACCESS_KEY_ID"] = key.access
            options["SECRET_ACCESS_KEY"] = key.secret
            options["SESSION_TOKEN"] = key.token
        }
        if let multipart {
            options["CHUNK_SIZE"] = multipart.chunk
            options["UPLOAD_CUTOFF"] = multipart.cutoff
            options["UPLOAD_CONCURRENCY"] = String(multipart.concurrency)
        }
        for (key, value) in options {
            guard !value.utf8.contains(0) else { throw ShelfError("连接设置含有无效字符。") }
            environment["RCLONE_CONFIG_\(alias.uppercased())_\(key)"] = value
        }
        var remote = alias
        if connection.hasHTTPSOverride && connection.skipTLSVerification == true {
            remote += ",override.no_check_certificate=true"
        } else if !connection.caBundle.isEmpty {
            // The global ca_cert option accepts a CSV list, then the remote parser reads its own quoted value.
            let ca = csvQuote(connection.caBundle)
            let escaped = ca.replacingOccurrences(of: "'", with: "''")
            remote += ",override.ca_cert='\(escaped)'"
        }
        return "\(remote):\(location.path)"
    }

    private static func csvQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func resolvedRegion(_ location: RemoteTransferLocation, environment: [String: String]) async throws -> String {
        if let region = location.bucketRegion, !region.isEmpty { return region }
        if !location.connection.region.isEmpty { return location.connection.region }
        if let region = [environment["AWS_REGION"], environment["AWS_DEFAULT_REGION"]].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
            return region
        }
        return try await profileValue("region", for: location.connection) ?? "us-east-1"
    }

    private static func uploadThreshold(for connection: Connection) async throws -> String {
        guard let value = try await profileValue("s3.multipart_threshold", for: connection) else { return "8M" }
        let number = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let pattern = #"\A([0-9]+)\s*([KMGT]?)(?:I?B)?\z"#
        guard let match = number.range(of: pattern, options: .regularExpression) else {
            throw ShelfError("AWS 配置中的上传分片阈值无效，请在任务中指定分片大小。")
        }
        let normalized = number[match].filter { !$0.isWhitespace }
        let digits = normalized.prefix(while: \.isNumber)
        let suffix = normalized.dropFirst(digits.count)
        let multipliers: [Character: Int64] = ["K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40]
        let (bytes, overflow) = (Int64(digits) ?? 0).multipliedReportingOverflow(by: suffix.first.flatMap { multipliers[$0] } ?? 1)
        guard !overflow, (1...(5 << 30)).contains(bytes) else {
            throw ShelfError("AWS 配置中的上传分片阈值超出 S3 支持范围，请在任务中指定分片大小。")
        }
        return "\(bytes)B"
    }

    private static func profileValue(_ key: String, for connection: Connection) async throws -> String? {
        guard connection.auth == .profile else { return nil }
        let profile = connection.profile.isEmpty ? [] : ["--profile=\(connection.profile)"]
        do {
            let data = try await Engine.run(["configure", "get", key] + profile)
            let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        } catch let error as ShelfError where error.message == "AWS CLI 退出状态码 1。" {
            return nil
        }
    }
}
