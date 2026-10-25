CREATE TABLE settings (
    key text PRIMARY KEY,
    value jsonb NOT NULL,
    revision bigint NOT NULL DEFAULT 1
);

CREATE TABLE devices (
    id text PRIMARY KEY,
    name text NOT NULL,
    token_hash text UNIQUE NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz
);

CREATE TABLE requests (
    scope text NOT NULL,
    key text NOT NULL,
    fingerprint text NOT NULL,
    response jsonb NOT NULL DEFAULT '{}',
    status_code integer NOT NULL DEFAULT 200,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(scope, key)
);

CREATE TABLE assets (
    sha256 text PRIMARY KEY CHECK (sha256 ~ '^[a-f0-9]{64}$'),
    media_type text NOT NULL,
    byte_size bigint NOT NULL CHECK (byte_size >= 0),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE works (
    id text PRIMARY KEY,
    title text NOT NULL,
    authors jsonb NOT NULL DEFAULT '[]',
    abstract text NOT NULL DEFAULT '',
    source text NOT NULL DEFAULT 'local',
    source_url text NOT NULL DEFAULT '',
    published_at text NOT NULL DEFAULT '',
    venue text NOT NULL DEFAULT '',
    collection text NOT NULL DEFAULT 'library' CHECK(collection IN ('library','candidates')),
    current_version_id text,
    current_document_id text,
    current_analysis_id text,
    desired_analysis_generation bigint NOT NULL DEFAULT 0,
    revision bigint NOT NULL DEFAULT 1,
    enrichment jsonb NOT NULL DEFAULT '{}',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);
CREATE INDEX works_created ON works(created_at DESC, id);
CREATE INDEX works_collection ON works(collection) WHERE deleted_at IS NULL;

CREATE TABLE external_ids (
    source text NOT NULL,
    identifier text NOT NULL,
    work_id text NOT NULL REFERENCES works(id),
    PRIMARY KEY(source, identifier)
);

CREATE TABLE work_versions (
    id text PRIMARY KEY,
    work_id text NOT NULL REFERENCES works(id),
    label text NOT NULL DEFAULT '',
    source_url text NOT NULL DEFAULT '',
    pdf_asset text REFERENCES assets(sha256),
    html_asset text REFERENCES assets(sha256),
    metadata jsonb NOT NULL DEFAULT '{}',
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(work_id, label)
);
ALTER TABLE works ADD FOREIGN KEY(current_version_id) REFERENCES work_versions(id);

CREATE TABLE documents (
    id text PRIMARY KEY,
    version_id text NOT NULL REFERENCES work_versions(id),
    input_hash text NOT NULL,
    parser text NOT NULL,
    parser_version text NOT NULL,
    structure_quality text NOT NULL,
    page_count integer NOT NULL DEFAULT 0,
    artifact_sha text NOT NULL REFERENCES assets(sha256),
    warnings jsonb NOT NULL DEFAULT '[]',
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(version_id, input_hash, parser, parser_version)
);
ALTER TABLE works ADD FOREIGN KEY(current_document_id) REFERENCES documents(id);

CREATE TABLE blocks (
    id text PRIMARY KEY,
    document_id text NOT NULL REFERENCES documents(id),
    ordinal integer NOT NULL,
    kind text NOT NULL DEFAULT 'paragraph',
    page integer NOT NULL CHECK(page >= 1),
    text text NOT NULL,
    bbox jsonb NOT NULL DEFAULT '{}',
    heading text NOT NULL DEFAULT '',
    search tsvector GENERATED ALWAYS AS (to_tsvector('english', text)) STORED,
    UNIQUE(document_id, ordinal)
);
CREATE INDEX blocks_search ON blocks USING gin(search);

CREATE TABLE figures (
    id text PRIMARY KEY,
    document_id text NOT NULL REFERENCES documents(id),
    label text NOT NULL,
    caption text NOT NULL DEFAULT '',
    page integer NOT NULL CHECK(page >= 1),
    bbox jsonb NOT NULL DEFAULT '{}',
    status text NOT NULL DEFAULT 'pending',
    asset_sha text REFERENCES assets(sha256),
    provenance jsonb NOT NULL DEFAULT '{}',
    error text NOT NULL DEFAULT '',
    revision bigint NOT NULL DEFAULT 1,
    UNIQUE(document_id, label)
);

CREATE TABLE groups (
    id text PRIMARY KEY,
    name text NOT NULL,
    revision bigint NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE group_works (
    group_id text NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    work_id text NOT NULL REFERENCES works(id),
    PRIMARY KEY(group_id, work_id)
);

CREATE TABLE notes (
    id text PRIMARY KEY,
    work_id text NOT NULL REFERENCES works(id),
    pdf_sha256 text NOT NULL,
    page integer NOT NULL CHECK(page >= 1),
    selected_text text NOT NULL DEFAULT '',
    rects jsonb NOT NULL DEFAULT '[]',
    body text NOT NULL DEFAULT '',
    revision bigint NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE reading_state (
    work_id text PRIMARY KEY REFERENCES works(id),
    pdf_sha256 text,
    page integer NOT NULL DEFAULT 1,
    section text NOT NULL DEFAULT 'report',
    revision bigint NOT NULL DEFAULT 1,
    device_id text REFERENCES devices(id),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE research_questions (
    id text PRIMARY KEY,
    title text NOT NULL,
    context text NOT NULL DEFAULT '',
    constraints text NOT NULL DEFAULT '',
    status text NOT NULL DEFAULT 'active' CHECK(status IN ('active','paused','completed')),
    revision bigint NOT NULL DEFAULT 1,
    desired_comparison_generation bigint NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE question_works (
    question_id text NOT NULL REFERENCES research_questions(id),
    work_id text NOT NULL REFERENCES works(id),
    reason text NOT NULL DEFAULT '',
    PRIMARY KEY(question_id, work_id)
);
CREATE TABLE evidence (
    id text PRIMARY KEY,
    question_id text NOT NULL REFERENCES research_questions(id),
    work_id text NOT NULL REFERENCES works(id),
    document_id text NOT NULL REFERENCES documents(id),
    block_id text REFERENCES blocks(id),
    figure_id text REFERENCES figures(id),
    quote text NOT NULL DEFAULT '',
    note text NOT NULL DEFAULT '',
    relation text NOT NULL DEFAULT 'context' CHECK(relation IN ('supports','contradicts','context')),
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (block_id IS NOT NULL OR figure_id IS NOT NULL)
);
CREATE TABLE judgments (
    id text PRIMARY KEY,
    question_id text NOT NULL REFERENCES research_questions(id),
    statement text NOT NULL,
    rationale text NOT NULL DEFAULT '',
    next_step text NOT NULL DEFAULT '',
    status text NOT NULL DEFAULT 'tentative' CHECK(status IN ('tentative','accepted','revised')),
    evidence_ids jsonb NOT NULL DEFAULT '[]',
    revision bigint NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE judgment_history (
    id bigserial PRIMARY KEY,
    judgment_id text NOT NULL REFERENCES judgments(id),
    revision bigint NOT NULL,
    snapshot jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(judgment_id, revision)
);
CREATE TABLE research_results (
    id text PRIMARY KEY,
    question_id text NOT NULL REFERENCES research_questions(id),
    judgment_id text REFERENCES judgments(id),
    title text NOT NULL,
    outcome text NOT NULL CHECK(outcome IN ('supports','contradicts','inconclusive','observation')),
    body text NOT NULL,
    metrics jsonb NOT NULL DEFAULT '{}',
    artifact_url text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE operations (
    id text PRIMARY KEY,
    kind text NOT NULL,
    input jsonb NOT NULL,
    state text NOT NULL DEFAULT 'queued',
    cancel_requested boolean NOT NULL DEFAULT false,
    pause_requested boolean NOT NULL DEFAULT false,
    budget_limit bigint NOT NULL DEFAULT 120000 CHECK(budget_limit >= 0),
    budget_used bigint NOT NULL DEFAULT 0 CHECK(budget_used >= 0),
    budget_reserved bigint NOT NULL DEFAULT 0 CHECK(budget_reserved >= 0),
    result jsonb NOT NULL DEFAULT '{}',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE stages (
    id text PRIMARY KEY,
    operation_id text NOT NULL REFERENCES operations(id),
    kind text NOT NULL,
    queue text NOT NULL,
    input jsonb NOT NULL,
    input_hash text NOT NULL,
    outcome text NOT NULL DEFAULT 'pending',
    generation bigint NOT NULL DEFAULT 0,
    attempts integer NOT NULL DEFAULT 0,
    queue_job_id bigint,
    result jsonb NOT NULL DEFAULT '{}',
    error jsonb NOT NULL DEFAULT '{}',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(operation_id, kind, input_hash)
);
CREATE INDEX stage_operation ON stages(operation_id);
CREATE TABLE stage_dependencies (
    stage_id text NOT NULL REFERENCES stages(id),
    depends_on text NOT NULL REFERENCES stages(id),
    PRIMARY KEY(stage_id, depends_on),
    CHECK(stage_id <> depends_on)
);
CREATE TABLE attempts (
    id text PRIMARY KEY,
    stage_id text NOT NULL REFERENCES stages(id),
    generation bigint NOT NULL,
    status text NOT NULL DEFAULT 'running',
    error jsonb NOT NULL DEFAULT '{}',
    started_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    UNIQUE(stage_id, generation)
);
CREATE TABLE model_invocations (
    id text PRIMARY KEY,
    stage_id text NOT NULL REFERENCES stages(id),
    generation bigint NOT NULL,
    purpose text NOT NULL,
    request_hash text NOT NULL,
    model text NOT NULL,
    state text NOT NULL DEFAULT 'reserved',
    reserved_tokens bigint NOT NULL,
    used_tokens bigint,
    response_sha text REFERENCES assets(sha256),
    error text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE analyses (
    id text PRIMARY KEY,
    work_id text REFERENCES works(id),
    question_id text REFERENCES research_questions(id),
    document_id text REFERENCES documents(id),
    operation_id text NOT NULL REFERENCES operations(id),
    kind text NOT NULL,
    generation bigint NOT NULL,
    input_hash text NOT NULL,
    data jsonb NOT NULL,
    artifact_sha text NOT NULL REFERENCES assets(sha256),
    created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE works ADD FOREIGN KEY(current_analysis_id) REFERENCES analyses(id);

CREATE TABLE source_checkpoints (
    source text NOT NULL,
    scope text NOT NULL,
    cursor jsonb NOT NULL DEFAULT '{}',
    coverage jsonb NOT NULL DEFAULT '{}',
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(source, scope)
);
CREATE TABLE source_requests (
    id text PRIMARY KEY,
    operation_id text NOT NULL REFERENCES operations(id),
    source text NOT NULL,
    query jsonb NOT NULL,
    status text NOT NULL,
    result jsonb NOT NULL DEFAULT '{}',
    error text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE provider_limits (
    provider text PRIMARY KEY,
    next_allowed_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE feedback (
    work_id text NOT NULL REFERENCES works(id),
    question_id text NOT NULL DEFAULT '',
    choice text NOT NULL CHECK(choice IN ('useful','known','later','irrelevant')),
    reason text NOT NULL DEFAULT '',
    revision bigint NOT NULL DEFAULT 1,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(work_id, question_id)
);

CREATE TABLE outbox (
    id text PRIMARY KEY,
    kind text NOT NULL,
    entity_id text NOT NULL,
    revision bigint NOT NULL DEFAULT 0,
    payload jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    delivered boolean NOT NULL DEFAULT false
);
CREATE INDEX outbox_pending ON outbox(created_at, id) WHERE delivered = false;
CREATE TABLE event_counter (singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton), cursor bigint NOT NULL);
INSERT INTO event_counter VALUES(true, 0);
CREATE TABLE events (
    cursor bigint PRIMARY KEY,
    event_id text UNIQUE NOT NULL,
    kind text NOT NULL,
    entity_id text NOT NULL,
    revision bigint NOT NULL,
    payload jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

