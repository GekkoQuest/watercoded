import ProcessKit

// Standalone relay for tests and command-line use. The app runs the same code as `Watercoded --relay …`.
RelayHost.main(arguments: Array(CommandLine.arguments.dropFirst()))
