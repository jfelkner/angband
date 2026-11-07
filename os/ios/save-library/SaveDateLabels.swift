import Foundation

enum SaveDateLabels {
    static func lastSaved(_ date: Date, now: Date = Date()) -> String {
        guard date != .distantPast else { return "Unknown" }
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "Less than a minute ago" }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func snapshotDate(_ url: URL) -> Date? {
        // Snapshot names contain the save's timestamp in UTC. The file's own
        // modification date is when the snapshot copy was created.
        let pattern = #"^(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})Z-[0-9a-f]{12}\.save$"#
        guard let match = url.lastPathComponent.firstMatch(of: try! Regex(pattern)) else {
            return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
        let timestamp = "\(match[1].substring ?? "")T\(match[2].substring ?? ""):\(match[3].substring ?? ""):\(match[4].substring ?? "")Z"
        return ISO8601DateFormatter().date(from: timestamp)
    }

    static func snapshot(_ url: URL) -> String {
        guard let date = snapshotDate(url) else { return "Date unavailable" }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }
}
