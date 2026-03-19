import Foundation

/// Loads skills from JSON files in ~/Library/Application Support/Sky/skills/
/// and matches them to user goals for URL-aware prompt hints.
final class SkillsService: Sendable {

    static let shared = SkillsService()
    private init() {}

    struct Page: Codable {
        let urlContains: String?
        let description: String
        let instructions: String
        enum CodingKeys: String, CodingKey {
            case urlContains = "url_contains"
            case description, instructions
        }
    }

    struct Skill: Codable {
        let name: String
        let triggers: [String]
        let overview: String
        let pages: [Page]?
        let generalHint: String?
        enum CodingKeys: String, CodingKey {
            case name, triggers, overview, pages
            case generalHint = "general_hint"
        }
    }

    // Loaded once at init from disk.
    private let skills: [Skill] = {
        guard let dir = SkillsService.skillsDirectory else { return [] }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "json" }) else { return [] }

        return files.compactMap { url -> Skill? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Skill.self, from: data)
        }
    }()

    // MARK: - Lookup

    /// Returns a hint string for the given goal and optional current URL.
    /// Prefers a page-specific hint when the URL matches; falls back to generalHint.
    func findHint(for goal: String, currentURL: String? = nil) -> String? {
        let lowerGoal = goal.lowercased()
        guard let skill = skills.first(where: { skill in
            skill.triggers.contains(where: { lowerGoal.contains($0.lowercased()) })
        }) else { return nil }

        // Try URL-aware page match first
        if let url = currentURL, let pages = skill.pages {
            let allPages = pages.map { "[\($0.description)]\n\($0.instructions)" }
            if let matched = pages.first(where: { page in
                guard let pattern = page.urlContains else { return false }
                return url.lowercased().contains(pattern.lowercased())
            }) {
                return "Skill: \(skill.name)\nPage: \(matched.description)\n\(matched.instructions)"
            }
            // URL didn't match any page — return overview + all page hints
            let pagesText = allPages.joined(separator: "\n\n")
            return "Skill: \(skill.name)\n\(skill.overview)\n\nPage hints:\n\(pagesText)"
        }

        // No URL or no pages — use generalHint or overview
        return "Skill: \(skill.name)\n\(skill.generalHint ?? skill.overview)"
    }

    // MARK: - Seeding

    /// Seeds the skills directory with built-in JSON files if it is empty.
    /// Idempotent — skips files that already exist.
    func seedDefaultSkillsIfNeeded() {
        guard let dir = SkillsService.skillsDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let defaults: [(name: String, content: String)] = [
            ("flipkart_order.json", flipkartOrderSkill),
            ("flipkart_cancel.json", flipkartCancelSkill),
            ("amazon_order.json", amazonOrderSkill),
            ("amazon_cancel.json", amazonCancelSkill)
        ]

        for item in defaults {
            let fileURL = dir.appendingPathComponent(item.name)
            guard !FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            try? item.content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Directory

    private static var skillsDirectory: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Sky/skills")
    }

    // MARK: - Default skill JSON strings

    private let flipkartOrderSkill = """
    {
      "name": "flipkart_order",
      "triggers": ["flipkart", "order on flipkart", "buy on flipkart"],
      "overview": "Placing an order on Flipkart. Exact flow: Buy at price → Continue → select payment → Place Order → Confirm order.",
      "general_hint": "EXACT FLIPKART ORDER FLOW: STEP 1: Click 'Buy at ₹X' button on the product page. STEP 2: On the order summary page, click 'Continue'. STEP 3: Select the payment method (e.g. 'Cash on Delivery'). STEP 4: Click 'Place Order'. STEP 5: A confirmation dialog appears — click 'Confirm order'. DONE when order confirmation appears. TRAPS TO AVOID: Do NOT click 'Cash on Delivery' on the product page — it opens an info panel, not checkout. Do NOT call done after Place Order — you must still click 'Confirm order' in the dialog.",
      "pages": [
        {
          "url_contains": "flipkart.com",
          "description": "Flipkart product or order page",
          "instructions": "EXACT FLIPKART ORDER FLOW: STEP 1: Click 'Buy at ₹X' button on the product page. STEP 2: On the order summary page, click 'Continue'. STEP 3: Select the payment method (e.g. 'Cash on Delivery'). STEP 4: Click 'Place Order'. STEP 5: A confirmation dialog appears — click 'Confirm order'. DONE only when order confirmation appears with an order ID. Never call done after just clicking Place Order."
        }
      ]
    }
    """

    private let flipkartCancelSkill = """
    {
      "name": "flipkart_cancel",
      "triggers": ["cancel flipkart", "cancel order flipkart", "flipkart cancel"],
      "overview": "Cancelling an order on Flipkart via My Orders.",
      "general_hint": "Navigate to My Orders, find the order, and click Cancel.",
      "pages": [
        {
          "url_contains": "flipkart.com/account/orders",
          "description": "Flipkart My Orders page",
          "instructions": "Find the order to cancel. Click on it to open order details, then click Cancel. Confirm cancellation when prompted."
        }
      ]
    }
    """

    private let amazonOrderSkill = """
    {
      "name": "amazon_order",
      "triggers": ["amazon", "order on amazon", "buy on amazon"],
      "overview": "Placing an order on Amazon using Buy Now. Exact flow: Buy Now → checkout → select payment → Use this payment method → Place your order.",
      "general_hint": "On Amazon, always use Buy Now (not Add to Cart) when the goal is to place an order. Done only when order confirmation screen appears.",
      "pages": [
        {
          "url_contains": "amazon.in",
          "description": "Amazon India product page",
          "instructions": "EXACT ORDER FLOW — follow strictly: STEP 1: Click 'Buy Now' (NOT 'Add to Cart'). Buy Now goes straight to secure checkout. STEP 2: On the secure checkout page, find and click 'Cash on Delivery' (or the required payment method) — it will be in the elements list. STEP 3: Click 'Use this payment method' — this button MUST be clicked after selecting a payment method. STEP 4: On the final review page, click 'Place your order'. DONE only when you see order confirmation with an order ID. NEVER call done after just selecting a payment method."
        },
        {
          "url_contains": "amazon.com",
          "description": "Amazon US product page",
          "instructions": "EXACT ORDER FLOW: STEP 1: Click 'Buy Now'. STEP 2: On checkout, scroll down to see all options. STEP 3: Select the payment method. STEP 4: Click 'Use this payment method'. STEP 5: Click 'Place your order'. Done only on order confirmation screen."
        }
      ]
    }
    """

    private let amazonCancelSkill = """
    {
      "name": "amazon_cancel",
      "triggers": ["cancel amazon", "cancel order amazon", "amazon cancel", "cancel my order"],
      "overview": "Cancelling an Amazon order. Exact flow: Returns & Orders → View or edit order → Cancel items → select item → Request cancellation.",
      "general_hint": "EXACT CANCELLATION FLOW: STEP 1: Click 'Returns & Orders' in the nav bar. STEP 2: You will see order cards each with options like Track package, View or edit order, Ask Product Question. If there are multiple orders ask the user which one to cancel. STEP 3: Click 'View or edit order' on the chosen order. STEP 4: On the order details page click 'Cancel items'. STEP 5: On the cancel items page, click 'Select all' to select the item — this is more reliable than the individual checkbox. STEP 6: Click 'Request cancellation'. Only these two clicks on this page. Do not click product names or links. Done when cancellation confirmation appears.",
      "pages": [
        {
          "url_contains": "amazon.in",
          "description": "Amazon India — any page",
          "instructions": "EXACT CANCELLATION FLOW: STEP 1: Click 'Returns & Orders' in the top nav bar. STEP 2: You will see order cards. Each card has options: Track package, View or edit order, Ask Product Question, Write a product review. If there is only one order proceed. If there are multiple orders, use askUser to ask the user which order to cancel (describe each order briefly). STEP 3: Click 'View or edit order' on the chosen order. STEP 4: On the order details page, find and click 'Cancel items'. STEP 5: On the cancellation page, select the item checkbox or 'Select all', then click 'Request cancellation'. DONE when you see a cancellation confirmation message."
        },
        {
          "url_contains": "amazon.in/gp/buy/itemcancel",
          "description": "Amazon cancel items page",
          "instructions": "You are on the Cancel Items page. STEP 1: Look for a checkbox element — it may be labeled with the product name, 'Select all', or just be an AXCheckBox. Click it to select the item. STEP 2: After selecting, click 'Request cancellation'. That is all — do not do anything else. DONE when cancellation confirmation appears."
        },
        {
          "url_contains": "amazon.in/gp/css/order-details",
          "description": "Amazon order details page",
          "instructions": "You are on the order details page. Find and click 'Cancel items' to proceed to cancellation."
        },
        {
          "url_contains": "amazon.com",
          "description": "Amazon US — any page",
          "instructions": "EXACT CANCELLATION FLOW: STEP 1: Click 'Returns & Orders' in the top nav. STEP 2: Find the order cards. If multiple orders ask the user which to cancel. STEP 3: Click 'View or edit order'. STEP 4: Click 'Cancel items'. STEP 5: Select item and click 'Request cancellation'. Done on confirmation."
        }
      ]
    }
    """
}
