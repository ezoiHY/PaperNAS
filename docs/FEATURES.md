# Features and limits

| Capability | Browser | Mac |
| --- | --- | --- |
| Library, candidates, search, filters, groups, batch organization | Yes | Yes |
| PDF/DOI/arXiv/link import | Yes | Yes |
| Analysis, extraction, source discovery | Yes | Yes |
| Original PDF and authenticated figure downloads | Server-rendered PDF pages and original download | PDFKit |
| Notes and shared reading position | Explicit page and quotation | Native PDF selection/rectangle anchors |
| Source blocks and immutable research evidence | Yes | Yes |
| Questions, judgments/history, plans, results, understanding | Yes | Yes |
| Comparison and Markdown/JSON research exports | Yes | Yes |
| Figure correction | Page preview with PDF-point coordinates | Native region selection |
| Durable tasks and manual uncertain-call reconciliation | Yes | Yes |
| Provider/discovery settings, device management | Yes | Yes |
| Math in analysis | Safe text; export retains source | Local KaTeX |
| Interface language | English | Primarily Chinese |
| Credential persistence | Tab session storage | Keychain |

Browser analysis rendering supports current structured reports and conservative legacy Markdown. It does not execute imported HTML. Browser PDF pages are rendered by the server; use the explicit page field and Save position for synchronization. Download the original file when you want local text selection or another PDF viewer. No offline editing queue is provided.

Model analysis is opt-in. The configured provider receives excerpts and may charge for them. Token budgets are reservations/accounting, not a money cap. A successful citation check proves the quote occurs in the supplied text; it does not establish the claim's validity or complete coverage.

Daily discovery adds a bounded number of candidates per source. Earlier automatic ranking/deep-reading pipelines are not part of this backend. Candidate feedback is stored but does not train a model or automatically adjust ranking.

Not implemented: semantic/vector search, Zotero synchronization, OpenReview/PMLR acquisition, scanned PDF OCR, reliable formula transcription, automatic experiment execution, multi-user permissions, offline sync, and signed/notarized public Mac releases.

The server retains evidence and earlier document versions for provenance. Removing a paper from the visible library does not imply secure erasure of every stored object. There is no general-purpose storage garbage collector in this release.
