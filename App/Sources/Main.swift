import Delegation
import ProcessKit
import SwiftUI

/// Entry point. The app binary has two helper modes instead of separate helper binaries:
/// `--relay …` runs a background session relay (docs/adr/0009), and
/// `--delegate-mcp <current-id> --agents a,b` serves the `delegate` MCP tool to an agent (docs/adr/0012).
@main
enum Main {
    static func main() {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--relay") {
            RelayHost.main(arguments: Array(arguments[(flag + 1)...]))
        }
        if let flag = arguments.firstIndex(of: "--delegate-mcp"), arguments.indices.contains(flag + 1) {
            func value(after name: String) -> String? {
                arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            }
            DelegateMCPServer.run(
                parentID: arguments[flag + 1],
                agents: value(after: "--agents")?.split(separator: ",").map(String.init) ?? [],
                mailbox: value(after: "--mailbox")
                    .map { DelegationMailbox(root: URL(filePath: $0)) } ?? DelegationMailbox()
            )
            exit(0)
        }
        WatercodedApp.main()
    }
}
