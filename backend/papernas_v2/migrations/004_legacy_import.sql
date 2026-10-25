-- HTML extraction in v1 did not have PDF page anchors. Preserve that unknown
-- value instead of inventing page 1 for migrated evidence.
ALTER TABLE blocks ALTER COLUMN page DROP NOT NULL;
ALTER TABLE figures ALTER COLUMN page DROP NOT NULL;
ALTER TABLE notes ADD COLUMN prefix text NOT NULL DEFAULT '';
ALTER TABLE notes ADD COLUMN suffix text NOT NULL DEFAULT '';

CREATE TABLE legacy_imports (
    snapshot_sha text PRIMARY KEY REFERENCES assets(sha256),
    source text NOT NULL,
    counts jsonb NOT NULL,
    imported_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE legacy_records (
    work_id text PRIMARY KEY REFERENCES works(id),
    source_identity text UNIQUE NOT NULL,
    document_id text REFERENCES documents(id),
    original_asset text NOT NULL REFERENCES assets(sha256),
    brief jsonb,
    summary text NOT NULL DEFAULT '',
    markdown text NOT NULL DEFAULT '',
    bibliography jsonb NOT NULL DEFAULT '{}'
);
