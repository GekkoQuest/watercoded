import ProcessKit
import SwiftUI

/// Entry point. `Watercoded --relay …` runs as a background session relay instead of the app,
/// so agents can outlive the app without a separate helper binary (docs/adr/0009).
@main
enum Main {
    static func main() {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--relay") {
            RelayHost.main(arguments: Array(arguments[(flag + 1)...]))
        }
        WatercodedApp.main()
    }
}
