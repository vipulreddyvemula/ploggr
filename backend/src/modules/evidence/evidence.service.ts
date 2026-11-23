import { BadRequestException, ConflictException, Injectable, NotFoundException, ServiceUnavailableException, UnsupportedMediaTypeException } from '@nestjs/common';
import { createHash, randomUUID } from 'node:crypto';
import sharp from 'sharp';
import { DataSource, EntityManager, IsNull, Not, QueryFailedError } from 'typeorm';
import { requireRecorder } from '../plogs/recording-device';
import { Plog } from '../plogs/plog.entity';
import { EvidenceStorage } from './evidence-storage';
import { parseCapture, parseMetadataField } from './capture-metadata';
import { GarbageEvidence } from './garbage-evidence.entity';

export interface PhotoUpload { buffer: Buffer; mimetype: string }

export async function validatePhoto(file?: PhotoUpload) {
  if (!file?.buffer.length) throw new BadRequestException('A garbage photo is required');
  const jpeg = file.buffer.subarray(0, 3).equals(Buffer.from([255, 216, 255]));
  const png = file.buffer.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  const expected = jpeg ? 'image/jpeg' : png ? 'image/png' : undefined;
  if (!expected || file.mimetype !== expected) throw new UnsupportedMediaTypeException('Use a JPEG or PNG photo');
  try {
    const image = sharp(file.buffer, { limitInputPixels: 32_000_000, failOn: 'warning' });
    const info = await image.metadata();
    if (info.format !== expected.slice(6) || (info.pages ?? 1) !== 1) throw new Error();
    await image.resize(1, 1).raw().toBuffer();
  } catch {
    throw new BadRequestException('Invalid or oversized image');
  }
  return file;
}

export async function perceptualHash(bytes: Buffer) {
  const pixels = await sharp(bytes, { limitInputPixels: 32_000_000 })
    .rotate().flatten({ background: '#fff' }).toColourspace('b-w').resize(9, 8, { fit: 'fill' }).raw().toBuffer();
  let hash = 0n;
  for (let i = 0; i < 72; i++) {
    if (i % 9 === 8) continue;
    hash = (hash << 1n) | BigInt(pixels[i] > pixels[i + 1]);
  }
  const value = hash.toString(16).padStart(16, '0');
  return /^0+$|^f+$/.test(value) ? null : value;
}

function reference(photo: GarbageEvidence) {
  return { id: photo.id, mediaType: photo.mediaType, byteSize: photo.byteSize, uploadedAt: photo.uploadedAt, ...(photo.capture ? { capture: photo.capture } : {}) };
}

@Injectable()
export class EvidenceService {
  constructor(private readonly source: DataSource, private readonly storage: EvidenceStorage) {}

  async list(owner: string, plogId: string) {
    const owned = { id: plogId, user: { id: owner } };
    if (!await this.source.getRepository(Plog).existsBy(owned)) throw new NotFoundException();
    const photos = await this.source.getRepository(GarbageEvidence).find({
      where: { plog: owned, uploadedAt: Not(IsNull()) }, order: { createdAt: 'ASC', id: 'ASC' },
    });
    return { items: photos.map(reference) };
  }

  async image(owner: string, plogId: string, id: string) {
    const photo = await this.source.getRepository(GarbageEvidence).findOneBy({
      id, plog: { id: plogId, user: { id: owner } }, uploadedAt: Not(IsNull()),
    });
    if (!photo) throw new NotFoundException();
    const bytes = await this.storage.read(photo.storageKey);
    if (bytes.length !== photo.byteSize || createHash('sha256').update(bytes).digest('hex') !== photo.sha256) {
      throw new ServiceUnavailableException('Image unavailable');
    }
    return { bytes, mediaType: photo.mediaType };
  }

  private async lockPlog(manager: EntityManager, owner: string, plogId: string) {
    const plog = await manager.getRepository(Plog).createQueryBuilder('p')
      .where('p.user_id = :owner AND p.id = :plogId', { owner, plogId })
      .setLock('pessimistic_write').getOne();
    if (!plog) throw new NotFoundException();
    return plog;
  }

  async remove(owner: string, plogId: string, id: string, recorder?: string) {
    await this.source.transaction(async manager => {
      const plog = await this.lockPlog(manager, owner, plogId);
      if (plog.status !== 'active') throw new ConflictException('Photo selection is closed');
      requireRecorder(plog.recordingDevice, recorder);
      const rows = await manager.query(
        'DELETE FROM garbage_evidence WHERE id=$1 AND plog_id=$2 RETURNING storage_key', [id, plog.id]);
      if (rows.length) {
        await manager.query('INSERT INTO evidence_deletion_queue(storage_key) VALUES($1) ON CONFLICT DO NOTHING',
          [rows[0].storage_key]);
      }
    });
  }

  async upload(owner: string, plogId: string, id: string, input?: PhotoUpload, metadata?: unknown, recorder?: string) {
    const file = await validatePhoto(input);
    const capture = parseCapture(parseMetadataField(metadata));
    const sha256 = createHash('sha256').update(file.buffer).digest('hex');
    const visualHash = await perceptualHash(file.buffer);
    const photo = await this.source.transaction(async manager => {
      const plog = await this.lockPlog(manager, owner, plogId);
      const repo = manager.getRepository(GarbageEvidence);
      const existing = await repo.findOneBy({ id, plog: { id: plog.id } });
      if (existing) {
        const saved = existing.capture;
        const sameCapture = saved?.source === capture?.source && saved?.capturedAt === capture?.capturedAt
          && saved?.gps?.latitude === capture?.gps?.latitude && saved?.gps?.longitude === capture?.gps?.longitude
          && saved?.gps?.accuracyMeters === capture?.gps?.accuracyMeters && saved?.gps?.recordedAt === capture?.gps?.recordedAt;
        const sameEmbedded = saved?.embeddedTime === capture?.embeddedTime
          && saved?.embeddedLocation?.latitude === capture?.embeddedLocation?.latitude
          && saved?.embeddedLocation?.longitude === capture?.embeddedLocation?.longitude;
        if (existing.sha256 !== sha256 || !sameCapture || !sameEmbedded) throw new ConflictException('Photo ID already used');
        return existing;
      }
      if (plog.status !== 'active') throw new ConflictException('Photo selection is closed');
      requireRecorder(plog.recordingDevice, recorder);
      if (await repo.countBy({ plog: { id: plog.id } }) >= 6) throw new ConflictException('Six photos already selected');
      const entry = repo.create({ id, plog, byteSize: file.buffer.length, mediaType: file.mimetype, sha256,
        storageKey: 'evidence/' + plog.id + '/' + randomUUID(), uploadedAt: null, capture, perceptualHash: visualHash });
      try { await repo.insert(entry); } catch (error) {
        if (error instanceof QueryFailedError && error.driverError.code === '23505') throw new ConflictException('Photo ID already used');
        throw error;
      }
      return entry;
    });
    if (photo.uploadedAt) return reference(photo);
    return this.source.transaction(async manager => {
      const plog = await this.lockPlog(manager, owner, plogId);
      const repo = manager.getRepository(GarbageEvidence);
      const pending = await repo.findOneBy({ id, plog: { id: plog.id } });
      if (!pending || pending.storageKey !== photo.storageKey) throw new ConflictException('The photo was removed');
      if (pending.uploadedAt) return reference(pending);
      if (plog.status !== 'active') throw new ConflictException('Photo selection is closed');
      requireRecorder(plog.recordingDevice, recorder);
      await this.storage.put(pending.storageKey, file.buffer, pending.mediaType);
      pending.uploadedAt = new Date();
      await repo.update({ id }, { uploadedAt: pending.uploadedAt });
      return reference(pending);
    });
  }
}
