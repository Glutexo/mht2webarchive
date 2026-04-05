import Foundation
import MHTWebArchiveCLI

@main
struct Main {
    static func main() {
        exit(MHT2WebArchiveApp.run(arguments: Array(CommandLine.arguments.dropFirst())))
    }
}
