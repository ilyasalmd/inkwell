// Inkwell Bridge: runs the Inkwell MCP server (server.py) as a child process.
// Claude starts each extension as its own process for macOS privacy checks, and python3 on its own isn't allowed
// into iCloud Drive. A child process is checked against this signed helper instead, so giving "InkwellBridge"
// Full Disk Access once lets the server read Inkwell's iCloud folder.
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    FileHandle.standardError.write("usage: InkwellBridge <server.py> [args...]\n".data(using: .utf8)!)
    exit(64)
}

var pid: pid_t = 0
let argv: [UnsafeMutablePointer<CChar>?] = (["/usr/bin/python3"] + args).map { strdup($0) } + [nil]
let rc = posix_spawn(&pid, "/usr/bin/python3", nil, nil, argv, environ)
guard rc == 0 else {
    FileHandle.standardError.write("InkwellBridge: couldn't start python3 (\(rc))\n".data(using: .utf8)!)
    exit(1)
}

// Pass Claude's stop signals on to the server.
var sources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { kill(pid, sig) }
    source.resume()
    sources.append(source)
}

DispatchQueue.global().async {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    exit(code)
}
dispatchMain()
