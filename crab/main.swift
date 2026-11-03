import CrabKit
import Foundation

let appBundleID = "com.tristansmith.Crab"

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("crab: \(msg)\n".utf8))
    exit(1)
}

func badUsage(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("crab: \(msg)\nRun 'crab -h' for usage.\n".utf8))
    exit(2)
}

/// Opens the Crab app, passing along VM_ROOT / CRAB_SEARCH_DIR and the boot flags.
/// Prefers the app this binary is bundled in (Crab.app/Contents/Helpers/crab).
func launchGUI(_ rawArgs: [String]) throws(CrabError) {
    var openArgs: [String] = []
    let me = URL(filePath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundle = me.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if bundle.pathExtension == "app" {
        openArgs += ["-a", bundle.path]
    } else {
        openArgs += ["-b", appBundleID]
    }
    let env = ProcessInfo.processInfo.environment
    for key in ["VM_ROOT", "CRAB_SEARCH_DIR"] {
        if let value = env[key], !value.isEmpty {
            openArgs += ["--env", "\(key)=\(value)"]
        }
    }
    let flags = rawArgs.filter { $0 != "gui" && $0 != "--gui" }
    if !flags.isEmpty {
        openArgs += ["--args"] + flags
    }
    let status: Int32
    do {
        status = try runInheriting(URL(filePath: "/usr/bin/open"), openArgs)
    } catch {
        throw CrabError("failed to run open: \(error.localizedDescription)")
    }
    if status != 0 {
        throw CrabError("couldn't open the Crab app; build and install it from Crab.xcodeproj")
    }
}

func isRegularFile(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
}

func expectArgs(_ ok: Bool, _ usage: String) {
    if !ok {
        badUsage("usage: \(usage)")
    }
}

let rawArgs = Array(CommandLine.arguments.dropFirst())
let cli: CLI
do {
    cli = try parseArgs(rawArgs)
} catch {
    badUsage(error.message)
}

var paths = Paths(searchDirOverride: cli.opts.searchDir)
let opts = cli.opts
let positional = cli.positional
let nargs = positional.count
let first = positional.first

if cli.help {
    print(usageText(paths))
    exit(0)
}

do {
    if cli.gui {
        try launchGUI(rawArgs)
        exit(0)
    }

    switch cli.cmd {
    case "":
        if nargs == 0 {
            try cmdBoot(paths, opts, vmName: nil, image: nil)
        } else if nargs == 1, let first, isRegularFile(first) {
            try cmdBoot(paths, opts, vmName: nil, image: URL(filePath: first))
        } else if nargs == 1 {
            badUsage("no such image or command: \(first ?? "")")
        } else {
            badUsage("too many arguments")
        }
    case "boot":
        expectArgs(nargs == 1, "crab boot [options] NAME")
        try cmdBoot(paths, opts, vmName: first, image: nil)
    case "stop":
        expectArgs(nargs == 1, "crab stop NAME")
        try cmdStop(paths, first!)
    case "kill":
        expectArgs(nargs == 1, "crab kill NAME")
        try cmdKill(paths, first!)
    case "disc":
        expectArgs((1...2).contains(nargs), "crab disc NAME [IMAGE|eject]")
        try cmdDisc(paths, first!, nargs > 1 ? positional[1] : nil)
    case "ssh":
        expectArgs(nargs > 0, "crab ssh [USER@]NAME [-- COMMAND...]")
        try cmdSSH(paths, first!, Array(positional.dropFirst()))
    case "set":
        expectArgs(nargs > 0, "crab set NAME [KEY=VALUE...]")
        try cmdSet(paths, first!, Array(positional.dropFirst()))
    case "clone":
        expectArgs(nargs == 2, "crab clone NAME NEW")
        try cmdClone(paths, first!, positional[1])
    case "rename":
        expectArgs(nargs == 2, "crab rename NAME NEW")
        try cmdRename(paths, first!, positional[1])
    case "resize":
        expectArgs(nargs == 2, "crab resize NAME SIZE")
        try cmdResize(paths, first!, positional[1])
    case "get":
        expectArgs(nargs <= 1, "crab get [options] [DISTRO[/VARIANT]]")
        try await cmdGet(paths, opts, spec: first)
    case "sync":
        expectArgs(nargs == 0, "crab sync")
        try await cmdSync(paths)
    case "list":
        expectArgs(nargs == 0, "crab list")
        cmdList(paths)
    case "images":
        expectArgs(nargs == 0, "crab images")
        cmdImages(paths)
    case "clean":
        expectArgs(nargs <= 1, "crab clean [DAYS]")
        var days = defaultCleanDays
        if let first {
            guard let d = Int(first), d >= 0 else { badUsage("DAYS should be a number") }
            days = d
        }
        cmdClean(paths, days: days)
    case "delete":
        expectArgs(nargs == 1, "crab delete NAME")
        try cmdDelete(paths, first!)
    case "snapshot":
        expectArgs((1...2).contains(nargs), "crab snapshot NAME [TAG]")
        try cmdSnapshot(paths, first!, tag: nargs > 1 ? positional[1] : nil)
    case "snapshots":
        expectArgs(nargs == 1, "crab snapshots NAME")
        try cmdSnapshots(paths, first!)
    case "restore":
        expectArgs(nargs == 2, "crab restore NAME TAG")
        try cmdRestore(paths, first!, positional[1])
    case "delsnap":
        expectArgs(nargs == 2, "crab delsnap NAME TAG")
        try cmdDelsnap(paths, first!, positional[1])
    case "mirrors":
        try await cmdMirrors(paths, positional)
    case "dir":
        if nargs == 0 {
            print(paths.searchDir.path)
        } else if nargs == 1, let first {
            let p = absPath(URL(filePath: first))
            do {
                try paths.saveSearchDir(p)
            } catch {
                die("failed to save search dir: \(error.localizedDescription)")
            }
            print("Default ISO search & download folder set to: \(p.path)")
        } else {
            badUsage("usage: crab dir [PATH]")
        }
    default:
        badUsage("unknown command: \(cli.cmd)")
    }
} catch {
    die(error.message)
}
