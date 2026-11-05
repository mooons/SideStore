// The runner inserts the production methods at the markers below. UIKit and
// SideSign boundaries are small stand-ins; HTTP, files, ZIPs and plists are real.
import Foundation

func debugLog(_ message: String) {}
struct CheckFailure: Error, CustomStringConvertible { let description: String }
func expect(_ value: Bool, _ message: String) throws {
    if !value { throw CheckFailure(description: message) }
}
enum OperationError: Error {
    case invalidApp(reason: String), cancelled, unknownResult
}
struct StoreApp { static let altstoreAppID = "com.SideStore.SideStore" }
protocol AppProtocol {
    var name: String { get }
    var bundleIdentifier: String { get }
    var url: URL? { get }
}
struct AnyApp: AppProtocol {
    let name: String
    let bundleIdentifier: String
    let url: URL?
    let storeApp: StoreApp?
    var openAppURL: URL { url! }
}
typealias InstalledApp = AnyApp
final class UIViewController {}
final class NSManagedObjectContext {}
final class StandaloneOperationContext { var dbBackgroundContext: NSManagedObjectContext? }
struct PipelineExecutionHandler {}
enum AppOperation {
    case install(AppProtocol)
    var app: AppProtocol { switch self { case .install(let app): return app } }
    var bundleIdentifier: String { app.bundleIdentifier }
}
final class RefreshGroup {
    var error: Error?
    var activeTask: Task<Void, Never>?
    var completionHandler: (([String: Result<InstalledApp, Error>]) -> Void)?
    init(dbContext: NSManagedObjectContext) {}
    func cancel() { activeTask?.cancel() }
}
final class PipelineRunner {
    var receivedApp: AppProtocol?
    func perform(_ operations: [AppOperation], handler: PipelineExecutionHandler, group: RefreshGroup) async throws {
        let app = operations[0].app
        try expect(app.url?.isFileURL == true, "pipeline received an unresolved remote URL")
        try expect(FileManager.default.fileExists(atPath: app.url!.path), "staged IPA was deleted before pipeline execution")
        receivedApp = app
        group.completionHandler?([app.bundleIdentifier: .success(AnyApp(name: app.name, bundleIdentifier: app.bundleIdentifier, url: app.url, storeApp: nil))])
    }
    // PIPELINE_RUNNER_METHODS
}
enum InstallTarget { case url(URL), app(AppProtocol) }
enum PackageType: String {
    case ipa, app
    init?(url: URL) { self.init(rawValue: url.pathExtension.lowercased()) }
}
struct InfoPlistParser {
    let dictionary: [String: Any]
    init(data: Data) throws {
        dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    }
    init(bundleURL: URL) throws { try self.init(data: Data(contentsOf: bundleURL.appendingPathComponent("Info.plist"))) }
    var bundleIdentifier: String? { dictionary["CFBundleIdentifier"] as? String }
    var displayName: String? { dictionary["CFBundleDisplayName"] as? String }
    var bundleName: String? { dictionary["CFBundleName"] as? String }
}
enum Archive {
    final class Reader {
        let url: URL
        let entries: [String]
        var index = 0
        static func unzip(_ args: [String]) throws -> Data {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try expect(process.terminationStatus == 0, "invalid fixture ZIP")
            return data
        }
        init(url: URL) throws {
            self.url = url
            entries = String(decoding: try Self.unzip(["-Z1", url.path]), as: UTF8.self).split(separator: "\n").map(String.init)
        }
        static func open(at url: URL) throws -> Reader { try Reader(url: url) }
        func goToFirstFile() throws { index = 0 }
        func currentFilename() throws -> String { entries[index] }
        func readCurrentFile() throws -> Data { try Self.unzip(["-p", url.path, entries[index]]) }
        func goToNextFile() -> Bool { index += 1; return index < entries.count }
    }
}
final class AppManager {
    let pipelineRunner = PipelineRunner()
    func makePipelineHandler(presentingViewController: UIViewController?) -> PipelineExecutionHandler { PipelineExecutionHandler() }
    func getValidDbContext(_ context: NSManagedObjectContext?) -> NSManagedObjectContext { context ?? NSManagedObjectContext() }
    func resolve(_ target: InstallTarget) async throws -> AppProtocol {
        try await resolveApp(for: target)
    }
    // APP_MANAGER_METHODS
    // INSTALL_METHOD
}

final class UIApplication {
    static let shared = UIApplication()
    func open(_ url: URL) {}
}
extension UserDefaults { var isAutoLaunchAppAfterInstallEnabled: Bool { false } }

@main
struct ImportRegressionCheck {
    static func main() async {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            let base = CommandLine.arguments[2]
            let selected = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "all"
            if selected == "url" || selected == "all" {
                let manager = AppManager()
                for suffix in ["SideStore.ipa", "download?id=fixture"] {
                    let app = try await manager.resolve(.url(URL(string: base + "/" + suffix)!))
                    defer {
                        if let file = app.url, file.isFileURL { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                    }
                    try expect(app.bundleIdentifier == "com.example.ImportFixture", "remote install guessed the bundle ID from its filename")
                    try expect(app.name == "Import Fixture", "remote install did not read the app name from Info.plist")
                    try expect(app.url?.isFileURL == true, "downloaded IPA was not retained for the pipeline")
                }
                let local = try await manager.resolve(.url(root.appendingPathComponent("Fixture.ipa")))
                try expect(local.bundleIdentifier == "com.example.ImportFixture", "local IPA metadata changed")
                let source = AnyApp(name: "Source App", bundleIdentifier: "com.expected.Source", url: URL(string: base + "/SideStore.ipa"), storeApp: nil)
                let unchanged = try await manager.resolve(.app(source))
                try expect(unchanged.bundleIdentifier == source.bundleIdentifier && unchanged.url == source.url, "source-provided identity was replaced")
                for target in [InstallTarget.url(URL(string: base + "/missing.ipa")!),
                               .url(root.appendingPathComponent("Invalid.ipa"))] {
                    var rejected = false
                    do { _ = try await manager.resolve(target) }
                    catch { rejected = true }
                    try expect(rejected, "invalid HTTP response or missing bundle ID was accepted")
                }
                print("PASS: remote/local IPA identity, source identity and invalid import rejection")

                var completions = 0
                var success = false
                let group = manager.install(.url(URL(string: base + "/SideStore.ipa")!)) { result in
                    completions += 1
                    success = (try? result.get().bundleIdentifier) == "com.example.ImportFixture"
                }
                await group.activeTask?.value
                try expect(success && completions == 1, "prepared install did not complete exactly once with the real bundle ID")
                try expect(manager.pipelineRunner.receivedApp?.bundleIdentifier == "com.example.ImportFixture", "pipeline started with guessed identity")
                let staged = manager.pipelineRunner.receivedApp!.url!
                try expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path), "prepared download directory was not cleaned up")

                let runner = PipelineRunner()
                var cleaned = false
                var failures = 0
                let cancelled = runner.performSingleOperation(resolving: {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    return .install(source)
                }, cleanup: { cleaned = true }, handler: PipelineExecutionHandler(), dbContext: NSManagedObjectContext()) { result in
                    if case .failure = result { failures += 1 }
                }
                cancelled.cancel()
                await cancelled.activeTask?.value
                try expect(cleaned && failures == 1 && runner.receivedApp == nil, "preparation cancellation did not clean up and finish exactly once")
                cleaned = false
                failures = 0
                let failed = runner.performSingleOperation(resolving: {
                    throw OperationError.invalidApp(reason: "fixture preparation failure")
                }, cleanup: { cleaned = true }, handler: PipelineExecutionHandler(), dbContext: NSManagedObjectContext()) { result in
                    if case .failure = result { failures += 1 }
                }
                await failed.activeTask?.value
                try expect(cleaned && failures == 1 && runner.receivedApp == nil, "preparation failure did not clean up and finish exactly once")
                print("PASS: prepared install lifetime, completion, cancellation and failure cleanup")
            }

        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}
