import { BadRequestException, ConflictException, Injectable, NotFoundException } from '@nestjs/common';
import { createHash } from 'node:crypto';
import sharp from 'sharp';
import { DataSource, EntityManager } from 'typeorm';
import { EvidenceStorage } from '../evidence/evidence-storage';
import { type PhotoUpload, validatePhoto } from '../evidence/evidence.service';
import { CollectionFields, MapQuery, SpotFields, ObservationInput } from './reports.dto';

const visible = "r.status IN ('open','collected')";
const selection = `SELECT r.id, r.category, r.notes, r.place, r.status, r.last_seen_at AS "lastSeenAt",
  EXISTS (SELECT 1 FROM spot_observations o WHERE o.report_id=r.id AND o.outcome='missing'
    AND o.created_at>coalesce(r.last_seen_at,r.created_at)) AS "needsChecking", r.created_at AS "createdAt",
  ST_Y(r.location::geometry) AS latitude, ST_X(r.location::geometry) AS longitude,
  r.author_id=$1 AS mine, (SELECT count(*)::int FROM litter_report_photos WHERE report_id=r.id) AS "photoCount"
  FROM litter_reports r`;
const digest = (data: Buffer | string) => createHash('sha256').update(data).digest('hex');

@Injectable()
export class ReportsService {
  constructor(
    private readonly db: DataSource,
    private readonly storage: EvidenceStorage,
  ) {}

  async list(owner: string, viewport: MapQuery) {
    const { south, north, west, east } = viewport;
    if (+south > +north) throw new BadRequestException('Invalid viewport');
    const inBox = (left: string, right: string) =>
      `r.location::geometry && ST_MakeEnvelope(${left},$2,${right},$3,4326)`;
    const bounds = +west <= +east ? inBox('$4', '$5') : `(${inBox('$4', '180')} OR ${inBox('-180', '$5')})`;
    const rows = await this.db.query(
      `${selection} WHERE r.status='open' AND ${bounds}
      ORDER BY r.created_at DESC,r.id DESC LIMIT 101`,
      [owner, south, north, west, east],
    );
    return { items: rows.slice(0, 100), truncated: rows.length > 100 };
  }

  async clusters(viewport: MapQuery) {
    const south=Number(viewport.south), north=Number(viewport.north), west=Number(viewport.west), east=Number(viewport.east);
    if (north < south) throw new BadRequestException('Invalid viewport');
    const bounds=west<=east ? 'location::geometry && ST_MakeEnvelope($1,$2,$3,$4,4326)' :
      '(location::geometry && ST_MakeEnvelope($1,$2,180,$4,4326) OR location::geometry && ST_MakeEnvelope(-180,$2,$3,$4,4326))';
    const width=(east<west?east+360:east)-west;
    return this.db.query(`WITH points AS (
      SELECT id,ST_Y(location::geometry) AS lat,ST_X(location::geometry) +
        CASE WHEN ST_X(location::geometry)<$1 THEN 360 ELSE 0 END AS lng FROM litter_reports
      WHERE status='open' AND ${bounds})
      SELECT CASE WHEN count(*)=1 THEN min(id::text) END AS id,count(*)::int AS count,avg(lat) AS latitude,
        avg(lng)-CASE WHEN avg(lng)>180 THEN 360 ELSE 0 END AS longitude
      FROM points GROUP BY floor((lng-$1)/$5),floor((lat-$2)/$6)`,
      [west,south,east,north,Math.max(width/12,0.00001),Math.max((north-south)/16,0.00001)]);
  }

  async mine(owner: string, before?: string) {
    const rows = await this.db.query(
      `${selection} WHERE r.author_id=$1 AND ${visible}
      AND ($2::uuid IS NULL OR (r.created_at,r.id)<(SELECT created_at,id FROM litter_reports WHERE id=$2 AND author_id=$1))
      ORDER BY r.created_at DESC,r.id DESC LIMIT 26`,
      [owner, before ?? null],
    );
    return { items: rows.slice(0, 25), nextCursor: rows.length > 25 ? rows[24].id : null };
  }

  async detail(owner: string, id: string) {
    const [report] = await this.db.query(`${selection} WHERE r.id=$2 AND ${visible}`, [owner, id]);
    if (!report) throw new NotFoundException();
    return report;
  }

  async image(id: string, position: number) {
    const [photo] = await this.db.query(
      `SELECT p.storage_key FROM litter_report_photos p
      JOIN litter_reports r ON p.report_id=r.id WHERE r.id=$1 AND p.position=$2 AND ${visible}`,
      [id, position],
    );
    if (!photo) throw new NotFoundException();
    return this.storage.read(photo.storage_key);
  }

  async collection(owner: string, id: string, fields: CollectionFields) {
    const files: PhotoUpload[] = [];
    for (const photoId of fields.photoIds) {
      const [photo] = await this.db.query(
        `SELECT e.storage_key,e.media_type FROM garbage_evidence e
        JOIN plogs p ON p.id=e.plog_id WHERE p.user_id=$1 AND p.id=$2 AND e.id=$3 AND e.uploaded_at IS NOT NULL`,
        [owner, fields.plogId, photoId],
      );
      if (!photo) throw new NotFoundException();
      files.push({ buffer: await this.storage.read(photo.storage_key), mimetype: photo.media_type });
    }
    return this.publish(owner, id, fields, files, fields.plogId);
  }

  async publish(owner: string, id: string, fields: SpotFields, files: PhotoUpload[], plogId?: string) {
    if (!files?.length || files.length > 6) throw new BadRequestException('Choose one to six photos');
    const { category, notes } = fields;
    const lat = Number(fields.latitude);
    const lng = Number(fields.longitude);
    const fingerprint = digest(
      JSON.stringify([lat, lng, category, notes, plogId ?? null, files.map((f) => digest(f.buffer)), ...(fields.place ? [fields.place] : [])]),
    );
    // Reserve an immutable request before writing any objects. Lost acknowledgements use the same keys.
    for (const file of files) await validatePhoto(file);
    const status = await this.db.transaction(async (manager) => {
      const activity = plogId ? await this.lockPlog(manager, owner, plogId) : null;
      await manager.query(
        `INSERT INTO litter_reports(id,author_id,collection_plog_id,location,category,notes,fingerprint,status)
        VALUES ($1,$2,$3,ST_SetSRID(ST_MakePoint($4,$5),4326)::geography,$6,$7,$8,'uploading')
        ON CONFLICT(id) DO NOTHING`,
        [id, owner, plogId ?? null, lng, lat, category, notes, fingerprint],
      );
      const [row] = await manager.query(
        'SELECT author_id,fingerprint,status FROM litter_reports WHERE id=$1 FOR UPDATE',
        [id],
      );
      if (row.author_id !== owner) throw new NotFoundException();
      if (row.fingerprint !== fingerprint || ['hidden', 'withdrawn'].includes(row.status))
        throw new ConflictException('Report ID already used');
      if (activity === 'completed' && row.status === 'uploading')
        throw new ConflictException('Plog already completed');
      return row.status as string;
    });
    if (status !== 'uploading') return { id, status };
    const keys: string[] = [];
    for (const [index, file] of files.entries()) {
      // Re-encoding applies orientation and strips EXIF, IPTC and GPS before sharing.
      const bytes = await sharp(file.buffer, { limitInputPixels: 32_000_000 })
        .rotate()
        .resize({ width: 1800, height: 1800, fit: 'inside', withoutEnlargement: true })
        .jpeg({ quality: 85 })
        .toBuffer();
      const key = 'evidence/reports/' + id + '/' + index + '.jpg';
      await this.storage.put(key, bytes, 'image/jpeg');
      keys.push(key);
    }
    return this.db.transaction(async (manager) => {
      const [row] = await manager.query('SELECT status FROM litter_reports WHERE id=$1 FOR UPDATE', [id]);
      if (row.status !== 'uploading') return { id, status: row.status };
      for (const [index, key] of keys.entries()) {
        await manager.query('INSERT INTO litter_report_photos VALUES ($1,$2,$3)', [id, index, key]);
      }
      const next = plogId ? 'pending_finish' : 'open';
      await manager.query('UPDATE litter_reports SET status=$2,place=$3 WHERE id=$1', [id, next, fields.place ?? '']);
      return { id, status: next };
    });
  }

  private async lockPlog(manager: EntityManager, owner: string, id: string) {
    const [plog] = await manager.query('SELECT status FROM plogs WHERE id=$1 AND user_id=$2 FOR UPDATE', [
      id,
      owner,
    ]);
    if (!plog) throw new NotFoundException();
    return plog.status as string;
  }

  async nearby(owner: string, lat: number, lon: number) {
    if (!Number.isFinite(lat) || !Number.isFinite(lon) || Math.abs(lat)>90 || Math.abs(lon)>180)
      throw new BadRequestException('Invalid area');
    return this.db.query(`${selection} WHERE r.status='open' AND ST_DWithin(r.location,
      ST_SetSRID(ST_MakePoint($3,$2),4326)::geography,75)
      ORDER BY r.location <-> ST_SetSRID(ST_MakePoint($3,$2),4326)::geography LIMIT 8`, [owner,lat,lon]);
  }

  async observe(owner: string, report: string, id: string, body: ObservationInput) {
    const { outcome, photoId } = body;
    if (outcome === 'cleaned' && !photoId || outcome === 'missing' && photoId) throw new BadRequestException('A cleanup needs a pickup photo');
    return this.db.transaction(async tx => {
      await tx.query('SELECT pg_advisory_xact_lock(hashtext($1))',[id]);
      const [spot] = await tx.query('SELECT status FROM litter_reports WHERE id=$1 FOR UPDATE',[report]);
      if (!spot) throw new NotFoundException();
      const [old] = await tx.query('SELECT * FROM spot_observations WHERE id=$1',[id]);
      if (old) {
        if (old.report_id !== report || old.user_id !== owner || old.outcome !== outcome || old.photo_id !== (photoId ?? null))
          throw new ConflictException('Observation already used');
        return {id,status:spot.status};
      }
      if (!['open','collected'].includes(spot.status)) throw new NotFoundException();
      if (photoId) {
        const [photo] = await tx.query(`SELECT e.id FROM garbage_evidence e JOIN plogs p ON p.id=e.plog_id
          WHERE e.id=$1 AND p.user_id=$2 AND e.uploaded_at IS NOT NULL`,[photoId,owner]);
        if (!photo) throw new NotFoundException();
      }
      const resolved = outcome === 'cleaned' && spot.status === 'open';
      await tx.query('INSERT INTO spot_observations(id,report_id,user_id,outcome,photo_id,resolved) VALUES($1,$2,$3,$4,$5,$6)',
        [id,report,owner,outcome,photoId ?? null,resolved]);
      if (resolved) await tx.query("UPDATE litter_reports SET status='collected',last_seen_at=now() WHERE id=$1",[report]);
      if (outcome === 'remains' && spot.status === 'open')
        await tx.query('UPDATE litter_reports SET last_seen_at=now() WHERE id=$1',[report]);
      return {id,status:resolved?'collected':spot.status};
    });
  }

  async withdraw(owner: string, id: string) {
    const rows = await this.db.query(
      `WITH removed AS (UPDATE litter_reports SET status='withdrawn'
      WHERE id=$1 AND author_id=$2 AND status IN ('open','collected','withdrawn') RETURNING id) SELECT * FROM removed`,
      [id, owner],
    );
    if (!rows.length) throw new NotFoundException();
  }

  async flag(owner: string, id: string) {
    await this.detail(owner, id);
    await this.db.query('INSERT INTO litter_report_flags VALUES ($1,$2,now()) ON CONFLICT DO NOTHING', [
      id,
      owner,
    ]);
  }
}
