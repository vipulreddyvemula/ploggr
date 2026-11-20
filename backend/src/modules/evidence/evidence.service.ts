import { BadRequestException, ConflictException, Injectable, NotFoundException, UnsupportedMediaTypeException } from '@nestjs/common';
import { createHash } from 'node:crypto';
import sharp from 'sharp';
import { DataSource, IsNull, QueryFailedError } from 'typeorm';
import { Plog } from '../plogs/plog.entity';
import { EvidenceStorage } from './evidence-storage';
import { GarbageEvidence } from './garbage-evidence.entity';

export interface PhotoUpload { buffer: Buffer; mimetype: string }

async function validatePhoto(file?: PhotoUpload) {
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

function reference(photo: GarbageEvidence) {
  return { id: photo.id, mediaType: photo.mediaType, byteSize: photo.byteSize, uploadedAt: photo.uploadedAt };
}

@Injectable()
export class EvidenceService {
  constructor(private readonly source: DataSource, private readonly storage: EvidenceStorage) {}

  async upload(owner: string, plogId: string, id: string, input?: PhotoUpload) {
    const file = await validatePhoto(input);
    const sha256 = createHash('sha256').update(file.buffer).digest('hex');
    const photo = await this.source.transaction(async manager => {
      const plog = await manager.getRepository(Plog).createQueryBuilder('p')
        .where('p.user_id = :owner AND p.id = :plogId', { owner, plogId }).setLock('pessimistic_write').getOne();
      if (!plog) throw new NotFoundException();
      const repo = manager.getRepository(GarbageEvidence);
      const existing = await repo.findOneBy({ id, plog: { id: plog.id } });
      if (existing) {
        if (existing.sha256 !== sha256) throw new ConflictException('Photo ID already used');
        return existing;
      }
      if (plog.status !== 'active') throw new ConflictException('Photo selection is closed');
      if (await repo.countBy({ plog: { id: plog.id } }) >= 6) throw new ConflictException('Six photos already selected');
      const entry = repo.create({ id, plog, byteSize: file.buffer.length, mediaType: file.mimetype, sha256,
        storageKey: 'evidence/' + plog.id + '/' + id.toLowerCase(), uploadedAt: null });
      try { await repo.insert(entry); } catch (error) {
        if (error instanceof QueryFailedError && error.driverError.code === '23505') throw new ConflictException('Photo ID already used');
        throw error;
      }
      return entry;
    });
    if (!photo.uploadedAt) {
      // The durable reservation gives a failed or interrupted PUT the same object key on retry.
      await this.storage.put(photo.storageKey, file.buffer, photo.mediaType);
      const repo = this.source.getRepository(GarbageEvidence);
      await repo.update({ id: photo.id, uploadedAt: IsNull() }, { uploadedAt: new Date() });
      return reference(await repo.findOneByOrFail({ id: photo.id }));
    }
    return reference(photo);
  }
}
