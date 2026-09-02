# QuestBeacon

QuestBeacon is a lightweight quest navigation addon for [OctoWoW](https://octowow.st/) and World of Warcraft 1.12.1 (`Interface: 11200`). It brings together the most useful questing features found in pfQuest and Questie-Octo, then adds a focused tracker and navigation experience of its own. QuestBeacon keeps its large quest database in SQLite instead of loading it into Lua, then uses authored quest coordinates to guide you through the world.

> [!WARNING]
> QuestBeacon is in a very early stage of development. Expect bugs, incomplete behavior, and major changes without notice.

## Features

- Directional arrow and distance readout aimed at an authored objective spawn point
- Quest tracker with watch controls, objective folding, zone views, and distance or level sorting
- Zoomable and pannable world map with pins for objectives, colored spawn points, item sources, turn-ins, and available quests
- Minimap pins for nearby quest objectives and locations
- Quest mob indicators on the target frame, mouseover tooltips, and nameplates
- Optional world-map and minimap markers for banks, vendors, repairs, travel, and other services
- Deterministic spawn clustering and item-source resolution
- Quest completion history and configurable availability filters
- Frame-budgeted database work to keep the 1.12 client responsive

## Prerequisites

QuestBeacon is built specifically for the following environment. These components are required and are not bundled with the addon:

- [OctoWoW](https://octowow.st/) or a compatible World of Warcraft 1.12.1 client
- [ClassicAPI](https://github.com/brues-code/ClassicAPI/releases/latest), which supplies the quest, map, and player-position APIs used by QuestBeacon
- [HearthDB - copypasteonly fork](https://github.com/copypasteonly/HearthDB), which lets QuestBeacon read its bundled SQLite database

Follow the installation instructions in the ClassicAPI and HearthDB repositories, including any plugin-loader requirements, before installing QuestBeacon.

## Installation

1. Install and verify [ClassicAPI](https://github.com/brues-code/ClassicAPI/releases/latest) and [HearthDB](https://github.com/copypasteonly/HearthDB).
2. Download or clone the [QuestBeacon repository](https://github.com/copypasteonly/QuestBeacon).
3. Copy the `QuestBeacon` directory to `Interface\AddOns\QuestBeacon` in your OctoWoW installation.
4. Confirm that the final path is `Interface\AddOns\QuestBeacon\QuestBeacon.toc`.
5. Fully restart the game, then run `/qbeacon status` to verify ClassicAPI, HearthDB, and the quest database.

QuestBeacon disables itself with a chat message if a required API or HearthDB function is unavailable.

## Getting started

Use `/qbeacon settings` or the cog button on the tracker to configure the arrow, tracker, map pins, minimap pins, service markers, and available-quest filters.

Available-quest pins are predicted from the local database until you open a questgiver. QuestBeacon then uses the server's offered quest list for that NPC and, on compatible servers, imports completed quest IDs once per login into session-only availability state.

- Click a quest title to fold or unfold its objectives.
- Right-click a quest title to open it in the quest log.
- Ctrl-click a quest title to select its target and open the relevant world-map area.
- Click an objective or a map pin to navigate to it.
- Scroll over the world map to zoom, then right-drag to pan around while zoomed in.
- Shift-drag the arrow to move it, Shift-scroll to resize it, or Shift-right-click it to reset it.

Objective spawn circles use a stable color for each mob or object. By default the world map combines
summary cluster icons with spawn circles, while the minimap shows nearby spawn circles without duplicate
objective clusters. Dense world-map circles merge when they overlap and separate as the map is zoomed in;
clicking a circle still selects an exact authored spawn location. These layers can be controlled independently
under the World Map and Minimap settings.

The main slash commands are:

```text
/qbeacon
/qbeacon settings
/qbeacon status
/qbeacon auto
/qbeacon next
/qbeacon prev
/qbeacon track <questID> [objective]
/qbeacon watch <questID>
/qbeacon watch all
/qbeacon unwatch <questID>
/qbeacon watched
/qbeacon show
/qbeacon hide
/qbeacon reset
```

## Credits and provenance

QuestBeacon stands on work from several Vanilla WoW addon projects:

- [pfQuest](https://github.com/shagu/pfQuest), created by Eric Mauser (Shagu), provides source quest data and the arrow, quest-pin, and tracker artwork shipped by QuestBeacon. Those portions retain pfQuest's MIT license and copyright notice.
- [pfQuest-octo](https://github.com/roby-brok/pfQuest-octo), maintained by Roby_Brok, provides OctoWoW database additions and corrections used by the offline database generator.
- A special thank-you to [The Kludge Bureau](https://github.com/The-Kludge-Bureau) for creating [HearthDB](https://github.com/The-Kludge-Bureau/HearthDB), the SQLite bridge that makes QuestBeacon's database architecture possible. QuestBeacon uses the [copypasteonly HearthDB fork](https://github.com/copypasteonly/HearthDB) at runtime.
- The Kludge Bureau's [Questbound](https://github.com/The-Kludge-Bureau/Questbound), by txtsd, was a major architectural and interface reference. Its SQLite access patterns, query caching, tracker and pin organization, routing, and settings helped shape QuestBeacon. QuestBeacon copies no Questbound implementation.
- The Kludge Bureau also deserves thanks for maintaining its [pfQuest](https://github.com/The-Kludge-Bureau/pfQuest) and [pfQuest-turtle](https://github.com/The-Kludge-Bureau/pfQuest-turtle) work, which contributed to the database lineage used by pfQuest-octo, and for [Reliquary](https://github.com/The-Kludge-Bureau/Reliquary), which QuestBeacon's offline tooling used to verify DBC schemas. Original pfQuest authorship remains credited to Shagu above.
- [Questie-Octo](https://github.com/SandreaSub/Questie-Octo) provided valuable ideas for frame-budgeted scheduling, map-update caching, availability publishing, quest-log handling, and minimap work. QuestBeacon's implementation remains independent.
- [ClassicAPI](https://github.com/brues-code/ClassicAPI) and [HearthDB](https://github.com/copypasteonly/HearthDB) provide the external runtime capabilities that make the addon possible.

Thank you to these authors and contributors for sharing their work and ideas with the Vanilla WoW community.

## License

QuestBeacon's original contributions are available under the MIT License. Third-party material retains its upstream license and copyright. See [LICENSE](LICENSE) for the complete terms and pfQuest notices.
