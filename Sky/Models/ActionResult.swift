/// Represents the outcome of an action handled by Sky's action router.
enum ActionResult {
    /// The action completed successfully; the associated string is the display message.
    case success(String)
    /// The action failed; the associated string is a plain-English reason.
    case failure(String)
    /// The action was saved to the scheduler; the associated string describes the schedule.
    case scheduled(String)
    /// The action produced an informational answer to display inline in the panel.
    case answer(String)
}
