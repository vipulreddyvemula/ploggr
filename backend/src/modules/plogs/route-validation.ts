import { BadRequestException } from '@nestjs/common';
import type { FinishPlogDto, RouteFix } from './plog.dto';

const radians = (degrees: number) => degrees * Math.PI / 180;
function distance(a: RouteFix, b: RouteFix) {
  const haversine = Math.sin(radians(b.latitude - a.latitude) / 2) ** 2
    + Math.cos(radians(a.latitude)) * Math.cos(radians(b.latitude))
    * Math.sin(radians(b.longitude - a.longitude) / 2) ** 2;
  return 12742000 * Math.asin(Math.sqrt(Math.min(1, haversine)));
}

export function validateRoute(dto: FinishPlogDto, startedAt: Date, endedAt: Date) {
  const start = startedAt.getTime();
  const end = endedAt.getTime();
  const wall = end - start;
  if (!Number.isFinite(end) || wall < 0 || wall > 7 * 86400000 || end > Date.now() + 30000) {
    throw new BadRequestException('Invalid Plog end time');
  }
  const active = wall - (dto.pausedMilliseconds ?? 0);
  const duration = Math.floor(active / 1000);
  if (dto.pausedMilliseconds != null && (active < -1 || Math.abs(dto.durationSeconds - duration) > 1)) {
    throw new BadRequestException('Invalid active duration');
  }
  const declared = dto.segmentStarts ?? [];
  if (declared.some((n, i) => n >= dto.route.length || (i > 0 && declared[i - 1] >= n))) {
    throw new BadRequestException('Invalid route segments');
  }
  const requestedBreaks = new Set(declared);
  const breaks: number[] = [];
  const route: RouteFix[] = [];
  let previous: RouteFix | undefined;
  let previousTimestamp: number | undefined;
  let lastTimestamp = start - 2000;
  let newSegment = false;
  for (const [index, point] of dto.route.entries()) {
    newSegment ||= requestedBreaks.has(index);
    const timestamp = point.recordedAt ? Date.parse(point.recordedAt) : undefined;
    if ((timestamp === undefined) !== (point.accuracyMeters == null)) {
      throw new BadRequestException('Route timestamps and accuracy must be supplied together');
    }
    if (timestamp !== undefined) {
      if (!Number.isFinite(timestamp)) throw new BadRequestException('Invalid route timestamp');
      if (timestamp <= lastTimestamp || timestamp > end + 1000) continue;
      lastTimestamp = timestamp;
    }
    const gap = timestamp !== undefined && previousTimestamp !== undefined ? timestamp - previousTimestamp : null;
    const meters = previous ? distance(previous, point) : 0;
    if (gap != null && gap > 30000) newSegment = true;
    if (previous && !newSegment && gap != null) {
      const uncertainty = Math.max(5, Math.min(20, (point.accuracyMeters! + previous.accuracyMeters!) / 2));
      if (meters < uncertainty || meters > 7 * gap / 1000 + uncertainty) continue;
    }
    if (previous && gap == null && ((timestamp === undefined) !== (previousTimestamp === undefined) || meters > 250)) {
      newSegment = true;
    }
    if (route.length && newSegment) breaks.push(route.length);
    route.push(point);
    previous = point;
    previousTimestamp = timestamp;
    newSegment = false;
  }
  return { route, breaks, duration: Math.max(0, Math.min(dto.durationSeconds, duration)) };
}
