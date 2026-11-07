import Foundation

struct DriveFile: Decodable {
    let id: String
    let name: String
    let mimeType: String?
    let parents: [String]?
    let modifiedTime: String?
    let trashed: Bool?
}

final class GoogleDrive {
    private let oauth: GoogleOAuth
    init(oauth: GoogleOAuth) { self.oauth = oauth }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [],
                         body: Data? = nil, contentType: String? = nil) async throws -> Data {
        var components = URLComponents(string: "https://www.googleapis.com\(path)")!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(try await oauth.authorizedToken())", forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw DriveError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private struct FileList: Decodable {
        let nextPageToken: String?
        let files: [DriveFile]
    }
    private struct Changes: Decodable {
        struct Change: Decodable {
            let fileId: String
            let removed: Bool?
            let file: DriveFile?
        }
        let nextPageToken: String?
        let newStartPageToken: String?
        let changes: [Change]
    }
    private struct StartPage: Decodable { let startPageToken: String }
    private struct About: Decodable {
        struct User: Decodable { let permissionId: String }
        let user: User
    }

    func accountID() async throws -> String {
        try JSONDecoder().decode(About.self, from: await request("GET", "/drive/v3/about",
            query: [URLQueryItem(name: "fields", value: "user(permissionId)")]))
            .user.permissionId
    }

    func listFiles(in parent: String? = nil) async throws -> [DriveFile] {
        var result: [DriveFile] = []
        var page: String?
        repeat {
            var query = [URLQueryItem(name: "q", value: parent.map {
                "'\($0)' in parents and trashed = false"
            } ?? "trashed = false"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,parents,modifiedTime,trashed)"),
                URLQueryItem(name: "pageSize", value: "1000")]
            if let page { query.append(URLQueryItem(name: "pageToken", value: page)) }
            let response = try JSONDecoder().decode(FileList.self,
                from: await request("GET", "/drive/v3/files", query: query))
            result += response.files
            page = response.nextPageToken
        } while page != nil
        return result
    }

    func startPageToken() async throws -> String {
        try JSONDecoder().decode(StartPage.self,
            from: await request("GET", "/drive/v3/changes/startPageToken")).startPageToken
    }

    func changes(since token: String) async throws -> (files: [DriveFile], removed: [String], token: String) {
        var page: String? = token
        var files: [DriveFile] = []
        var removed: [String] = []
        var finalToken = token
        while let current = page {
            let query = [URLQueryItem(name: "pageToken", value: current),
                URLQueryItem(name: "fields", value: "nextPageToken,newStartPageToken,changes(fileId,removed,file(id,name,mimeType,parents,modifiedTime,trashed))"),
                URLQueryItem(name: "pageSize", value: "1000")]
            let response = try JSONDecoder().decode(Changes.self,
                from: await request("GET", "/drive/v3/changes", query: query))
            for change in response.changes {
                if change.removed == true || change.file?.trashed == true { removed.append(change.fileId) }
                else if let file = change.file { files.append(file) }
            }
            page = response.nextPageToken
            finalToken = response.newStartPageToken ?? page ?? finalToken
        }
        return (files, removed, finalToken)
    }

    func createFolder(named name: String, in parent: String? = nil) async throws -> DriveFile {
        let metadata: [String: Any] = ["name": name,
            "mimeType": "application/vnd.google-apps.folder",
            "parents": parent.map { [$0] } ?? []]
        let data = try JSONSerialization.data(withJSONObject: metadata)
        return try JSONDecoder().decode(DriveFile.self,
            from: await request("POST", "/drive/v3/files",
                query: [URLQueryItem(name: "fields", value: "id,name,mimeType,parents,modifiedTime")],
                body: data, contentType: "application/json"))
    }

    func upload(named name: String, in parent: String, data: Data,
                mimeType: String = "application/octet-stream") async throws -> DriveFile {
        if data.count > 5_000_000 {
            return try await uploadResumable(named: name, in: parent, data: data,
                                             mimeType: mimeType)
        }
        let boundary = "angband-\(UUID().uuidString)"
        let metadata = try JSONSerialization.data(withJSONObject:
            ["name": name, "parents": [parent], "mimeType": mimeType])
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return try JSONDecoder().decode(DriveFile.self,
            from: await request("POST", "/upload/drive/v3/files",
                query: [URLQueryItem(name: "uploadType", value: "multipart"),
                        URLQueryItem(name: "fields", value: "id,name,mimeType,parents,modifiedTime")],
                body: body, contentType: "multipart/related; boundary=\(boundary)"))
    }

    private func uploadResumable(named name: String, in parent: String, data: Data,
                                 mimeType: String) async throws -> DriveFile {
        var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files")!
        components.queryItems = [URLQueryItem(name: "uploadType", value: "resumable"),
            URLQueryItem(name: "fields", value: "id,name,mimeType,parents,modifiedTime")]
        var start = URLRequest(url: components.url!)
        start.httpMethod = "POST"
        start.setValue("Bearer \(try await oauth.authorizedToken())", forHTTPHeaderField: "Authorization")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        start.setValue(String(data.count), forHTTPHeaderField: "X-Upload-Content-Length")
        start.httpBody = try JSONSerialization.data(withJSONObject:
            ["name": name, "parents": [parent], "mimeType": mimeType])
        let (startData, response) = try await URLSession.shared.data(for: start)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let location = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Location"),
              let url = URL(string: location) else {
            throw DriveError.http(status, String(data: startData, encoding: .utf8) ?? "")
        }
        var upload = URLRequest(url: url)
        upload.httpMethod = "PUT"
        upload.setValue("Bearer \(try await oauth.authorizedToken())", forHTTPHeaderField: "Authorization")
        upload.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        upload.httpBody = data
        let (result, completion) = try await URLSession.shared.data(for: upload)
        let finalStatus = (completion as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(finalStatus) else {
            throw DriveError.http(finalStatus, String(data: result, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(DriveFile.self, from: result)
    }

    func replace(_ id: String, data: Data, mimeType: String = "application/json") async throws {
        _ = try await request("PATCH", "/upload/drive/v3/files/\(id)",
            query: [URLQueryItem(name: "uploadType", value: "media")],
            body: data, contentType: mimeType)
    }

    func download(_ id: String) async throws -> Data {
        try await request("GET", "/drive/v3/files/\(id)",
                          query: [URLQueryItem(name: "alt", value: "media")])
    }

    enum DriveError: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            if case .http(let status, let body) = self {
                return "Google Drive returned \(status): \(body.prefix(500))"
            }
            return nil
        }
    }
}
