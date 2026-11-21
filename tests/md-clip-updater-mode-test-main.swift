@main
enum UpdaterModeTestMain {
    static func main() {
        print(UpdaterMode.parse(arguments: CommandLine.arguments).rawValue)
    }
}
