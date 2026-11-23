import {
  BadRequestException,
  Controller,
  Get,
  Query,
  ServiceUnavailableException,
  UseGuards,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { AuthGuard } from '../auth/auth.guard';

type Place = { name: string; latitude: number; longitude: number };
type Feature = { properties?: Record<string, string>; geometry?: { coordinates?: number[] } };

function point(lat?: string, lon?: string) {
  if (typeof lat !== 'string' || typeof lon !== 'string' || !lat.trim() || !lon.trim()) return;
  const latitude = Number(lat), longitude = Number(lon);
  if (Number.isFinite(latitude) && Number.isFinite(longitude) && Math.abs(latitude) <= 90 && Math.abs(longitude) <= 180) {
    return { latitude, longitude };
  }
}

@Controller('places')
@UseGuards(AuthGuard)
export class PlacesController {
  private readonly cache = new Map<string, { time: number; places: Place[] }>();
  private readonly pending = new Map<string, Promise<Place[]>>();
  constructor(private readonly config: ConfigService) {}

  @Get()
  async places(@Query('q') raw?: string, @Query('lat') lat?: string, @Query('lon') lon?: string) {
    if (raw !== undefined && typeof raw !== 'string') throw new BadRequestException('Invalid search');
    const term = raw?.trim().replace(/\s+/g, ' ').slice(0, 120);
    const origin = point(lat, lon);
    if (((lat !== undefined || lon !== undefined) && !origin) || (!term && !origin)) {
      throw new BadRequestException('Choose a place');
    }
    if (term && term.length < 2) throw new BadRequestException('Enter at least two characters');
    const base =
      this.config.get<string>('PHOTON_URL') ||
      (this.config.get('NODE_ENV') === 'production' ? null : 'https://photon.komoot.io');
    if (!base) throw new ServiceUnavailableException('Place search is unavailable');
    const url = new URL(term ? 'api/' : 'reverse/', base.replace(/\/?$/, '/'));
    if (term) url.searchParams.set('q', term);
    if (origin) {
      const digits = term ? 2 : 5;
      url.searchParams.set('lat', origin.latitude.toFixed(digits));
      url.searchParams.set('lon', origin.longitude.toFixed(digits));
    }
    url.searchParams.set('limit', term ? '6' : '1');
    const normalized = new URL(url);
    if (term) normalized.searchParams.set('q', term.toLowerCase());
    const key = normalized.href;
    const hit = this.cache.get(key);
    if (hit && Date.now() - hit.time < (hit.places.length ? 3600000 : 60000)) return hit.places;
    const request = this.pending.get(key);
    if (request) return request;
    const lookup = this.lookup(url).then((places) => {
      this.cache.delete(key);
      if (this.cache.size >= 1000) this.cache.delete(this.cache.keys().next().value!);
      this.cache.set(key, { time: Date.now(), places });
      return places;
    }).catch(() => {
      if (hit?.places.length && Date.now() - hit.time < 86400000) return hit.places;
      throw new ServiceUnavailableException('Place search is unavailable');
    }).finally(() => this.pending.delete(key));
    this.pending.set(key, lookup);
    return lookup;
  }

  private async lookup(url: URL) {
    const res = await fetch(url, {
      signal: AbortSignal.timeout(4000),
      headers: { 'User-Agent': 'Ploggr place search' },
    });
    if (!res.ok) throw new Error('Geocoder returned an error');
    const data = (await res.json()) as { features: Feature[] };
    const labels = new Set<string>();
    return data.features.flatMap((f) => {
      const p = f.properties ?? {}, xy = f.geometry?.coordinates;
      if (!xy || !point(String(xy[1]), String(xy[0]))) return [];
      const street = [p.housenumber, p.street].filter(Boolean).join(' ');
      const name = [...new Set([p.name, street, p.district, p.city, p.county, p.state, p.country].filter(Boolean))]
        .join(', ')
        .slice(0, 160);
      if (!name || labels.has(name)) return [];
      labels.add(name);
      return [{ name, latitude: xy[1], longitude: xy[0] }];
    });
  }
}
