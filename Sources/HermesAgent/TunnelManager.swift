import Foundation

enum TunnelStatus {
    case connecting
    case connected
    case disconnected
}

class TunnelManager {
    private var process: Process?
    private let user: String
    private let host: String
    private let localPort: Int
    private let remoteHost: String
    private let remotePort: Int

    var onStatusChange: ((TunnelStatus) -> Void)?
    private(set) var status: TunnelStatus = .connecting
    private var monitorTimer: Timer?

    init(user: String, host: String, localPort: Int, remoteHost: String, remotePort: Int) {
        self.user = user
        self.host = host
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    func start(onReady: @escaping () -> Void) {
        setStatus(.connecting)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = [
            "-N",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ExitOnForwardFailure=yes",
            "-L", "\(localPort):\(remoteHost):\(remotePort)",
            "\(user)@\(host)",
        ]

        let pipe = Pipe()
        p.standardError = pipe

        // Detect if process dies unexpectedly
        p.terminationHandler = { [weak self] process in
            guard let self = self else { return }
            if process.terminationReason == .exit && process.terminationStatus != 0 {
                DispatchQueue.main.async {
                    self.setStatus(.disconnected)
                }
            }
        }

        do {
            try p.run()
            self.process = p
            print("SSH tunnel started (pid \(p.processIdentifier))")
        } catch {
            print("Failed to start SSH: \(error)")
            setStatus(.disconnected)
            onReady()
            return
        }

        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let connected = self.waitForPortForward(timeout: 5.0, interval: 0.5)
            DispatchQueue.main.async {
                if connected {
                    self.setStatus(.connected)
                    self.startMonitoring()
                } else {
                    self.setStatus(.disconnected)
                }
                onReady()
            }
        }
    }

    func stop() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        guard let p = process else { return }
        let pid = p.processIdentifier
        p.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            if p.isRunning { kill(pid, SIGKILL) }
        }
        process = nil
    }

    private func startMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) {
            [weak self] _ in
            guard let self = self, let p = self.process else { return }
            if !p.isRunning {
                self.setStatus(.disconnected)
                self.monitorTimer?.invalidate()
            }
        }
    }

    private func waitForPortForward(timeout: TimeInterval = 8.0, interval: TimeInterval = 0.5)
        -> Bool
    {
        // A local TCP connect only proves ssh is holding the port — ssh always
        // accepts immediately, even when the far end of the forward is broken
        // (e.g. the remote service isn't running, or localhost-on-remote
        // resolves to an address nothing is bound to). An HTTP round-trip is
        // what actually tells us the tunnel is usable.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if process?.isRunning != true {
                return false
            }
            if httpProbeSucceeds(port: localPort, timeout: 1.5) {
                return true
            }
            Thread.sleep(forTimeInterval: interval)
        }
        return false
    }

    private func httpProbeSucceeds(port: Int, timeout: TimeInterval) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return false }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"

        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            // Any HTTP response (including 4xx/5xx) means the tunnel delivered
            // bytes end-to-end — that's what we're verifying here.
            if response is HTTPURLResponse { reachable = true }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 0.5) == .timedOut {
            task.cancel()
            return false
        }
        return reachable
    }

    private func setStatus(_ newStatus: TunnelStatus) {
        status = newStatus
        onStatusChange?(newStatus)
    }
}
