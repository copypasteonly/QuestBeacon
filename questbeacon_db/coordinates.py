from __future__ import annotations

from dataclasses import dataclass
from math import isfinite
from typing import Any

from questbeacon_db.dbc import AreaRecord, WorldMapAreaRecord


@dataclass(frozen=True)
class CoordinateResult:
    area_id: int
    mapped_area_id: int | None
    map_id: int | None
    map_x: float
    map_y: float
    world_x: float | None
    world_y: float | None
    status: str


class CoordinateConverter:
    def __init__(self, areas: tuple[AreaRecord, ...], world_map_areas: tuple[WorldMapAreaRecord, ...]):
        self._areas = {area.id: area for area in areas}
        self._wma: dict[int, list[WorldMapAreaRecord]] = {}
        for record in world_map_areas:
            self._wma.setdefault(record.area_id, []).append(record)
        for records in self._wma.values():
            records.sort(key=lambda row: row.id)

    def convert(
        self,
        area_id: int,
        map_x: float,
        map_y: float,
        zone_transforms: dict[int, Any] | None = None,
    ) -> CoordinateResult:
        if not all(isfinite(value) for value in (map_x, map_y)):
            return CoordinateResult(area_id, None, None, map_x, map_y, None, None, "invalid_percent")
        current_area = area_id
        current_x = float(map_x)
        current_y = float(map_y)
        transformed = False
        visited: set[int] = set()
        transforms = zone_transforms or {}

        while True:
            chosen, status = self._choose_wma(current_area)
            if chosen is not None:
                world_y = chosen.loc_left - current_x / 100.0 * (chosen.loc_left - chosen.loc_right)
                world_x = chosen.loc_top - current_y / 100.0 * (chosen.loc_top - chosen.loc_bottom)
                return CoordinateResult(
                    area_id, current_area, chosen.map_id, map_x, map_y,
                    round(world_x, 6), round(world_y, 6),
                    "converted_subzone" if transformed else "converted_direct",
                )
            if status in {"ambiguous_wma", "degenerate_wma"}:
                return CoordinateResult(area_id, current_area, None, map_x, map_y, None, None, status)
            if current_area in visited:
                return CoordinateResult(area_id, current_area, None, map_x, map_y, None, None, "zone_cycle")
            visited.add(current_area)
            transform = transforms.get(current_area)
            if not isinstance(transform, dict):
                missing = "missing_area" if current_area not in self._areas else "missing_wma"
                return CoordinateResult(area_id, current_area, None, map_x, map_y, None, None, missing)
            try:
                parent = int(transform[1])
                width, height = float(transform[2]), float(transform[3])
                center_x, center_y = float(transform[4]), float(transform[5])
            except (KeyError, TypeError, ValueError):
                return CoordinateResult(area_id, current_area, None, map_x, map_y, None, None, "invalid_subzone")
            if parent <= 0 or width <= 0 or height <= 0:
                return CoordinateResult(area_id, current_area, None, map_x, map_y, None, None, "invalid_subzone")
            current_x = center_x - width / 2.0 + current_x / 100.0 * width
            current_y = center_y - height / 2.0 + current_y / 100.0 * height
            current_area = parent
            transformed = True

    def _choose_wma(self, area_id: int) -> tuple[WorldMapAreaRecord | None, str]:
        candidates = self._wma.get(area_id, [])
        valid = [
            row for row in candidates
            if row.loc_left != row.loc_right and row.loc_top != row.loc_bottom
        ]
        if not valid:
            return None, "degenerate_wma" if candidates else "missing_wma"
        area = self._areas.get(area_id)
        if area:
            matching = [row for row in valid if row.map_id == area.map_id]
            if matching:
                valid = matching
        bounds = {(row.map_id, row.loc_left, row.loc_right, row.loc_top, row.loc_bottom) for row in valid}
        if len(bounds) > 1:
            return None, "ambiguous_wma"
        return valid[0], "ok"
