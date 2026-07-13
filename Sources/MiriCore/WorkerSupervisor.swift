import Foundation

public actor WorkerSupervisor {
    public enum State: Equatable, Sendable { case stopped, starting, running, failed(String) }
    public private(set) var state: State = .stopped
    private var process: Process?

    public init() {}
    public func start(executable: URL, arguments: [String] = []) throws {
        guard process == nil else { return }; state = .starting
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        process.standardInput = Pipe(); process.standardOutput = Pipe(); process.standardError = Pipe()
        process.terminationHandler = { [weak self] value in Task { await self?.terminated(value.terminationStatus) } }
        do { try process.run(); self.process = process; state = .running }
        catch { state = .failed(error.localizedDescription); throw error }
    }
    public func stop() { process?.terminate(); process = nil; state = .stopped }
    private func terminated(_ status: Int32) { process = nil; if state != .stopped { state = .failed("Worker exited with status \(status)") } }
}
