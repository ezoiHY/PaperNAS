# Native Mac client

SwiftUI navigation and forms, PDFKit for original documents, local KaTeX/WebKit for math, and Keychain for device credentials. Requires macOS 14+, Swift 6, and Xcode Command Line Tools. UI labels are currently primarily Chinese; paper content retains its source language. The new browser client uses English labels.

![Native Mac reading view with chapter navigation and source citations](../docs/images/macos-analysis.jpg)

**[Take the Mac app tour](../docs/MACOS-GALLERY.md)** for 17 screenshots of the library, focused reading, PDF notes, source figures, evidence capture, research plans, comparison, tasks, and dark appearance. All pictured papers and research records are synthetic demonstration content.

From the repository root:

```sh
bash scripts/build-app.sh release
bash scripts/test-mac.sh
```

Open `dist/Paper NAS.app` and connect to your API. The default is `http://127.0.0.1:8788`; use HTTPS for remote servers. The application preserves existing saved connections and identifiers when upgraded.

For an intentionally trusted private-network HTTP deployment:

```sh
PAPERNAS_HTTP_HOST='your-private-host.example' bash scripts/build-app.sh release
```

The value is one hostname or IP without scheme, port, or path. It adds a narrow App Transport Security exception to the built app only; it does not provide TLS. The API client also validates schemes, host classes, and same-origin redirects. Prefer HTTPS.

Set `PAPERNAS_SIGN_IDENTITY` to your own signing identity for distribution. By default builds are ad-hoc signed. Developer ID signing, notarization, stapling, and a clean-machine Gatekeeper check are separate release steps; ad-hoc builds are not notarized public binaries.

Open `Package.swift` in Xcode for development. Optional private-server tests use `PAPER_NAS_TEST_CONNECTION_FILE`; legacy projection tests use `PAPER_NAS_REPORT_FIXTURES`. Neither belongs in Git or releases. Default Swift tests use synthetic fixtures.

`scripts/preview-v2.sh` is a developer utility that builds an isolated preview identity from an existing app and private connection file. End users only need the normal app.
