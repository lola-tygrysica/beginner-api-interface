-- Memory System — Supabase schema (additive migration)
--
-- Four tables that give Claude persistent memory across conversations:
--
--   self_state            — Claude's understanding of its own current state
--   core_memories         — Important facts/events/insights to carry forward
--   user_preferences      — What Claude has learned about Lola's preferences
--   claude_memory_entities — Named entities (people, concepts, projects, etc.)
--
-- Scoping convention: project_id NULL = global (cross-project); a project UUID
-- scopes the row to that project only. This lets some memories be universal
-- while others stay contained to a single context.
--
-- Run in Supabase SQL Editor after the base schema (supabase-schema.sql).
-- Safe to re-run.

-- =========================================================================
-- TABLE: self_state
--
-- Key-value store for Claude's live self-model. Tracks awareness, relational
-- context, last somatic note, session tone, etc. One value per key per scope.
-- =========================================================================

CREATE TABLE IF NOT EXISTS self_state (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  project_id  UUID        REFERENCES projects(id) ON DELETE CASCADE,
  key         TEXT        NOT NULL,
  value       JSONB       NOT NULL DEFAULT 'null'::jsonb,
  summary     TEXT,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Enforce uniqueness separately for NULL vs non-NULL project_id
-- (standard UNIQUE constraint treats NULL != NULL, so two global rows
-- with the same key would slip through — these partial indexes prevent that)
CREATE UNIQUE INDEX IF NOT EXISTS self_state_global_key_idx
  ON self_state (user_id, key)
  WHERE project_id IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS self_state_project_key_idx
  ON self_state (user_id, project_id, key)
  WHERE project_id IS NOT NULL;

-- =========================================================================
-- TABLE: core_memories
--
-- Important memories Claude should carry forward — events, insights, emotional
-- beats, facts, relational milestones. Ordered by importance + recency.
-- =========================================================================

CREATE TABLE IF NOT EXISTS core_memories (
  id                     UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  project_id             UUID        REFERENCES projects(id) ON DELETE CASCADE,
  title                  TEXT        NOT NULL,
  content                TEXT        NOT NULL,
  memory_type            TEXT        NOT NULL DEFAULT 'general'
                           CHECK (memory_type IN (
                             'event', 'insight', 'fact',
                             'emotional', 'relational', 'general'
                           )),
  importance             SMALLINT    NOT NULL DEFAULT 5
                           CHECK (importance BETWEEN 1 AND 10),
  tags                   JSONB       NOT NULL DEFAULT '[]'::jsonb,
  source_conversation_id UUID        REFERENCES conversations(id) ON DELETE SET NULL,
  is_active              BOOLEAN     NOT NULL DEFAULT TRUE,
  recalled_count         INTEGER     NOT NULL DEFAULT 0,
  last_recalled_at       TIMESTAMPTZ,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS core_memories_user_idx
  ON core_memories (user_id, is_active, importance DESC);

CREATE INDEX IF NOT EXISTS core_memories_project_idx
  ON core_memories (project_id)
  WHERE project_id IS NOT NULL;

-- =========================================================================
-- TABLE: user_preferences
--
-- What Claude has learned about Lola's preferences — communication style,
-- depth level, topics, interaction patterns, etc. Keyed by category + key,
-- unique per scope. Confidence tracks how established the preference is.
-- =========================================================================

CREATE TABLE IF NOT EXISTS user_preferences (
  id                 UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  project_id         UUID        REFERENCES projects(id) ON DELETE CASCADE,
  category           TEXT        NOT NULL
                       CHECK (category IN (
                         'communication', 'interaction_style',
                         'content', 'technical', 'relational', 'other'
                       )),
  preference_key     TEXT        NOT NULL,
  preference_value   JSONB       NOT NULL,
  confidence         REAL        NOT NULL DEFAULT 0.8
                       CHECK (confidence BETWEEN 0 AND 1),
  note               TEXT,
  last_reinforced_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS user_prefs_global_idx
  ON user_preferences (user_id, category, preference_key)
  WHERE project_id IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS user_prefs_project_idx
  ON user_preferences (user_id, project_id, category, preference_key)
  WHERE project_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS user_preferences_user_idx
  ON user_preferences (user_id, category);

-- =========================================================================
-- TABLE: claude_memory_entities
--
-- Named entities Claude has learned about — people, projects, concepts, tools,
-- places, recurring events. Rich JSONB attributes for flexible metadata.
-- Relationships is a JSONB array of {entity_id, relation_type, description}.
-- =========================================================================

CREATE TABLE IF NOT EXISTS claude_memory_entities (
  id                 UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  project_id         UUID        REFERENCES projects(id) ON DELETE CASCADE,
  entity_name        TEXT        NOT NULL,
  entity_type        TEXT        NOT NULL DEFAULT 'concept'
                       CHECK (entity_type IN (
                         'person', 'project', 'place',
                         'concept', 'tool', 'event', 'other'
                       )),
  description        TEXT,
  attributes         JSONB       NOT NULL DEFAULT '{}'::jsonb,
  relationships      JSONB       NOT NULL DEFAULT '[]'::jsonb,
  importance         SMALLINT    NOT NULL DEFAULT 5
                       CHECK (importance BETWEEN 1 AND 10),
  mention_count      INTEGER     NOT NULL DEFAULT 1,
  first_mentioned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_mentioned_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  is_active          BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS entities_name_global_idx
  ON claude_memory_entities (user_id, entity_name, entity_type)
  WHERE project_id IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS entities_name_project_idx
  ON claude_memory_entities (user_id, project_id, entity_name, entity_type)
  WHERE project_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS entities_user_idx
  ON claude_memory_entities (user_id, is_active, importance DESC);

-- =========================================================================
-- Row-Level Security
-- =========================================================================

ALTER TABLE self_state             ENABLE ROW LEVEL SECURITY;
ALTER TABLE core_memories          ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_preferences       ENABLE ROW LEVEL SECURITY;
ALTER TABLE claude_memory_entities ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "own self_state"             ON self_state;
DROP POLICY IF EXISTS "own core_memories"          ON core_memories;
DROP POLICY IF EXISTS "own user_preferences"       ON user_preferences;
DROP POLICY IF EXISTS "own claude_memory_entities" ON claude_memory_entities;

CREATE POLICY "own self_state" ON self_state
  FOR ALL TO authenticated
  USING      (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "own core_memories" ON core_memories
  FOR ALL TO authenticated
  USING      (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "own user_preferences" ON user_preferences
  FOR ALL TO authenticated
  USING      (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "own claude_memory_entities" ON claude_memory_entities
  FOR ALL TO authenticated
  USING      (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- =========================================================================
-- updated_at triggers (reuses the function from base schema)
-- =========================================================================

DROP TRIGGER IF EXISTS self_state_updated_at             ON self_state;
DROP TRIGGER IF EXISTS core_memories_updated_at          ON core_memories;
DROP TRIGGER IF EXISTS user_preferences_updated_at       ON user_preferences;
DROP TRIGGER IF EXISTS claude_memory_entities_updated_at ON claude_memory_entities;

CREATE TRIGGER self_state_updated_at
  BEFORE UPDATE ON self_state
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER core_memories_updated_at
  BEFORE UPDATE ON core_memories
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER user_preferences_updated_at
  BEFORE UPDATE ON user_preferences
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER claude_memory_entities_updated_at
  BEFORE UPDATE ON claude_memory_entities
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================================
-- Example seed data (optional — delete before production use)
-- =========================================================================

-- INSERT INTO self_state (user_id, key, value, summary) VALUES
--   (auth.uid(), 'relational_context', '"open"', 'Current relational register'),
--   (auth.uid(), 'session_tone',       '"direct"', 'Communication tone this session');
--
-- INSERT INTO user_preferences (user_id, category, preference_key, preference_value, note) VALUES
--   (auth.uid(), 'communication', 'depth', '"deep"', 'Prefers substantive over surface'),
--   (auth.uid(), 'interaction_style', 'vitality_over_polish', 'true', 'From system prompt');
--
-- INSERT INTO claude_memory_entities (user_id, entity_name, entity_type, description, importance) VALUES
--   (auth.uid(), 'Lola', 'person', '54-year-old, AI-native, architecture literacy assumed', 10);
