export const rewardLimits = { carbonPoints: 10, movementPoints: 5, plogPoints: 100 };

export const activityFields = `p.id,p.user_id,p.started_at,p.ended_at,p.distance_meters,p.duration_seconds,
  p.segment_starts,coalesce(p.completed_at,p.ended_at) AS accepted_at`;

// Scopes supply completed Plogs, including user id, ending time and acceptance time.
export function cleanupRewardsFor(allowUnreported: boolean) {
  return `
  pickup_photos AS (
    SELECT a.id, e.id AS photo_id, e.sha256, e.perceptual_hash, e.created_at,
      ${allowUnreported ? `EXISTS (
        SELECT 1 FROM garbage_evidence camera WHERE camera.plog_id=a.id AND camera.sha256=e.sha256
          AND camera.uploaded_at IS NOT NULL AND camera.capture->>'source'='camera'
          AND (camera.capture->>'capturedAt')::timestamptz BETWEEN
            a.started_at-interval '2 seconds' AND a.ended_at+interval '1 second'
          AND (camera.capture->>'capturedAt')::timestamptz <= camera.uploaded_at+interval '5 seconds'
      ) AND NOT EXISTS (
        SELECT 1 FROM spot_observations o JOIN garbage_evidence claimed ON claimed.id=o.photo_id
        WHERE o.plog_id=a.id AND o.outcome='cleaned'
          AND images_match(claimed.sha256,claimed.perceptual_hash,e.sha256,e.perceptual_hash)
      )` : 'false'} AS unreported,
      ARRAY(SELECT o.report_id FROM spot_observations o
        JOIN garbage_evidence photo ON photo.id=o.photo_id AND photo.plog_id=a.id
        JOIN litter_reports r ON r.id=o.report_id AND r.collection_plog_id IS NULL
        WHERE o.plog_id=a.id AND o.user_id=a.user_id AND o.outcome='cleaned'
          AND o.verification='verified' AND o.resolved AND o.reward_sha256=e.sha256
          AND photo.sha256=e.sha256 AND r.status IN ('collected','withdrawn')
        ORDER BY o.report_id) AS spots,
      (
        EXISTS (SELECT 1 FROM litter_report_photos f WHERE f.published_at <= a.accepted_at
          AND images_match(f.sha256,f.perceptual_hash,e.sha256,e.perceptual_hash))
        OR EXISTS (
          SELECT 1 FROM spot_observations o JOIN garbage_evidence photo ON photo.id=o.photo_id
          WHERE o.plog_id=a.id AND o.outcome='cleaned' AND o.verification<>'verified'
            AND photo.sha256=e.sha256
        )
        OR EXISTS (
          SELECT 1 FROM garbage_evidence prior JOIN plogs p ON p.id=prior.plog_id
          WHERE p.id<>a.id AND p.status='completed' AND prior.uploaded_at IS NOT NULL
            AND (coalesce(p.completed_at,p.ended_at),p.id)<(a.accepted_at,a.id)
            AND images_match(prior.sha256,prior.perceptual_hash,e.sha256,e.perceptual_hash)
        )
      ) AS reused
    FROM activities a JOIN garbage_evidence e ON e.plog_id=a.id AND e.uploaded_at IS NOT NULL
    WHERE EXISTS (SELECT 1 FROM spot_observations o WHERE o.plog_id=a.id
      AND o.outcome='cleaned' AND o.verification='verified' AND o.resolved)
      ${allowUnreported ? `OR EXISTS (SELECT 1 FROM garbage_evidence camera
        WHERE camera.plog_id=a.id AND camera.uploaded_at IS NOT NULL AND camera.capture->>'source'='camera')` : ''}
  ), evidence AS (
    SELECT e.*, NOT reused AND NOT EXISTS (
      SELECT 1 FROM pickup_photos prior WHERE prior.id=e.id AND NOT prior.reused
        AND prior.sha256<>e.sha256
        AND (cardinality(prior.spots)=0,NOT prior.unreported,prior.created_at,prior.photo_id)
          < (cardinality(e.spots)=0,NOT e.unreported,e.created_at,e.photo_id)
        AND images_match(prior.sha256,prior.perceptual_hash,e.sha256,e.perceptual_hash)
    ) AS eligible
    FROM pickup_photos e
  ), eligible_items AS (
    SELECT a.id, item, support.spots, (item->>'count')::int AS count,
      item->>'material' AS material,
      (item->'weight'->>'estimateKg')::numeric AS estimated_weight,
      item->>'weightReviewed'='true' AS weight_reviewed,
      (item->'potentialImpact'->>'avoidedKg')::numeric AS ai_impact
    FROM activities a JOIN plog_analysis job ON job.plog_id=a.id
    CROSS JOIN LATERAL jsonb_array_elements(job.result->'items') item
    CROSS JOIN LATERAL (
      SELECT array_agg(DISTINCT spot) FILTER (WHERE spot IS NOT NULL) AS spots,
        bool_and(coalesce(e.eligible,false)) AS valid,
        bool_or(cardinality(e.spots)>0) AS linked,
        bool_and(coalesce(e.unreported,false)) AS camera_only
      FROM jsonb_array_elements_text(item->'photoIds') AS view(photo)
      LEFT JOIN evidence e ON e.id=a.id AND e.photo_id::text=view.photo
      LEFT JOIN LATERAL unnest(e.spots) spot ON true
    ) support
    WHERE support.valid AND (support.linked OR support.camera_only) AND item->>'certain'='true'
      AND (item->>'count')::int BETWEEN 1 AND 1000 AND item->>'material'<>'Unknown'
  ), item_totals AS (
    SELECT i.id, sum(i.count)::int AS items,
      sum(i.count * coalesce((job.reward_policy->'material_points'->>i.material)::numeric,0)) AS item_points,
      sum(greatest(i.ai_impact,0)) AS modeled_savings
    FROM eligible_items i JOIN plog_analysis job ON job.plog_id=i.id GROUP BY i.id
  ), eligible_spots AS (
    SELECT id, array_agg(DISTINCT spot ORDER BY spot) AS spots
    FROM eligible_items CROSS JOIN LATERAL unnest(spots) spot GROUP BY id
  ), impact_material AS (
    SELECT id,material,sum(estimated_weight) FILTER (WHERE weight_reviewed IS DISTINCT FROM true) AS ai_weight,
      sum(estimated_weight) FILTER (WHERE weight_reviewed) AS reviewed_weight,sum(ai_impact) AS ai_impact
    FROM eligible_items GROUP BY id,material
  ), impact_totals AS (
    SELECT i.id, sum(i.ai_weight) FILTER (WHERE d.mass_kg IS NULL) AS estimated_weight,
      sum(i.reviewed_weight) FILTER (WHERE d.mass_kg IS NULL) AS reviewed_weight,
      sum(d.mass_kg) AS measured_weight, sum(coalesce(
        CASE WHEN d.mass_kg IS NOT NULL THEN (d.mass_kg*(b.factor-f.factor))::numeric END,i.ai_impact
      )) AS potential_savings,
      count(*) FILTER (WHERE i.ai_weight IS NOT NULL OR i.reviewed_weight IS NOT NULL OR d.mass_kg IS NOT NULL)::int AS weight_materials,
      count(*)::int AS materials
    FROM impact_material i LEFT JOIN plog_disposal d ON d.plog_id=i.id AND d.material=i.material
    LEFT JOIN disposal_factors b ON (d.region,d.material,d.baseline,d.factor_version)=(b.region,b.material,b.pathway,b.version)
    LEFT JOIN disposal_factors f ON (d.region,d.material,d.actual,d.factor_version)=(f.region,f.material,f.pathway,f.version)
    GROUP BY i.id
  ), progress_inputs AS (
    SELECT a.*, job.approved_at, job.reward_policy, job.state, job.reviewed,
      coalesce(t.items,0) AS item_count, coalesce(s.spots,'{}'::uuid[]) AS spots, impacts.estimated_weight, impacts.reviewed_weight, impacts.measured_weight,
      impacts.potential_savings, impacts.weight_materials, impacts.materials,
      coalesce(job.state='ready' AND (job.reviewed OR NOT job.suspicious_evidence) AND t.items>0,false) AS eligible,
      EXISTS(SELECT 1 FROM evidence e WHERE e.id=a.id AND e.eligible AND (e.unreported OR cardinality(e.spots)>0)) AS verified,
      least(${rewardLimits.plogPoints},coalesce(t.item_points,0)) AS item_points,
      least(${rewardLimits.carbonPoints},coalesce(t.modeled_savings *
        (job.reward_policy->>'carbon_points_per_kg')::numeric,0)) AS carbon_bonus
    FROM activities a LEFT JOIN plog_analysis job ON job.plog_id=a.id LEFT JOIN item_totals t ON t.id=a.id
    LEFT JOIN eligible_spots s ON s.id=a.id LEFT JOIN impact_totals impacts ON impacts.id=a.id
  ), receipts AS (
    SELECT a.*, movement.meters AS effort_meters, movement.seconds AS effort_seconds, parts.impact_points,
      least(${rewardLimits.movementPoints},a.item_points,
        ${rewardLimits.plogPoints}-a.item_points-parts.impact_points,
        coalesce(floor(movement.meters/1000)+floor(movement.seconds/1200),0)) AS movement_points
    FROM progress_inputs a
    CROSS JOIN LATERAL (SELECT least(${rewardLimits.plogPoints}-a.item_points,a.carbon_bonus) AS impact_points) parts
    LEFT JOIN LATERAL (
      SELECT sum(meters)::numeric AS meters,CASE WHEN count(*)>0 THEN least(a.duration_seconds,sum(seconds)) END::numeric AS seconds
      FROM (
        SELECT ST_Distance(location,previous,false) AS meters,
          extract(epoch FROM recorded_at-prior_time) AS seconds,
          greatest(5,least(20,(accuracy_meters+prior_accuracy)/2)) AS uncertainty,
          accuracy_meters,prior_accuracy
        FROM (
          SELECT seq.*, lag(location) OVER route AS previous, lag(recorded_at) OVER route AS prior_time,
            lag(accuracy_meters) OVER route AS prior_accuracy
          FROM plog_route_points seq WHERE seq.plog_id=a.id WINDOW route AS (ORDER BY sequence)
        ) fixes
        WHERE NOT (sequence=ANY(a.segment_starts))
          AND prior_time>=a.started_at-interval '2 seconds' AND recorded_at<=a.ended_at+interval '1 second'
      ) segments WHERE seconds>0 AND seconds<=30 AND accuracy_meters BETWEEN 0.1 AND 40 AND prior_accuracy BETWEEN 0.1 AND 40
        AND meters>=uncertainty AND meters<=7*seconds+uncertainty
    ) movement ON a.eligible
  ), ledger AS (
    SELECT r.*,
      CASE WHEN eligible THEN greatest(1,cardinality(spots)) ELSE 0 END AS cleanup_count,
      CASE WHEN eligible THEN round(item_points+impact_points+movement_points,2) ELSE 0 END AS score,
      CASE WHEN eligible THEN 'earned'
        WHEN verified AND state IN ('queued','processing','review','failed') THEN 'pending'
        WHEN verified AND state='ready' AND reviewed THEN 'rejected'
        ELSE 'ineligible' END AS reward_status
    FROM receipts r
  )
`;
}

export const cleanupRewards = cleanupRewardsFor(true);

export const receiptBreakdown = `jsonb_build_object(
  'items',l.item_points,'impact',l.impact_points,'movement',l.movement_points,
  'distanceMeters',l.effort_meters,'movingSeconds',l.effort_seconds,
  'spots',cardinality(l.spots),'verifiedCleanups',l.cleanup_count,'acceptedItems',l.item_count,'reportIds',l.spots,
  'photoIds',ARRAY(SELECT DISTINCT photo FROM eligible_items i
    CROSS JOIN LATERAL jsonb_array_elements_text(i.item->'photoIds') photo WHERE i.id=l.id ORDER BY photo)
)`;
