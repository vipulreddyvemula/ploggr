import { materials } from './litter-classification';

export const defaultRewardRules = {
  version: 'm3-v1',
  material_points: Object.fromEntries(materials.filter((m) => m !== 'Unknown').map((m) => [m, 1])),
  carbon_points_per_kg: 2,
};
export const rewardLimits = { carbonPoints: 10, plogPoints: 100 };

// The caller scopes the `activities` CTE before reading evidence or expanding results.
export const cleanupRewards = `
  evidence AS (
    SELECT a.id, e.id AS photo_id,
      EXISTS (
        SELECT 1 FROM spot_observations o
        JOIN garbage_evidence claim ON claim.id=o.photo_id AND claim.plog_id=a.id
        WHERE o.plog_id=a.id AND o.outcome='cleaned' AND o.verification='verified'
          AND o.resolved AND o.reward_sha256=e.sha256
      ) AS verified,
      (
        EXISTS (SELECT 1 FROM litter_report_photos f WHERE f.sha256=e.sha256)
        OR EXISTS (
          SELECT 1 FROM spot_observations o
          JOIN garbage_evidence claim ON claim.id=o.photo_id AND claim.plog_id=a.id
          WHERE o.plog_id=a.id AND o.outcome='cleaned' AND o.verification<>'verified' AND claim.sha256=e.sha256
        )
        OR EXISTS (
          SELECT 1 FROM garbage_evidence prior JOIN plogs p ON p.id=prior.plog_id
          WHERE p.id<>a.id AND p.status='completed' AND prior.uploaded_at IS NOT NULL
            AND (coalesce(p.completed_at,p.ended_at),p.id)<(a.accepted_at,a.id)
            AND (prior.sha256=e.sha256 OR (
              left(prior.perceptual_hash,4)=left(e.perceptual_hash,4)
              AND bit_count(('x'||prior.perceptual_hash)::bit(64) # ('x'||e.perceptual_hash)::bit(64)) <= 4
            ))
        )
      ) AS excluded
    FROM activities a JOIN garbage_evidence e ON e.plog_id=a.id AND e.uploaded_at IS NOT NULL
  ), eligible_items AS (
    SELECT a.id, item
    FROM activities a CROSS JOIN LATERAL jsonb_array_elements(a.result->'items') item
    CROSS JOIN LATERAL (
      SELECT bool_or(e.verified) AS verified, bool_and(e.photo_id IS NOT NULL AND NOT e.excluded) AS valid
      FROM jsonb_array_elements_text(item->'photoIds') AS view(photo)
      LEFT JOIN evidence e ON e.id=a.id AND e.photo_id=view.photo::uuid
    ) support
    WHERE support.verified AND support.valid AND item->>'certain'='true'
      AND item->>'count' IS NOT NULL AND item->>'material'<>'Unknown'
  ), points AS (
    SELECT a.id, a.user_id, a.state,
      EXISTS(SELECT 1 FROM evidence e WHERE e.id=a.id AND e.verified AND NOT e.excluded) AS verified,
      round(least(${rewardLimits.plogPoints},
        coalesce(sum((item->>'count')::int * coalesce(($3::jsonb->>(item->>'material'))::numeric,0)),0)
        + least(${rewardLimits.carbonPoints},coalesce(sum(greatest((item->'potentialImpact'->>'avoidedKg')::numeric,0)),0)*$4::numeric)
      ),2)::float8 AS score
    FROM activities a LEFT JOIN eligible_items i ON i.id=a.id
    GROUP BY a.id,a.user_id,a.state
  )
`;
