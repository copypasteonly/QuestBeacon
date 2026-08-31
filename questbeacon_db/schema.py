SCHEMA_VERSION = 4

SCHEMA_SQL = """
PRAGMA foreign_keys=ON;
PRAGMA application_id=1363298644;
PRAGMA user_version=4;

CREATE TABLE maps (
  id INTEGER PRIMARY KEY,
  directory TEXT NOT NULL,
  instance_type INTEGER NOT NULL,
  name_en_us TEXT,
  area_table_id INTEGER
);
CREATE TABLE areas (
  id INTEGER PRIMARY KEY,
  map_id INTEGER NOT NULL,
  parent_area_id INTEGER,
  name_en_us TEXT,
  world_map_area_id INTEGER,
  loc_left REAL, loc_right REAL, loc_top REAL, loc_bottom REAL,
  mapping_status TEXT NOT NULL
);
CREATE TABLE quests (
  id INTEGER PRIMARY KEY,
  level INTEGER NOT NULL,
  min_level INTEGER NOT NULL,
  race_mask INTEGER NOT NULL,
  class_mask INTEGER NOT NULL,
  quest_sort INTEGER,
  skill_id INTEGER,
  event_id INTEGER,
  title_en_us TEXT
);
CREATE TABLE quest_prerequisites (
  quest_id INTEGER NOT NULL,
  prerequisite_quest_id INTEGER NOT NULL,
  ordinal INTEGER NOT NULL,
  PRIMARY KEY (quest_id, prerequisite_quest_id),
  FOREIGN KEY (quest_id) REFERENCES quests(id)
);
CREATE TABLE entities (
  kind INTEGER NOT NULL,
  entry_id INTEGER NOT NULL,
  level_min INTEGER,
  level_max INTEGER,
  name_en_us TEXT,
  data_status TEXT NOT NULL CHECK (data_status IN ('full', 'name_only')),
  coordinate_count INTEGER NOT NULL CHECK (coordinate_count >= 0),
  PRIMARY KEY (kind, entry_id)
);
CREATE TABLE entity_clusters (
  kind INTEGER NOT NULL,
  entry_id INTEGER NOT NULL,
  cluster_id INTEGER NOT NULL,
  area_id INTEGER NOT NULL,
  mapped_area_id INTEGER,
  map_id INTEGER,
  world_x REAL, world_y REAL,
  map_x REAL NOT NULL, map_y REAL NOT NULL,
  point_count INTEGER NOT NULL,
  radius REAL NOT NULL,
  is_noise INTEGER NOT NULL,
  conversion_status TEXT NOT NULL,
  PRIMARY KEY (kind, entry_id, cluster_id),
  FOREIGN KEY (kind, entry_id) REFERENCES entities(kind, entry_id)
);
CREATE TABLE item_sources (
  item_id INTEGER NOT NULL,
  source_kind INTEGER NOT NULL,
  source_id INTEGER NOT NULL,
  rate_pct REAL NOT NULL,
  provenance TEXT NOT NULL,
  PRIMARY KEY (item_id, source_kind, source_id, provenance)
);
CREATE TABLE reference_loot_sources (
  reference_id INTEGER NOT NULL,
  source_kind INTEGER NOT NULL,
  source_id INTEGER NOT NULL,
  PRIMARY KEY (reference_id, source_kind, source_id)
);
CREATE TABLE quest_objective_sources (
  quest_id INTEGER NOT NULL,
  objective_index INTEGER,
  source_kind INTEGER NOT NULL,
  source_id INTEGER NOT NULL,
  ordinal INTEGER NOT NULL,
  PRIMARY KEY (quest_id, source_kind, source_id, ordinal),
  FOREIGN KEY (quest_id) REFERENCES quests(id)
);
CREATE TABLE quest_starters (
  quest_id INTEGER NOT NULL,
  source_kind INTEGER NOT NULL,
  source_id INTEGER NOT NULL,
  PRIMARY KEY (quest_id, source_kind, source_id),
  FOREIGN KEY (quest_id) REFERENCES quests(id)
);
CREATE TABLE quest_area_candidates (
  area_id INTEGER NOT NULL,
  quest_id INTEGER NOT NULL,
  source_kind INTEGER NOT NULL,
  source_id INTEGER NOT NULL,
  cluster_id INTEGER NOT NULL,
  PRIMARY KEY (area_id, quest_id, source_kind, source_id, cluster_id),
  FOREIGN KEY (area_id) REFERENCES areas(id),
  FOREIGN KEY (quest_id, source_kind, source_id)
    REFERENCES quest_starters(quest_id, source_kind, source_id),
  FOREIGN KEY (source_kind, source_id, cluster_id)
    REFERENCES entity_clusters(kind, entry_id, cluster_id)
);
CREATE TABLE quest_enders (
  quest_id INTEGER NOT NULL,
  source_kind INTEGER NOT NULL,
  source_id INTEGER NOT NULL,
  PRIMARY KEY (quest_id, source_kind, source_id),
  FOREIGN KEY (quest_id) REFERENCES quests(id)
);
CREATE TABLE item_use_targets (
  item_id INTEGER NOT NULL,
  target_kind INTEGER NOT NULL,
  target_id INTEGER NOT NULL,
  PRIMARY KEY (item_id, target_kind, target_id)
);
CREATE TABLE quest_fallback_targets (
  quest_id INTEGER NOT NULL,
  objective_index INTEGER,
  source_kind INTEGER NOT NULL,
  source_id INTEGER NOT NULL,
  area_id INTEGER NOT NULL,
  mapped_area_id INTEGER,
  map_id INTEGER,
  world_x REAL, world_y REAL,
  map_x REAL NOT NULL, map_y REAL NOT NULL,
  conversion_status TEXT NOT NULL,
  PRIMARY KEY (quest_id, source_kind, source_id, area_id, map_x, map_y),
  FOREIGN KEY (quest_id) REFERENCES quests(id)
);
CREATE TABLE build_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);

CREATE INDEX idx_clusters_entry ON entity_clusters(kind, entry_id);
CREATE INDEX idx_clusters_area ON entity_clusters(area_id, map_id);
CREATE INDEX idx_item_sources ON item_sources(item_id, source_kind);
CREATE INDEX idx_reference_sources ON reference_loot_sources(reference_id, source_kind);
CREATE INDEX idx_objective_quest ON quest_objective_sources(quest_id);
CREATE INDEX idx_starters_quest ON quest_starters(quest_id);
CREATE INDEX idx_enders_quest ON quest_enders(quest_id);
CREATE INDEX idx_fallback_quest ON quest_fallback_targets(quest_id, objective_index);
CREATE INDEX idx_prerequisites_quest ON quest_prerequisites(quest_id, ordinal);
CREATE INDEX idx_quests_eligibility ON quests(min_level, race_mask, class_mask);
CREATE INDEX idx_area_candidates_area ON quest_area_candidates(area_id, quest_id);
CREATE INDEX idx_area_candidates_quest ON quest_area_candidates(quest_id, area_id);
CREATE INDEX idx_clusters_complete ON entity_clusters(kind, entry_id, cluster_id);
"""
