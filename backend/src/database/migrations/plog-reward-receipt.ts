import { activityFields, cleanupRewardsFor, receiptBreakdown } from '../../modules/field/cleanup-rewards';

export function savePlogRewardReceiptSql(allowUnreported: boolean) {
  return `
      CREATE OR REPLACE FUNCTION save_plog_reward_receipt(target uuid) RETURNS void LANGUAGE sql AS $$
        WITH activities AS (
          SELECT ${activityFields} FROM plogs p WHERE p.id=target AND p.status='completed'
        ), ${cleanupRewardsFor(allowUnreported)}
        INSERT INTO plog_reward_receipts(plog_id,policy,state,points,evidence_and_components)
        SELECT l.id,l.reward_policy,l.reward_status,l.score,
          CASE WHEN l.eligible THEN ${receiptBreakdown} END
        FROM ledger l WHERE l.reward_policy IS NOT NULL
        ON CONFLICT(plog_id) DO UPDATE SET
          state=excluded.state,points=excluded.points,
          evidence_and_components=excluded.evidence_and_components,updated_at=clock_timestamp()
        WHERE (plog_reward_receipts.state,plog_reward_receipts.points,plog_reward_receipts.evidence_and_components)
          IS DISTINCT FROM (excluded.state,excluded.points,excluded.evidence_and_components);
      $$;

  `;
}
