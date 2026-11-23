import { BadRequestException, ConflictException, Injectable, NotFoundException, UnprocessableEntityException } from '@nestjs/common';
import { createHash } from 'node:crypto';
import sharp from 'sharp';
import { DataSource, EntityManager } from 'typeorm';
import { parseCapture, parseMetadataField } from '../evidence/capture-metadata';
import { requireRecorder } from '../plogs/recording-device';
import { EvidenceStorage } from '../evidence/evidence-storage';
import { type PhotoUpload, validatePhoto } from '../evidence/evidence.service';
import { CollectionFields, DiscoverQuery, MapQuery, SpotFields, ObservationInput } from './reports.dto';

const visible = "r.collection_plog_id IS NULL AND r.status IN ('open','collected')";
const stale = "coalesce(r.last_seen_at,r.created_at) < now()-interval '30 days'";
const needsChecking = `EXISTS (SELECT 1 FROM spot_observations o WHERE o.report_id=r.id
  AND o.outcome='missing' AND o.verification IN ('verified','legacy')
  AND coalesce(o.observed_at,o.created_at)>coalesce(r.last_seen_at,r.created_at))`;
const selectReports = (origin?: string | null) => `SELECT r.id, r.previous_report_id AS "previousReportId", r.location_source AS "locationSource",
  (r.status='open' AND ${stale}) AS stale, r.category, r.notes, r.place, r.status, r.last_seen_at AS "lastSeenAt",
  ${needsChecking} AS "needsChecking", r.created_at AS "createdAt",
  ST_Y(r.location::geometry) AS latitude, ST_X(r.location::geometry) AS longitude,
  r.author_id=$1 AS mine, (SELECT count(*)::int FROM litter_report_photos WHERE report_id=r.id) AS "photoCount"
  ${origin ? `, ST_Distance(r.location,${origin}) AS distance` : ''}
  FROM litter_reports r`;
const selection = selectReports();
const digest = (data: Buffer | string) => createHash('sha256').update(data).digest('hex');

@Injectable()
export class ReportsService {
  constructor(
    private readonly db: DataSource,
    private readonly storage: EvidenceStorage,
  ) {}

  async list(owner: string, query: DiscoverQuery) {
    const { south, north, west, east, lat, lon, radius, ageDays, category, sort, status, limit = 100 } = query;
    if (+south > +north) throw new BadRequestException('Invalid viewport');
    const origin = lat !== undefined && lon !== undefined;
    if ((lat === undefined) !== (lon === undefined) || (!origin && (radius || sort === 'nearest'))) {
      throw new BadRequestException('Choose an origin for nearby discovery');
    }
    const inBox = (left: string, right: string) =>
      `r.location::geometry && ST_MakeEnvelope(${left},$2,${right},$3,4326)`;
    const bounds = +west <= +east ? inBox('$4', '$5') : `(${inBox('$4', '180')} OR ${inBox('-180', '$5')})`;
    const params: (string | number)[] = [owner, south, north, west, east];
    const bind = (value: string | number) => '$' + params.push(value);
    const location = origin ? `ST_SetSRID(ST_MakePoint(${bind(+lon)},${bind(+lat)}),4326)::geography` : null;
    const filters = [
      bounds,
      'r.collection_plog_id IS NULL',
      status === 'collected' ? "r.status='collected'" : "r.status='open'",
    ];
    if (status === 'open') filters.push(`NOT (${stale} OR ${needsChecking})`);
    if (status === 'verification') filters.push(`(${stale} OR ${needsChecking})`);
    if (category) filters.push(`r.category=${bind(category)}`);
    if (radius) filters.push(`ST_DWithin(r.location,${location},${bind(radius)})`);
    if (ageDays) filters.push(`r.created_at>=now()-${bind(ageDays)}::int*interval '1 day'`);
    const order = sort === 'nearest' ? 'distance, ' : '';
    const rows = await this.db.query(
      `${selectReports(location)}
      WHERE ${filters.join(' AND ')}
      ORDER BY ${order}r.created_at DESC,r.id DESC LIMIT ${bind(limit + 1)}`,
      params,
    );
    return { items: rows.slice(0, limit), truncated: rows.length > limit };
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

  async collection(owner: string, id: string, fields: CollectionFields, recorder?: string) {
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
    return this.publish(owner, id, fields, files, fields.plogId, recorder);
  }

  async publish(owner: string, id: string, fields: SpotFields, files: PhotoUpload[], plogId?: string, recorder?: string) {
    if (!files?.length || files.length > 6) throw new BadRequestException('Choose one to six photos');
    const { category, notes } = fields;
    const lat = Number(fields.latitude);
    const lng = Number(fields.longitude);
    const rawCaptures = parseMetadataField(fields.captures);
    if (rawCaptures !== undefined && (!Array.isArray(rawCaptures) || rawCaptures.length !== files.length)) {
      throw new BadRequestException('Send metadata for each photo');
    }
    const captures = (rawCaptures as unknown[] | undefined)?.map(value => value === null ? null : parseCapture(value));
    const fingerprint = digest(
      JSON.stringify([lat, lng, category, notes, plogId ?? null, files.map((f) => digest(f.buffer)), ...(fields.place ? [fields.place] : []), ...(captures?.some(Boolean) ? [captures] : []), ...(fields.locationSource === 'gps' ? ['gps'] : []), ...(fields.previousReportId ? [fields.previousReportId] : [])]),
    );
    // Reserve an immutable request before writing any objects. Lost acknowledgements use the same keys.
    for (const file of files) await validatePhoto(file);
    const reservation = await this.db.transaction(async (manager) => {
      const activity = plogId ? await this.lockPlog(manager, owner, plogId, recorder) : null;
      if (!plogId) {
        await this.lockDraft(manager, id);
        const [cancelled] = await manager.query(
          'SELECT 1 FROM litter_report_draft_cancellations WHERE author_id=$1 AND report_id=$2', [owner, id]);
        if (cancelled) throw new ConflictException('The report draft was cancelled');
      }
      await manager.query(
        `INSERT INTO litter_reports(id,author_id,collection_plog_id,location,category,notes,fingerprint,status)
        VALUES ($1,$2,$3,ST_SetSRID(ST_MakePoint($4,$5),4326)::geography,$6,$7,$8,'uploading')
        ON CONFLICT(id) DO NOTHING`,
        [id, owner, plogId ?? null, lng, lat, category, notes, fingerprint],
      );
      const [row] = await manager.query(
        'SELECT author_id,fingerprint,status,upload_token FROM litter_reports WHERE id=$1 FOR UPDATE',
        [id],
      );
      if (!row || row.author_id !== owner) throw new NotFoundException();
      if (row.fingerprint !== fingerprint || ['hidden', 'withdrawn'].includes(row.status))
        throw new ConflictException('Report ID already used');
      if (activity && activity !== 'active' && row.status === 'uploading')
        throw new ConflictException('Plog is closed');
      return { status: row.status as string, token: row.upload_token as string };
    });
    if (reservation.status !== 'uploading') return { id, status: reservation.status };
    const images: Buffer[] = [];
    for (const file of files) {
      images.push(await sharp(file.buffer, { limitInputPixels: 32_000_000 })
        .rotate()
        .resize({ width: 1800, height: 1800, fit: 'inside', withoutEnlargement: true })
        .jpeg({ quality: 85 })
        .toBuffer());
    }
    return this.db.transaction(async (manager) => {
      const activity = plogId ? await this.lockPlog(manager, owner, plogId, recorder) : null;
      const [row] = await manager.query(
        'SELECT status FROM litter_reports WHERE id=$1 AND author_id=$2 AND upload_token=$3 FOR UPDATE',
        [id, owner, reservation.token]);
      if (!row) throw new NotFoundException();
      if (['hidden', 'withdrawn'].includes(row.status)) throw new ConflictException('Report ID already used');
      if (row.status !== 'uploading') return { id, status: row.status };
      if (activity && activity !== 'active') throw new ConflictException('Plog is closed');
      for (const [index, bytes] of images.entries()) {
        const key = 'evidence/reports/' + id + '/' + reservation.token + '/' + index + '.jpg';
        await this.storage.put(key, bytes, 'image/jpeg');
        await manager.query(
          'INSERT INTO litter_report_photos(report_id,position,storage_key,capture,sha256) VALUES ($1,$2,$3,$4,$5)',
          [id, index, key, captures?.[index] ?? null, digest(files[index].buffer)]);
      }
      const next = plogId ? 'pending_finish' : 'open';
      const [previous] = plogId ? [] : await manager.query(`
        SELECT previous.id FROM litter_reports previous JOIN litter_reports current ON current.id=$1
        WHERE previous.status='collected' AND previous.collection_plog_id IS NULL
          AND ST_DWithin(previous.location,current.location,75)
          AND ($2::uuid IS NULL AND previous.category=current.category OR previous.id=$2)
        ORDER BY previous.created_at DESC,previous.id LIMIT 1
      `, [id, fields.previousReportId ?? null]);
      await manager.query(`
        UPDATE litter_reports SET status=$2,place=$3,location_source=$4,previous_report_id=$5,
          last_seen_at=CASE WHEN $2='open' THEN created_at END WHERE id=$1
      `, [id, next, fields.place ?? '', fields.locationSource ?? 'manual', previous?.id ?? null]);
      return { id, status: next };
    });
  }

  private async lockPlog(manager: EntityManager, owner: string, id: string, recorder?: string) {
    const [plog] = await manager.query('SELECT status,recording_device FROM plogs WHERE id=$1 AND user_id=$2 FOR UPDATE', [
      id,
      owner,
    ]);
    if (!plog) throw new NotFoundException();
    if (plog.status === 'active') requireRecorder(plog.recording_device, recorder);
    return plog.status as string;
  }

  async nearby(owner: string, lat: number, lon: number) {
    if (!Number.isFinite(lat) || !Number.isFinite(lon) || Math.abs(lat)>90 || Math.abs(lon)>180)
      throw new BadRequestException('Invalid area');
    return this.db.query(`${selection} WHERE r.status='open' AND ST_DWithin(r.location,
      ST_SetSRID(ST_MakePoint($3,$2),4326)::geography,75)
      ORDER BY r.location <-> ST_SetSRID(ST_MakePoint($3,$2),4326)::geography LIMIT 8`, [owner,lat,lon]);
  }

  async observe(owner: string, report: string, id: string, body: ObservationInput, recorder?: string) {
    const { outcome, photoId, plogId, gps } = body;
    const sighting = outcome === 'missing' || outcome === 'present';
    if ((!sighting && !photoId) || (sighting && (photoId || plogId))) {
      throw new BadRequestException('Provide a pickup photo for a cleanup or a fresh location for a sighting');
    }
    return this.db.transaction(async tx => {
      await tx.query('SELECT pg_advisory_xact_lock(hashtext($1))', [id]);
      let activity: string | null = null;
      let activityStatus: string | null = null;
      let recordingDevice: string | null = null;
      if (photoId) {
        const [photo] = await tx.query(`
          SELECT p.id,p.status,p.recording_device FROM garbage_evidence e JOIN plogs p ON p.id=e.plog_id
          WHERE e.id=$1 AND p.user_id=$2 AND e.uploaded_at IS NOT NULL AND ($3::uuid IS NULL OR p.id=$3)
          FOR UPDATE OF p
        `, [photoId, owner, plogId ?? null]);
        if (!photo) throw new NotFoundException();
        activity = photo.id;
        activityStatus = photo.status;
        recordingDevice = photo.recording_device;
      }
      const [spot] = await tx.query(
        'SELECT status,created_at FROM litter_reports WHERE id=$1 AND collection_plog_id IS NULL FOR UPDATE', [report]);
      if (!spot) throw new NotFoundException();
      const [old] = await tx.query('SELECT * FROM spot_observations WHERE id=$1', [id]);
      if (old) {
        if (old.report_id !== report || old.user_id !== owner || old.outcome !== outcome
          || old.photo_id !== (photoId ?? null) || (old.plog_id && old.plog_id !== activity)) {
          throw new ConflictException('Observation already used');
        }
        return { id, status: spot.status, verification: old.verification };
      }
      if (!['open','collected'].includes(spot.status)) throw new NotFoundException();
      let verification = 'unverified';
      if (photoId) {
        if (activityStatus !== 'active') throw new UnprocessableEntityException('This Plog is closed');
        requireRecorder(recordingDevice, recorder);
        const [previous] = await tx.query(
          `SELECT 1 FROM garbage_evidence photo
          JOIN garbage_evidence used ON used.plog_id=photo.plog_id AND used.sha256=photo.sha256
          JOIN spot_observations o ON o.photo_id=used.id
          WHERE photo.id=$1 LIMIT 1`, [photoId]);
        if (previous) throw new UnprocessableEntityException('This evidence already supports an observation');
        verification = 'pending';
      } else if (sighting && gps && spot.status === 'open' && gps.accuracyMeters <= 40) {
        const observationTime = Date.parse(gps.recordedAt);
        if (observationTime >= new Date(spot.created_at).getTime()
          && observationTime <= Date.now() + 5000 && observationTime >= Date.now() - 7 * 86400000) {
          const [{ nearby }] = await tx.query(`
            SELECT ST_DWithin(location,ST_SetSRID(ST_MakePoint($2,$3),4326)::geography,75) AS nearby
            FROM litter_reports WHERE id=$1
          `, [report, gps.longitude, gps.latitude]);
          if (nearby) verification = 'verified';
        }
      }
      await tx.query(`
        INSERT INTO spot_observations(id,report_id,user_id,outcome,photo_id,plog_id,verification,observed_at)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8)
      `, [id, report, owner, outcome, photoId ?? null, activity, verification, gps?.recordedAt ?? null]);
      if (outcome === 'present' && verification === 'verified') {
        await tx.query('UPDATE litter_reports SET last_seen_at=greatest(last_seen_at,$2) WHERE id=$1',
          [report, gps!.recordedAt]);
      }
      return { id, status: spot.status, verification };
    });
  }

  async edit(owner: string, id: string, fields: SpotFields) {
    const [row] = await this.db.query(`
      WITH edited AS (
        UPDATE litter_reports SET location=ST_SetSRID(ST_MakePoint($4,$3),4326)::geography,
          category=$5,notes=$6,place=$7,location_source=$8
        WHERE id=$1 AND author_id=$2 AND status='open' RETURNING id
      ) SELECT id FROM edited
    `, [id, owner, +fields.latitude, +fields.longitude, fields.category, fields.notes, fields.place ?? '', fields.locationSource ?? 'manual']);
    if (!row) throw new NotFoundException();
    return this.detail(owner, id);
  }

  async history(owner: string, id: string) {
    const [report] = await this.db.query('SELECT id FROM litter_reports WHERE id=$1 AND author_id=$2', [id, owner]);
    if (!report) throw new NotFoundException();
    return this.db.query(
      'SELECT status,changed_at AS "changedAt" FROM litter_report_status_history WHERE report_id=$1 ORDER BY event_id', [id]);
  }

  async withdraw(owner: string, id: string) {
    if (!await this.db.transaction(tx => this.withdrawOwnedReport(tx, owner, id))) {
      throw new NotFoundException();
    }
  }

  async cancelDraft(owner: string, id: string) {
    await this.db.transaction(async tx => {
      await this.lockDraft(tx, id);
      await tx.query(`
        INSERT INTO litter_report_draft_cancellations(author_id,report_id)
        VALUES($1,$2) ON CONFLICT DO NOTHING
      `, [owner, id]);
      await this.withdrawOwnedReport(tx, owner, id);
    });
  }

  private async lockDraft(tx: EntityManager, id: string) {
    await tx.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', ['litter draft:' + id]);
  }

  private async withdrawOwnedReport(tx: EntityManager, owner: string, id: string) {
    const [row] = await tx.query(`
      SELECT status FROM litter_reports WHERE id=$1 AND author_id=$2 AND collection_plog_id IS NULL
        AND status IN ('open','collected','uploading','withdrawn') FOR UPDATE
    `, [id, owner]);
    if (!row) return false;
    if (row.status !== 'withdrawn') {
      await tx.query('SELECT queue_report_photo_deletion($1)', [id]);
      await tx.query("UPDATE litter_reports SET status='withdrawn' WHERE id=$1", [id]);
    }
    return true;
  }

  async flag(owner: string, id: string) {
    await this.detail(owner, id);
    await this.db.query('INSERT INTO litter_report_flags VALUES ($1,$2,now()) ON CONFLICT DO NOTHING', [
      id,
      owner,
    ]);
  }
}
