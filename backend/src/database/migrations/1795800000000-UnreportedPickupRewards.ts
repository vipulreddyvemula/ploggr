import type { MigrationInterface, QueryRunner } from 'typeorm';
import { savePlogRewardReceiptSql } from './plog-reward-receipt';

export class UnreportedPickupRewards1795800000000 implements MigrationInterface {
  async up(db: QueryRunner) {
    await db.query(savePlogRewardReceiptSql(true));
    await this.refreshCameraReceipts(db);
  }

  async down(db: QueryRunner) {
    await db.query(savePlogRewardReceiptSql(false));
    await this.refreshCameraReceipts(db);
  }

  private async refreshCameraReceipts(db: QueryRunner) {
    await db.query(`
      SELECT save_plog_reward_receipt(p.id)
      FROM plogs p JOIN plog_analysis a ON a.plog_id=p.id
      WHERE p.status='completed' AND EXISTS (
        SELECT 1 FROM garbage_evidence e WHERE e.plog_id=p.id
          AND e.uploaded_at IS NOT NULL AND e.capture->>'source'='camera'
      )
    `);
  }
}
