import AppKit
import Foundation
import Security

struct Connection: Codable, Identifiable, Equatable, Sendable {
    enum Auth: String, Codable, CaseIterable, Identifiable {
        case profile, keys, anonymous
        var id: Self { self }
        var title: String {
            switch self {
            case .profile: "AWS 配置文件"
            case .keys: "访问密钥"
            case .anonymous: "匿名访问"
            }
        }
    }
    var id = UUID()
    var name = "AWS 默认连接"
    var auth = Auth.profile
    var profile = ""
    var region = ""
    var endpoint = ""
    var pathStyle = false
    var requesterPays = false
    var bucket = ""
    var caBundle = ""
    var skipTLSVerification: Bool?

    var endpointURL: URLComponents? {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            return nil
        }
        return url
    }

    var hasHTTPSOverride: Bool { endpointURL?.scheme?.lowercased() == "https" }
}

struct Credentials: Codable, Sendable {
    var access = ""
    var secret = ""
    var token = ""
}

struct ShelfError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Keychain {
    static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.cloudshelf.s3.credentials",
         kSecAttrAccount as String: id.uuidString]
    }

    static func read(_ id: UUID) throws -> Credentials {
        var options = query(id)
        options[kSecReturnData as String] = true
        options[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(options as CFDictionary, &result)
        guard code == errSecSuccess, let data = result as? Data else {
            throw ShelfError("无法读取连接密钥。钥匙串状态码 \(code)。")
        }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    static func save(_ credentials: Credentials, for id: UUID) throws {
        let options = query(id)
        let data = try JSONEncoder().encode(credentials)
        var code = SecItemUpdate(options as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if code == errSecItemNotFound {
            var item = options
            item[kSecValueData as String] = data
            code = SecItemAdd(item as CFDictionary, nil)
        }
        guard code == errSecSuccess else { throw ShelfError("无法保存连接密钥。钥匙串状态码 \(code)。") }
    }

    static func remove(_ id: UUID) throws {
        let code = SecItemDelete(query(id) as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else {
            throw ShelfError("无法移除钥匙串中的密钥。状态码 \(code)。")
        }
    }
}

typealias OutputHandler = @Sendable (String) -> Void
typealias ResponseHandler = @Sendable (S3HTTPResponse) -> Void

final class ResponseCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var response: S3HTTPResponse?
    func set(_ response: S3HTTPResponse) { lock.withLock { self.response = response } }
    func get() -> S3HTTPResponse? { lock.withLock { response } }
}

struct S3HTTPResponse: Sendable {
    let status: Int?
    let url: String?
    let headers: [String: String]
    var sdkStatus: Int? = nil
    var errorCode: String?
    var errorRequestID: String?

    var operationStatus: Int? { sdkStatus ?? status }

    var requestID: String? {
        header("x-amz-request-id") ?? errorRequestID
    }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func parse(_ diagnostics: String, includeErrorCode: Bool = false) -> Self? {
        var status: Int?
        var url: String?
        var sdkStatus: Int?
        var response: Self?
        var expectingErrorBody = false
        let pattern = #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#
        let pairs = try! NSRegularExpression(pattern: "(\(pattern))\\s*:\\s*(\(pattern))")
        for line in diagnostics.split(whereSeparator: \.isNewline) {
            if expectingErrorBody {
                if let error = errorFields(from: line) {
                    response?.errorCode = error.code
                    response?.errorRequestID = error.requestID
                }
                expectingErrorBody = false
            }
            if let logger = line.range(of: " - urllib3.connectionpool - DEBUG - "),
               let boundary = line.range(of: #" HTTP/\d(?:\.\d)?["'] "#, options: .regularExpression),
               logger.upperBound <= boundary.lowerBound {
                status = Int(line[boundary.upperBound...].prefix(3))
                let request = line[logger.upperBound..<boundary.lowerBound].split(separator: " ", maxSplits: 2)
                url = nil
                sdkStatus = nil
                if request.count == 3 {
                    let path = request[2].prefix { $0 != "?" }
                    if path.hasPrefix("/"), var address = URLComponents(string: "\(request[0])\(path)"),
                       ["https", "http"].contains(address.scheme), address.host != nil {
                        address.user = nil
                        address.password = nil
                        address.query = nil
                        address.fragment = nil
                        url = address.string
                    }
                }
            }
            // Botocore can promote an HTTP 200 with an invalid or error body to a service error.
            if line.contains(" - botocore.handlers - DEBUG - Error found for response with 200 status code: ") {
                sdkStatus = 500
            }
            if includeErrorCode, let status = response?.operationStatus, (400..<600).contains(status),
               line.hasSuffix(" - botocore.parsers - DEBUG - Response body:") {
                expectingErrorBody = true
            }
            let marker = " - botocore.parsers - DEBUG - Response headers: "
            guard let start = line.range(of: marker) else { continue }
            let raw = String(line[start.upperBound...])
            var headers: [String: String] = [:]
            for match in pairs.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
                guard let key = Range(match.range(at: 1), in: raw),
                      let value = Range(match.range(at: 2), in: raw) else { continue }
                let name = unquote(raw[key])
                let canonical = name.lowercased()
                guard !["authorization", "proxy-authorization", "cookie", "set-cookie",
                        "x-amz-security-token", "x-amz-s3session-token",
                        "x-amz-server-side-encryption-customer-key"].contains(canonical) else { continue }
                headers[name] = unquote(raw[value])
            }
            response = Self(status: status, url: url, headers: headers, sdkStatus: sdkStatus)
        }
        return response
    }

    private static func errorFields(from line: Substring) -> (code: String?, requestID: String?)? {
        guard line.utf8.count <= 65_536, line.first == "b",
              let quote = line.dropFirst().first, quote == "'" || quote == "\"", line.last == quote else { return nil }
        let body = unquote(line.dropFirst())
        let bytes = body.unicodeScalars.compactMap { UInt8(exactly: $0.value) }
        guard bytes.count == body.unicodeScalars.count, let xml = String(bytes: bytes, encoding: .utf8),
              !xml.contains("<!DOCTYPE"),
              let document = try? XMLDocument(data: Data(bytes), options: [.nodeLoadExternalEntitiesNever]),
              let root = document.rootElement(), root.localName == "Error" else { return nil }
        let elements = root.children?.compactMap { $0 as? XMLElement } ?? []
        var code = elements.first { $0.localName == "Code" }?.stringValue
        if code?.range(of: #"^[A-Za-z][A-Za-z0-9]{0,63}$"#, options: .regularExpression) == nil { code = nil }
        var requestID = elements.first { $0.localName?.lowercased() == "requestid" }?.stringValue
        if requestID?.range(of: #"^[A-Za-z0-9+_.:/=-]{1,256}$"#, options: .regularExpression) == nil { requestID = nil }
        return (code, requestID)
    }

    private static func unquote(_ literal: Substring) -> String {
        var output = ""
        var characters = literal.dropFirst().dropLast().makeIterator()
        while let character = characters.next() {
            guard character == "\\", let next = characters.next() else {
                output.append(character)
                continue
            }
            switch next {
            case "n": output.append("\n")
            case "r": output.append("\r")
            case "t": output.append("\t")
            case "\"", "'", "\\": output.append(next)
            case "x", "u", "U":
                let length = next == "x" ? 2 : next == "u" ? 4 : 8
                let hex = (0..<length).compactMap { _ in characters.next() }
                if let number = UInt32(String(hex), radix: 16), let scalar = UnicodeScalar(number) { output.unicodeScalars.append(scalar) }
            default: output.append("\\"); output.append(next)
            }
        }
        return output
    }
}

private final class Child: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false

    func stop() {
        lock.withLock {
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }

    func run(_ executable: URL, _ arguments: [String], _ environment: [String: String],
             _ progress: OutputHandler?, response: ResponseHandler? = nil, captureServiceErrors: Bool = false,
             literalObjectKey: String? = nil) throws -> Data {
        let output = Pipe()
        let errors = Pipe()
        let errorData = ErrorBuffer()
        if let literalObjectKey {
            // Pass ASCII through Foundation, then restore the key bytes before replacing the shell with the CLI.
            let launch = """
                key=$(printf '%s' "$1" | /usr/bin/base64 -D && printf '.') || exit 1
                shift
                exec "$@" "--key=${key%.}"
                """
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", launch, "s3Shelf", Data(literalObjectKey.utf8).base64EncodedString(), executable.path] + arguments
        } else {
            process.executableURL = executable
            process.arguments = arguments
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try process.run()
        }
        let drains = DispatchGroup()
        drains.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorData.data = errors.fileHandleForReading.readDataToEndOfFile()
            drains.leave()
        }
        var data = Data()
        var remainder = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if let progress {
                remainder.append(chunk)
                while let boundary = remainder.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                    if boundary != remainder.startIndex { progress(String(decoding: remainder[..<boundary], as: UTF8.self)) }
                    remainder.removeSubrange(...boundary)
                }
            } else { data.append(chunk) }
        }
        if let progress, !remainder.isEmpty { progress(String(decoding: remainder, as: UTF8.self)) }
        process.waitUntilExit()
        drains.wait()
        if lock.withLock({ cancelled }) { throw CancellationError() }
        let diagnostics = String(decoding: errorData.data, as: UTF8.self)
        let received = response != nil || captureServiceErrors && process.terminationStatus != 0
            ? S3HTTPResponse.parse(diagnostics, includeErrorCode: captureServiceErrors) : nil
        if let received { response?(received) }
        if process.terminationStatus != 0 {
            // An empty S3 error message can make the AWS CLI S3 error formatter throw
            // before it reports the service's original error code.
            if captureServiceErrors, diagnostics.contains("awscli/customizations/s3errormsg.py"),
               diagnostics.contains("TypeError: argument of type 'NoneType'"),
               let code = received?.errorCode, let status = received?.operationStatus {
                let requestID = received?.requestID.map { "，请求 ID \($0)" } ?? ""
                let statusLabel = received?.sdkStatus == nil ? "HTTP \(status)" : "AWS CLI 处理状态 \(status)"
                throw ShelfError("S3 操作失败 (\(code))，\(statusLabel)\(requestID)。")
            }
            let message = response == nil && !captureServiceErrors
                ? diagnostics.trimmingCharacters(in: .whitespacesAndNewlines)
                : diagnostics.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("aws: [ERROR]:") }).map(String.init) ?? ""
            throw ShelfError(message.isEmpty ? "AWS CLI 退出状态码 \(process.terminationStatus)。" : message)
        }
        return data
    }

    private final class ErrorBuffer: @unchecked Sendable { var data = Data() }
}

enum Engine {
    private static let commandsWithServiceErrors: Set<String> = [
        "create-bucket", "delete-bucket",
        "get-bucket-acl", "get-object-acl", "put-bucket-acl", "put-object-acl",
        "get-bucket-policy", "put-bucket-policy", "delete-bucket-policy", "get-bucket-policy-status",
        "get-public-access-block", "put-public-access-block", "delete-public-access-block",
        "get-bucket-ownership-controls", "put-bucket-ownership-controls", "delete-bucket-ownership-controls"
    ]

    static func executable() throws -> URL {
        guard let resources = Bundle.main.resourceURL else { throw ShelfError("找不到应用资源。") }
        let bundled = resources.appendingPathComponent("aws-cli/aws")
        let candidates = [bundled.path, "/usr/local/bin/aws", "/opt/homebrew/bin/aws"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ShelfError("找不到 AWS CLI v2。请使用包含 AWS CLI 的安装包。")
        }
        return URL(fileURLWithPath: path)
    }

    static func profileEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        environment["AWS_PAGER"] = ""
        environment["AWS_CLI_AUTO_PROMPT"] = "off"
        environment["AWS_CLI_FILE_ENCODING"] = "UTF-8"
        environment["PYTHONIOENCODING"] = "utf-8"
        return environment
    }

    static func run(_ arguments: [String], connection: Connection? = nil, endpointOverride: Bool = true,
                    inputJSON: Data? = nil,
                    literalObjectKey: String? = nil,
                    maxAttempts: Int? = nil,
                    response: ResponseHandler? = nil,
                    progress: OutputHandler? = nil) async throws -> Data {
        let child = Child()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                var environment = profileEnvironment()
                if let maxAttempts { environment["AWS_MAX_ATTEMPTS"] = String(maxAttempts) }
                var flags = ["--no-cli-pager", "--no-cli-auto-prompt"]
                let subcommand = arguments.dropFirst().first ?? ""
                let captureServiceErrors = arguments.first == "s3api" &&
                    (subcommand.hasSuffix("-tagging") || commandsWithServiceErrors.contains(subcommand))
                if response != nil || captureServiceErrors { flags.append("--debug") }
                var temporary: URL?
                defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
                if inputJSON != nil || connection?.auth == .keys || connection?.pathStyle == true {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                           attributes: [.posixPermissions: 0o700])
                    temporary = directory
                }
                var command = arguments
                if let inputJSON, let temporary {
                    let url = temporary.appendingPathComponent("input.json")
                    try inputJSON.write(to: url)
                    command += ["--cli-input-json", "file://\(url.path)"]
                }
                if let connection {
                    if !connection.region.isEmpty { flags.append("--region=\(connection.region)") }
                    if endpointOverride {
                        if !connection.endpoint.isEmpty { flags.append("--endpoint-url=\(connection.endpoint)") }
                        if connection.skipTLSVerification == true && connection.hasHTTPSOverride {
                            flags.append("--no-verify-ssl")
                        } else if !connection.caBundle.isEmpty {
                            flags.append("--ca-bundle=\(connection.caBundle)")
                        }
                    }
                    if connection.auth == .profile, !connection.profile.isEmpty { flags.append("--profile=\(connection.profile)") }
                    if connection.auth == .anonymous { flags.append("--no-sign-request") }
                    if (connection.auth == .keys || connection.pathStyle), let directory = temporary {
                        let config = directory.appendingPathComponent("config")
                        var content = "[default]\n"
                        if connection.auth == .profile {
                            let source = environment["AWS_CONFIG_FILE"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws/config").path
                            if FileManager.default.fileExists(atPath: source) {
                                try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: config)
                            } else {
                                try Data(content.utf8).write(to: config)
                            }
                        } else {
                            environment["AWS_PROFILE"] = nil
                            environment["AWS_DEFAULT_PROFILE"] = nil
                            environment["AWS_SHARED_CREDENTIALS_FILE"] = directory.appendingPathComponent("credentials").path
                            environment["AWS_IGNORE_CONFIGURED_ENDPOINT_URLS"] = "true"
                            if connection.pathStyle { content += "s3 =\n    addressing_style = path\n" }
                            try Data(content.utf8).write(to: config)
                        }
                        environment["AWS_CONFIG_FILE"] = config.path
                        if connection.auth == .profile, connection.pathStyle {
                            let selectedProfile = connection.profile.isEmpty ? (environment["AWS_PROFILE"] ?? environment["AWS_DEFAULT_PROFILE"]) : connection.profile
                            let args = ["configure", "set", "s3.addressing_style", "path"] + (selectedProfile.map { ["--profile=\($0)"] } ?? [])
                            _ = try Child().run(executable(), args, environment, nil)
                        }
                    }
                    if connection.auth == .keys {
                        let credentials = try Keychain.read(connection.id)
                        environment["AWS_ACCESS_KEY_ID"] = credentials.access
                        environment["AWS_SECRET_ACCESS_KEY"] = credentials.secret
                        environment["AWS_SESSION_TOKEN"] = credentials.token.isEmpty ? nil : credentials.token
                        environment["AWS_SECURITY_TOKEN"] = nil
                    }
                }
                return try child.run(executable(), flags + command, environment, progress,
                                     response: response, captureServiceErrors: captureServiceErrors, literalObjectKey: literalObjectKey)
            }.value
        } onCancel: { child.stop() }
    }

    static func json<T: Decodable>(_ type: T.Type, _ arguments: [String], connection: Connection) async throws -> T {
        let data = try await run(arguments + ["--output=json"], connection: connection)
        return try JSONDecoder().decode(type, from: data)
    }

    static func s3URI(_ bucket: String, _ key: String = "") -> String { "s3://\(bucket)/\(key)" }
}
