import Foundation
import Darwin

final class BackendRunner: @unchecked Sendable {
    private let process = Process()

    func start(_ request: [String: Any], onEvent: @escaping ([String: Any]) -> Void,
               onExit: @escaping (Int32) -> Void) throws {
        guard let resources = Bundle.main.resourceURL else {
            throw NSError(domain: "MusicLocal", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到 App 资源，请重新安装。"])
        }
        let python = resources.appendingPathComponent("python")
        let backend = resources.appendingPathComponent("backend")
        process.executableURL = python.appendingPathComponent("bin/python3.12")
        process.arguments = ["-u", backend.appendingPathComponent("worker.py").path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONHOME"] = python.path
        env["PYTHONPATH"] = resources.appendingPathComponent("site-packages").path + ":" + backend.path
        env["PYTHONNOUSERSITE"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        env.removeValue(forKey: "PYTHONSTARTUP")
        env.removeValue(forKey: "PYTHONINSPECT")
        process.environment = env
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = input
        let payload = try JSONSerialization.data(withJSONObject: request)
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: payload + Data([10]))
        try input.fileHandleForWriting.close()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var buffer = Data()
            func deliver(_ line: Data) {
                guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
                DispatchQueue.main.async { onEvent(record) }
            }
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 10) {
                    deliver(buffer.subdata(in: buffer.startIndex..<newline))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
            }
            if !buffer.isEmpty { deliver(buffer) }
            try? output.fileHandleForReading.close()
            process.waitUntilExit()
            let code = process.terminationStatus
            DispatchQueue.main.async { onExit(code) }
        }
    }

    func cancel() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if Darwin.kill(-pid, SIGTERM) != 0 { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
            if process.isRunning {
                if Darwin.kill(-pid, SIGKILL) != 0 { Darwin.kill(pid, SIGKILL) }
            }
        }
    }
}
