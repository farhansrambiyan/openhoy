import AppKit
import Contacts

struct ContactInfo: Sendable {
    let fullName: String
    let firstName: String
    let imageData: Data?
}

/// Maps phone numbers / emails from `chat.db` to names and photos in Contacts.
final class ContactResolver: @unchecked Sendable {
    static let shared = ContactResolver()

    private let store = CNContactStore()
    private let lock = NSLock()
    private var byKey: [String: ContactInfo] = [:]
    private var loaded = false
    private var me: ContactInfo?

    /// The user's own contact card, for their avatar next to sent messages.
    var meInfo: ContactInfo? { lock.withLock { me } }

    var authorizationStatus: CNAuthorizationStatus { CNContactStore.authorizationStatus(for: .contacts) }

    func requestAccess() async -> Bool {
        let status = authorizationStatus
        if status == .authorized { return true }
        if status != .notDetermined, status.rawValue != 4 /* limited */ { return false }
        do { return try await store.requestAccess(for: .contacts) } catch { return false }
    }

    /// Loads every contact's handles into memory. Cheap enough for typical address books.
    func reload() {
        guard authorizationStatus == .authorized || authorizationStatus.rawValue == 4 else { return }
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactThumbnailImageDataKey, CNContactImageDataAvailableKey,
        ] as [CNKeyDescriptor]
        var map: [String: ContactInfo] = [:]
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { contact, _ in
            let full = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let name = !full.isEmpty ? full : (!contact.nickname.isEmpty ? contact.nickname : contact.organizationName)
            guard !name.isEmpty else { return }
            let first = !contact.nickname.isEmpty ? contact.nickname : (!contact.givenName.isEmpty ? contact.givenName : name)
            let info = ContactInfo(fullName: name, firstName: first,
                                   imageData: contact.imageDataAvailable ? contact.thumbnailImageData : nil)
            for phone in contact.phoneNumbers {
                if let key = Self.key(for: phone.value.stringValue) { map[key] = info }
            }
            for email in contact.emailAddresses {
                if let key = Self.key(for: email.value as String) { map[key] = info }
            }
        }
        var meCard: ContactInfo?
        if let contact = try? store.unifiedMeContactWithKeys(toFetch: keys) {
            let full = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            meCard = ContactInfo(fullName: full.isEmpty ? "Me" : full, firstName: contact.givenName.isEmpty ? "Me" : contact.givenName,
                                 imageData: contact.imageDataAvailable ? contact.thumbnailImageData : nil)
        }
        lock.withLock {
            byKey = map
            me = meCard
            loaded = true
        }
    }

    func info(for handle: String) -> ContactInfo? {
        guard let key = Self.key(for: handle) else { return nil }
        return lock.withLock { byKey[key] }
    }

    /// Emails are matched case-insensitively; phone numbers on their last 9 digits so
    /// `+1 (555) 123-4567` and `5551234567` resolve to the same person.
    static func key(for handle: String) -> String? {
        let trimmed = handle.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("@") { return "e:" + trimmed.lowercased() }
        let digits = trimmed.filter(\.isNumber)
        guard digits.count >= 5 else { return nil }
        return "p:" + String(digits.suffix(9))
    }

    /// `+15551234567` → `+1 555 123 4567`-ish, for handles without a contact.
    static func prettyHandle(_ handle: String) -> String {
        guard !handle.contains("@") else { return handle }
        let digits = handle.filter(\.isNumber)
        guard digits.count == 11, digits.hasPrefix("1") else { return handle }
        let d = Array(digits)
        return "+1 (\(String(d[1...3]))) \(String(d[4...6]))-\(String(d[7...10]))"
    }
}
