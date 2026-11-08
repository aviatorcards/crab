import Foundation

public let catalogMaxAgeDays: Int = 7
public let defaultMem = "2G"
public let defaultPPCMem = "512M"
/// Mac OS 9 on QEMU's mac99 fails to boot with more than this (in MB).
public let maxPPCMemMB = 1536
public let defaultCPUs = 2
public let defaultDiskSize = "20G"
public let defaultCleanDays: Int = 30

/// An error with a message meant for the user.
public struct CrabError: Error, CustomStringConvertible, Equatable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Every on-disk location crab uses, derived from `VM_ROOT` (default `~/VMs`).
public struct Paths: Sendable, Equatable {
    public var vmRoot: URL
    public var scratchRoot: URL
    public var history: URL
    public var catalog: URL
    public var mirrorsFile: URL
    public var configFile: URL
    public var searchDir: URL

    public init(searchDirOverride: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = homeDir()
        let vmRoot = environment["VM_ROOT"].flatMap { $0.isEmpty ? nil : expandTilde($0) }
            ?? home.appending(path: "VMs", directoryHint: .isDirectory)
        self.init(root: vmRoot)
        searchDir = searchDirOverride
            ?? environment["CRAB_SEARCH_DIR"].flatMap { $0.isEmpty ? nil : expandTilde($0) }
            ?? readConfigKey(configFile, "search_dir").map(expandTilde)
            ?? home.appending(path: "Downloads", directoryHint: .isDirectory)
    }

    /// Paths rooted at `root`, with the search folder at `root/images`. Used by tests.
    public init(root: URL) {
        vmRoot = root
        scratchRoot = root.appending(path: ".scratch")
        history = root.appending(path: ".image-history")
        catalog = root.appending(path: ".catalog")
        mirrorsFile = root.appending(path: "mirrors")
        configFile = root.appending(path: "config")
        searchDir = root.appending(path: "images")
    }

    public mutating func saveSearchDir(_ newDir: URL) throws {
        searchDir = newDir
        try FileManager.default.createDirectory(at: vmRoot, withIntermediateDirectories: true)
        var lines: [String] = []
        var found = false
        if let existing = try? String(contentsOf: configFile, encoding: .utf8) {
            for line in existing.lines {
                if line.hasPrefix("search_dir=") {
                    lines.append("search_dir=\(newDir.path)")
                    found = true
                } else {
                    lines.append(line)
                }
            }
        }
        if !found {
            lines.append("search_dir=\(newDir.path)")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: configFile, atomically: true, encoding: .utf8)
    }
}

public func homeDir() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
}

public func expandTilde(_ raw: String) -> URL {
    if raw == "~" {
        return homeDir()
    }
    if raw.hasPrefix("~/") {
        return homeDir().appending(path: String(raw.dropFirst(2)))
    }
    return URL(filePath: raw)
}

public func readConfigKey(_ configFile: URL, _ key: String) -> String? {
    guard let content = try? String(contentsOf: configFile, encoding: .utf8) else { return nil }
    let prefix = "\(key)="
    var val: String?
    for line in content.lines {
        let trimmed = line.trimmed
        if trimmed.hasPrefix("#") || trimmed.isEmpty {
            continue
        }
        if trimmed.hasPrefix(prefix) {
            let rest = trimmed.dropFirst(prefix.count).trimmed
            if !rest.isEmpty {
                val = rest
            }
        }
    }
    return val
}

public func nowSecs() -> Int {
    Int(Date().timeIntervalSince1970)
}

public func fmtAge(_ unixSecs: Int) -> String {
    let days = max(0, nowSecs() - unixSecs) / 86400
    switch days {
    case 0: return "today"
    case 1: return "1 day ago"
    default: return "\(days) days ago"
    }
}

/// Bytes actually allocated on disk (so sparse qcow2 files count what they use),
/// summed over a directory's contents.
public func diskBytes(_ url: URL) -> Int {
    var st = stat()
    guard lstat(url.path, &st) == 0 else { return 0 }
    if (st.st_mode & S_IFMT) == S_IFDIR {
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return entries.reduce(0) { $0 + diskBytes($1) }
    }
    return Int(st.st_blocks) * 512
}

public func diskKB(_ url: URL) -> Int {
    (diskBytes(url) + 512) / 1024
}

public func humanSize(_ url: URL) -> String {
    let bytes = diskBytes(url)
    if bytes == 0 && !url.exists {
        return "?"
    }
    let kb = bytes / 1024
    if kb < 1024 {
        return "\(kb)K"
    } else if kb < 1_048_576 {
        let mb = Double(kb) / 1024
        return mb < 10 ? String(format: "%.1fM", mb) : "\(Int(mb.rounded()))M"
    } else {
        return String(format: "%.1fG", Double(kb) / 1_048_576)
    }
}

public func fmtKB(_ kb: Int) -> String {
    if kb < 1_048_576 {
        return "\((kb + 512) / 1024)M"
    }
    return String(format: "%.1fG", Double(kb) / 1_048_576)
}

/// An absolute path with symlinks resolved; relative paths are taken from
/// the current directory. For images, delete and trash the `imageEntryPath`
/// and open `pathOpenedForBoot`: resolving here and then deleting that path
/// removes the file a symlink points at.
public func absPath(_ url: URL) -> URL {
    let absolute = url.absoluteURL.standardizedFileURL
    return absolute.exists ? absolute.resolvingSymlinksInPath() : absolute
}

/// Absolute path of a directory entry. `.` and `..` are removed lexically
/// and symlinks are left in place, so unlinking this path removes a link
/// and not its target.
public func imageEntryPath(_ url: URL) -> URL {
    let path = url.path
    let absolute: String
    if path.hasPrefix("/") {
        absolute = path
    } else {
        let cwd = FileManager.default.currentDirectoryPath
        absolute = cwd.hasSuffix("/") ? cwd + path : cwd + "/" + path
    }
    let normalized = lexicalNormalize(absolute)
    if normalized == path {
        return url
    }
    return URL(filePath: normalized)
}

/// The file QEMU should open. A symlink is resolved to its target; any other
/// path is left as the directory entry so non-link arguments stay stable.
public func pathOpenedForBoot(_ url: URL) -> URL {
    let entry = imageEntryPath(url)
    guard isSymlink(entry) else {
        if url.path.hasPrefix("/") && !url.path.contains("/./") && !url.path.contains("/../")
            && !url.path.hasSuffix("/.") && !url.path.hasSuffix("/..") {
            return url
        }
        return entry
    }
    return resolveSymlink(entry)
}

func isSymlink(_ url: URL) -> Bool {
    var st = stat()
    return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
}

/// `realpath` of a symlink. On failure the link itself is returned; opening
/// that still follows it, and it is never used as a path to delete.
func resolveSymlink(_ url: URL) -> URL {
    guard let cstr = realpath(url.path, nil) else { return url }
    defer { free(cstr) }
    return URL(filePath: String(cString: cstr))
}

func lexicalNormalize(_ absolute: String) -> String {
    var parts: [String] = []
    for part in absolute.split(separator: "/", omittingEmptySubsequences: true) {
        if part == "." {
            continue
        }
        if part == ".." {
            if !parts.isEmpty {
                parts.removeLast()
            }
            continue
        }
        parts.append(String(part))
    }
    if parts.isEmpty {
        return "/"
    }
    return "/" + parts.joined(separator: "/")
}

/// Removes a file or symlink. `unlink` deletes the directory entry, so a
/// symlink is removed and the file it points at is left alone.
public func removeImageEntry(_ url: URL) throws(CrabError) {
    let entry = imageEntryPath(url)
    var st = stat()
    guard lstat(entry.path, &st) == 0 else {
        throw CrabError("failed to delete \(entry.path): \(String(cString: strerror(errno)))")
    }
    let kind = st.st_mode & S_IFMT
    guard kind == S_IFLNK || kind == S_IFREG else {
        throw CrabError("refusing to delete \(entry.path): not a file")
    }
    if unlink(entry.path) != 0 {
        throw CrabError("failed to delete \(entry.path): \(String(cString: strerror(errno)))")
    }
}

/// Moves a file or symlink to the Trash. The path is the directory entry:
/// a symlink is trashed and its target is not.
public func trashImageEntry(_ url: URL) throws(CrabError) {
    let entry = imageEntryPath(url)
    var st = stat()
    guard lstat(entry.path, &st) == 0 else {
        throw CrabError("failed to trash \(entry.path): \(String(cString: strerror(errno)))")
    }
    let kind = st.st_mode & S_IFMT
    guard kind == S_IFLNK || kind == S_IFREG else {
        throw CrabError("refusing to trash \(entry.path): not a file")
    }
    do {
        try FileManager.default.trashItem(at: entry, resultingItemURL: nil)
    } catch {
        throw CrabError("failed to trash \(entry.path): \(error.localizedDescription)")
    }
}

public func fileMtime(_ url: URL) -> Int {
    let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    return date.map { Int($0.timeIntervalSince1970) } ?? nowSecs()
}

public func fileBirthtime(_ url: URL) -> Int {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    let date = (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date)
    return date.map { Int($0.timeIntervalSince1970) } ?? nowSecs()
}

public func askYes(_ prompt: String) -> Bool {
    guard let answer = promptLine("\(prompt) [y/N] ")?.trimmed.lowercased() else { return false }
    return answer == "y" || answer == "yes"
}

/// Prints `prompt` and reads a line, or nil at end of input.
public func promptLine(_ prompt: String) -> String? {
    print(prompt, terminator: "")
    fflush(stdout)
    return readLine(strippingNewline: true)
}

public func hostArch() -> String {
    #if arch(arm64)
    return "arm64"
    #else
    return "amd64"
    #endif
}

public func hostUnameM() -> String {
    #if arch(arm64)
    return "arm64"
    #else
    return "x86_64"
    #endif
}

public let installQemuHint = "brew install qemu"

public func logImageBoot(_ paths: Paths, _ image: URL, dryRun: Bool) {
    if dryRun {
        return
    }
    try? FileManager.default.createDirectory(at: paths.vmRoot, withIntermediateDirectories: true)
    // Record the directory entry. Older crabs stored a symlink-resolved path;
    // imageLastBoot still matches those.
    let line = Data("\(nowSecs())\t\(imageEntryPath(image).path)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: paths.history) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    } else {
        try? line.write(to: paths.history)
    }
}

/// Paths a history line might use for this image: the directory entry, and
/// (for lines written by older crabs) the symlink-resolved path. The resolved
/// path is only for matching, never for deletion.
func imageHistoryKeys(_ image: URL) -> Set<String> {
    let entry = imageEntryPath(image)
    var keys: Set<String> = [image.path, entry.path, pathOpenedForBoot(image).path]
    if entry.exists {
        keys.insert(entry.resolvingSymlinksInPath().path)
    }
    return keys
}

public func imageLastBoot(_ paths: Paths, _ image: URL) -> Int? {
    guard let content = try? String(contentsOf: paths.history, encoding: .utf8) else { return nil }
    let targets = imageHistoryKeys(image)
    var last: Int?
    for line in content.lines {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, targets.contains(String(parts[1])), let t = Int(parts[0]) {
            last = t
        }
    }
    return last
}

public func imageLastUsed(_ paths: Paths, _ image: URL) -> Int {
    let added = fileBirthtime(image)
    if let booted = imageLastBoot(paths, image), booted > added {
        return booted
    }
    return added
}

public struct ImageEntry: Sendable, Hashable, Identifiable {
    public var path: URL
    public var name: String
    public var sizeHuman: String
    public var sizeKB: Int
    public var downloadedSecs: Int
    public var lastBootedSecs: Int?
    public var fileInfo: String
    public var id: URL { path }
}

/// The .iso files in the search folder, then the .img files, each sorted by path.
/// Each path is the directory entry. A symlink is listed as the link, so
/// deleting it does not delete the file it points at.
public func listImagePaths(_ paths: Paths) -> [URL] {
    let entries = (try? FileManager.default.contentsOfDirectory(at: paths.searchDir, includingPropertiesForKeys: nil)) ?? []
    var isos: [URL] = []
    var imgs: [URL] = []
    for url in entries where url.isFile {
        let entry = imageEntryPath(url)
        switch entry.pathExtension.lowercased() {
        case "iso": isos.append(entry)
        case "img": imgs.append(entry)
        default: break
        }
    }
    return isos.sorted { $0.path < $1.path } + imgs.sorted { $0.path < $1.path }
}

/// Reads an ISO 9660 Primary Volume Descriptor: sector 16 (offset 0x8000)
/// starts with `\x01CD001`, and the 32-byte volume identifier is at 40..<72.
public func inspectISO9660(_ url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard (try? handle.seek(toOffset: 0x8000)) != nil,
          let pvd = try? handle.read(upToCount: 128), pvd.count == 128 else {
        return nil
    }
    let bytes = [UInt8](pvd)
    guard bytes[1..<6].elementsEqual("CD001".utf8) else { return nil }
    let volID = String(decoding: bytes[40..<72], as: UTF8.self)
    return volID.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// What `file -b` would say about an ISO, or "" for anything else.
public func fileBrief(_ url: URL) -> String {
    guard let vol = inspectISO9660(url) else { return "" }
    return vol.isEmpty ? "ISO 9660 CD-ROM filesystem data" : "ISO 9660 CD-ROM filesystem data '\(vol)'"
}

/// The text between the first and last single quote, with runs of spaces squeezed.
public func extractQuotedLabel(_ fileOutput: String) -> String {
    guard let first = fileOutput.firstIndex(of: "'"),
          let last = fileOutput.lastIndex(of: "'"), last > first else {
        return ""
    }
    let inner = fileOutput[fileOutput.index(after: first)..<last]
    return inner.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

public func listImageEntries(_ paths: Paths) -> [ImageEntry] {
    listImagePaths(paths).map { url in
        // Size follows the symlink so a link to an ISO still shows the ISO's
        // size. `path` stays the directory entry that delete and trash use.
        let opened = pathOpenedForBoot(url)
        return ImageEntry(
            path: url,
            name: url.lastPathComponent,
            sizeHuman: humanSize(opened),
            sizeKB: diskKB(opened),
            downloadedSecs: fileBirthtime(url),
            lastBootedSecs: imageLastBoot(paths, url),
            fileInfo: extractQuotedLabel(fileBrief(url))
        )
    }
}

public func validMem(_ s: String) -> Bool {
    var num = Substring(s)
    if let last = num.last, "MmGg".contains(last) {
        num = num.dropLast()
    }
    return !num.isEmpty && num.allSatisfy(\.isASCIIDigit)
}

/// A size as `validMem` accepts it, in MB (QEMU reads a bare number as MB).
func memMB(_ s: String) -> Int? {
    guard validMem(s) else { return nil }
    switch s.last {
    case "G", "g": return Int(s.dropLast()).map { $0 * 1024 }
    case "M", "m": return Int(s.dropLast())
    default: return Int(s)
    }
}

public func validCPUs(_ s: String) -> Bool {
    !s.isEmpty && !s.hasPrefix("0") && s.allSatisfy(\.isASCIIDigit)
}

public func validPort(_ s: String) -> Bool {
    !s.isEmpty && s.allSatisfy(\.isASCIIDigit) && UInt16(s) != nil
}

/// A disk size for qemu-img: digits with an M, G or T suffix, optionally
/// prefixed with + (grow by) when `relative` is allowed.
public func validDiskSize(_ s: String, relative: Bool) -> Bool {
    var s = Substring(s)
    if relative && s.hasPrefix("+") {
        s = s.dropFirst()
    }
    guard let last = s.last, "MmGgTt".contains(last) else { return false }
    let num = s.dropLast()
    return !num.isEmpty && num.allSatisfy(\.isASCIIDigit) && num != "0"
}

/// A host port forwarded into the guest, written as `[udp:]HOST:GUEST`.
public struct Forward: Sendable, Hashable, CustomStringConvertible {
    public var udp: Bool
    public var host: UInt16
    public var guest: UInt16

    public init(udp: Bool, host: UInt16, guest: UInt16) {
        self.udp = udp
        self.host = host
        self.guest = guest
    }

    public static func parse(_ s: String) -> Forward? {
        var rest = Substring(s)
        var udp = false
        if rest.hasPrefix("udp:") {
            udp = true
            rest = rest.dropFirst(4)
        } else if rest.hasPrefix("tcp:") {
            rest = rest.dropFirst(4)
        }
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let host = String(rest[..<colon])
        let guest = String(rest[rest.index(after: colon)...])
        guard validPort(host), validPort(guest), let h = UInt16(host), let g = UInt16(guest), h != 0, g != 0 else {
            return nil
        }
        return Forward(udp: udp, host: h, guest: g)
    }

    /// Parses a comma-separated list as saved in vm.conf; "" and "0" mean none.
    public static func parseList(_ s: String) throws(CrabError) -> [Forward] {
        let s = s.trimmed
        if s.isEmpty || s == "0" {
            return []
        }
        var out: [Forward] = []
        for item in s.split(separator: ",", omittingEmptySubsequences: false) {
            guard let f = Forward.parse(item.trimmed) else {
                throw CrabError("bad port forward '\(item)' (want HOST:GUEST or udp:HOST:GUEST)")
            }
            out.append(f)
        }
        return out
    }

    public static func listToConf(_ fwds: [Forward]) -> String {
        fwds.isEmpty ? "0" : fwds.map(\.description).joined(separator: ",")
    }

    /// The `hostfwd=` value for QEMU's user-mode network.
    public var hostfwd: String {
        "\(udp ? "udp" : "tcp"):127.0.0.1:\(host)-:\(guest)"
    }

    public var description: String {
        udp ? "udp:\(host):\(guest)" : "\(host):\(guest)"
    }
}

// MARK: - Small helpers

extension StringProtocol {
    /// Lines split on \n (and \r\n).
    var lines: [String] {
        var out = split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
        }
        if out.last == "" {
            out.removeLast()
        }
        return out
    }

    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}

extension URL {
    var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    var isFile: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    var isDirectory: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The file name without its last extension.
    var fileStem: String {
        deletingPathExtension().lastPathComponent
    }
}
