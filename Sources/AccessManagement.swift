import Foundation

struct S3Tag: Codable, Equatable, Identifiable {
    var key = ""
    var value = ""
    let id = UUID()

    enum CodingKeys: String, CodingKey { case key = "Key", value = "Value" }

    init(key: String = "", value: String = "") {
        self.key = key
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        key = try fields.decode(String.self, forKey: .key)
        value = try fields.decodeIfPresent(String.self, forKey: .value) ?? ""
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key.utf8.elementsEqual(rhs.key.utf8) && lhs.value.utf8.elementsEqual(rhs.value.utf8)
    }
}

struct S3Tags: Codable, Equatable {
    var entries: [S3Tag] = []
    enum CodingKeys: String, CodingKey { case entries = "TagSet" }

    init(entries: [S3Tag] = []) { self.entries = entries }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        entries = try fields.decodeIfPresent([S3Tag].self, forKey: .entries) ?? []
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entries.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
            == rhs.entries.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
    }

    func validation(limit: Int) -> String? {
        if entries.count > limit { return "最多可保存 \(limit) 个标签。" }
        var keys = Set<Data>()
        for (index, tag) in entries.enumerated() {
            let row = index + 1
            if tag.key.isEmpty { return "第 \(row) 行需要填写标签键。" }
            if tag.key.utf16.count > 128 { return "第 \(row) 行的标签键超过 128 个 UTF‑16 单元。" }
            if tag.value.utf16.count > 256 { return "第 \(row) 行的值超过 256 个 UTF‑16 单元。" }
            if tag.key.lowercased().hasPrefix("aws:") { return "第 \(row) 行的标签键使用了 AWS 保留前缀 aws:。" }
            if !keys.insert(Data(tag.key.utf8)).inserted { return "标签键「\(tag.key)」重复。" }
        }
        return nil
    }
}

struct S3ACL: Codable, Equatable {
    struct Owner: Codable, Equatable {
        var id: String?
        var name: String?
        enum CodingKeys: String, CodingKey { case id = "ID", name = "DisplayName" }

        var description: String {
            let parts = [name, id].compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return parts.isEmpty ? "端点未提供所有者信息" : parts.joined(separator: " · ")
        }
    }

    struct Grant: Codable, Equatable, Identifiable {
        struct Grantee: Codable, Equatable {
            var type = "CanonicalUser"
            var canonicalID: String?
            var uri: String?
            var email: String?
            var displayName: String?
            enum CodingKeys: String, CodingKey {
                case type = "Type", canonicalID = "ID", uri = "URI", email = "EmailAddress", displayName = "DisplayName"
            }
            var identifier: String {
                get {
                    switch type {
                    case "Group": uri ?? ""
                    case "AmazonCustomerByEmail": email ?? ""
                    default: canonicalID ?? ""
                    }
                }
                set {
                    canonicalID = type == "CanonicalUser" ? newValue : nil
                    uri = type == "Group" ? newValue : nil
                    email = type == "AmazonCustomerByEmail" ? newValue : nil
                    displayName = nil
                }
            }
            var label: String {
                [displayName, identifier].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            }
        }

        var grantee = Grantee()
        var permission = "READ"
        let id = UUID()
        enum CodingKeys: String, CodingKey { case grantee = "Grantee", permission = "Permission" }
        var signature: [String] { [grantee.type, grantee.identifier, permission] }
    }

    var owner: Owner?
    var grants: [Grant] = []
    enum CodingKeys: String, CodingKey { case owner = "Owner", grants = "Grants" }

    init(owner: Owner? = nil, grants: [Grant] = []) { self.owner = owner; self.grants = grants }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.owner) || container.contains(.grants) else {
            throw ShelfError("端点没有返回 ACL 数据。")
        }
        owner = try container.decodeIfPresent(Owner.self, forKey: .owner)
        grants = try container.decodeIfPresent([Grant].self, forKey: .grants) ?? []
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.owner?.id == rhs.owner?.id && lhs.signatures == rhs.signatures
    }

    private var signatures: [[String]] { grants.map(\.signature).sorted { $0.lexicographicallyPrecedes($1) } }
    var hasOwnerID: Bool { !(owner?.id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }

    static let groups: [(title: String, uri: String)] = [
        ("所有人", "http://acs.amazonaws.com/groups/global/AllUsers"),
        ("AWS 已认证用户", "http://acs.amazonaws.com/groups/global/AuthenticatedUsers"),
        ("S3 日志投递", "http://acs.amazonaws.com/groups/s3/LogDelivery")
    ]

    static func permissions(isBucket: Bool) -> [String] {
        isBucket ? ["READ", "WRITE", "READ_ACP", "WRITE_ACP", "FULL_CONTROL"] : ["READ", "READ_ACP", "WRITE_ACP", "FULL_CONTROL"]
    }

    func validation(isBucket: Bool) -> String? {
        if !hasOwnerID { return "端点未返回所有者 Canonical ID，无法安全写入 ACL。" }
        if grants.count > 100 { return "ACL 最多支持 100 条授权。" }
        var entries = Set<[String]>()
        for (index, grant) in grants.enumerated() {
            if !["CanonicalUser", "Group", "AmazonCustomerByEmail"].contains(grant.grantee.type) {
                return "第 \(index + 1) 条授权的主体类型不受支持。"
            }
            if grant.grantee.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "第 \(index + 1) 条授权缺少主体标识。"
            }
            if !Self.permissions(isBucket: isBucket).contains(grant.permission) { return "第 \(index + 1) 条授权不适用于此资源。" }
            if !entries.insert(grant.signature).inserted { return "第 \(index + 1) 条授权与已有授权重复。" }
        }
        return nil
    }
}

struct BucketPolicy: Equatable {
    var text: String?

    static func normalized(_ value: String) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
              json["Statement"] is [String: Any] || json["Statement"] is [[String: Any]] else {
            throw ShelfError("策略必须是有效的 JSON 对象，并包含 Statement 对象或数组。")
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        if lhs.text == rhs.text { return true }
        guard let lhs = lhs.text, let rhs = rhs.text, let normalized = try? normalized(lhs) else { return false }
        return normalized == (try? Self.normalized(rhs))
    }
}

struct PublicAccessBlock: Codable, Equatable {
    var blockPublicACLs = true
    var ignorePublicACLs = true
    var blockPublicPolicy = true
    var restrictPublicBuckets = true

    enum CodingKeys: String, CodingKey {
        case blockPublicACLs = "BlockPublicAcls", ignorePublicACLs = "IgnorePublicAcls"
        case blockPublicPolicy = "BlockPublicPolicy", restrictPublicBuckets = "RestrictPublicBuckets"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        blockPublicACLs = try values.decodeIfPresent(Bool.self, forKey: .blockPublicACLs) ?? false
        ignorePublicACLs = try values.decodeIfPresent(Bool.self, forKey: .ignorePublicACLs) ?? false
        blockPublicPolicy = try values.decodeIfPresent(Bool.self, forKey: .blockPublicPolicy) ?? false
        restrictPublicBuckets = try values.decodeIfPresent(Bool.self, forKey: .restrictPublicBuckets) ?? false
    }
}

@MainActor
extension InspectorClient {
    var isBucket: Bool { target.object == nil }
    var tagLimit: Int { isBucket ? 50 : 10 }

    func readTags(fresh: Bool = false) async throws -> InspectorReading<S3Tags> {
        try await readAccess(.tags, "get-\(resourceKind)-tagging", fresh: fresh, missing: ["NoSuchTagSet"]) { result in
            guard let result else { return S3Tags() }
            return try JSONDecoder().decode(S3Tags.self, from: result.data)
        }
    }

    func writeTags(_ tags: S3Tags) async throws {
        if let error = tags.validation(limit: tagLimit) { throw ShelfError(error) }
        if tags.entries.isEmpty && (isBucket || !connection.requesterPays) {
            // DeleteObjectTagging has no RequestPayer parameter. PUT with an empty set supports it.
            _ = try await accessRequest("delete-\(resourceKind)-tagging", writing: true,
                                        missing: ["NoSuchTagSet"], allowRequesterPays: false)
        } else {
            _ = try await accessRequest("put-\(resourceKind)-tagging", body: ["Tagging": try payload(tags)], writing: true)
        }
    }

    func readACL(fresh: Bool = false) async throws -> InspectorReading<S3ACL> {
        try await readAccess(.acl, "get-\(resourceKind)-acl", fresh: fresh) { result in
            try JSONDecoder().decode(S3ACL.self, from: result?.data ?? Data())
        }
    }

    func writeACL(_ acl: S3ACL) async throws {
        if let error = acl.validation(isBucket: isBucket) { throw ShelfError(error) }
        _ = try await accessRequest("put-\(resourceKind)-acl", body: ["AccessControlPolicy": try payload(acl)], writing: true)
    }

    func readBucketPolicy(fresh: Bool = false) async throws -> InspectorReading<BucketPolicy> {
        try await readAccess(.policy, "get-bucket-policy", fresh: fresh, missing: ["NoSuchBucketPolicy"]) { result in
            guard let result else { return BucketPolicy(text: nil) }
            guard let text = result.fields["Policy"] as? String else { throw ShelfError("端点未返回有效的存储桶策略。") }
            return BucketPolicy(text: (try? BucketPolicy.normalized(text)) ?? text)
        }
    }

    func writeBucketPolicy(_ policy: BucketPolicy) async throws {
        if let text = policy.text {
            _ = try BucketPolicy.normalized(text)
            _ = try await accessRequest("put-bucket-policy", body: ["Policy": text], writing: true)
        } else {
            _ = try await accessRequest("delete-bucket-policy", writing: true, missing: ["NoSuchBucketPolicy"])
        }
    }

    func readPublicAccessBlock(fresh: Bool = false) async throws -> InspectorReading<PublicAccessBlock?> {
        struct Envelope: Decodable { let PublicAccessBlockConfiguration: PublicAccessBlock }
        return try await readAccess(.accessBlock, "get-public-access-block", fresh: fresh,
                                    missing: ["NoSuchPublicAccessBlockConfiguration"]) { result in
            guard let result else { return nil }
            return try JSONDecoder().decode(Envelope.self, from: result.data).PublicAccessBlockConfiguration
        }
    }

    func writePublicAccessBlock(_ configuration: PublicAccessBlock?) async throws {
        if let configuration {
            _ = try await accessRequest("put-public-access-block",
                                        body: ["PublicAccessBlockConfiguration": try payload(configuration)], writing: true)
        } else {
            _ = try await accessRequest("delete-public-access-block", writing: true,
                                        missing: ["NoSuchPublicAccessBlockConfiguration"])
        }
    }

    func readOwnership(fresh: Bool = false) async throws -> InspectorReading<String?> {
        try await readAccess(.ownership, "get-bucket-ownership-controls", fresh: fresh,
                             missing: ["OwnershipControlsNotFoundError"], bucketScoped: true) { result in
            guard let result else { return nil }
            let controls = result.fields["OwnershipControls"] as? [String: Any]
            guard let rules = controls?["Rules"] as? [[String: String]], let ownership = rules.first?["ObjectOwnership"] else {
                throw ShelfError("端点未返回有效的对象所有权设置。")
            }
            return ownership
        }
    }

    func readPolicyStatus(fresh: Bool = false) async throws -> InspectorReading<Bool?> {
        try await readAccess(.policyStatus, "get-bucket-policy-status", fresh: fresh, missing: ["NoSuchBucketPolicy"]) { result in
            guard let result else { return nil }
            guard let isPublic = (result.fields["PolicyStatus"] as? [String: Any])?["IsPublic"] as? Bool else {
                throw ShelfError("端点未返回有效的存储桶策略公开状态。")
            }
            return isPublic
        }
    }

    private func readAccess<Value>(_ kind: InspectorCacheKind, _ command: String, fresh: Bool = false,
                                   missing: [String] = [], bucketScoped: Bool = false,
                                   decode: @MainActor (Result?) throws -> Value) async throws -> InspectorReading<Value> {
        guard target.supportsAccessManagement else { throw ShelfError("所选项没有可管理的权限或标签。") }
        return try await inspectorCache.load(target, kind: kind, fresh: fresh) {
            let result = try await accessRequest(command, missing: missing, bucketScoped: bucketScoped)
            // Allow space for the decoded Swift records in addition to the wire payload size.
            return (try decode(result), (result?.data.count ?? 0) * 2)
        }
    }

    private var resourceKind: String { isBucket ? "bucket" : "object" }

    private func payload<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func accessRequest(_ command: String, body: [String: Any]? = nil, writing: Bool = false,
                               missing: [String] = [], allowRequesterPays: Bool = true, bucketScoped: Bool = false) async throws -> Result? {
        guard target.supportsAccessManagement else { throw ShelfError("所选项没有可管理的权限或标签。") }
        if writing && connection.auth == .anonymous { throw ShelfError("匿名连接只能查看权限和标签。") }
        let object = bucketScoped ? nil : target.object
        var parameters = body ?? [:]
        if let object {
            // macOS can normalize Unicode in subprocess arguments. S3 keys preserve their original bytes.
            parameters["Key"] = object.key
            parameters["VersionId"] = object.version
        }
        let bytes = parameters.isEmpty ? nil : try JSONSerialization.data(withJSONObject: parameters)
        defer {
            if writing {
                inspectorCache.invalidateMutation(command, change: ObjectChange(bucket: target.bucket.Name, key: object?.key))
            }
        }
        let result = try await fetch(command, requesterPays: object != nil && allowRequesterPays, inputJSON: bytes)
        if let error = result.error {
            if missing.contains(where: { error.contains("(\($0))") }) { return nil }
            if error.contains("AccessControlListNotSupported") {
                throw ShelfError("端点已禁用 ACL。可在存储桶权限页查看存储桶策略。\n\(error)")
            }
            if error.contains("(NotImplemented)") || error.contains("(MethodNotAllowed)") {
                throw ShelfError("当前端点或资源类型不支持此操作。\n\(error)")
            }
            throw ShelfError(error)
        }
        return result
    }
}
