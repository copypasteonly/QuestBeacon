from __future__ import annotations

import json
import hashlib
import os
import sqlite3
import tempfile
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable

from questbeacon_db import __version__
from questbeacon_db.clustering import Cluster, SpawnPoint, dbscan
from questbeacon_db.coordinates import CoordinateConverter, CoordinateResult
from questbeacon_db.dbc import DbcData, load_dbc_directory
from questbeacon_db.pfquest import PfQuestSnapshot, load_pfquest
from questbeacon_db.schema import SCHEMA_SQL, SCHEMA_VERSION


ENTITY_KIND = {"U": 1, "O": 2, "I": 3, "V": 4, "R": 5, "A": 6, "IR": 7}


def _items(value: Any) -> list[tuple[Any, Any]]:
    return sorted(value.items(), key=lambda pair: (str(type(pair[0])), str(pair[0]))) if isinstance(value, dict) else []


def _values(value: Any) -> list[Any]:
    return [child for _, child in _items(value)]


def _number(value: Any, default: float = 0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _level_range(value: Any) -> tuple[int | None, int | None]:
    if value is None:
        return None, None
    parts = str(value).split("-", 1)
    try:
        low = int(parts[0])
        high = int(parts[1]) if len(parts) == 2 else low
        return low, high
    except ValueError:
        return None, None


def _title(locale: dict[Any, Any], entry_id: int) -> str | None:
    value = locale.get(entry_id)
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return value.get("T") or value.get("N")
    return None


def _coordinate_rows(
    snapshot: PfQuestSnapshot,
    converter: CoordinateConverter,
) -> tuple[list[tuple[Any, ...]], Counter[str]]:
    rows: list[tuple[Any, ...]] = []
    stats: Counter[str] = Counter()
    zone_transforms = snapshot.data["zones"].get("data", {})
    for kind, family in ((1, "units"), (2, "objects")):
        for entry_id, entity in _items(snapshot.data[family].get("data", {})):
            if not isinstance(entity, dict):
                continue
            converted_groups: dict[tuple[int, int, int, str], list[SpawnPoint]] = defaultdict(list)
            failed: set[tuple[int, float, float, CoordinateResult]] = set()
            for coordinate in _values(entity.get("coords", {})):
                if not isinstance(coordinate, dict) or not all(key in coordinate for key in (1, 2, 3)):
                    continue
                map_x, map_y, area_id = float(coordinate[1]), float(coordinate[2]), int(coordinate[3])
                result = converter.convert(area_id, map_x, map_y, zone_transforms)
                stats[result.status] += 1
                if result.world_x is None or result.world_y is None or result.map_id is None:
                    failed.add((area_id, map_x, map_y, result))
                else:
                    key = (area_id, int(result.mapped_area_id or area_id), result.map_id, result.status)
                    converted_groups[key].append(SpawnPoint(result.world_x, result.world_y, map_x, map_y))
            summaries: list[tuple[int, int | None, int | None, Cluster | None, float, float, str]] = []
            for (area_id, mapped_area_id, map_id, status), points in sorted(converted_groups.items()):
                for cluster in dbscan(points):
                    summaries.append((area_id, mapped_area_id, map_id, cluster, cluster.map_x, cluster.map_y, status))
            for area_id, map_x, map_y, result in sorted(failed, key=lambda row: (row[0], row[1], row[2], row[3].status)):
                summaries.append((area_id, result.mapped_area_id, result.map_id, None, map_x, map_y, result.status))
            summaries.sort(key=lambda row: (row[0], row[2] if row[2] is not None else -1, row[4], row[5], row[6]))
            for cluster_id, summary in enumerate(summaries, start=1):
                area_id, mapped_area_id, map_id, cluster, map_x, map_y, status = summary
                rows.append((
                    kind, int(entry_id), cluster_id, area_id, mapped_area_id, map_id,
                    cluster.world_x if cluster else None, cluster.world_y if cluster else None,
                    map_x, map_y, cluster.point_count if cluster else 1,
                    cluster.radius if cluster else 0.0, int(cluster.is_noise if cluster else True), status,
                ))
    return rows, stats


def _relation_rows(quests: dict[Any, Any], role: str) -> list[tuple[int, int, int]]:
    rows: set[tuple[int, int, int]] = set()
    for quest_id, quest in _items(quests):
        relation = quest.get(role, {}) if isinstance(quest, dict) else {}
        for type_name, ids in _items(relation):
            if type_name not in ENTITY_KIND:
                continue
            rows.update((int(quest_id), ENTITY_KIND[type_name], int(source_id)) for source_id in _values(ids))
    return sorted(rows)


def _objective_rows(quests: dict[Any, Any]) -> list[tuple[int, None, int, int, int]]:
    rows: list[tuple[int, None, int, int, int]] = []
    for quest_id, quest in _items(quests):
        relation = quest.get("obj", {}) if isinstance(quest, dict) else {}
        ordinal = 0
        for type_name, ids in _items(relation):
            if type_name not in ENTITY_KIND:
                continue
            for source_id in _values(ids):
                ordinal += 1
                rows.append((int(quest_id), None, ENTITY_KIND[type_name], int(source_id), ordinal))
    return rows


def _fallback_rows(
    objectives: list[tuple[int, None, int, int, int]],
    snapshot: PfQuestSnapshot,
    converter: CoordinateConverter,
) -> list[tuple[Any, ...]]:
    triggers = snapshot.data["areatrigger"].get("data", {})
    transforms = snapshot.data["zones"].get("data", {})
    rows: list[tuple[Any, ...]] = []
    for quest_id, objective_index, kind, source_id, _ in objectives:
        if kind != ENTITY_KIND["A"]:
            continue
        trigger = triggers.get(source_id)
        for coordinate in _values(trigger.get("coords", {}) if isinstance(trigger, dict) else {}):
            if not isinstance(coordinate, dict) or not all(key in coordinate for key in (1, 2, 3)):
                continue
            map_x, map_y, area_id = float(coordinate[1]), float(coordinate[2]), int(coordinate[3])
            result = converter.convert(area_id, map_x, map_y, transforms)
            rows.append((quest_id, objective_index, kind, source_id, area_id, result.mapped_area_id,
                         result.map_id, result.world_x, result.world_y, map_x, map_y, result.status))
    return sorted(rows)


def _insert_all(connection: sqlite3.Connection, table: str, columns: tuple[str, ...], rows: Iterable[tuple[Any, ...]]) -> None:
    placeholders = ",".join("?" for _ in columns)
    connection.executemany(f"INSERT INTO {table} ({','.join(columns)}) VALUES ({placeholders})", rows)


def build_database(pfquest: Path, octo: Path, dbc: Path, output: Path, report: Path) -> dict[str, Any]:
    snapshot = load_pfquest(pfquest, octo)
    dbc_data = load_dbc_directory(dbc)
    converter = CoordinateConverter(dbc_data.areas, dbc_data.world_map_areas)
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    report.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=output.name + ".", suffix=".tmp", dir=output.parent)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        stats = _write_database(temporary, snapshot, dbc_data, converter)
        os.replace(temporary, output)
        stats["database"] = str(output)
    finally:
        if temporary.exists():
            temporary.unlink()
    report.write_text(json.dumps(stats, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return stats


def _write_database(
    path: Path,
    snapshot: PfQuestSnapshot,
    dbc_data: DbcData,
    converter: CoordinateConverter,
) -> dict[str, Any]:
    data = snapshot.data
    quests = data["quests"].get("data", {})
    quest_locale = data["quests"].get("enUS", {})
    cluster_rows, conversion_stats = _coordinate_rows(snapshot, converter)
    objective_rows = _objective_rows(quests)
    starter_rows = _relation_rows(quests, "start")
    ender_rows = _relation_rows(quests, "end")
    fallback_rows = _fallback_rows(objective_rows, snapshot, converter)

    connection = sqlite3.connect(path)
    try:
        connection.executescript(SCHEMA_SQL)
        with connection:
            _insert_all(connection, "maps", ("id", "directory", "instance_type", "name_en_us", "area_table_id"),
                        ((row.id, row.directory, row.instance_type, row.name_en_us, row.area_table_id) for row in sorted(dbc_data.maps, key=lambda row: row.id)))
            wma_by_area: dict[int, list[Any]] = defaultdict(list)
            for row in dbc_data.world_map_areas:
                wma_by_area[row.area_id].append(row)
            area_rows = []
            for area in sorted(dbc_data.areas, key=lambda row: row.id):
                candidates = sorted(wma_by_area.get(area.id, []), key=lambda row: row.id)
                valid = [row for row in candidates if row.loc_left != row.loc_right and row.loc_top != row.loc_bottom]
                matching = [row for row in valid if row.map_id == area.map_id]
                chosen = (matching or valid)[0] if len({(r.map_id, r.loc_left, r.loc_right, r.loc_top, r.loc_bottom) for r in (matching or valid)}) == 1 else None
                status = "mapped" if chosen else ("ambiguous" if valid else "missing")
                area_rows.append((area.id, area.map_id, area.parent_area_id or None, area.name_en_us,
                                  chosen.id if chosen else None, chosen.loc_left if chosen else None,
                                  chosen.loc_right if chosen else None, chosen.loc_top if chosen else None,
                                  chosen.loc_bottom if chosen else None, status))
            _insert_all(connection, "areas", ("id", "map_id", "parent_area_id", "name_en_us", "world_map_area_id",
                        "loc_left", "loc_right", "loc_top", "loc_bottom", "mapping_status"), area_rows)
            _insert_all(connection, "quests", ("id", "level", "min_level", "race_mask", "class_mask", "quest_sort", "title_en_us"),
                        ((int(qid), int(q.get("lvl", 0)), int(q.get("min", 0)), int(q.get("race", 255)),
                          int(q.get("class", 0)), int(q.get("sort", 0)) or None, _title(quest_locale, int(qid)))
                         for qid, q in _items(quests) if isinstance(q, dict)))
            entities = []
            for kind, family in ((1, "units"), (2, "objects")):
                locale = data[family].get("enUS", {})
                for entry_id, entity in _items(data[family].get("data", {})):
                    if isinstance(entity, dict):
                        low, high = _level_range(entity.get("lvl"))
                        entities.append((kind, int(entry_id), low, high, _title(locale, int(entry_id))))
            _insert_all(connection, "entities", ("kind", "entry_id", "level_min", "level_max", "name_en_us"), sorted(entities))
            _insert_all(connection, "entity_clusters", ("kind", "entry_id", "cluster_id", "area_id", "mapped_area_id", "map_id",
                        "world_x", "world_y", "map_x", "map_y", "point_count", "radius", "is_noise", "conversion_status"), cluster_rows)

            item_rows = []
            for item_id, item in _items(data["items"].get("data", {})):
                if not isinstance(item, dict):
                    continue
                for type_name in ("U", "O", "I", "V", "R"):
                    for source_id, rate in _items(item.get(type_name, {})):
                        item_rows.append((int(item_id), ENTITY_KIND[type_name], int(source_id), _number(rate, 100), type_name))
            _insert_all(connection, "item_sources", ("item_id", "source_kind", "source_id", "rate_pct", "provenance"), sorted(set(item_rows)))
            ref_rows = []
            for reference_id, sources in _items(data["refloot"].get("data", {})):
                if not isinstance(sources, dict):
                    continue
                for type_name in ("U", "O"):
                    ref_rows.extend((int(reference_id), ENTITY_KIND[type_name], int(source_id)) for source_id in _values(sources.get(type_name, {})))
            _insert_all(connection, "reference_loot_sources", ("reference_id", "source_kind", "source_id"), sorted(set(ref_rows)))
            _insert_all(connection, "quest_objective_sources", ("quest_id", "objective_index", "source_kind", "source_id", "ordinal"), objective_rows)
            _insert_all(connection, "quest_starters", ("quest_id", "source_kind", "source_id"), starter_rows)
            _insert_all(connection, "quest_enders", ("quest_id", "source_kind", "source_id"), ender_rows)
            use_rows = []
            for item_id, targets in _items(data["quests-itemreq"].get("data", {})):
                for target_id, _ in _items(targets):
                    raw = int(target_id)
                    use_rows.append((int(item_id), 2 if raw < 0 else 1, abs(raw)))
            _insert_all(connection, "item_use_targets", ("item_id", "target_kind", "target_id"), sorted(set(use_rows)))
            _insert_all(connection, "quest_fallback_targets", ("quest_id", "objective_index", "source_kind", "source_id", "area_id",
                        "mapped_area_id", "map_id", "world_x", "world_y", "map_x", "map_y", "conversion_status"), fallback_rows)
            snapshot_id = hashlib.sha256(
                "\n".join(f"{key}={value}" for key, value in sorted(snapshot.commits.items())).encode("ascii")
            ).hexdigest()
            metadata = {
                "schema_version": str(SCHEMA_VERSION), "generator_version": __version__,
                "pfquest_commit": snapshot.commits["pfquest"], "pfquest_octo_commit": snapshot.commits["pfquest_octo"],
                "source_snapshot": snapshot_id, "optional_dbc_tables": ",".join(dbc_data.optional_tables),
            }
            _insert_all(connection, "build_metadata", ("key", "value"), sorted(metadata.items()))
        connection.execute("ANALYZE")
        connection.execute("PRAGMA optimize")
        connection.execute("VACUUM")
    finally:
        connection.close()
    return {
        "database": str(path), "schema_version": SCHEMA_VERSION,
        "counts": {"quests": len(quests), "clusters": len(cluster_rows), "objectives": len(objective_rows),
                   "starters": len(starter_rows), "enders": len(ender_rows), "fallbacks": len(fallback_rows)},
        "coordinates": dict(sorted(conversion_stats.items())), "source_commits": snapshot.commits,
    }
