import { ConfigService } from '@nestjs/config';
import sharp from 'sharp';
import type { DataSource } from 'typeorm';
import type { EvidenceStorage } from '../evidence/evidence-storage';
import { AnalysisWorker, normalizeDetections } from './analysis.service';

const photos = [
  { id: 'first', storage_key: 'private-a', sha256: 'a' },
  { id: 'second', storage_key: 'private-b', sha256: 'b' },
];
const bottle = {
  label: 'empty drink bottle',
  material: 'PET plastic',
  type: 'Bottle',
  count: 2,
  weight: { estimateKg: 0.04, minKg: 0.03, maxKg: 0.06 },
  photos: [1, 0, 1],
  box: [10, 20, 300, 400],
  certain: true,
};

describe('Gemini litter results', () => {
  it('uses the group estimate once across supporting views with a range and sourced scenario', () => {
    const { items: [item] } = normalizeDetections({ quality: 'clear', items: [bottle] }, photos);
    expect(item).toMatchObject({
      count: 2,
      photoIds: ['second', 'first'],
      weight: bottle.weight,
      potentialImpact: {
        baseline: 'Landfill', alternative: 'Recycling', version: 'EPA WARM v16', region: 'US national average',
      },
    });
    const impact = item.potentialImpact!;
    expect(impact.avoidedKg).toBeCloseTo(0.04 * 1.06 / 0.90718474, 8);
    expect(impact.minKg).toBeLessThan(impact.avoidedKg);
    expect(impact.maxKg).toBeGreaterThan(impact.avoidedKg);
  });

  it('retains uncountable groups and suppresses invalid mass ranges and unsupported impact', () => {
    const { items } = normalizeDetections({ quality: 'unclear', items: [
      { ...bottle, material: 'Unknown', type: 'Unsorted waste', count: null, weight: null },
      { ...bottle, material: 'Textile', type: 'Shoe' },
      { ...bottle, weight: { estimateKg: 0.1, minKg: 0.2, maxKg: 0.3 } },
      { ...bottle, material: 'Organic', type: 'Food scraps' },
    ] }, photos);
    expect(items[0]).toMatchObject({ count: null, certain: false, weight: null, potentialImpact: null });
    expect(items[1]).toMatchObject({ weight: bottle.weight, potentialImpact: null });
    expect(items[2]).toMatchObject({ weight: null, potentialImpact: null });
    expect(items[3]).toMatchObject({ potentialImpact: { alternative: 'Composting' } });
  });

  it('rejects an item whose evidence index is outside the request', () => {
    expect(() => normalizeDetections({ quality: 'clear', items: [{ ...bottle, photos: [2] }] }, photos))
      .toThrow('Invalid item');
  });
});

describe('Gemini availability', () => {
  const success = () => Response.json({
    modelVersion: 'returned-model',
    candidates: [{ content: { parts: [{
      text: JSON.stringify({ quality: 'clear', items: [{ ...bottle, photos: [0] }] }),
    }] } }],
  });
  let worker: AnalysisWorker;
  let query: jest.Mock;
  let provider: jest.SpyInstance;
  let now: number;

  beforeEach(async () => {
    now = Date.now();
    jest.spyOn(Date, 'now').mockImplementation(() => now);
    provider = jest.spyOn(global, 'fetch');
    const image = await sharp({ create: { width: 8, height: 8, channels: 3, background: 'white' } })
      .jpeg().toBuffer();
    query = jest.fn().mockImplementation((sql: string) => {
      if (sql.startsWith('WITH next')) return [[{ plog_id: 'plog', suspicious_evidence: false, attempts: 5 }]];
      if (sql.includes('FROM garbage_evidence')) return [photos[0]];
      return [];
    });
    worker = new AnalysisWorker(
      { query } as unknown as DataSource,
      { read: jest.fn().mockResolvedValue(image) } as unknown as EvidenceStorage,
      new ConfigService({
        GEMINI_MODEL: 'primary', GEMINI_FALLBACK_MODELS: ['primary', 'fallback'], GEMINI_API_KEY: 'test',
      }),
    );
  });

  afterEach(() => jest.restoreAllMocks());

  it('tries the second model after a timeout and skips the cooling primary for the next job', async () => {
    provider.mockRejectedValueOnce(new DOMException('timed out', 'TimeoutError'))
      .mockResolvedValueOnce(success()).mockResolvedValueOnce(success());
    await worker.processNext();
    await worker.processNext();
    expect(provider.mock.calls.map(([url]: [string]) => url.split('/').at(-1))).toEqual([
      'primary:generateContent', 'fallback:generateContent', 'fallback:generateContent',
    ]);
    expect(query.mock.calls.filter(([sql]) => sql.includes('SET result='))).toEqual([
      [expect.any(String), ['plog', expect.any(String), expect.any(String), 'ready', 'returned-model']],
      [expect.any(String), ['plog', expect.any(String), expect.any(String), 'ready', 'returned-model']],
    ]);
  });

  it('keeps a job queued past three attempts during an outage, then resumes after cooldown', async () => {
    provider.mockResolvedValueOnce(new Response(null, { status: 429, headers: { 'Retry-After': '600' } }))
      .mockResolvedValueOnce(new Response(null, { status: 503, headers: { 'Retry-After': '900' } }))
      .mockResolvedValueOnce(success());
    await worker.processNext();
    const [sql, parameters] = query.mock.calls.at(-1)!;
    expect(sql).toContain('lease=NULL,next_run=$4');
    expect(parameters).toEqual(['plog', expect.any(String), 'queued', new Date(now + 600_000)]);

    const queries = query.mock.calls.length;
    await worker.processNext();
    expect(query).toHaveBeenCalledTimes(queries);
    expect(provider).toHaveBeenCalledTimes(2);

    now += 600_001;
    await worker.processNext();
    expect(provider.mock.calls[2][0]).toContain('/primary:generateContent');
    expect(query.mock.calls.at(-1)![1]).toEqual([
      'plog', expect.any(String), expect.any(String), 'ready', 'returned-model',
    ]);
  });

  it('surfaces credential errors without sending photos to another model', async () => {
    provider.mockResolvedValueOnce(new Response(null, { status: 403 }));
    await worker.processNext();
    expect(provider).toHaveBeenCalledTimes(1);
    expect(query.mock.calls.at(-1)![1]).toEqual(['plog', expect.any(String), 'failed', expect.any(Date)]);
  });
});
