# API conventions

Current API prefix: `/api/v2`. `/health` is unauthenticated and reports `api_version`, application version, and worker count. FastAPI's `/docs` and `/openapi.json` describe endpoints and schemas; authorization is still required for workspace data.

## Authentication

`POST /api/v2/auth/devices` exchanges the owner's access key and a device name for a device token. Send it as `Authorization: Bearer …`. Tokens are stored as hashes on the server and can be revoked through `/devices`. A device has access to the entire personal workspace.

## Mutations

Send `Idempotency-Key` on business mutations: 16–128 alphanumeric, dash, or underscore characters. Reuse a key only when retrying the exact same method, path, and body after an uncertain outcome. Reusing it for a different payload returns an error. Provider-key updates and device registration have their own explicit semantics.

Send the most recently read `revision` when editing a revisioned resource. A 409 revision conflict means the client must refresh and reconcile its unsaved input, not silently overwrite newer state.

## Resources

| Endpoints | Purpose |
| --- | --- |
| `/works`, `/works/{id}` | Library/candidates, search, material state, paper details and collection/group changes |
| `/imports/pdf`, `/operations` | PDF upload and durable import/extract/analyze/discover/compare/repair operations |
| `/works/{id}/pdf`, `/assets/{sha}` | Authenticated original documents and assets |
| `/blocks/{id}`, `/figures/{id}/page-preview` | Immutable source text and PDF previews for figure correction |
| `/groups`, `/works/{id}/notes`, `/works/{id}/reading-state` | Organization and personal reading records |
| `/research/questions/{id}` | Question with papers, evidence, judgments, plans, results, snapshots, and comparisons |
| `/research/questions/{id}/export` | Markdown or JSON research export |
| `/operations/{id}/{action}` | Pause, resume, retry, cancel |
| `/model-invocations/{id}/resolve` | Explicit reconciliation of an unknown provider outcome |
| `/settings/model`, `/settings/model/key`, `/settings/discovery` | Configuration; reads never reveal provider keys |
| `/events?after={cursor}` | Committed event stream |

The server retains selected `/papers` and `/jobs` aliases for native compatibility. New clients should use the documented v2 resources. Do not expose the database directly to clients.
