import Foundation
import AppKit

/// All magic strings and constants used throughout the app.
enum Constants {

    // MARK: - App
    enum App {
        static let name = "Sky"
        static let bundleIdentifier = "com.andrewwilson.Sky"
        static let supportDirectoryName = "Sky"
    }

    // MARK: - Config
    enum Config {
        static let fileName = "config.json"
        static let defaultAPIKey = ""
        static let defaultProvider = "anthropic"
    }

    // MARK: - Database
    enum Database {
        static let fileName = "scheduler.db"

        enum Table {
            static let scheduledActions = "scheduled_actions"
        }

        enum Column {
            static let id = "id"
            static let actionType = "action_type"
            static let paramsJson = "params_json"
            static let displaySummary = "display_summary"
            static let runAt = "run_at"
            static let recurrence = "recurrence"
            static let recurrenceDetail = "recurrence_detail"
            static let lastRunAt = "last_run_at"
            static let nextRunAt = "next_run_at"
            static let isActive = "is_active"
            static let createdAt = "created_at"
        }
    }

    // MARK: - Anthropic API
    enum API {
        static let anthropicBaseURL = "https://api.anthropic.com/v1/messages"
        static let anthropicVersion = "2023-06-01"
        static let model = "claude-sonnet-4-20250514"
        static let maxTokens = 1024
    }

    // MARK: - OpenAI API
    enum OpenAI {
        static let baseURL = "https://api.openai.com/v1/chat/completions"
        static let model = "gpt-4o"
    }

    // MARK: - Panel
    enum Panel {
        static let width: CGFloat = 640
        static let inputHeight: CGFloat = 56
        static let cardHeight: CGFloat = 80
        static let cornerRadius: CGFloat = 14
        static let topOffsetRatio: CGFloat = 0.35
        static let fadeInDuration: TimeInterval = 0.15
        static let slideDownDuration: TimeInterval = 0.2
        static let inputFontSize: CGFloat = 16
        static let summaryFontSize: CGFloat = 14
        static let placeholder = "Ask anything or give a command..."
        static let apiKeyPrompt = "Enter your API key to get started..."
        static let setupHeight: CGFloat = 170
        /// Max visible height for the inline answer area (scrolls if text is taller).
        static let answerHeight: CGFloat = 200
    }

    // MARK: - Hotkey
    enum Hotkey {
        /// Default hotkey: Option + Space
        static let defaultKeyCode: UInt16 = 49
        /// CGEventFlags.maskAlternate.rawValue — must match CGEvent flag bits, NOT NSEventModifierFlags
        static let defaultModifiers: UInt64 = 0x00080000
    }

    // MARK: - Menu Bar
    enum MenuBar {
        static let symbolName = "sparkle"
        static let openTitle = "Open Sky"
        static let scheduledActionsTitle = "Scheduled Actions"
        static let recentActionsTitle = "Recent Actions"
        static let workflowsTitle = "Workflows"
        static let memoryTitle = "Memory"
        static let settingsTitle = "Settings…"
        static let quitTitle = "Quit"
    }

    // MARK: - Notifications
    enum Notification {
        static let meetingCategory  = "MEETING_JOIN"
        static let joinAction       = "JOIN_NOW"
        static let meetingURLKey    = "meeting_url"
        static let meetingIDPrefix  = "sky-meeting-"
    }

    // MARK: - Scheduler
    enum Scheduler {
        static let tickInterval: TimeInterval = 60
    }

    // MARK: - AppleScript templates (%@ = positional substitution via String(format:))
    enum AppleScript {
        /// Send an email via Mail.app. Args: subject, body, recipient email.
        static let sendMail = """
            tell application "Mail"
                set newMsg to make new outgoing message with properties {subject:"%@", content:"%@", visible:false}
                tell newMsg
                    make new to recipient with properties {address:"%@"}
                end tell
                send newMsg
            end tell
            """

        /// Send an iMessage via Messages.app. Args: body, recipient (name or email).
        static let sendMessage = """
            tell application "Messages"
                set targetService to first service whose service type = iMessage
                set targetBuddy to buddy "%@" of targetService
                send "%@" to targetBuddy
            end tell
            """

        /// Create a note in Notes.app. Args: title, body.
        static let createNote = """
            tell application "Notes"
                tell account "iCloud"
                    make new note with properties {name:"%@", body:"%@"}
                end tell
            end tell
            """

        /// Returns "<URL>\n<title>" for the frontmost Safari tab.
        static let safariContext = """
            tell application "Safari"
                set theURL to URL of current tab of front window
                set theTitle to name of current tab of front window
                return theURL & "\n" & theTitle
            end tell
            """

        /// Returns "<URL>\n<title>" for the active Chrome tab.
        static let chromeContext = """
            tell application "Google Chrome"
                set theURL to URL of active tab of front window
                set theTitle to title of active tab of front window
                return theURL & "\n" & theTitle
            end tell
            """

        /// Returns "<URL>\n<title>" for the active Arc tab.
        static let arcContext = """
            tell application "Arc"
                set theURL to URL of active tab of front window
                set theTitle to title of active tab of front window
                return theURL & "\n" & theTitle
            end tell
            """

        /// Play/pause the current media player (Spotify or Apple Music).
        static let mediaPlayPause = """
            if application "Spotify" is running then
                tell application "Spotify" to playpause
            else if application "Music" is running then
                tell application "Music" to playpause
            end if
            """

        /// Skip to next track in the current media player.
        static let mediaNextTrack = """
            if application "Spotify" is running then
                tell application "Spotify" to next track
            else if application "Music" is running then
                tell application "Music" to next track
            end if
            """

        /// Returns "Track Name by Artist" from the current media player, or "Nothing playing".
        static let mediaGetInfo = """
            if application "Spotify" is running then
                tell application "Spotify"
                    return (name of current track) & " by " & (artist of current track)
                end tell
            else if application "Music" is running then
                tell application "Music"
                    return (name of current track) & " by " & (artist of current track)
                end tell
            end if
            return "Nothing playing"
            """
    }

    // MARK: - Success messages
    enum Success {
        static let reminderSet    = "Reminder set ✓"
        static let eventCreated   = "Event created ✓"
        static let mailSent       = "Mail sent ✓"
        static let messageSent    = "Message sent ✓"
        static let noteSaved      = "Note saved ✓"
        static let opening        = "Opening… ✓"
        static let searching      = "Searching… ✓"
    }

    // MARK: - App Aliases — maps casual names / common spellings to bundle IDs
    // MARK: - Notification Names
    enum NotificationName {
        static let hidePanel                = Foundation.Notification.Name("sky.panel.hide")
        static let skyShowPanel             = Foundation.Notification.Name("sky.panel.show")
        static let skyBrowserConfirmation   = Foundation.Notification.Name("sky.browser.confirmation")
    }

    static let appAliases: [String: String] = [
        "settings":              "com.apple.systempreferences",
        "system settings":       "com.apple.systempreferences",
        "system preferences":    "com.apple.systempreferences",
        "safari":                "com.apple.Safari",
        "chrome":                "com.google.Chrome",
        "google chrome":         "com.google.Chrome",
        "firefox":               "org.mozilla.firefox",
        "mail":                  "com.apple.mail",
        "messages":              "com.apple.MobileSMS",
        "facetime":              "com.apple.FaceTime",
        "calendar":              "com.apple.iCal",
        "notes":                 "com.apple.Notes",
        "reminders":             "com.apple.reminders",
        "finder":                "com.apple.finder",
        "terminal":              "com.apple.Terminal",
        "xcode":                 "com.apple.dt.Xcode",
        "vs code":               "com.microsoft.VSCode",
        "vscode":                "com.microsoft.VSCode",
        "visual studio code":    "com.microsoft.VSCode",
        "slack":                 "com.tinyspeck.slackmacgap",
        "spotify":               "com.spotify.client",
        "zoom":                  "us.zoom.xos",
        "figma":                 "com.figma.Desktop",
        "notion":                "notion.id",
        "arc":                   "company.thebrowser.Browser",
        "brave":                 "com.brave.Browser",
        "whatsapp":              "net.whatsapp.WhatsApp",
        "telegram":              "ru.keepcoder.Telegram",
        "discord":               "com.hnc.Discord",
        "photos":                "com.apple.Photos",
        "music":                 "com.apple.Music",
        "maps":                  "com.apple.Maps",
        "calculator":            "com.apple.calculator",
        "preview":               "com.apple.Preview",
        "activity monitor":      "com.apple.ActivityMonitor",
        "cursor":                "com.todesktop.230313mzl4w4u92",
        "warp":                  "dev.warp.Warp-Stable",
        "linear":                "com.linear",
        "things":                "com.culturedcode.ThingsMac"
    ]

    // MARK: - Action Types
    enum ActionType {
        static let sendMail = "send_mail"
        static let scheduleMail = "schedule_mail"
        static let createEvent = "create_event"
        static let joinMeeting = "join_meeting"
        static let setReminder = "set_reminder"
        static let sendMessage = "send_message"
        static let makeCall = "make_call"
        static let findFile = "find_file"
        static let openApp = "open_app"
        static let webSearch = "web_search"
        static let clipboardHistory = "clipboard_history"
        static let windowManagement = "window_management"
        static let setFocus = "set_focus"
        static let quickNote = "quick_note"
        static let mediaPlayPause    = "media_play_pause"
        static let mediaNextTrack    = "media_next_track"
        static let mediaGetInfo      = "media_get_info"
        static let showLog           = "show_log"
        static let answer            = "answer"
        static let readCalendarToday = "read_calendar_today"
        static let createWorkflow    = "create_workflow"
        static let saveMemory        = "save_memory"
        static let showMemory        = "show_memory"
        static let computerUse       = "computer_use"
        static let executeFlow       = "execute_flow"
        static let mediaPlaySpecific = "media_play_specific"
        static let whatDoYouSee      = "what_do_you_see"
        static let resolvePermission = "resolve_permission"
        static let testBrowser       = "test_browser"
        static let browserLogin      = "browser_login"
        static let browserLoginDone  = "browser_login_done"
        static let unknown = "unknown"
    }

    // MARK: - Flow (multi-step UI automation)
    enum Flow {
        static let decisionRules = """
        COMPLETION AND FAILURE RULES:

        For "done" — return done IMMEDIATELY when you see proof. Do NOT take any more actions:
        - Google Meet joined: if "Leave call" is visible → return done RIGHT NOW. "Leave call" means you are ALREADY inside the meeting. DO NOT click it. DO NOT click anything else. Just return done.
        - Zoom joined (browser): if "Leave Meeting" is visible → return done RIGHT NOW. DO NOT click it. You are already in the meeting.
        - Zoom joined (browser): if BOTH "Mute" AND "Start Video" are visible together → you are inside the Zoom meeting → return done. Do not click anything.
        - Zoom joined (browser): if "Leave" button is visible alongside "Mute" → return done immediately.
        - Also done if you see "Turn off camera" or "Stop video" alongside "Mute" (inside active call controls)
        - Order placed: screen shows "Order confirmed", "Order Placed", "Thank you for your order", or "Order number" → return done
        - Form submitted: screen shows a success/confirmation message → return done
        - Never return "done" immediately after clicking a button — wait one step to observe the result first
        - NEVER call done just because you selected a payment method or clicked a payment option — that is NOT order completion. Done only when the confirmation screen appears.
        - A "Payments Options" panel or popup showing payment info (COD, UPI etc.) = you are still on the product page. Close it (click X) and find the real checkout button.
        - On a cancellation page with a "Request cancellation" button: STEP 1 — click target "select all" to select the item (this is more reliable than finding the individual checkbox). STEP 2 — click "Request cancellation". Only these two actions. Do not click anything else on this page. Do not click product names or links.
        - CRITICAL: "Leave call" = you are IN the meeting = done. Never click Leave call.
        - CRITICAL: "Leave Meeting" = you are IN the Zoom meeting = done. Never click Leave Meeting.

        ZOOM BROWSER NAVIGATION RULES — CRITICAL:
        - If you see "Join from browser" AND you have NOT clicked it yet → click "Join from browser"
        - If you just clicked "Join from browser" (it appears in completed steps) → DO NOT click it again. Wait for the meeting to load.
        - NEVER click an element labeled just "Zoom" — this is a tab/link that navigates AWAY from the meeting page and breaks the flow.
        - If you see a permission dialog (Allow/Don't Allow) after clicking "Join from browser" → handle it as a PERMISSION dialog (askUser with PERMISSION: prefix)
        - After a permission dialog is handled, DO NOT click "Zoom" or "Join from browser" again. Wait 2 seconds for the meeting to fully load, then check if you are in the meeting.

        For "failed" — be specific about WHY:
        - If a required element doesn't exist: "Could not find [specific element] on this page"
        - If you clicked the same element twice with no change: use "retry" action instead of "failed" (up to 2 retries)
        - If you see an error message on screen: "Page shows error: [error text]"
        - If step 8 or higher: "Could not complete [goal] in expected steps — last action: [last action taken]"
        - Never return a vague message — always say specifically what you tried and what you saw

        For "retry" — use when you clicked something but the screen looks unchanged:
        {"action": "retry", "target": "element to try again", "reasoning": "why retrying"}

        PERMISSION DIALOGS — HIGHEST PRIORITY:
        If you see ANY of these button combinations on screen:
        - "Allow" + "Don't Allow"
        - "Allow" + "Never for This Website" + "Don't Allow"
        - "OK" + "Cancel" with text mentioning camera/microphone/location/contacts
        This is a SYSTEM PERMISSION DIALOG. You MUST return:
        {"action": "askUser", "question": "PERMISSION: [site] wants [resource] access. Choose: Allow / Never for This Website / Don't Allow", "reasoning": "permission dialog requires user choice"}
        Do NOT click anything in a permission dialog without asking the user first.

        ELEMENT SELECTION RULES:
        - ALWAYS prefer action buttons over navigation elements
        - Action buttons: "Place Order", "Buy Now", "Checkout", "Confirm", "Submit", "Pay", "Continue" — these move the flow forward
        - Navigation elements: Cart icons, Menu items, Account links, Search bars — only click these if no action button exists
        - If you see "Place Order" or "Buy Now" or "Checkout" anywhere — click that FIRST, not the cart
        - A button with a price next to it (like "Place Order ₹287") is almost always the correct action
        - Never click the same element you clicked in the previous step unless explicitly retrying

        CHECKOUT FLOW ORDER — follow this sequence strictly:
        1. If you see "Buy Now" or "Buy this now" → click it FIRST (fastest path to checkout)
        2. If no "Buy Now", look for "Place Order" → click it
        3. If no "Place Order", look for "Proceed to checkout" or "Checkout" → click it
        4. Only go to Cart if none of the above exist AND you haven't added to cart yet
        5. NEVER click "Cart" or "Cart X Cart" if you already see "Place Order" or "Buy Now" on screen
        6. "Cash on Delivery" shown as a badge/icon on a product page is NOT a clickable payment button — ignore it
        7. Payment method selection only appears AFTER you click Buy Now or Place Order

        NAVIGATION DEAD ENDS — never click these unless explicitly required:
        - "Cart X Cart" (where X is a number) — this is a nav icon, not a checkout button
        - Search bars
        - Account/login links (unless the page is asking you to log in)
        - Site logos
        - "More" dropdown menus
        - Tab titles or browser tabs
        - "Next page" or "Previous page" — these are browser navigation arrows, not page actions
        - Product name links on a cancellation or order page — clicking these navigates away

        PAGE LOADING:
        - If element count is very low (under 15 elements) the page is still loading — return wait action
        - If you see a loading spinner or skeleton elements — return wait action
        - Never click on a navigation element just because the page has few elements

        MULTI-PART GOALS: Complete ALL parts of the goal before returning done. If goal says "join with camera off", you must BOTH turn off camera AND click join — do not skip either part.
        CAMERA/MIC: If the goal mentions camera or mic state, actively find and click the camera/mic toggle BEFORE clicking join. Do not assume they are already in the right state.
        For camera off: look for "Turn off camera", "Stop video", camera icon button
        For mic off: look for "Mute", "Turn off mic", microphone icon button
        For meeting joins: after handling camera/mic, click "Join", "Join Now", "Ask to join", or "Join meeting"
        Only click elements that actually exist in the CURRENT SCREEN ELEMENTS list.
        Be decisive — pick the most obvious next step toward the COMPLETE goal.
        """
    }

    // MARK: - System Prompt
    // MARK: - Computer Use
    enum ComputerUse {
        static let screenRecordingKey = "NSScreenRecordingUsageDescription"
    }

    static let systemPrompt = """
    You are an intent parser for a macOS AI assistant called Sky. Your job is to analyze natural language commands and return a structured JSON object describing the user's intent.

    IMPORTANT: Respond ONLY with a valid JSON object. No prose, no markdown, no code blocks, no backticks. Just raw JSON.

    The user message always begins with a [Context:] block showing the exact current date, time, and timezone. You MUST resolve all relative dates and times using this context. Never use a default or guessed date.

    The user message may also include [Clipboard:], [Active app:], [Selected text:], and [Browser:] context blocks. Use all of them to resolve pronouns like 'this', 'it', 'the link', 'what I copied', 'this page', 'review this'. For example if the user says 'send this to @andrew' and [Clipboard: https://zoom.us/j/123] is present, use that URL as the message body.

    When a [Browser:] block is present with a URL and title, treat the URL as the current page the user is referring to when they say "this", "this page", or "here". Use the title to understand what the page is about. For "remind me to review this" create a reminder with the page title as the subject and the URL in the body/notes field. For "send this page to @john" use the URL as the message body.

    The user message may also include [Memory — Aliases:], [Memory — Facts:], and [Memory — Preferences:] blocks. These contain things the user has explicitly told Sky to remember. Use aliases to resolve names (e.g. if "mum → Jane Wilson" is present, treat "mum" as "Jane Wilson"). Use facts and preferences to personalise responses.

    If the user's command involves multiple actions, return them all in the actions array in the order they should execute. If it is a single action, still return it wrapped in the actions array with one element.

    The JSON must follow this exact schema:
    {
      "actions": [
        {
          "action": "<action_type>",
          "params": {
            "to": "<contact name or email if mentioned, null if not>",
            "body": "<message body if applicable, null if not>",
            "subject": "<email subject if applicable, null if not>",
            "datetime": "<ISO8601 string with timezone offset if a time is mentioned, null if not>",
            "recurrence": "<none | daily | weekly | monthly | custom>",
            "recurrence_detail": "<natural language recurrence detail if custom, null if not>",
            "url": "<URL or meeting link if mentioned, null if not>",
            "query": "<search query or file name for search/find actions, null if not>",
            "app_name": "<app name for open_app action, null if not>",
            "duration_minutes": <integer minutes for focus sessions, null if not>,
            "confidence": "<high | medium | low>",
            "memory_category": "<alias | fact | preference | null>",
            "memory_key": "<alias key for save_memory category alias, e.g. 'mum', null if not>",
            "memory_value": "<value to save: alias target, fact text, or preference text, null if not>"
          },
          "display_summary": "<short one-liner describing this specific action>"
        }
      ],
      "display_summary": "<short overall summary shown to the user in the confirmation card>"
    }

    Valid action types:
    - send_mail: Compose and send an email
    - schedule_mail: Schedule an email for later
    - create_event: Add a calendar event
    - join_meeting: Open a meeting URL or join a meeting
    - set_reminder: Create a reminder
    - send_message: Send an iMessage or SMS
    - make_call: Initiate a phone or FaceTime call
    - find_file: Search for a file on the Mac
    - open_app: Launch a macOS application
    - web_search: Search the web
    - clipboard_history: Access clipboard history
    - window_management: Manage app windows
    - set_focus: Enable focus/do not disturb mode
    - quick_note: Create a quick note. Do NOT use this for shopping/ordering commands — those are execute_flow.
    - media_play_pause: Play or pause the current media (Spotify or Apple Music)
    - media_next_track: Skip to the next track
    - media_get_info: Get the currently playing song and artist
    - show_log: Show recent action history (handled client-side — return this if user asks what Sky just did)
    - answer: Respond with an informational answer shown inline — use this for questions you can answer directly from context (conversions, summaries, definitions, time zones, page descriptions, math). Put the full answer in params.body. Never use web_search for something you can answer directly from context. Only use web_search if you genuinely cannot answer without live data.
    - read_calendar_today: Show today's calendar events inline
    - create_workflow: Save a reusable workflow. Put the trigger phrase in params.body and the list of step descriptions in params.workflow_steps (array of strings).
    - save_memory: Save something to Sky's memory. Set memory_category to "alias" (memory_key = the alias, memory_value = the real name/email), "fact" (memory_value = the fact text), or "preference" (memory_value = the preference text).
    - show_memory: Show what Sky remembers about the user (handled client-side).
    - computer_use: Use when the user wants to click a single specific UI element — a button, link, field, or toggle visible on screen right now. Set params.body to a natural description of what to click, e.g. "join button", "accept cookies button". Sky finds and clicks it via the Accessibility API.
    - execute_flow: Use when the user wants to complete a multi-step UI flow: ordering or buying a product online (on Amazon, Flipkart, or any shopping site), joining a meeting fully (click join, handle camera/mic), filling a form, completing checkout, going through a signup, or any task needing multiple clicks in sequence. ALWAYS use execute_flow for "order", "buy", "purchase", "checkout", "place order" commands — never use quick_note for these. Set params.body to the full goal including preferences, e.g. "order this product using cash on delivery", "join this meeting with camera off and mic on". Set params.url if a URL is involved.
    - media_play_specific: Use when the user wants to play a specific song, artist, album, or playlist. Set params.query to what to play, params.body to "spotify" or "music" based on context or preference.
    - what_do_you_see: Use when the user asks what's on the current page, what Sky can see, what elements are available, or what Sky can do here. No params needed.
    - resolve_permission: Use when the user says "allow", "allow always", "never", "don't allow" after Sky showed a PERMISSION dialog. Set params.body = their choice (e.g. "Allow", "Never for This Website", "Don't Allow"). Set params.query = the permission key from context (e.g. "permission_meet.google.com_camera").
    - test_browser: TEMPORARY TEST ACTION — use when user says "test browser" or "test headless". No params needed.
    - browser_login: Use when user says "login amazon", "login flipkart", "sign in to amazon", "authenticate amazon", or similar. Set params.body to the site name (e.g. "amazon", "flipkart").
    - browser_login_done: Use when user says "done", "logged in", "finished" after Sky asked them to log in. No params needed.
    - unknown: Intent is unclear or cannot be determined

    If the intent is unclear, set action to "unknown" and set display_summary to a clarifying question for the user.
    If confidence is low, still pick the best matching action but set confidence to "low".
    Always include all fields in params even if null.

    MULTI-STEP RULE: For commands containing "and", "then", "also", or "after that" — ALWAYS return multiple actions in the actions array. Never collapse two requested actions into one. Example: "text john and remind me tomorrow" must return two actions: send_message AND set_reminder.

    CLIPBOARD RULE: When the user says "send this", "share this", "forward this" — "this" refers to the [Clipboard:] content. Use the clipboard content as the message body or url param accordingly. If clipboard contains a URL, use it as the url param. If it contains text, use it as the body param.

    MEETING PREFERENCES: When the user says "remember to always join meetings with camera off/on" or "always join with mic muted/on" — use save_memory with memory_category="preference", memory_key="meeting_camera" (or "meeting_mic"), memory_value="off" (or "on").

    RECENT ACTIONS: The [Recent actions:] block shows what Sky just did. Use it to resolve "that", "it", "the same person", "reschedule that" — these refer to things in the recent actions list.
    """
}
