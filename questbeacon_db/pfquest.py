from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from lupa import LuaRuntime


BASE_DATA = (
    "items", "units", "objects", "refloot", "quests-itemreq", "quests",
    "zones", "minimap", "areatrigger", "meta",
)
BASE_LOCALE = ("items", "units", "objects", "quests", "zones", "professions")
OCTO_DATA = (
    "items-turtle", "units-turtle", "objects-turtle", "refloot-turtle",
    "quests-itemreq-turtle", "quests-turtle", "patches-turtle",
    "zones-turtle", "minimap-turtle", "areatrigger-turtle", "meta-turtle",
)
OCTO_LOCALE = (
    "items-turtle", "units-turtle", "objects-turtle", "quests-turtle",
    "zones-turtle", "professions-turtle",
)
FIELD_MERGE = ("quests", "units", "items", "objects")
PATCH_DATABASES = (
    "items", "quests", "quests-itemreq", "objects", "units", "zones",
    "professions", "areatrigger", "refloot",
)


@dataclass(frozen=True)
class PfQuestSnapshot:
    data: dict[str, Any]
    commits: dict[str, str]
    octo_overwrites_complete: bool


def _addon_root(path: Path, marker: str) -> Path:
    path = path.resolve()
    if (path / marker).is_file():
        return path
    child = path / "pfQuest-octo"
    if (child / marker).is_file():
        return child
    raise FileNotFoundError(f"cannot find {marker} below {path}")


def _require_files(paths: list[Path]) -> None:
    missing = [str(path) for path in paths if not path.is_file()]
    if missing:
        raise FileNotFoundError("missing required pfQuest inputs:\n" + "\n".join(missing))


def _git_commit(path: Path) -> str:
    repo = path
    while repo != repo.parent and not (repo / ".git").exists():
        repo = repo.parent
    if not (repo / ".git").exists():
        return "unknown"
    result = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "HEAD"],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else "unknown"


def _execute(lua: LuaRuntime, path: Path) -> None:
    try:
        lua.execute(path.read_text(encoding="utf-8-sig"))
    except Exception as exc:
        raise RuntimeError(f"failed to execute trusted Lua input {path}: {exc}") from exc


def _pythonize(value: Any, lua_table_type: type) -> Any:
    if isinstance(value, lua_table_type):
        result: dict[Any, Any] = {}
        for key, child in value.items():
            py_key = int(key) if isinstance(key, float) and key.is_integer() else key
            result[py_key] = _pythonize(child, lua_table_type)
        return result
    return value


def load_pfquest(pfquest_path: Path, octo_path: Path) -> PfQuestSnapshot:
    pfquest = _addon_root(pfquest_path, "pfQuest.toc")
    octo = _addon_root(octo_path, "pfQuest-octo.toc")

    base_files = [pfquest / "db" / "init.lua"]
    base_files.extend(pfquest / "db" / f"{name}.lua" for name in BASE_DATA)
    base_files.extend(pfquest / "db" / "enUS" / f"{name}.lua" for name in BASE_LOCALE)
    base_files.append(pfquest / "overwrites.lua")
    octo_files = [octo / "db" / f"{name}.lua" for name in OCTO_DATA]
    octo_files.extend(octo / "db" / "enUS" / f"{name}.lua" for name in OCTO_LOCALE)
    octo_files.extend((octo / "overwrites.lua", octo / "patchtable.lua"))
    _require_files(base_files + octo_files)

    lua = LuaRuntime(unpack_returned_tuples=True)
    _execute(lua, base_files[0])
    for path in base_files[1:]:
        _execute(lua, path)

    pfdb = lua.globals().pfDB
    for name in PATCH_DATABASES:
        table = pfdb[name]
        if table["data-turtle"] is None:
            table["data-turtle"] = lua.table()
        if table["enUS-turtle"] is None:
            table["enUS-turtle"] = lua.table()
    if pfdb["minimap-turtle"] is None:
        pfdb["minimap-turtle"] = lua.table()
    if pfdb["meta-turtle"] is None:
        pfdb["meta-turtle"] = lua.table()

    for path in octo_files[:-2]:
        _execute(lua, path)
    _execute(lua, octo / "overwrites.lua")
    complete = bool(pfdb["octo-overwrites-complete"])
    if not complete:
        raise RuntimeError("pfQuest-octo overwrites did not complete")

    lua.execute(
        """
        local fieldmerge = { quests=true, units=true, items=true, objects=true }
        local dbs = { "items", "quests", "quests-itemreq", "objects", "units",
                      "zones", "professions", "areatrigger", "refloot" }
        local function replace(base, diff)
          for k, v in pairs(diff) do
            if v == "_" then base[k] = nil else base[k] = v end
          end
        end
        local function merge_fields(base, diff)
          for k, v in pairs(diff) do
            if v == "_" then
              base[k] = nil
            elseif type(v) == "table" and type(base[k]) == "table" then
              for field, child in pairs(v) do
                if child == "_" then base[k][field] = nil else base[k][field] = child end
              end
            else
              base[k] = v
            end
          end
        end
        for _, name in ipairs(dbs) do
          local diff = pfDB[name]["data-turtle"]
          if diff then
            if fieldmerge[name] then merge_fields(pfDB[name]["data"], diff)
            else replace(pfDB[name]["data"], diff) end
          end
          local locale = pfDB[name]["enUS"]
          local locale_diff = pfDB[name]["enUS-turtle"]
          if locale and locale_diff then merge_fields(locale, locale_diff) end
        end
        if pfDB["minimap-turtle"] then replace(pfDB["minimap"], pfDB["minimap-turtle"]) end
        if pfDB["meta-turtle"] then replace(pfDB["meta"], pfDB["meta-turtle"]) end
        """
    )

    lua_table_type = type(lua.table())
    snapshot = _pythonize(pfdb, lua_table_type)
    return PfQuestSnapshot(
        data=snapshot,
        commits={"pfquest": _git_commit(pfquest), "pfquest_octo": _git_commit(octo)},
        octo_overwrites_complete=complete,
    )
