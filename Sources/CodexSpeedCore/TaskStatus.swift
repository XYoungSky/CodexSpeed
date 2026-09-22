// Derived only from explicit turn lifecycle records, not conversation text.
public enum TaskPhase: String {
    case idle, running, completed, interrupted
}
