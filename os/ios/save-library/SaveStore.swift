import CryptoKit
import Foundation

struct SaveStore {
    enum ImportResult: Equatable {
        case added, updated, olderVersion, duplicate
    }

    private let fm = FileManager.default

    /// A managed character has one active save directly inside its folder.
    func activeSave(in folder: URL) -> URL? {
        guard let files = try? fm.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return nil }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.first {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true &&
            (try? SaveMetadata.read(from: $0)) != nil
        }
    }

    func managedFolders(in root: URL) -> [URL] {
        guard let entries = try? fm.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true &&
            activeSave(in: $0) != nil
        }
    }

    /// Copies loose saves in the chosen folder into managed character folders.
    /// The original files remain where they were found.
    func discoverLooseSaves(in root: URL) throws -> [ImportResult] {
        let entries = try fm.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        return try entries.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true &&
            (try? SaveMetadata.read(from: $0)) != nil
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
         .map { try importSave(from: $0, into: root) }
    }

    @discardableResult
    func importSave(from source: URL, into root: URL) throws -> ImportResult {
        let metadata = try SaveMetadata.read(from: source)
        let candidates = managedFolders(in: root).compactMap { folder -> (URL, URL, SaveMetadata)? in
            guard let active = activeSave(in: folder),
                  let current = try? SaveMetadata.read(from: active),
                  current.name.caseInsensitiveCompare(metadata.name) == .orderedSame,
                  current.race == nil || metadata.race == nil || current.race == metadata.race,
                  current.characterClass == nil || metadata.characterClass == nil ||
                    current.characterClass == metadata.characterClass else { return nil }
            return (folder, active, current)
        }
        let exact = candidates.filter {
            $0.2.race == metadata.race && $0.2.characterClass == metadata.characterClass
        }
        // An incomplete description may match multiple runs, so only use that
        // fallback when it identifies a single folder.
        let eligible = exact.isEmpty ? (candidates.count == 1 ? candidates : []) : exact
        if let (folder, active, _) = eligible.max(by: {
            let left = (try? $0.1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let right = (try? $1.1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return left < right
        }) {
            let incoming = try Data(contentsOf: source)
            if incoming == (try Data(contentsOf: active)) {
                try recordSource(source, in: folder)
                return .duplicate
            }
            let sourceDate = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let activeDate = (try? active.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if sourceDate >= activeDate {
                try snapshot(active, in: folder)
                try snapshot(source, in: folder)
                let temp = folder.appendingPathComponent("incoming-\(UUID().uuidString)")
                try fm.copyItem(at: source, to: temp)
                do { _ = try fm.replaceItemAt(active, withItemAt: temp) }
                catch { try? fm.removeItem(at: temp); throw error }
                try recordSource(source, in: folder)
                return .updated
            }
            let added = try snapshot(source, in: folder)
            try recordSource(source, in: folder)
            return added ? .olderVersion : .duplicate
        }

        let slug = metadata.name.replacingOccurrences(
            of: #"[^A-Za-z0-9_-]"#, with: "-", options: .regularExpression)
        let folder = root.appendingPathComponent(
            "\(slug.isEmpty ? "character" : slug)-\(UUID().uuidString.prefix(8))",
            isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let active = folder.appendingPathComponent(source.lastPathComponent)
            try fm.copyItem(at: source, to: active)
            try snapshot(active, in: folder)
            try recordSource(source, in: folder)
            return .added
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    func sourcePaths(in folder: URL) -> [String] {
        let file = folder.appendingPathComponent("import-sources.json")
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func recordSource(_ source: URL, in folder: URL) throws {
        var paths = sourcePaths(in: folder)
        let path = source.standardizedFileURL.path
        guard !paths.contains(path) else { return }
        paths.append(path)
        let data = try JSONEncoder().encode(paths)
        try data.write(to: folder.appendingPathComponent("import-sources.json"), options: .atomic)
    }

    @discardableResult
    func snapshot(_ save: URL, in folder: URL) throws -> Bool {
        let data = try Data(contentsOf: save)
        let digest = digest(for: data)
        if try suppressedHashes(in: folder).contains(digest) { return false }
        let directory = folder.appendingPathComponent("snapshots", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        if existing.contains(where: { $0.lastPathComponent.contains(String(digest.prefix(12))) }) { return false }
        let savedAt = (try? save.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let timestamp = ISO8601DateFormatter().string(from: savedAt)
            .replacingOccurrences(of: ":", with: "-")
        let destination = directory.appendingPathComponent("\(timestamp)-\(digest.prefix(12)).save")
        try data.write(to: destination, options: .atomic)
        return true
    }

    /// Returns the newly suppressed digest, or nil if it was already suppressed.
    func suppressSavePoint(_ file: URL) throws -> String? {
        let snapshots = file.deletingLastPathComponent()
        guard snapshots.lastPathComponent == "snapshots" else {
            throw SavePointError.invalidLocation
        }
        let folder = snapshots.deletingLastPathComponent()
        let hash = digest(for: try Data(contentsOf: file))
        var hashes = try suppressedHashes(in: folder)
        guard hashes.insert(hash).inserted else { return nil }
        try writeSuppressedHashes(hashes, in: folder)
        return hash
    }

    func unsuppressSavePoint(_ digest: String, in folder: URL) throws {
        var hashes = try suppressedHashes(in: folder)
        hashes.remove(digest)
        try writeSuppressedHashes(hashes, in: folder)
    }

    func suppressedDigests(in folder: URL) throws -> Set<String> {
        try suppressedHashes(in: folder)
    }

    func suppressDigest(_ digest: String, in folder: URL) throws {
        var hashes = try suppressedHashes(in: folder)
        if hashes.insert(digest).inserted { try writeSuppressedHashes(hashes, in: folder) }
    }

    private func digest(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func suppressedHashes(in folder: URL) throws -> Set<String> {
        let file = folder.appendingPathComponent("deleted-savepoints.json")
        guard fm.fileExists(atPath: file.path) else { return [] }
        return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: file)))
    }

    private func writeSuppressedHashes(_ hashes: Set<String>, in folder: URL) throws {
        let file = folder.appendingPathComponent("deleted-savepoints.json")
        try JSONEncoder().encode(hashes.sorted()).write(to: file, options: .atomic)
    }

    enum SavePointError: Error {
        case invalidLocation
    }
}

/// Watches loose files directly in the selected save folder. A changed file
/// must have the same size and modification date on two scans before import.
struct SaveFolderWatcher {
    private struct Signature: Equatable {
        let modified: Date
        let size: UInt64
    }

    private let fm = FileManager.default
    private var imported: [URL: Signature] = [:]
    private var pending: [URL: Signature] = [:]

    mutating func prime(in root: URL) throws {
        imported = try signatures(in: root)
        pending.removeAll()
    }

    mutating func scan(in root: URL, store: SaveStore, now: Date = Date()) throws
        -> [SaveStore.ImportResult] {
        let current = try signatures(in: root)
        imported = imported.filter { current[$0.key] != nil }
        pending = pending.filter { current[$0.key] != nil }
        var results: [SaveStore.ImportResult] = []
        for (file, signature) in current.sorted(by: { $0.key.path < $1.key.path }) {
            if imported[file] == signature { continue }
            guard pending[file] == signature else {
                pending[file] = signature
                continue
            }
            guard now.timeIntervalSince(signature.modified) >= 2 else { continue }
            if (try? SaveMetadata.read(from: file)) != nil {
                results.append(try store.importSave(from: file, into: root))
            }
            // Ignore unrelated or incomplete files until they change again.
            imported[file] = signature
            pending[file] = nil
        }
        return results
    }

    private func signatures(in root: URL) throws -> [URL: Signature] {
        let files = try fm.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        var result: [URL: Signature] = [:]
        for file in files {
            let values = try file.resourceValues(forKeys: [
                .isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
            guard values.isRegularFile == true, let modified = values.contentModificationDate,
                  let size = values.fileSize else { continue }
            result[file] = Signature(modified: modified, size: UInt64(size))
        }
        return result
    }
}
