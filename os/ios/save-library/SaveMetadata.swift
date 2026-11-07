import Foundation

struct SaveMetadata: Equatable {
    let name: String
    let race: String?
    let characterClass: String?
    let level: Int?
    let experience: Int?
    let dungeonDepth: Int?
    let isDead: Bool
    let description: String

    static func read(from url: URL) throws -> SaveMetadata {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let header = try handle.read(upToCount: 36) ?? Data()
        guard header.count == 36,
              header.prefix(8) == Data("SaveVNLA".utf8),
              header[8..<19] == Data("description".utf8),
              header[23] == 0 else {
            throw SaveError.invalidHeader
        }

        func littleEndian32(_ offset: Int) -> Int {
            Int(header[offset]) | Int(header[offset + 1]) << 8 |
                Int(header[offset + 2]) << 16 | Int(header[offset + 3]) << 24
        }

        let version = littleEndian32(24)
        let size = littleEndian32(28)
        guard version == 1, size > 0, size <= 4096 else {
            throw SaveError.unsupportedDescription
        }
        let block = try handle.read(upToCount: size) ?? Data()
        guard block.count == size, let end = block.firstIndex(of: 0),
              let description = String(data: block.prefix(upTo: end), encoding: .utf8) else {
            throw SaveError.invalidDescription
        }
        let experience = readExperience(from: handle, afterDescriptionSize: size)

        if let range = description.range(of: ", dead (") {
            return SaveMetadata(name: String(description[..<range.lowerBound]), race: nil,
                                characterClass: nil, level: nil, experience: experience,
                                dungeonDepth: nil,
                                isDead: true, description: description)
        }

        let pattern = #"^(.+), L([0-9]+) (.+) ([^ ]+), at DL([0-9]+)$"#
        guard let match = description.firstMatch(of: try Regex(pattern)),
              let level = Int(match[2].substring ?? ""),
              let depth = Int(match[5].substring ?? "") else {
            return SaveMetadata(name: description, race: nil, characterClass: nil,
                                level: nil, experience: experience, dungeonDepth: nil,
                                isDead: false,
                                description: description)
        }
        return SaveMetadata(name: String(match[1].substring ?? ""),
                            race: String(match[3].substring ?? ""),
                            characterClass: String(match[4].substring ?? ""),
                            level: level, experience: experience, dungeonDepth: depth,
                            isDead: false,
                            description: description)
    }

    private static func readExperience(from handle: FileHandle,
                                       afterDescriptionSize size: Int) -> Int? {
        guard let fileSize = try? handle.seekToEnd() else { return nil }
        var offset = UInt64(36 + (size + 3) / 4 * 4)
        while offset <= fileSize && fileSize - offset >= 28 {
            try? handle.seek(toOffset: offset)
            guard let header = try? handle.read(upToCount: 28), header.count == 28,
                  let end = header.prefix(16).firstIndex(of: 0),
                  let name = String(data: header.prefix(upTo: end), encoding: .utf8) else {
                return nil
            }
            func number(_ position: Int) -> UInt32 {
                UInt32(header[position]) | UInt32(header[position + 1]) << 8 |
                    UInt32(header[position + 2]) << 16 | UInt32(header[position + 3]) << 24
            }
            let version = number(16)
            let blockSize = UInt64(number(20))
            let dataStart = offset + 28
            let paddedSize = (blockSize + 3) / 4 * 4
            guard paddedSize <= fileSize - dataStart else { return nil }
            if name == "player" {
                guard version == 1, blockSize <= 65_536,
                      let data = try? handle.read(upToCount: Int(blockSize)),
                      data.count == Int(blockSize) else { return nil }
                var reader = PlayerBlockReader(data: data)
                return reader.experience()
            }
            offset = dataStart + paddedSize
        }
        return nil
    }

    private struct PlayerBlockReader {
        let data: Data
        var offset = 0

        mutating func skip(_ count: Int) -> Bool {
            guard count >= 0, count <= data.count - offset else { return false }
            offset += count
            return true
        }

        mutating func skipString() -> Bool {
            guard offset < data.count,
                  let end = data[offset...].firstIndex(of: 0) else { return false }
            offset = end + 1
            return true
        }

        mutating func byte() -> Int? {
            guard offset < data.count else { return nil }
            defer { offset += 1 }
            return Int(data[offset])
        }

        mutating func word() -> Int? {
            guard let low = byte(), let high = byte() else { return nil }
            return low | high << 8
        }

        mutating func dword() -> Int? {
            guard let low = word(), let high = word() else { return nil }
            return low | high << 16
        }

        mutating func experience() -> Int? {
            for _ in 0..<6 {
                guard skipString() else { return nil }
            }
            guard skip(9), let statCount = byte(), statCount <= 16,
                  skip(statCount * 8 + 10), skipString(),
                  let slotCount = word(), slotCount <= 128 else { return nil }
            for _ in 0..<slotCount {
                guard skip(2), skipString() else { return nil }
            }
            guard skip(12) else { return nil } // padding, gold, maximum experience
            return dword()
        }
    }

    enum SaveError: Error {
        case invalidHeader, unsupportedDescription, invalidDescription
    }
}
