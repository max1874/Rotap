import Foundation

if CommandLine.arguments.contains("--list-sources") {
    for source in AudioSource.available() {
        print("\(source.id)\t\(source.name)\(source.isPlaying ? "\t(playing)" : "")")
    }
    exit(0)
} else if let headless = HeadlessRecording(arguments: CommandLine.arguments) {
    exit(headless.run())
} else {
    RotapApp.main()
}
