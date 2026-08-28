from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path


class DbcError(ValueError):
    pass


@dataclass(frozen=True)
class AreaRecord:
    id: int
    map_id: int
    parent_area_id: int
    name_en_us: str


@dataclass(frozen=True)
class WorldMapAreaRecord:
    id: int
    map_id: int
    area_id: int
    name: str
    loc_left: float
    loc_right: float
    loc_top: float
    loc_bottom: float


@dataclass(frozen=True)
class MapRecord:
    id: int
    directory: str
    instance_type: int
    name_en_us: str
    area_table_id: int


@dataclass(frozen=True)
class DbcData:
    areas: tuple[AreaRecord, ...]
    world_map_areas: tuple[WorldMapAreaRecord, ...]
    maps: tuple[MapRecord, ...]
    optional_tables: tuple[str, ...]


class WdbcFile:
    def __init__(self, path: Path, expected_fields: int):
        self.path = path
        raw = path.read_bytes()
        if len(raw) < 20:
            raise DbcError(f"{path}: truncated WDBC header")
        magic, count, fields, record_size, strings_size = struct.unpack_from("<4s4I", raw)
        if magic != b"WDBC":
            raise DbcError(f"{path}: unsupported magic {magic!r}")
        if fields != expected_fields:
            raise DbcError(f"{path}: expected {expected_fields} fields, found {fields}")
        if record_size != fields * 4:
            raise DbcError(f"{path}: record size {record_size} does not match field count")
        records_end = 20 + count * record_size
        expected_size = records_end + strings_size
        if expected_size != len(raw):
            raise DbcError(f"{path}: header size {expected_size} does not match file size {len(raw)}")
        self._raw = raw
        self._count = count
        self._record_size = record_size
        self._strings = raw[records_end:]

    def uint(self, row: int, field: int) -> int:
        self._check_row(row)
        return struct.unpack_from("<I", self._raw, 20 + row * self._record_size + field * 4)[0]

    def float(self, row: int, field: int) -> float:
        self._check_row(row)
        return struct.unpack_from("<f", self._raw, 20 + row * self._record_size + field * 4)[0]

    def string(self, row: int, field: int) -> str:
        offset = self.uint(row, field)
        if offset >= len(self._strings):
            raise DbcError(f"{self.path}: string offset {offset} is outside the string block")
        end = self._strings.find(b"\0", offset)
        if end < 0:
            raise DbcError(f"{self.path}: unterminated string at offset {offset}")
        return self._strings[offset:end].decode("utf-8", errors="replace")

    def __len__(self) -> int:
        return self._count

    def _check_row(self, row: int) -> None:
        if row < 0 or row >= self._count:
            raise IndexError(row)


def _find_dbc(directory: Path, filename: str, required: bool = True) -> Path | None:
    direct = directory / filename
    if direct.is_file():
        return direct
    match = next((p for p in directory.iterdir() if p.name.casefold() == filename.casefold()), None)
    if match is None and required:
        raise FileNotFoundError(f"missing required DBC: {directory / filename}")
    return match


def load_dbc_directory(directory: Path) -> DbcData:
    directory = directory.resolve()
    if not directory.is_dir():
        raise FileNotFoundError(f"DBC directory does not exist: {directory}")
    area_file = WdbcFile(_find_dbc(directory, "AreaTable.dbc"), 25)  # type: ignore[arg-type]
    wma_file = WdbcFile(_find_dbc(directory, "WorldMapArea.dbc"), 8)  # type: ignore[arg-type]
    map_file = WdbcFile(_find_dbc(directory, "Map.dbc"), 42)  # type: ignore[arg-type]

    areas = tuple(
        AreaRecord(area_file.uint(i, 0), area_file.uint(i, 1), area_file.uint(i, 2), area_file.string(i, 11))
        for i in range(len(area_file))
    )
    world_map_areas = tuple(
        WorldMapAreaRecord(
            wma_file.uint(i, 0), wma_file.uint(i, 1), wma_file.uint(i, 2), wma_file.string(i, 3),
            wma_file.float(i, 4), wma_file.float(i, 5), wma_file.float(i, 6), wma_file.float(i, 7),
        )
        for i in range(len(wma_file))
    )
    maps = tuple(
        MapRecord(map_file.uint(i, 0), map_file.string(i, 1), map_file.uint(i, 2), map_file.string(i, 4), map_file.uint(i, 19))
        for i in range(len(map_file))
    )
    optional = tuple(
        name for name in ("QuestInfo.dbc", "QuestSort.dbc") if _find_dbc(directory, name, required=False)
    )
    return DbcData(areas, world_map_areas, maps, optional)
