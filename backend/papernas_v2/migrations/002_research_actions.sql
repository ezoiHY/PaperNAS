CREATE TABLE research_actions (
    id text PRIMARY KEY,
    question_id text NOT NULL REFERENCES research_questions(id),
    judgment_id text REFERENCES judgments(id),
    title text NOT NULL,
    hypothesis text NOT NULL DEFAULT '',
    method text NOT NULL DEFAULT '',
    baseline text NOT NULL DEFAULT '',
    metrics text NOT NULL DEFAULT '',
    success_criterion text NOT NULL DEFAULT '',
    stop_condition text NOT NULL DEFAULT '',
    resource_budget text NOT NULL DEFAULT '',
    status text NOT NULL DEFAULT 'planned' CHECK(status IN ('planned','running','completed','abandoned')),
    revision bigint NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE research_results ADD COLUMN action_id text REFERENCES research_actions(id);
CREATE TABLE research_snapshots (
    id text PRIMARY KEY,
    question_id text NOT NULL REFERENCES research_questions(id),
    title text NOT NULL,
    understanding text NOT NULL,
    open_questions text NOT NULL DEFAULT '',
    next_focus text NOT NULL DEFAULT '',
    evidence_ids jsonb NOT NULL DEFAULT '[]',
    question_revision bigint NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX evidence_question ON evidence(question_id,created_at);
CREATE INDEX judgments_question ON judgments(question_id,updated_at);
CREATE INDEX invocations_stage_request ON model_invocations(stage_id,request_hash,created_at DESC);
CREATE INDEX assets_created ON assets(created_at);
