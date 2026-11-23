import { BadRequestException, ServiceUnavailableException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PlacesController } from './places.controller';

describe('place discovery', () => {
  afterEach(() => jest.restoreAllMocks());

  const landmark = {
    properties: { name: 'Riverside Park', city: 'Pune', country: 'India' },
    geometry: { coordinates: [73.85, 18.51] },
  };
  const reply = () => Response.json({ features: [landmark, landmark] });

  it('coalesces equivalent forward searches and passes the area bias to Photon', async () => {
    const controller = new PlacesController(new ConfigService({ PHOTON_URL: 'http://photon.internal:2322' }));
    const provider = jest.spyOn(global, 'fetch').mockResolvedValueOnce(reply());
    const rows = [{ name: 'Riverside Park, Pune, India', latitude: 18.51, longitude: 73.85 }];
    expect(await Promise.all([
      controller.places('  Riverside  Park', '18.512', '73.852'),
      controller.places('riverside park', '18.51', '73.85'),
    ])).toEqual([rows, rows]);
    expect(await controller.places('RIVERSIDE PARK', '18.51', '73.85')).toEqual(rows);
    expect(provider).toHaveBeenCalledTimes(1);
    const url = provider.mock.calls[0][0] as URL;
    expect(url.pathname).toBe('/api/');
    expect(Object.fromEntries(url.searchParams)).toMatchObject({
      q: 'Riverside Park', lat: '18.51', lon: '73.85',
    });
  });

  it('reuses a recent reverse lookup after a provider error and rejects invalid coordinates', async () => {
    const controller = new PlacesController(new ConfigService({ PHOTON_URL: 'http://photon.internal:2322' }));
    const clock = jest.spyOn(Date, 'now').mockReturnValue(0);
    const provider = jest.spyOn(global, 'fetch')
      .mockResolvedValueOnce(reply())
      .mockResolvedValue(new Response(null, { status: 503 }));
    await expect(controller.places(undefined, '91', '73.85')).rejects.toBeInstanceOf(BadRequestException);
    expect(provider).not.toHaveBeenCalled();
    const rows = await controller.places(undefined, '18.51', '73.85');
    clock.mockReturnValue(7200000);
    await expect(controller.places(undefined, '18.51', '73.85')).resolves.toEqual(rows);
    expect(provider).toHaveBeenCalledTimes(2);
    await expect(controller.places('other park')).rejects.toBeInstanceOf(ServiceUnavailableException);
  });
});
