import Foundation

/// Owns the latest request across actor reentrancy. Old cleanup cannot clear its replacement.
struct FlightRequestSlot<Value: Sendable> {
    private var task: Task<Value, Error>?
    private var ticket: UUID?
    var isActive: Bool { task != nil }
    mutating func replace(with value: Task<Value, Error>) -> UUID {
        task?.cancel()
        let id = UUID(); task = value; ticket = id
        return id
    }
    mutating func finish(_ id: UUID) {
        guard ticket == id else { return }
        task = nil; ticket = nil
    }
    mutating func cancel() {
        task?.cancel(); task = nil; ticket = nil
    }
}
