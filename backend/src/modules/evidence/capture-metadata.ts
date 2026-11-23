import { BadRequestException } from '@nestjs/common';
import { plainToInstance } from 'class-transformer';
import { IsBoolean, IsIn, IsISO8601, IsNumber, IsOptional, Matches, Max, Min, validateSync } from 'class-validator';

class Coordinates {
  @IsNumber() @Min(-90) @Max(90)
  latitude!: number;

  @IsNumber() @Min(-180) @Max(180)
  longitude!: number;
}

export class GpsSample extends Coordinates {
  @IsNumber() @Min(0.1) @Max(10000)
  accuracyMeters!: number;

  @IsISO8601({ strict: true }) @Matches(/T.*(?:Z|[+-]\d{2}:\d{2})$/)
  recordedAt!: string;
}

class CaptureFields {
  @IsIn(['camera', 'gallery', 'unknown'])
  source!: 'camera' | 'gallery' | 'unknown';

  @IsISO8601({ strict: true }) @Matches(/T.*(?:Z|[+-]\d{2}:\d{2})$/)
  capturedAt!: string;

  @IsOptional() @IsBoolean()
  embeddedTime?: boolean;
}

export type CaptureMetadata = CaptureFields & { gps?: GpsSample; embeddedLocation?: Coordinates };

function parseObject<T extends object>(value: unknown, type: new () => T): T {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new BadRequestException('Invalid photo or GPS metadata');
  }
  const parsed = plainToInstance(type, value);
  if (validateSync(parsed, { whitelist: true, forbidNonWhitelisted: true }).length) {
    throw new BadRequestException('Invalid photo or GPS metadata');
  }
  return parsed;
}

export function parseCapture(value: unknown): CaptureMetadata | null {
  if (value === undefined) return null;
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new BadRequestException('Invalid photo metadata');
  }
  const { gps, embeddedLocation, ...metadata } = value as Record<string, unknown>;
  const fields = parseObject(metadata, CaptureFields);
  const capturedAt = new Date(fields.capturedAt);
  if (!Number.isFinite(capturedAt.getTime())) throw new BadRequestException('Invalid capture time');
  const sample = gps === undefined ? undefined : parseObject(gps, GpsSample);
  if (sample && !Number.isFinite(Date.parse(sample.recordedAt))) throw new BadRequestException('Invalid GPS time');
  if (sample) sample.recordedAt = new Date(sample.recordedAt).toISOString();
  const location = embeddedLocation === undefined ? undefined : parseObject(embeddedLocation, Coordinates);
  if ((location || fields.embeddedTime) && fields.source !== 'gallery') {
    throw new BadRequestException('Embedded metadata requires a gallery photo');
  }
  return {
    source: fields.source,
    capturedAt: capturedAt.toISOString(),
    ...(sample && { gps: sample }),
    ...(location && { embeddedLocation: location }),
    ...(fields.embeddedTime && { embeddedTime: true }),
  };
}

export function parseMetadataField(value: unknown): unknown {
  if (value === undefined) return undefined;
  if (typeof value !== 'string') throw new BadRequestException('Invalid metadata field');
  try {
    return JSON.parse(value) as unknown;
  } catch {
    throw new BadRequestException('Invalid metadata field');
  }
}
