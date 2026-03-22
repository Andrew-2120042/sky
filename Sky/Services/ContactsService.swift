@preconcurrency import Contacts

/// Loads all CNContacts into memory and provides fast fuzzy-name search.
final class ContactsService: @unchecked Sendable {

    /// Shared singleton; safe to call from any context.
    static let shared = ContactsService()

    private var contacts: [ResolvedContact] = []
    private let serialQueue = DispatchQueue(label: "com.andrewwilson.Sky.contacts", qos: .utility)

    private init() {}

    // MARK: - Load

    /// Fetches all contacts from CNContactStore and caches them in memory.
    /// Fire-and-forget: returns immediately and populates the cache in the background.
    /// CNContactStore.enumerateContacts is a blocking call that internally uses a
    /// background-QoS thread; awaiting it from a higher-priority task causes a priority
    /// inversion that Xcode's Thread Performance Checker flags as a hang risk.
    func load() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }

        // CNContactNoteKey is intentionally excluded — reading notes requires a special
        // Apple entitlement and logs "Attempt to read notes by an unentitled app" otherwise.
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactIdentifierKey as CNKeyDescriptor
        ]

        // Run entirely on serialQueue — no thread blocks waiting for this work,
        // so no priority inversion is possible.
        serialQueue.async {
            let request = CNContactFetchRequest(keysToFetch: keys)
            let store = CNContactStore()
            var result: [ResolvedContact] = []
            do {
                try store.enumerateContacts(with: request) { cnContact, _ in
                    let displayName = [cnContact.givenName, cnContact.familyName]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    let email = cnContact.emailAddresses.first.map { $0.value as String }
                    let phone = cnContact.phoneNumbers.first.map { $0.value.stringValue }
                    result.append(ResolvedContact(
                        displayName: displayName,
                        email: email,
                        phone: phone,
                        cnIdentifier: cnContact.identifier
                    ))
                }
            } catch {
                LoggingService.shared.log(error: error, context: "ContactsService.load")
            }
            self.contacts = result   // already on serialQueue — no inner async needed
        }
    }

    // MARK: - Search

    /// Returns up to 5 contacts whose names best match `query`, scored by relevance.
    func search(query: String) -> [ResolvedContact] {
        let lowered = query.lowercased()
        return serialQueue.sync {
            let scored: [(contact: ResolvedContact, score: Int)] = contacts.compactMap { contact in
                let name = contact.displayName.lowercased()
                if name == lowered {
                    return (contact, 3)
                } else if name.hasPrefix(lowered) {
                    return (contact, 2)
                } else if name.contains(lowered) {
                    return (contact, 1)
                }
                return nil
            }
            return scored
                .sorted { $0.score > $1.score }
                .prefix(5)
                .map(\.contact)
        }
    }

    // MARK: - Resolve

    /// Returns the first contact whose name, email, or phone matches `nameOrEmail`.
    /// Checks MemoryService aliases first so "mum" can resolve to "Jane Wilson".
    func resolve(nameOrEmail: String) -> ResolvedContact? {
        let lookupName = MemoryService.shared.resolveAlias(nameOrEmail) ?? nameOrEmail
        let lowered = lookupName.lowercased()
        return serialQueue.sync {
            contacts.first { contact in
                contact.displayName.lowercased().contains(lowered)
                || (contact.email?.lowercased().contains(lowered) == true)
                || (contact.phone?.lowercased().contains(lowered) == true)
            }
        }
    }

    /// Returns ALL contacts whose display name contains `name` (case-insensitive).
    /// Used for ambiguity detection when multiple contacts share a name.
    /// Also resolves aliases before searching.
    func findAll(name: String) -> [ResolvedContact] {
        let lookupName = MemoryService.shared.resolveAlias(name) ?? name
        let lowered = lookupName.lowercased()
        return serialQueue.sync {
            contacts.filter { $0.displayName.lowercased().contains(lowered) }
        }
    }
}
