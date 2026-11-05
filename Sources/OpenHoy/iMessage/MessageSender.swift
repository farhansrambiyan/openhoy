import Foundation

enum MessageSenderError: LocalizedError {
    case script(String)

    var errorDescription: String? {
        switch self {
        case .script(let message):
            if message.contains("-1743") || message.localizedCaseInsensitiveContains("not authorized") {
                return "OpenHoy isn't allowed to control Messages. Enable it in System Settings › Privacy & Security › Automation."
            }
            return message
        }
    }
}

/// Sends through Messages.app with AppleScript, so everything goes out over the
/// user's own iMessage account — no servers, no sign-up.
enum MessageSender {
    enum Payload {
        case text(String)
        case file(URL)
    }

    static var isDryRun: Bool { ProcessInfo.processInfo.environment["OPENHOY_DRY_RUN"] == "1" }

    /// The chat guid is the most reliable target (works for groups); the buddy fallback
    /// covers 1:1 chats whose guid Messages doesn't expose to AppleScript.
    private static let script = """
    on run argv
        set chatGuid to item 1 of argv
        set handleId to item 2 of argv
        set payloadKind to item 3 of argv
        set payloadValue to item 4 of argv
        if payloadKind is "file" then
            set thePayload to (POSIX file payloadValue)
        else
            set thePayload to payloadValue
        end if
        tell application "Messages"
            try
                send thePayload to chat id chatGuid
                return "ok"
            on error errMsg number errNum
                if handleId is "" then error errMsg number errNum
            end try
            try
                set targetService to 1st account whose service type = iMessage
                send thePayload to participant handleId of targetService
                return "ok"
            on error
                set targetService to 1st service whose service type = iMessage
                send thePayload to buddy handleId of targetService
                return "ok"
            end try
        end tell
    end run
    """

    static func send(_ payload: Payload, to chat: ChatSummary) async throws {
        let handle = chat.isGroup ? "" : chat.primaryHandle
        switch payload {
        case .text(let text):
            try await run(arguments: [chat.sendGUID, handle, "text", text])
        case .file(let url):
            let staged = try stage(url)
            try await run(arguments: [chat.sendGUID, handle, "file", staged.path])
        }
    }

    /// Asks Messages for something harmless so macOS shows the Automation prompt.
    static func requestAutomationAccess() async throws {
        _ = try await runRaw(source: "tell application \"Messages\" to get name", arguments: [])
    }

    // MARK: - Internals

    /// Messages refuses AppleScript attachments from arbitrary paths on recent macOS
    /// releases; files under ~/Pictures are accepted. We stage a copy there (each in its
    /// own folder so the original filename is preserved) and prune old copies later.
    static var outboxURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/OpenHoy Outbox", isDirectory: true)
    }

    private static func stage(_ url: URL) throws -> URL {
        let folder = outboxURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    static func pruneOutbox(olderThan age: TimeInterval = 24 * 3600) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: outboxURL, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for item in items {
            let created = (try? item.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff { try? fm.removeItem(at: item) }
        }
    }

    private static func run(arguments: [String]) async throws {
        if isDryRun {
            NSLog("[OpenHoy dry-run] send %@", arguments.description)
            try await Task.sleep(nanoseconds: 400_000_000)
            return
        }
        _ = try await runRaw(source: script, arguments: arguments)
    }

    private static func runRaw(source: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-"] + arguments
                let input = Pipe(), output = Pipe(), errors = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                    input.fileHandleForWriting.write(Data(source.utf8))
                    try? input.fileHandleForWriting.close()
                    let out = output.fileHandleForReading.readDataToEndOfFile()
                    let err = errors.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: String(decoding: out, as: UTF8.self))
                    } else {
                        let message = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(throwing: MessageSenderError.script(message.isEmpty ? "Messages couldn't send this." : message))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
