#if os(iOS)
import Foundation
import UIKit
import UniformTypeIdentifiers

@_cdecl("angband_show_save_library")
public func angbandShowSaveLibrary() {
    DispatchQueue.main.async {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows)
            .first(where: { $0.isKeyWindow }),
              let root = window.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(UINavigationController(rootViewController: SaveLibraryController()), animated: true)
    }
}

private final class SaveLibraryController: UITableViewController, UIDocumentPickerDelegate {
    private let store = SaveStore()
    private let root: URL
    private let clientID: String
    private var localSaves: [URL] = []
    private var cloudPoints: [CloudSavePoint] = []
    private var cloudGroups: [(name: String, points: [CloudSavePoint])] = []
    private func regroupCloud() {
        cloudGroups = Dictionary(grouping: cloudPoints, by: \.characterID).values.compactMap { points in
            guard let latest = points.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
            return (name: latest.characterName,
                    points: points.sorted { $0.createdAt > $1.createdAt })
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var syncing = false
    private var oauth: GoogleOAuth? {
        clientID.isEmpty ? nil : GoogleOAuth(clientID: clientID)
    }

    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("save", isDirectory: true)
        clientID = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String ?? ""
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Save Library"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
            target: self, action: #selector(close))
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Import", style: .plain, target: self,
                            action: #selector(importFiles)),
            UIBarButtonItem(title: "Sync", style: .plain, target: self,
                            action: #selector(sync))]
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "save")
        refresh()
        if oauth?.isSignedIn == true { sync() }
    }

    @objc private func close() { dismiss(animated: true) }

    private func refresh() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do { _ = try store.discoverLooseSaves(in: root) }
        catch { show(error) }
        localSaves = ((try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? SaveMetadata.read(from: $0)) != nil }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return left > right
            }
        if let oauth {
            cloudPoints = ((try? CloudSync(root: root, oauth: oauth).records()) ?? [])
                .sorted { $0.createdAt > $1.createdAt }
        }
        regroupCloud()
        tableView.reloadData()
    }

    @objc private func importFiles() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        var imported = 0
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                _ = try SaveMetadata.read(from: url)
                var destination = root.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: destination.path) {
                    destination = root.appendingPathComponent(
                        "\(url.lastPathComponent)-\(UUID().uuidString.prefix(6))")
                }
                try FileManager.default.copyItem(at: url, to: destination)
                imported += 1
            } catch { show(error) }
        }
        refresh()
        if imported > 0 {
            let alert = UIAlertController(title: "Imported \(imported) save(s)",
                message: "They will appear in Angband's game selection when you next open the game.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    @objc private func sync() {
        guard !syncing else { return }
        guard let oauth else {
            let alert = UIAlertController(title: "Google Drive is not configured",
                message: "Set GOOGLE_IOS_CLIENT_ID when building the iOS app.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        syncing = true
        Task { @MainActor in
            defer { syncing = false; refresh() }
            do {
                if !oauth.isSignedIn { try await oauth.signIn() }
                let sync = try CloudSync(root: root, oauth: oauth)
                _ = try await sync.sync()
                cloudPoints = try sync.records().sorted { $0.createdAt > $1.createdAt }
                regroupCloud()
                tableView.reloadData()
            } catch { show(error) }
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 + cloudGroups.count }

    override func tableView(_ tableView: UITableView,
                            titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "On this device" : cloudGroups[section - 1].name
    }

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        section == 0 ? localSaves.count : cloudGroups[section - 1].points.count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "save", for: indexPath)
        var content = cell.defaultContentConfiguration()
        if indexPath.section == 0 {
            let file = localSaves[indexPath.row]
            let metadata = try? SaveMetadata.read(from: file)
            content.text = metadata?.name ?? file.lastPathComponent
            content.secondaryText = metadata?.description ?? file.lastPathComponent
        } else {
            let point = cloudGroups[indexPath.section - 1].points[indexPath.row]
            content.text = point.createdAt.formatted(date: .abbreviated, time: .shortened)
            content.secondaryText = "Level \(point.metadata.level.map(String.init) ?? "—") · \(point.createdAt.formatted(date: .abbreviated, time: .shortened))"
        }
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            let file = localSaves[indexPath.row]
            let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            controller.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
            present(controller, animated: true)
        } else {
            let point = cloudGroups[indexPath.section - 1].points[indexPath.row]
            let alert = UIAlertController(title: point.characterName,
                message: "Download this save point to the device's save library?",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Download", style: .default) { [weak self] _ in
                self?.download(point)
            })
            present(alert, animated: true)
        }
    }

    private func download(_ point: CloudSavePoint) {
        guard let oauth else { return }
        Task { @MainActor in
            do {
                let sync = try CloudSync(root: root, oauth: oauth)
                let savePoint = try await sync.download(point)
                if localSaves.contains(where: {
                    guard let data = try? Data(contentsOf: $0) else { return false }
                    return CloudIdentity.digest(data) == point.digest
                }) {
                    refresh()
                    return
                }
                let base = point.characterName.replacingOccurrences(of: #"[^A-Za-z0-9_-]"#,
                    with: "-", options: .regularExpression)
                var playable = root.appendingPathComponent(base)
                if FileManager.default.fileExists(atPath: playable.path) {
                    playable = root.appendingPathComponent("\(base)-\(point.digest.prefix(8))")
                }
                if !FileManager.default.fileExists(atPath: playable.path) {
                    try FileManager.default.copyItem(at: savePoint, to: playable)
                }
                refresh()
            } catch { show(error) }
        }
    }

    private func show(_ error: Error) {
        let alert = UIAlertController(title: "Save Library", message: error.localizedDescription,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
#endif
