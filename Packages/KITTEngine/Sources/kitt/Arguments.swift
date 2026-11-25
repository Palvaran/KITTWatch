import Foundation

/// Minimal argument parsing: `--name value`, `--flag`, and positional arguments.
struct Arguments {
    private(set) var options: [String: String] = [:]
    private(set) var flags: Set<String> = []
    private(set) var positional: [String] = []

    init(_ raw: [String], flags known: Set<String> = []) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if known.contains(name) || i + 1 >= raw.count {
                    flags.insert(name)
                } else {
                    options[name] = raw[i + 1]
                    i += 1
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func string(_ name: String) -> String? { options[name] }
    func int(_ name: String) -> Int? { options[name].flatMap(Int.init) }
    func has(_ name: String) -> Bool { flags.contains(name) }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func expand(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
}
