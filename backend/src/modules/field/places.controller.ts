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

@Controller('places')
@UseGuards(AuthGuard)
export class PlacesController {
  private readonly cache = new Map<string, { time: number; places: Place[] }>();
  constructor(private readonly config: ConfigService) {}

  @Get()
  async places(@Query('q') raw?: string, @Query('lat') lat?: string, @Query('lon') lon?: string) {
    const term = raw?.trim().slice(0, 120);
    const base =
      this.config.get<string>('PHOTON_URL') ||
      (this.config.get('NODE_ENV') === 'production' ? null : 'https://photon.komoot.io');
    if (!base) throw new ServiceUnavailableException('Place search is unavailable');
    const url = new URL(term ? 'api/' : 'reverse/', base.replace(/\/?$/, '/'));
    if (term) url.searchParams.set('q', term);
    else {
      if (
        !lat ||
        !lon ||
        !Number.isFinite(+lat) ||
        !Number.isFinite(+lon) ||
        Math.abs(+lat) > 90 ||
        Math.abs(+lon) > 180
      )
        throw new BadRequestException('Choose a place');
      url.searchParams.set('lat', (+lat).toFixed(5));
      url.searchParams.set('lon', (+lon).toFixed(5));
    }
    url.searchParams.set('limit', term ? '6' : '1');
    const key = url.href,
      hit = this.cache.get(key);
    if (hit && Date.now() - hit.time < 3600000) return hit.places;
    try {
      const res = await fetch(url, {
        signal: AbortSignal.timeout(6000),
        headers: { 'User-Agent': 'Ploggr place search' },
      });
      if (!res.ok) throw new Error();
      const data = (await res.json()) as { features: Feature[] };
      const places = data.features.flatMap((f) => {
        const p = f.properties ?? {},
          xy = f.geometry?.coordinates;
        if (!xy || !Number.isFinite(xy[0]) || !Number.isFinite(xy[1])) return [];
        const name = [...new Set([p.name, p.street, p.district, p.city, p.state, p.country].filter(Boolean))]
          .join(', ')
          .slice(0, 160);
        return name ? [{ name, latitude: xy[1], longitude: xy[0] }] : [];
      });
      if (this.cache.size >= 1000) this.cache.delete(this.cache.keys().next().value!);
      this.cache.set(key, { time: Date.now(), places });
      return places;
    } catch {
      throw new ServiceUnavailableException('Place search is unavailable');
    }
  }
}
