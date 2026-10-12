import Foundation

public protocol TimeSource: Sendable {
    func now() -> Date
}

public struct SystemTime: TimeSource {
    public init() {}
    public func now() -> Date { Date() }
}
