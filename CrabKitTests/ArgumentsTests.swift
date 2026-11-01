import Foundation
import Testing
@testable import CrabKit

struct ArgumentsTests {
    @Test func bundledFlagsAndValues() throws {
        let cli = try parseArgs(["-kp2222", "-m", "4G", "-tn", "x.iso"])
        #expect(cli.opts.keep && cli.opts.dryRun)
        #expect(cli.opts.sshPort == "2222")
        #expect(cli.opts.mem == "4G")
        #expect(cli.opts.display == "terminal")
        #expect(cli.positional == ["x.iso"])
        #expect(cli.cmd == "")
    }

    @Test func commandBeforeOrAfterFlags() throws {
        #expect(try parseArgs(["boot", "-p", "2200", "vm"]).cmd == "boot")
        let cli = try parseArgs(["-p", "2200", "boot", "vm"])
        #expect(cli.cmd == "boot" && cli.positional == ["vm"])
        #expect(try parseArgs(["gui"]).gui)
        #expect(try parseArgs(["-m2G", "gui"]).gui)
        #expect(try parseArgs(["--gui"]).gui)
    }

    @Test func forwardsAccumulate() throws {
        let cli = try parseArgs(["-P", "8080:80", "-Pudp:5353:53", "boot", "vm"])
        #expect(Forward.listToConf(cli.opts.forwards ?? []) == "8080:80,udp:5353:53")
        #expect(try parseArgs(["-P0", "boot", "vm"]).opts.forwards == [])
        #expect(throws: CrabError.self) { try parseArgs(["-P", "80"]) }
    }

    @Test func doubleDashPassesTheRestThrough() throws {
        let cli = try parseArgs(["ssh", "root@vm", "--", "uname", "-a"])
        #expect(cli.cmd == "ssh")
        #expect(cli.positional == ["root@vm", "uname", "-a"])
    }

    @Test func usageErrors() throws {
        for bad in [["-m", "lots"], ["-c0"], ["-p", "70000"], ["-f", "coreboot"], ["-a", "riscv64"], ["-k", "-l"], ["-x"], ["-m"]] {
            #expect(throws: CrabError.self, "\(bad)") { try parseArgs(bad) }
        }
        #expect(try parseArgs(["-a", "aarch64"]).opts.arch == "arm64")
        #expect(try parseArgs(["-h", "-x"]).help)
    }
}
