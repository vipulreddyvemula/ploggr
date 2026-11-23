import type { EntityManager } from 'typeorm';

export async function lockPlogEvidence(tx: EntityManager, plogId: string) {
  const keys: { value: string }[] = await tx.query(`
    SELECT 'photo:' || sha256 AS value FROM garbage_evidence WHERE plog_id=$1
    UNION
    SELECT 'visual:' || left(perceptual_hash,4) AS value FROM garbage_evidence
      WHERE plog_id=$1 AND perceptual_hash IS NOT NULL
    ORDER BY value
  `, [plogId]);
  for (const { value } of keys) {
    await tx.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))', [value]);
  }
}

export async function finalizeObservations(tx: EntityManager, plogId: string, start: Date, end: Date) {
  const requested: { report_id: string }[] = await tx.query(
    "SELECT DISTINCT report_id FROM spot_observations WHERE plog_id=$1 AND verification='pending'", [plogId]);
  if (!requested.length) return;
  const current: { id: string; status: string }[] = await tx.query(
    'SELECT id,status FROM litter_reports WHERE id=ANY($1::uuid[]) ORDER BY id FOR NO KEY UPDATE',
    [requested.map(row => row.report_id)]);
  const statuses = new Map(current.map(r => [r.id, r.status]));
  const claims: { id: string; report_id: string; outcome: string; sha256: string; eligible: boolean }[] =
    await tx.query(`
      SELECT o.id,o.report_id,o.outcome,e.sha256,
        coalesce(e.capture->>'source'='camera'
          AND (e.capture->>'capturedAt')::timestamptz BETWEEN $2::timestamptz - interval '2 seconds' AND $3::timestamptz + interval '1 second'
          AND (e.capture->>'capturedAt')::timestamptz >= r.created_at
          AND (e.capture->>'capturedAt')::timestamptz <= e.uploaded_at + interval '5 seconds'
          AND (e.capture->'gps'->>'accuracyMeters')::float8 <= 40
          AND (e.capture->'gps'->>'recordedAt')::timestamptz BETWEEN
            (e.capture->>'capturedAt')::timestamptz - interval '30 seconds' AND
            (e.capture->>'capturedAt')::timestamptz + interval '5 seconds'
          AND ST_DWithin(r.location, ST_SetSRID(ST_MakePoint((e.capture->'gps'->>'longitude')::float8,
            (e.capture->'gps'->>'latitude')::float8),4326)::geography,75)
          AND NOT EXISTS (SELECT 1 FROM litter_report_photos f WHERE f.sha256=e.sha256)
          AND e.uploaded_at IS NOT NULL, false) AS eligible
      FROM spot_observations o JOIN garbage_evidence e ON e.id=o.photo_id AND e.plog_id=$1
      JOIN litter_reports r ON r.id=o.report_id
      WHERE o.plog_id=$1 AND o.verification='pending' ORDER BY o.report_id,o.created_at,o.id
    `, [plogId, start, end]);
  for (const claim of claims) {
    const status = statuses.get(claim.report_id);
    const [reused] = claim.eligible ? await tx.query(`
      SELECT 1 FROM garbage_evidence prior JOIN plogs p ON p.id=prior.plog_id
      WHERE prior.sha256=$1 AND p.status='completed' AND p.id<>$2
      UNION ALL SELECT 1 FROM spot_observations WHERE reward_sha256=$1 LIMIT 1
    `, [claim.sha256, plogId]) : [];
    let verification = 'unverified';
    if (claim.eligible && !reused && status === 'open') {
      verification = 'verified';
      if (claim.outcome === 'cleaned') {
        await tx.query("UPDATE litter_reports SET status='collected' WHERE id=$1", [claim.report_id]);
        statuses.set(claim.report_id, 'collected');
      } else {
        await tx.query('UPDATE litter_reports SET last_seen_at=now() WHERE id=$1', [claim.report_id]);
      }
    } else if (claim.eligible && !reused && status === 'collected') {
      verification = 'already_collected';
    }
    const resolved = verification === 'verified' && claim.outcome === 'cleaned';
    await tx.query('UPDATE spot_observations SET verification=$2,resolved=$3,reward_sha256=$4 WHERE id=$1',
      [claim.id, verification, resolved, resolved ? claim.sha256 : null]);
  }
}
