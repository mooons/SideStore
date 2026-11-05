# Import regression checks

Run with macOS Command Line Tools and Python 3:

```sh
python3 Checks/check-imports.py
```

Optional arguments `url` and `files` select one group.

The check compiles the production app-resolution, install-entry, pipeline-entry,
document-picker, staging, and FileManager methods. A loopback HTTP server serves
synthetic IPAs under unrelated and extensionless URL names. It checks metadata,
source identity preservation, invalid imports, download lifetime, completion,
cancellation, cleanup, and delayed confirmation after the original Inbox file
has been removed. Both original failure cases were observed before the fixes.

UIKit presentation, Core Data, signing, and the rest of the install pipeline are
stand-ins. The archive-reader boundary uses system `unzip` instead of SideSign;
the metadata-resolution logic itself is the production method. This is not a
full iOS build or an on-device Files-provider test. The Mac used for these local
commits has Command Line Tools, without the iOS SDK or XCTest.
