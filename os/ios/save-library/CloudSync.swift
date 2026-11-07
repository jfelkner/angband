import Foundation

/// Syncs immutable save points. Active saves are never overwritten by a remote head.
final class CloudSync {
    private let index: CloudIndex
    private let drive: GoogleDrive
    private let store = SaveStore()
    private let root: URL
    private let deviceID = CloudIdentity.deviceID()

    init(root: URL, oauth: GoogleOAuth) throws {
        self.root = root
        index = try CloudIndex(at: root.appendingPathComponent(".angband-launcher/index.sqlite"))
        if try index.state("oauthClientID") != oauth.clientID {
            try index.resetRemoteCache()
            try index.setState("oauthClientID", oauth.clientID)
        }
        drive = GoogleDrive(oauth: oauth)
    }

    func records() throws -> [CloudSavePoint] { try index.records() }

    func sync() async throws -> Int {
        try await checkAccount()
        let remoteRoot = try await ensureRoot()
        try await pullChanges(in: remoteRoot)
        var uploaded = 0
        for folder in store.managedFolders(in: root) {
            guard let active = store.activeSave(in: folder) else { continue }
            _ = try store.snapshot(active, in: folder)
            let allSavePoints = try FileManager.default.contentsOfDirectory(
                at: folder.appendingPathComponent("snapshots"), includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let remoteRecords = try index.records()
            let digests = Set(try allSavePoints.map { try index.digest(of: $0) })
            let matchingIDs = Set(remoteRecords.filter { digests.contains($0.digest) }.map(\.characterID))
            let characterID = try CloudIdentity.characterID(in: folder,
                adopting: matchingIDs.count == 1 ? matchingIDs.first : nil)
            for deletion in try index.tombstones() where deletion.characterID == characterID {
                try store.suppressDigest(deletion.digest, in: folder)
            }
            let suppressed = try store.suppressedDigests(in: folder)
            let savePoints = try allSavePoints.filter { !suppressed.contains(try index.digest(of: $0)) }
            var parent: String?
            for file in savePoints {
                let digest = try index.digest(of: file)
                let id = String(CloudIdentity.digest(Data("\(characterID):\(digest)".utf8)).prefix(32))
                if !(try index.hasRecord(id)) {
                    let bytes = try Data(contentsOf: file)
                    let objectName = "object-\(digest).save"
                    let objectID: String
                    if let existing = try index.file(named: objectName, in: remoteRoot) {
                        objectID = existing.id
                    } else {
                        let uploaded = try await drive.upload(named: objectName, in: remoteRoot, data: bytes)
                        try index.upsert(indexFile(uploaded))
                        objectID = uploaded.id
                    }
                    try index.setObject(digest, id: objectID)
                    let metadata = try SaveMetadata.read(from: file)
                    let savedAt = SaveDateLabels.snapshotDate(file) ?? Date()
                    let record = CloudSavePoint(format: 1, id: id, characterID: characterID,
                        characterName: metadata.name, digest: digest, objectName: objectName,
                        createdAt: savedAt, deviceID: deviceID, parentID: parent,
                        metadata: CloudCharacterMetadata(metadata))
                    let name = "point-\(id).json"
                    if let existing = try index.file(named: name, in: remoteRoot) {
                        try index.record(record, fileID: existing.id)
                    } else {
                        let uploadedFile = try await drive.upload(named: name, in: remoteRoot,
                            data: try CloudCoding.encoder().encode(record), mimeType: "application/json")
                        try index.upsert(indexFile(uploadedFile))
                        try index.record(record, fileID: uploadedFile.id)
                        uploaded += 1
                    }
                }
                parent = id
            }
            let activeDigest = CloudIdentity.digest(try Data(contentsOf: active))
            let latest = String(CloudIdentity.digest(Data("\(characterID):\(activeDigest)".utf8)).prefix(32))
            let headStateKey = "head:\(characterID):\(deviceID)"
            if !suppressed.contains(activeDigest), try index.hasRecord(latest),
               try index.state(headStateKey) != latest {
                let head = CloudHead(format: 1, characterID: characterID, deviceID: deviceID,
                    savePointID: latest, updatedAt: Date())
                let name = "head-\(characterID)-\(deviceID).json"
                let data = try CloudCoding.encoder().encode(head)
                if let existing = try index.file(named: name, in: remoteRoot) {
                    try await drive.replace(existing.id, data: data)
                } else {
                    let file = try await drive.upload(named: name, in: remoteRoot,
                        data: data, mimeType: "application/json")
                    try index.upsert(indexFile(file))
                }
                try index.setState(headStateKey, latest)
            }
            for digest in suppressed where !(try index.hasTombstone(
                characterID: characterID, digest: digest)) {
                let deletion = CloudTombstone(format: 1, characterID: characterID,
                    digest: digest, deletedAt: Date(), deviceID: deviceID)
                let name = "delete-\(characterID)-\(digest).json"
                if try index.file(named: name, in: remoteRoot) == nil {
                    let file = try await drive.upload(named: name, in: remoteRoot,
                        data: try CloudCoding.encoder().encode(deletion), mimeType: "application/json")
                    try index.upsert(indexFile(file))
                }
                try index.tombstone(deletion)
            }
        }
        return uploaded
    }

    /// Downloads a selected save point to a managed character folder and makes
    /// it visible to the existing library UI. It does not replace any active save.
    @discardableResult
    func download(_ record: CloudSavePoint) async throws -> URL {
        try await checkAccount()
        let remoteRoot = try await ensureRoot()
        guard let object = try index.file(named: record.objectName, in: remoteRoot) else {
            throw SyncError.objectMissing
        }
        let bytes = try await drive.download(object.id)
        guard CloudIdentity.digest(bytes) == record.digest else { throw SyncError.digestMismatch }
        let destinationFolder: URL
        if let match = store.managedFolders(in: root).first(where: {
            (try? CloudIdentity.characterID(in: $0)) == record.characterID
        }) {
            destinationFolder = match
        } else {
            let safeName = record.characterName.replacingOccurrences(of: #"[^A-Za-z0-9_-]"#,
                with: "-", options: .regularExpression)
            destinationFolder = root.appendingPathComponent(
                "\(safeName)-\(record.characterID.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: destinationFolder,
                withIntermediateDirectories: true)
            try record.characterID.write(to: destinationFolder.appendingPathComponent("character-id"),
                atomically: true, encoding: .utf8)
            let active = destinationFolder.appendingPathComponent(safeName.isEmpty ? "character" : safeName)
            try bytes.write(to: active, options: .atomic)
        }
        let savePoints = destinationFolder.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: savePoints, withIntermediateDirectories: true)
        let destination = savePoints.appendingPathComponent(
            "\(ISO8601DateFormatter().string(from: record.createdAt).replacingOccurrences(of: ":", with: "-"))-\(record.digest.prefix(12)).save")
        if !FileManager.default.fileExists(atPath: destination.path) {
            try bytes.write(to: destination, options: .atomic)
        }
        return destination
    }

    private func ensureRoot() async throws -> String {
        if let id = try index.state("driveRootID") { return id }
        let files = try await drive.listFiles()
        let existing = files.first {
            $0.name == "Angband Saves" && $0.mimeType == "application/vnd.google-apps.folder"
        }
        let folder: DriveFile
        if let existing { folder = existing }
        else { folder = try await drive.createFolder(named: "Angband Saves") }
        try index.setState("driveRootID", folder.id)
        return folder.id
    }

    private func checkAccount() async throws {
        let accountID = try await drive.accountID()
        if let previous = try index.state("driveAccountID"), previous != accountID {
            throw SyncError.accountChanged
        }
        try index.setState("driveAccountID", accountID)
    }

    private func pullChanges(in remoteRoot: String) async throws {
        if let token = try index.state("changeToken") {
            let changes = try await drive.changes(since: token)
            for id in changes.removed { try index.removeFile(id) }
            for file in changes.files where file.parents?.contains(remoteRoot) == true {
                try index.upsert(indexFile(file))
            }
            try index.setState("changeToken", changes.token)
        } else {
            let token = try await drive.startPageToken()
            for file in try await drive.listFiles(in: remoteRoot) {
                try index.upsert(indexFile(file))
            }
            try index.setState("changeToken", token)
        }
        for file in try index.files(in: remoteRoot, suffix: ".json")
        where file.name.hasPrefix("point-") {
            let id = String(file.name.dropFirst(6).dropLast(5))
            guard !(try index.hasRecord(id)) else { continue }
            let data = try await drive.download(file.id)
            let record = try CloudCoding.decoder().decode(CloudSavePoint.self, from: data)
            guard record.format == 1, record.id == id else { continue }
            try index.record(record, fileID: file.id)
        }
        for file in try index.files(in: remoteRoot, suffix: ".json")
        where file.name.hasPrefix("delete-") {
            let stem = String(file.name.dropFirst(7).dropLast(5))
            if let split = stem.lastIndex(of: "-") {
                let characterID = String(stem[..<split])
                let digest = String(stem[stem.index(after: split)...])
                if try index.hasTombstone(characterID: characterID, digest: digest) { continue }
            }
            let data = try await drive.download(file.id)
            let deletion = try CloudCoding.decoder().decode(CloudTombstone.self, from: data)
            guard deletion.format == 1, deletion.digest.count == 64 else { continue }
            if !(try index.hasTombstone(characterID: deletion.characterID,
                                        digest: deletion.digest)) {
                try index.tombstone(deletion)
            }
        }
    }

    private func indexFile(_ file: DriveFile) -> CloudIndex.RemoteFile {
        CloudIndex.RemoteFile(id: file.id, name: file.name,
            parent: file.parents?.first, modified: file.modifiedTime)
    }

    enum SyncError: LocalizedError {
        case objectMissing, digestMismatch, accountChanged
        var errorDescription: String? {
            switch self {
            case .objectMissing: "Save file is missing from Google Drive"
            case .digestMismatch: "Downloaded save did not match its recorded checksum"
            case .accountChanged: "This save folder is linked to a different Google account. Choose another local save folder for this account."
            }
        }
    }
}
