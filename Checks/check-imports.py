"""Run production import methods with macOS CLT, a local HTTP server and IPA fixtures.

UIKit presentation and SideSign's reader/parser interfaces are test stand-ins.
The ZIP reader stand-in uses system unzip; the actual metadata-resolution,
document-picker and staging methods are extracted unchanged from app sources.
This does not replace an iOS build or UI/device test.
"""
from pathlib import Path
import functools
import http.server
import plistlib
import subprocess
import sys
import tempfile
import threading
import zipfile

root = Path(__file__).resolve().parent.parent


def method(text, signature):
    start = text.index(signature)
    body = text.index("{", start)
    depth = 1
    end = body + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/missing.ipa":
            self.send_error(404)
            return
        # Serve the same archive under unrelated and extensionless URL names.
        self.path = "/Fixture.ipa"
        super().do_GET()

    def log_message(self, *_):
        pass


with tempfile.TemporaryDirectory(prefix="sidestore-import-check-") as directory:
    work = Path(directory)
    with zipfile.ZipFile(work / "Fixture.ipa", "w") as archive:
        archive.writestr("Payload/Fixture.app/Info.plist", plistlib.dumps({
            "CFBundleIdentifier": "com.example.ImportFixture", "CFBundleDisplayName": "Import Fixture"}))
    with zipfile.ZipFile(work / "Invalid.ipa", "w") as archive:
        archive.writestr("Payload/Fixture.app/Info.plist", plistlib.dumps({"CFBundleName": "Missing ID"}))
    app = (root / "AltStore/Managing Apps/AppManager.swift").read_text()
    handler = (root / "SideStore/DeepLinks/FileImportHandler.swift").read_text()
    picker = (root / "AltStore/My Apps/MyAppsViewController.swift").read_text()
    pipeline = (root / "SideStore/Core/Operations/PipelineRunner.swift").read_text()
    swift = (root / "Checks/ImportRegressionCheck.swift").read_text()
    swift = swift.replace("// APP_MANAGER_METHODS", method(app, "private func resolveApp(for") + "\n" + method(app, "private static func readAppMetadata("))
    swift = swift.replace("// INSTALL_METHOD", method(app, "func install(_ target: InstallTarget,"))
    start = pipeline.index("    @discardableResult\n    func performSingleOperation(")
    end = pipeline.index("    func performVoidOperation(", start)
    swift = swift.replace("// PIPELINE_RUNNER_METHODS", pipeline[start:end])
    swift = swift.replace("// FILE_IMPORT_METHOD", method(handler, "private func handleIPAImport("))
    swift = swift.replace("// DOCUMENT_PICKER_METHOD", method(picker, "func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt"))
    (work / "Check.swift").write_text(swift)
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5",
                    str(work / "Check.swift"), str(root / "AltStore/Extensions/FileManager+URLs.swift"),
                    "-o", str(work / "check")], check=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=directory))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        result = subprocess.call([str(work / "check"), directory,
                                  "http://127.0.0.1:" + str(server.server_port), *sys.argv[1:]])
    finally:
        server.shutdown()
        server.server_close()
    sys.exit(result)
