from __future__ import annotations

import hashlib
import json
import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from questbeacon_db.schema import SCHEMA_VERSION


EXPECTED_TABLES = {
    "maps", "areas", "quests", "entities", "entity_clusters", "item_sources",
    "reference_loot_sources", "quest_objective_sources", "quest_starters",
    "quest_enders", "item_use_targets", "quest_fallback_targets", "quest_prerequisites",
    "quest_area_candidates", "build_metadata",
}
EXPECTED_INDEXES = {
    "idx_clusters_entry", "idx_clusters_area", "idx_item_sources",
    "idx_reference_sources", "idx_objective_quest", "idx_starters_quest",
    "idx_enders_quest", "idx_fallback_quest", "idx_prerequisites_quest", "idx_quests_eligibility",
    "idx_area_candidates_area", "idx_area_candidates_quest", "idx_clusters_complete",
}


@dataclass(frozen=True)
class ValidationResult:
    ok: bool
    digest: str
    errors: tuple[str, ...]
    warnings: tuple[str, ...]
    counts: dict[str, int]

    def as_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok, "digest": self.digest, "errors": list(self.errors),
            "warnings": list(self.warnings), "counts": dict(sorted(self.counts.items())),
        }


def validate_database(path: Path) -> ValidationResult:
    path = path.resolve()
    if not path.is_file():
        return ValidationResult(False, "", (f"database does not exist: {path}",), (), {})
    errors: list[str] = []
    warnings: list[str] = []
    counts: dict[str, int] = {}
    connection = sqlite3.connect(f"file:{path.as_posix()}?mode=ro", uri=True)
    try:
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        missing_tables = sorted(EXPECTED_TABLES - tables)
        if missing_tables:
            errors.append("missing tables: " + ", ".join(missing_tables))
            return ValidationResult(False, "", tuple(errors), (), {})
        indexes = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='index'")}
        missing_indexes = sorted(EXPECTED_INDEXES - indexes)
        if missing_indexes:
            errors.append("missing indexes: " + ", ".join(missing_indexes))
        if connection.execute("PRAGMA user_version").fetchone()[0] != SCHEMA_VERSION:
            errors.append("schema version does not match the generator")
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            errors.append(f"integrity check failed: {integrity}")
        foreign_keys = list(connection.execute("PRAGMA foreign_key_check"))
        if foreign_keys:
            errors.append(f"foreign key check found {len(foreign_keys)} violation(s)")

        for table in sorted(EXPECTED_TABLES):
            counts[table] = int(connection.execute(f"SELECT count(*) FROM {table}").fetchone()[0])
        bad_rates = connection.execute(
            "SELECT count(*) FROM item_sources WHERE rate_pct < 0 OR rate_pct > 100"
        ).fetchone()[0]
        if bad_rates:
            errors.append(f"item_sources has {bad_rates} rate(s) outside 0..100")
        bad_clusters = connection.execute(
            "SELECT count(*) FROM entity_clusters WHERE point_count < 1 OR radius < 0"
        ).fetchone()[0]
        if bad_clusters:
            errors.append(f"entity_clusters has {bad_clusters} invalid summary row(s)")
        partial_world = connection.execute(
            "SELECT count(*) FROM entity_clusters WHERE (world_x IS NULL) <> (world_y IS NULL)"
        ).fetchone()[0]
        if partial_world:
            errors.append(f"entity_clusters has {partial_world} partial world coordinate row(s)")
        converted_missing = connection.execute(
            "SELECT count(*) FROM entity_clusters WHERE conversion_status LIKE 'converted_%' AND world_x IS NULL"
        ).fetchone()[0]
        if converted_missing:
            errors.append(f"entity_clusters has {converted_missing} converted row(s) without world coordinates")

        invalid_candidates = connection.execute(
            """SELECT count(*) FROM quest_area_candidates a
               JOIN entity_clusters c ON c.kind=a.source_kind AND c.entry_id=a.source_id
                 AND c.cluster_id=a.cluster_id
               WHERE c.world_x IS NULL OR c.world_y IS NULL
                 OR a.area_id <> COALESCE(c.mapped_area_id,c.area_id)"""
        ).fetchone()[0]
        if invalid_candidates:
            errors.append(f"quest_area_candidates has {invalid_candidates} invalid cluster mapping(s)")
        missing_candidates = connection.execute(
            """SELECT count(*) FROM quest_starters s
               JOIN entity_clusters c ON c.kind=s.source_kind AND c.entry_id=s.source_id
               WHERE c.world_x IS NOT NULL AND c.world_y IS NOT NULL AND NOT EXISTS (
                 SELECT 1 FROM quest_area_candidates a
                 WHERE a.area_id=COALESCE(c.mapped_area_id,c.area_id)
                   AND a.quest_id=s.quest_id AND a.source_kind=s.source_kind
                   AND a.source_id=s.source_id AND a.cluster_id=c.cluster_id
               )"""
        ).fetchone()[0]
        if missing_candidates:
            errors.append(f"quest_area_candidates is missing {missing_candidates} authored starter cluster(s)")

        dangling_objectives = connection.execute(
            """SELECT count(*) FROM quest_objective_sources q
               WHERE q.source_kind IN (1,2) AND NOT EXISTS (
                 SELECT 1 FROM entities e WHERE e.kind=q.source_kind AND e.entry_id=q.source_id
               )"""
        ).fetchone()[0]
        if dangling_objectives:
            errors.append(f"{dangling_objectives} objective entity reference(s) are missing")
        lost_authored_coordinates = connection.execute(
            """SELECT count(*) FROM quest_objective_sources q
               JOIN entities e ON e.kind=q.source_kind AND e.entry_id=q.source_id
               WHERE q.source_kind IN (1,2) AND e.coordinate_count > 0 AND NOT EXISTS (
                 SELECT 1 FROM entity_clusters c WHERE c.kind=q.source_kind AND c.entry_id=q.source_id
               )"""
        ).fetchone()[0]
        if lost_authored_coordinates:
            errors.append(f"{lost_authored_coordinates} objective source(s) lost authored coordinates")
        objectives_without_locations = connection.execute(
            """SELECT count(*) FROM quest_objective_sources q
               JOIN entities e ON e.kind=q.source_kind AND e.entry_id=q.source_id
               WHERE q.source_kind IN (1,2) AND e.coordinate_count = 0 AND NOT EXISTS (
                 SELECT 1 FROM entity_clusters c WHERE c.kind=q.source_kind AND c.entry_id=q.source_id
               )"""
        ).fetchone()[0]
        if objectives_without_locations:
            warnings.append(f"{objectives_without_locations} objective source(s) have no authored coordinates")
        out_of_bounds = connection.execute(
            "SELECT count(*) FROM entity_clusters WHERE map_x < 0 OR map_x > 100 OR map_y < 0 OR map_y > 100"
        ).fetchone()[0]
        if out_of_bounds:
            warnings.append(f"{out_of_bounds} cluster(s) have map percentages outside 0..100")
        metadata = dict(connection.execute("SELECT key, value FROM build_metadata"))
        for key in ("schema_version", "generator_version", "pfquest_commit", "pfquest_octo_commit", "source_snapshot"):
            if not metadata.get(key):
                errors.append(f"missing build metadata: {key}")
        digest = canonical_digest(connection)
    finally:
        connection.close()
    return ValidationResult(not errors, digest, tuple(errors), tuple(warnings), counts)


def canonical_digest(connection: sqlite3.Connection) -> str:
    digest = hashlib.sha256()
    tables = sorted(EXPECTED_TABLES)
    for table in tables:
        columns = [row[1] for row in connection.execute(f"PRAGMA table_info({table})")]
        order = ",".join(f'"{column}"' for column in columns)
        digest.update((table + "\n").encode("utf-8"))
        for row in connection.execute(f"SELECT * FROM {table} ORDER BY {order}"):
            digest.update(json.dumps(row, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
            digest.update(b"\n")
    return digest.hexdigest()
