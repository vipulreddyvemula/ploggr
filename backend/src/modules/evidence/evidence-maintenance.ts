import { Injectable, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { DataSource } from 'typeorm';
import { endIncompletePlog } from '../plogs/plogs.service';
import { EvidenceStorage } from './evidence-storage';

@Injectable()
export class EvidenceMaintenance implements OnModuleInit, OnModuleDestroy {
  private timer?: ReturnType<typeof setInterval>;
  private working = false;

  constructor(private readonly db: DataSource, private readonly storage: EvidenceStorage) {}

  onModuleInit() {
    this.timer = setInterval(() => void this.sweep().catch(() => undefined), 60000);
    this.timer.unref();
  }

  onModuleDestroy() {
    clearInterval(this.timer);
  }

  async sweep() {
    if (this.working) return;
    this.working = true;
    try {
      await this.db.transaction(async tx => {
        const abandoned: { id: string }[] = await tx.query(`
          SELECT id FROM plogs WHERE status='active' AND started_at < now() - interval '7 days'
          ORDER BY started_at LIMIT 20 FOR UPDATE SKIP LOCKED
        `);
        for (const { id } of abandoned) await endIncompletePlog(tx, id, 'abandoned');
        await tx.query(`
          WITH stale AS MATERIALIZED (
            SELECT id,queue_report_photo_deletion(id)
            FROM litter_reports WHERE collection_plog_id IS NULL AND status='uploading'
              AND created_at < now() - interval '2 days'
            ORDER BY created_at LIMIT 20 FOR UPDATE SKIP LOCKED
          )
          DELETE FROM litter_reports r USING stale WHERE r.id=stale.id
        `);
        await tx.query(`
          WITH stale AS (
            SELECT e.id FROM garbage_evidence e JOIN plogs p ON p.id=e.plog_id
            WHERE e.uploaded_at IS NULL AND e.created_at < now() - interval '2 days'
              AND p.status='active'
            ORDER BY e.created_at LIMIT 20 FOR UPDATE OF p SKIP LOCKED
          ), removed AS (
            DELETE FROM garbage_evidence e USING stale WHERE e.id=stale.id
            RETURNING e.storage_key
          )
          INSERT INTO evidence_deletion_queue(storage_key) SELECT storage_key FROM removed ON CONFLICT DO NOTHING
        `);
      });
      for (let i = 0; i < 20; i++) {
        const found = await this.db.transaction(async tx => {
          const [item] = await tx.query(`
            SELECT storage_key FROM evidence_deletion_queue WHERE next_attempt <= now()
            ORDER BY next_attempt,storage_key LIMIT 1 FOR UPDATE SKIP LOCKED
          `);
          if (!item) return false;
          try {
            await this.storage.delete(item.storage_key);
            await tx.query('DELETE FROM evidence_deletion_queue WHERE storage_key=$1', [item.storage_key]);
          } catch {
            await tx.query("UPDATE evidence_deletion_queue SET next_attempt=now()+interval '5 minutes' WHERE storage_key=$1",
              [item.storage_key]);
          }
          return true;
        });
        if (!found) break;
      }
    } finally {
      this.working = false;
    }
  }
}
