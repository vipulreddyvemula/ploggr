import { Injectable, OnApplicationBootstrap, OnApplicationShutdown } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { randomUUID } from 'node:crypto';
import sharp from 'sharp';
import { DataSource } from 'typeorm';
import { EvidenceStorage } from '../evidence/evidence-storage';

export const materials = ['Plastic', 'Paper', 'Glass', 'Metal', 'E-waste', 'Other'];
type Photo = { id: string; storage_key: string; sha256: string };
type Detection = {
  label: string;
  material: string;
  count: number;
  photos: number[];
  box: number[];
  certain: boolean;
};
type VisionReply = { quality: 'clear' | 'unclear' | 'empty'; items: Detection[] };

const schema = {
  type: 'OBJECT',
  required: ['quality', 'items'],
  properties: {
    quality: { type: 'STRING', enum: ['clear', 'unclear', 'empty'] },
    items: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        required: ['label', 'material', 'count', 'photos', 'box', 'certain'],
        properties: {
          label: { type: 'STRING' },
          material: { type: 'STRING', enum: materials },
          count: { type: 'INTEGER' },
          photos: { type: 'ARRAY', items: { type: 'INTEGER' } },
          box: { type: 'ARRAY', items: { type: 'INTEGER' } },
          certain: { type: 'BOOLEAN' },
        },
      },
    },
  },
};

export function normalizeDetections(value: VisionReply, photos: Photo[]) {
  if (
    !value ||
    !['clear', 'unclear', 'empty'].includes(value.quality) ||
    !Array.isArray(value.items) ||
    value.items.length > 200
  )
    throw new Error('Invalid analysis');
  const items = value.items.map((item) => {
    if (
      typeof item.label !== 'string' ||
      !item.label.trim() ||
      !materials.includes(item.material) ||
      !Number.isInteger(item.count) ||
      item.count < 1 ||
      item.count > 1000 ||
      typeof item.certain !== 'boolean' ||
      !Array.isArray(item.box) ||
      item.box.length !== 4 ||
      item.box.some((n) => !Number.isInteger(n) || n < 0 || n > 1000) ||
      item.box[0] >= item.box[2] ||
      item.box[1] >= item.box[3] ||
      !Array.isArray(item.photos) ||
      !item.photos.length ||
      item.photos.some((n) => !Number.isInteger(n) || n < 0 || n >= photos.length)
    )
      throw new Error('Invalid item');
    return {
      label: item.label.trim().slice(0, 80),
      material: item.material,
      count: item.count,
      certain: item.certain,
      box: item.box,
      photoIds: [...new Set(item.photos.map((n) => photos[n].id))],
    };
  });
  if (value.quality === 'empty' && items.length) throw new Error('Inconsistent result');
  return { quality: value.quality, items };
}

@Injectable()
export class AnalysisWorker implements OnApplicationBootstrap, OnApplicationShutdown {
  private timer?: NodeJS.Timeout;
  private working = false;
  constructor(
    private readonly db: DataSource,
    private readonly storage: EvidenceStorage,
    private readonly config: ConfigService,
  ) {}
  private get model() {
    return this.config.get<string>('GEMINI_MODEL') || process.env.GEMINI_MODEL || 'gemini-3.8-flash';
  }
  onApplicationBootstrap() {
    const key = this.config.get<string>('GEMINI_API_KEY') || process.env.GEMINI_API_KEY;
    if (!key) {
      console.warn('[AnalysisWorker] No GEMINI_API_KEY configured, analysis worker is idle.');
      return;
    }
    console.log(`[AnalysisWorker] Started analysis worker with model: ${this.model}`);
    this.timer = setInterval(() => void this.processNext().catch((err) => console.error('[AnalysisWorker] Interval error:', err)), 3000);
    this.timer.unref();
    void this.processNext().catch((err) => console.error('[AnalysisWorker] Initial run error:', err));
  }
  onApplicationShutdown() {
    clearInterval(this.timer);
  }

  async processNext() {
    if (this.working) return;
    this.working = true;
    try {
      const lease = randomUUID();
      const jobs = await this.db.query(
        `WITH next AS (
        SELECT plog_id FROM plog_analysis WHERE state IN ('queued','processing') AND next_run<=now()
        ORDER BY next_run FOR UPDATE SKIP LOCKED LIMIT 1)
        UPDATE plog_analysis a SET state='processing',lease=$1,attempts=attempts+1,next_run=now()+interval '5 minutes'
        FROM next WHERE a.plog_id=next.plog_id RETURNING a.plog_id,a.attempts,a.suspicious_evidence`,
        [lease],
      );
      const job = jobs[0]?.[0] ?? jobs[0];
      if (!job?.plog_id) return;
      console.log(`[AnalysisWorker] Picked up plog ${job.plog_id} for analysis (attempt ${job.attempts})...`);
      try {
        const photos: Photo[] = await this.db.query(
          `SELECT DISTINCT ON (sha256) id,storage_key,sha256 FROM garbage_evidence
          WHERE plog_id=$1 AND uploaded_at IS NOT NULL ORDER BY sha256,created_at,id`,
          [job.plog_id],
        );
        if (!photos.length) {
          console.log(`[AnalysisWorker] Plog ${job.plog_id} has no photos, marking empty.`);
          await this.db.query(
            "UPDATE plog_analysis SET state='ready', result='{\"quality\":\"empty\",\"items\":[]}', lease=NULL WHERE plog_id=$1 AND lease=$2",
            [job.plog_id, lease],
          );
          return;
        }
        console.log(`[AnalysisWorker] Preparing ${photos.length} photo(s) for Gemini API...`);
        const parts: object[] = [
          {
            text: 'Inspect the following views of collected litter together. Identify visible items and material. Count the same objects seen from multiple angles once. Group identical visible items. Give the zero-based photo indices for each group and a bounding box [ymin,xmin,ymax,xmax] in 0..1000 on the first listed photo. For sealed bags or uncountable piles use unclear. Use empty if no identifiable litter. Mark certain false for ambiguous items. Never infer hidden contents, weight, emissions, or pickup location.',
          },
        ];
        for (const photo of photos) {
          const image = await sharp(await this.storage.read(photo.storage_key))
            .rotate()
            .resize({ width: 1280, height: 1280, fit: 'inside', withoutEnlargement: true })
            .jpeg({ quality: 80 })
            .toBuffer();
          parts.push({ inlineData: { mimeType: 'image/jpeg', data: image.toString('base64') } });
        }
        const model = this.model;
        const apiKey = this.config.get<string>('GEMINI_API_KEY') || process.env.GEMINI_API_KEY;
        console.log(`[AnalysisWorker] Sending request to Gemini (${model})...`);
        const res = await fetch(
          'https://generativelanguage.googleapis.com/v1beta/models/' +
            encodeURIComponent(model) +
            ':generateContent',
          {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': apiKey!,
            },
            signal: AbortSignal.timeout(60000),
            body: JSON.stringify({
              contents: [{ role: 'user', parts }],
              generationConfig: {
                responseMimeType: 'application/json',
                responseSchema: schema,
                thinkingConfig: { thinkingBudget: 0 },
              },
            }),
          },
        );
        if (!res.ok) throw new Error(`Provider unavailable (${res.status})`);
        const data = (await res.json()) as {
          modelVersion?: string;
          candidates?: { content: { parts: { text?: string; thought?: boolean }[] } }[];
        };
        const output =
          data.candidates?.[0]?.content.parts
            .filter((p) => !p.thought)
            .map((p) => p.text ?? '')
            .join('') ?? '';
        const result = normalizeDetections(JSON.parse(output), photos);
        const state =
          !job.suspicious_evidence && result.quality === 'clear' && result.items.length > 0 && result.items.every((i) => i.certain)
            ? 'ready'
            : 'review';
        console.log(`[AnalysisWorker] Plog ${job.plog_id} analyzed successfully. State: ${state}, items: ${result.items.length}`);
        await this.db.query(
          'UPDATE plog_analysis SET result=$3,state=$4,model=$5,lease=NULL WHERE plog_id=$1 AND lease=$2',
          [job.plog_id, lease, JSON.stringify(result), state, data.modelVersion ?? model],
        );
      } catch (err) {
        console.error(`[AnalysisWorker] Error analyzing plog ${job.plog_id}:`, err);
        await this.db.query(
          `UPDATE plog_analysis SET state=CASE WHEN attempts>=3 THEN 'failed' ELSE 'queued' END,
          lease=NULL,next_run=now()+interval '30 seconds'*attempts WHERE plog_id=$1 AND lease=$2`,
          [job.plog_id, lease],
        );
      }
    } finally {
      this.working = false;
    }
  }
}
