import Foundation
import SQLite3

enum ChatDatabaseError: LocalizedError {
    case noAccess(String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .noAccess(let path):
            return "OpenHoy can't read \(path). Grant it Full Disk Access in System Settings › Privacy & Security."
        case .sqlite(let message):
            return "Messages database error: \(message)"
        }
    }
}

/// Read-only access to the Messages database (`~/Library/Messages/chat.db`).
/// Requires Full Disk Access. All work happens on this actor's executor.
actor ChatDatabase {
    static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["OPENHOY_CHAT_DB"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db")
    }

    let url: URL
    private var db: OpaquePointer?
    private var messageColumns: Set<String> = []

    init(url: URL = ChatDatabase.defaultURL) {
        self.url = url
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - Connection

    func open() throws {
        if db != nil { return }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw ChatDatabaseError.noAccess(url.path)
        }
        sqlite3_busy_timeout(handle, 2000)
        // Opening succeeds lazily even without permission; touch the schema to be sure.
        var probe: OpaquePointer?
        let probeRC = sqlite3_prepare_v2(handle, "SELECT name FROM sqlite_master LIMIT 1", -1, &probe, nil)
        let stepRC = probeRC == SQLITE_OK ? sqlite3_step(probe) : probeRC
        sqlite3_finalize(probe)
        guard stepRC == SQLITE_ROW || stepRC == SQLITE_DONE else {
            sqlite3_close_v2(handle)
            throw ChatDatabaseError.noAccess(url.path)
        }
        db = handle
        messageColumns = Set(try rows("PRAGMA table_info(message)") { $0.string(1) ?? "" })
    }

    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    // MARK: - Queries

    /// Changes whenever another connection (Messages) commits to the database: new rows
    /// *and* in-place updates such as delivery receipts, reads, edits and unsends.
    func dataVersion() throws -> Int64 {
        try open()
        return try rows("PRAGMA data_version") { $0.int64(0) }.first ?? 0
    }

    func recentChats(limit: Int = 60) throws -> [ChatSummary] {
        try open()
        struct Row {
            let rowID: Int64; let guid: String; let identifier: String; let name: String?; let service: String; let date: Int64
            let properties: Data?
        }
        // `chat.service_name` is unreliable for `any;-;…` rows (often "SMS" for an iMessage
        // conversation), so the service shown is the one the latest message actually used.
        let chatRows = try rows("""
            SELECT c.ROWID, c.guid, c.chat_identifier, c.display_name,
                   COALESCE((SELECT m.service FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id
                             WHERE j.chat_id = c.ROWID ORDER BY j.message_date DESC LIMIT 1), c.service_name),
                   MAX(cmj.message_date), c.properties
            FROM chat c
            JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            GROUP BY c.ROWID
            ORDER BY MAX(cmj.message_date) DESC
            LIMIT ?
            """, [.int(Int64(limit))]) { s in
            Row(rowID: s.int64(0), guid: s.string(1) ?? "", identifier: s.string(2) ?? "",
                name: s.string(3).flatMap { $0.isEmpty ? nil : $0 }, service: s.string(4) ?? "iMessage", date: s.int64(5),
                properties: s.data(6))
        }
        guard !chatRows.isEmpty else { return [] }

        // Group photos: `chat.properties` (a binary plist) names an attachment by guid.
        var photoGUIDs: [Int64: String] = [:]
        for row in chatRows {
            guard let data = row.properties,
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let guid = plist["groupPhotoGuid"] as? String, !guid.isEmpty else { continue }
            photoGUIDs[row.rowID] = guid
        }
        var photoPaths: [String: String] = [:]
        if !photoGUIDs.isEmpty {
            let guids = Array(Set(photoGUIDs.values))
            try rows("SELECT guid, filename FROM attachment WHERE guid IN (\(placeholders(guids.count)))",
                     guids.map { .text($0) }) { s in (s.string(0) ?? "", s.string(1)) }
                .forEach { guid, path in
                    if let path { photoPaths[guid] = (path as NSString).expandingTildeInPath }
                }
        }

        let ids = chatRows.map(\.rowID)
        var participants: [Int64: [String]] = [:]
        try rows("""
            SELECT chj.chat_id, h.id FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            WHERE chj.chat_id IN (\(placeholders(ids.count)))
            ORDER BY chj.ROWID
            """, ids.map { .int($0) }) { s in (s.int64(0), s.string(1) ?? "") }
            .forEach { chatID, handle in
                if !handle.isEmpty, !(participants[chatID]?.contains(handle) ?? false) {
                    participants[chatID, default: []].append(handle)
                }
            }

        return chatRows.map { row in
            ChatSummary(rowID: row.rowID, guid: row.guid, identifier: row.identifier, displayName: row.name,
                        service: row.service, participants: participants[row.rowID] ?? [row.identifier],
                        lastMessageDate: Self.date(fromAppleTime: row.date),
                        groupPhotoPath: photoGUIDs[row.rowID].flatMap { photoPaths[$0] })
        }
    }

    /// The most recent `limit` displayable messages of a chat, oldest first, with reactions folded in.
    func messages(chatRowIDs: [Int64], limit: Int = 60) throws -> [ChatMessage] {
        guard !chatRowIDs.isEmpty else { return [] }
        try open()
        let emojiColumn = messageColumns.contains("associated_message_emoji") ? "m.associated_message_emoji" : "NULL"
        let audioColumn = messageColumns.contains("is_audio_message") ? "m.is_audio_message" : "0"
        let retractedColumn = messageColumns.contains("date_retracted") ? "m.date_retracted" : "0"
        let threadColumn = messageColumns.contains("thread_originator_guid") ? "m.thread_originator_guid" : "NULL"
        let editedColumn = messageColumns.contains("date_edited") ? "m.date_edited" : "0"
        let errorColumn = messageColumns.contains("error") ? "m.error" : "0"
        let deliveredColumn = messageColumns.contains("is_delivered") ? "m.is_delivered" : "1"
        let readColumn = messageColumns.contains("date_read") ? "m.date_read" : "0"

        struct Raw {
            let rowID: Int64, guid: String, text: String?, isFromMe: Bool, date: Int64, sender: String?
            let assocGUID: String?, assocType: Int, emoji: String?, hasAttachments: Bool, isAudio: Bool, itemType: Int, retracted: Bool
            let replyTo: String?
            let edited: Bool, error: Bool, delivered: Bool, dateRead: Int64
        }

        // Over-fetch so reactions don't crowd out real messages.
        let rawRows = try rows("""
            SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.is_from_me, m.date, h.id,
                   m.associated_message_guid, m.associated_message_type, \(emojiColumn),
                   m.cache_has_attachments, \(audioColumn), m.item_type, \(retractedColumn), \(threadColumn),
                   \(editedColumn), \(errorColumn), \(deliveredColumn), \(readColumn)
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id IN (\(placeholders(chatRowIDs.count)))
            ORDER BY cmj.message_date DESC, m.ROWID DESC
            LIMIT ?
            """, chatRowIDs.map { .int($0) } + [.int(Int64(limit * 3))]) { s -> Raw in
            // `attributedBody` is authoritative: newer macOS keeps the full body there, and after
            // an edit it holds the current version while `text` can be missing, stale or shorter.
            var text = s.string(2)
            if let body = s.data(3), let decoded = AttributedBodyDecoder.decode(body), !decoded.isEmpty {
                text = decoded
            }
            return Raw(rowID: s.int64(0), guid: s.string(1) ?? UUID().uuidString, text: text, isFromMe: s.int64(4) != 0,
                       date: s.int64(5), sender: s.string(6), assocGUID: s.string(7), assocType: Int(s.int64(8)),
                       emoji: s.string(9), hasAttachments: s.int64(10) != 0, isAudio: s.int64(11) != 0,
                       itemType: Int(s.int64(12)), retracted: s.int64(13) != 0,
                       replyTo: s.string(14).flatMap { $0.isEmpty ? nil : $0 },
                       edited: s.int64(15) != 0, error: s.int64(16) != 0, delivered: s.int64(17) != 0,
                       dateRead: s.int64(18))
        }.reversed()
        // A message can be joined to more than one merged row; keep it once.
        var seenGUIDs = Set<String>()
        let raw = rawRows.filter { seenGUIDs.insert($0.guid).inserted }

        let messageRows = raw.filter { $0.itemType == 0 && $0.assocType == 0 }
        let reactionRows = raw.filter { (2000...2006).contains($0.assocType) || (3000...3006).contains($0.assocType) }

        let attachmentMap = try attachments(forMessageRowIDs: messageRows.filter(\.hasAttachments).map(\.rowID))

        // Fold reactions: last action per (target, reactor, kind) wins.
        var reactionState: [String: [String: Reaction]] = [:]
        for r in reactionRows {
            guard let target = r.assocGUID.map(Self.stripAssociatedPrefix) else { continue }
            let adding = r.assocType < 3000
            let kindRaw = adding ? r.assocType : r.assocType - 1000
            guard let kind = ReactionKind(rawValue: kindRaw) else { continue }
            let reactor = r.isFromMe ? "me" : (r.sender ?? "?")
            let key = "\(reactor)|\(kind.rawValue)|\(r.emoji ?? "")"
            if adding {
                // Each person has at most one tapback per message.
                reactionState[target]?.keys.filter { $0.hasPrefix(reactor + "|") }.forEach { reactionState[target]?.removeValue(forKey: $0) }
                reactionState[target, default: [:]][key] = Reaction(kind: kind, fromMe: r.isFromMe, emoji: r.emoji)
            } else {
                reactionState[target]?.removeValue(forKey: key)
            }
        }

        var result: [ChatMessage] = []
        for r in messageRows {
            let atts = attachmentMap[r.rowID] ?? []
            var message = ChatMessage(
                id: r.guid, rowID: r.rowID, text: r.text, isFromMe: r.isFromMe,
                date: Self.date(fromAppleTime: r.date), sender: r.sender, attachments: atts,
                reactions: Array((reactionState[r.guid] ?? [:]).values).sorted { $0.kind.rawValue < $1.kind.rawValue },
                isAudioMessage: r.isAudio)
            message.replyToGUID = r.replyTo
            if r.isFromMe { message.delivery = Self.deliveryState(error: r.error, delivered: r.delivered, dateRead: r.dateRead) }
            // Unsent messages keep their row with the body cleared. Older rows only set
            // `date_edited`, so an edited row with nothing left in it counts as unsent too.
            let empty = message.trimmedText == nil && message.attachments.isEmpty
            if r.retracted || (r.edited && empty) {
                message.text = nil
                message.attachments = []
                message.reactions = []
                message.isUnsent = true
            } else {
                guard !empty else { continue }
                message.isEdited = r.edited
            }
            result.append(message)
        }
        return Array(result.suffix(limit))
    }

    /// For each chat, the ROWID of the newest unread incoming message (if any).
    func newestUnreadRowIDs(chatRowIDs: [Int64]) throws -> [Int64: Int64] {
        guard !chatRowIDs.isEmpty else { return [:] }
        try open()
        var result: [Int64: Int64] = [:]
        try rows("""
            SELECT cmj.chat_id, MAX(m.ROWID)
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id IN (\(placeholders(chatRowIDs.count)))
              AND m.is_from_me = 0 AND m.is_read = 0 AND m.item_type = 0 AND m.associated_message_type = 0
            GROUP BY cmj.chat_id
            """, chatRowIDs.map { .int($0) }) { s in (s.int64(0), s.int64(1)) }
            .forEach { result[$0.0] = $0.1 }
        return result
    }

    private func attachments(forMessageRowIDs ids: [Int64]) throws -> [Int64: [MessageAttachment]] {
        guard !ids.isEmpty else { return [:] }
        var map: [Int64: [MessageAttachment]] = [:]
        try rows("""
            SELECT maj.message_id, a.guid, a.filename, a.mime_type, a.uti, a.transfer_name
            FROM message_attachment_join maj
            JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id IN (\(placeholders(ids.count)))
            ORDER BY maj.ROWID
            """, ids.map { .int($0) }) { s -> (Int64, MessageAttachment) in
            let path = s.string(2).map { ($0 as NSString).expandingTildeInPath }
            let mime = s.string(3), uti = s.string(4), name = s.string(5)
            let kind = AttachmentKind.classify(mimeType: mime, uti: uti, filename: name ?? path)
            return (s.int64(0), MessageAttachment(id: s.string(1) ?? UUID().uuidString,
                                                  url: path.map { URL(fileURLWithPath: $0) },
                                                  mimeType: mime, transferName: name, kind: kind))
        }.forEach { map[$0.0, default: []].append($0.1) }
        // Skip link-preview plugin payloads and other non-user files.
        return map.mapValues { $0.filter { !($0.transferName ?? "").hasSuffix(".pluginPayloadAttachment") } }
    }

    // MARK: - Helpers

    static func deliveryState(error: Bool, delivered: Bool, dateRead: Int64) -> DeliveryState {
        if error { return .notDelivered }
        if dateRead > 0 { return .read(date(fromAppleTime: dateRead)) }
        return delivered ? .delivered : .sent
    }

    static func date(fromAppleTime raw: Int64) -> Date {
        let value = Double(raw)
        let seconds = value > 1_000_000_000_000 ? value / 1_000_000_000 : value
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// `p:0/GUID` → `GUID`, `bp:GUID` → `GUID`.
    static func stripAssociatedPrefix(_ value: String) -> String {
        if let slash = value.firstIndex(of: "/") { return String(value[value.index(after: slash)...]) }
        if value.hasPrefix("bp:") { return String(value.dropFirst(3)) }
        return value
    }

    private func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    enum Bind { case int(Int64), text(String) }

    struct Statement {
        let handle: OpaquePointer
        func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(handle, i) }
        func string(_ i: Int32) -> String? {
            guard sqlite3_column_type(handle, i) != SQLITE_NULL, let c = sqlite3_column_text(handle, i) else { return nil }
            return String(cString: c)
        }
        func data(_ i: Int32) -> Data? {
            guard sqlite3_column_type(handle, i) == SQLITE_BLOB, let bytes = sqlite3_column_blob(handle, i) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, i)))
        }
    }

    @discardableResult
    private func rows<T>(_ sql: String, _ binds: [Bind] = [], map: (Statement) throws -> T) throws -> [T] {
        guard let db else { throw ChatDatabaseError.sqlite("database not open") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ChatDatabaseError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, bind) in binds.enumerated() {
            let position = Int32(index + 1)
            switch bind {
            case .int(let value): sqlite3_bind_int64(stmt, position, value)
            case .text(let value): sqlite3_bind_text(stmt, position, value, -1, transient)
            }
        }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                out.append(try map(Statement(handle: stmt)))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw ChatDatabaseError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
        }
        return out
    }
}
