import CryptoKit
import Foundation

enum CloudCoding {
    static func encoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.sortedKeys]
        return value
    }

    static func decoder() -> JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }
}

struct CloudSavePoint: Codable, Identifiable, Hashable {
    let format: Int
    let id: String
    let characterID: String
    let characterName: String
    let digest: String
    let objectName: String
    let createdAt: Date
    let deviceID: String
    let parentID: String?
    let metadata: CloudCharacterMetadata
}

struct CloudCharacterMetadata: Codable, Hashable {
    let race: String?
    let characterClass: String?
    let level: Int?
    let experience: Int?
    let dungeonDepth: Int?
    let isDead: Bool

    init(_ value: SaveMetadata) {
        race = value.race
        characterClass = value.characterClass
        level = value.level
        experience = value.experience
        dungeonDepth = value.dungeonDepth
        isDead = value.isDead
    }
}

struct CloudHead: Codable {
    let format: Int
    let characterID: String
    let deviceID: String
    let savePointID: String
    let updatedAt: Date
}

struct CloudTombstone: Codable {
    let format: Int
    let characterID: String
    let digest: String
    let deletedAt: Date
    let deviceID: String
}

enum CloudIdentity {
    static func characterID(in folder: URL, adopting suggestedID: String? = nil) throws -> String {
        let file = folder.appendingPathComponent("character-id")
        if let existing = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           UUID(uuidString: existing) != nil { return existing }
        let id = suggestedID.flatMap { UUID(uuidString: $0) != nil ? $0 : nil }
            ?? UUID().uuidString.lowercased()
        try id.write(to: file, atomically: true, encoding: .utf8)
        return id
    }

    static func deviceID() -> String {
        if let existing = UserDefaults.standard.string(forKey: "CloudDeviceID") { return existing }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "CloudDeviceID")
        return id
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
