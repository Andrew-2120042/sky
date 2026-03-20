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
        let startUrl: String?
        let overview: String
        let pages: [Page]?
        let generalHint: String?
        enum CodingKeys: String, CodingKey {
            case name, triggers, overview, pages
            case startUrl = "start_url"
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
    /// Matches by goal keywords OR by URL when the browser is already on a matching site.
    func findHint(for goal: String, currentURL: String? = nil) -> String? {
        let lower = goal.lowercased()
        let urlLower = currentURL?.lowercased() ?? ""

        guard let skill = skills.first(where: { skill in
            let matchesGoal = skill.triggers.allSatisfy { lower.contains($0.lowercased()) }
            let matchesURL = !urlLower.isEmpty
                && skill.triggers.contains(where: { urlLower.contains($0.lowercased()) })
                && skill.triggers.contains(where: {
                    lower.contains($0.lowercased()) || $0 == "order" || $0 == "cancel"
                })
            return matchesGoal || matchesURL
        }) else { return nil }

        print("🎯 [Skills] Matched skill: \(skill.name)")

        // Try URL-aware page match first
        if let url = currentURL, let pages = skill.pages {
            let allPages = pages.map { "[\($0.description)]\n\($0.instructions)" }
            if let matched = pages.first(where: { page in
                guard let pattern = page.urlContains else { return false }
                return url.lowercased().contains(pattern.lowercased())
            }) {
                return "Skill: \(skill.name)\nPage: \(matched.description)\n\(matched.instructions)"
            }
            let pagesText = allPages.joined(separator: "\n\n")
            return "Skill: \(skill.name)\n\(skill.overview)\n\nPage hints:\n\(pagesText)"
        }

        return "Skill: \(skill.name)\n\(skill.generalHint ?? skill.overview)"
    }

    /// Returns a start URL for the given goal — extracts an http URL from the goal text,
    /// or falls back to the skill's start_url / first page domain.
    func findStartUrl(for goal: String, currentURL: String? = nil) -> String? {
        let words = goal.components(separatedBy: .whitespaces)
        if let urlWord = words.first(where: { $0.hasPrefix("http") }) { return urlWord }

        let lower = goal.lowercased()
        let urlLower = currentURL?.lowercased() ?? ""

        for skill in skills {
            let matchesGoal = skill.triggers.allSatisfy { lower.contains($0.lowercased()) }
            let matchesURL = !urlLower.isEmpty
                && skill.triggers.contains(where: { urlLower.contains($0.lowercased()) })
            guard matchesGoal || matchesURL else { continue }
            if let su = skill.startUrl { return su }
            if let urlPattern = skill.pages?.first?.urlContains {
                return urlPattern.hasPrefix("http") ? urlPattern : "https://\(urlPattern)"
            }
        }
        return nil
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
      "triggers": ["amazon", "order"],
      "start_url": "https://www.amazon.in",
      "overview": "Place an order on Amazon India with cash on delivery.",
      "general_hint": "Amazon COD order flow: Buy Now → select Cash on Delivery → Use this payment method → Place your order. Never click Add to Shopping Cart. Never click Cash on Delivery more than once.",
      "pages": [
        {
          "url_contains": "amazon.in/dp/",
          "description": "Amazon product detail page",
          "instructions": "You are on a product page. Click 'Buy Now' button to go directly to checkout. Do NOT click 'Add to Shopping Cart'. Buy Now is faster and goes straight to checkout."
        },
        {
          "url_contains": "amazon.in/gp/cart",
          "description": "Amazon cart page",
          "instructions": "Click the 'Proceed to Buy' yellow button."
        },
        {
          "url_contains": "amazon.in/gp/buy/addressselect",
          "description": "Amazon address selection page",
          "instructions": "Your saved address should already be selected. Click 'Use this address' or 'Deliver to this address' or 'Continue'."
        },
        {
          "url_contains": "amazon.in/gp/buy/payselect",
          "description": "Amazon payment selection page — CRITICAL STEPS",
          "instructions": "EXACT STEPS FOR THIS PAGE: STEP 1 — Find and click 'Cash on Delivery/Pay on Delivery' radio button from PAYMENT OPTIONS to select it. STEP 2 — After selecting it, click 'Use this payment method' button. This is different from 'Continue'. Look specifically for 'Use this payment method'. STEP 3 — You will then land on the order review page. Do NOT click Cash on Delivery again after you have already clicked 'Use this payment method'."
        },
        {
          "url_contains": "amazon.in/gp/buy/spc",
          "description": "Amazon order review page — FINAL STEP",
          "instructions": "You are on the final review page. Click 'Place your order' button to complete the purchase. This is the last step. After clicking you will see order confirmation."
        },
        {
          "url_contains": "amazon.in/gp/buy/thankyou",
          "description": "Amazon order confirmation",
          "instructions": "Order placed successfully. Return done immediately."
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
