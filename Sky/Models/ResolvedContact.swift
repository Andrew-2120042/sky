/// A contact resolved from the user's address book, ready for display and action use.
struct ResolvedContact: Identifiable, Equatable {
    /// The full display name of the contact.
    let displayName: String
    /// The primary email address, if available.
    let email: String?
    /// The primary phone number, if available.
    let phone: String?
    /// The CNContact identifier used as the stable unique ID.
    let cnIdentifier: String

    /// Conforms to `Identifiable`; backed by `cnIdentifier`.
    var id: String { cnIdentifier }

    /// Returns the email if present, the phone number if present, or a fallback string.
    var subtitle: String {
        if let email = email { return email }
        if let phone = phone { return phone }
        return "No contact details"
    }
}
