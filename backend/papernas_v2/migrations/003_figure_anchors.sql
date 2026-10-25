ALTER TABLE figures ADD COLUMN desired_generation bigint NOT NULL DEFAULT 0;
ALTER TABLE evidence ADD COLUMN source_anchor jsonb NOT NULL DEFAULT '{}';
