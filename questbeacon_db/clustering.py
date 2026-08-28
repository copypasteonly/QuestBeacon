from __future__ import annotations

from dataclasses import dataclass
from math import hypot


@dataclass(frozen=True, order=True)
class SpawnPoint:
    world_x: float
    world_y: float
    map_x: float
    map_y: float


@dataclass(frozen=True)
class Cluster:
    world_x: float
    world_y: float
    map_x: float
    map_y: float
    point_count: int
    radius: float
    is_noise: bool


def dbscan(points: list[SpawnPoint], epsilon: float = 75.0, min_points: int = 2) -> list[Cluster]:
    unique = sorted(set(points))
    if not unique:
        return []
    neighbours = [
        [j for j, other in enumerate(unique) if hypot(point.world_x - other.world_x, point.world_y - other.world_y) <= epsilon]
        for point in unique
    ]
    labels: list[int | None] = [None] * len(unique)
    cluster_number = 0
    for index in range(len(unique)):
        if labels[index] is not None:
            continue
        if len(neighbours[index]) < min_points:
            labels[index] = -1
            continue
        labels[index] = cluster_number
        queue = list(neighbours[index])
        queued = set(queue)
        cursor = 0
        while cursor < len(queue):
            candidate = queue[cursor]
            cursor += 1
            if labels[candidate] == -1:
                labels[candidate] = cluster_number
            if labels[candidate] is not None:
                continue
            labels[candidate] = cluster_number
            if len(neighbours[candidate]) >= min_points:
                for neighbour in neighbours[candidate]:
                    if neighbour not in queued:
                        queued.add(neighbour)
                        queue.append(neighbour)
        cluster_number += 1

    groups: list[tuple[list[SpawnPoint], bool]] = []
    for number in range(cluster_number):
        groups.append(([unique[i] for i, label in enumerate(labels) if label == number], False))
    groups.extend(([unique[i]], True) for i, label in enumerate(labels) if label == -1)
    result = [_summarize(group, noise) for group, noise in groups]
    return sorted(result, key=lambda row: (row.is_noise, row.world_x, row.world_y, row.point_count))


def _summarize(points: list[SpawnPoint], is_noise: bool) -> Cluster:
    count = len(points)
    world_x = sum(point.world_x for point in points) / count
    world_y = sum(point.world_y for point in points) / count
    map_x = sum(point.map_x for point in points) / count
    map_y = sum(point.map_y for point in points) / count
    radius = max(hypot(point.world_x - world_x, point.world_y - world_y) for point in points)
    return Cluster(
        round(world_x, 6), round(world_y, 6), round(map_x, 6), round(map_y, 6),
        count, round(radius, 6), is_noise,
    )
