import {
  BadRequestException,
  Body,
  Controller,
  Get,
  NotFoundException,
  Param,
  ParseUUIDPipe,
  Post,
  Put,
  Query,
  Req,
  UseGuards,
} from '@nestjs/common';
import { IsIn, IsNumber, IsString, Length, Max, Min } from 'class-validator';
import { DataSource } from 'typeorm';
import { AuthGuard, type AuthenticatedRequest } from '../auth/auth.guard';
import { materials } from './analysis.service';

class DisposalInput {
  @IsIn(materials) material!: string;
  @IsNumber() @Min(0.001) @Max(10000) massKg!: number;
  @IsString() @Length(1, 80) region!: string;
  @IsString() @Length(1, 80) baseline!: string;
  @IsString() @Length(1, 80) actual!: string;
  @IsString() @Length(1, 80) version!: string;
}
const carbon = `SELECT d.material,d.mass_kg AS "massKg",d.region,d.baseline,d.actual,d.factor_version AS version,
  d.mass_kg*(b.factor-a.factor) AS "avoidedKg",b.source AS "baselineSource",a.source AS "actualSource",d.plog_id
  FROM plog_disposal d JOIN disposal_factors b ON (d.region,d.material,d.baseline,d.factor_version)=(b.region,b.material,b.pathway,b.version)
  JOIN disposal_factors a ON (d.region,d.material,d.actual,d.factor_version)=(a.region,a.material,a.pathway,a.version)`;

@Controller()
@UseGuards(AuthGuard)
export class ImpactController {
  constructor(private readonly db: DataSource) {}
  private async owned(owner: string, id: string) {
    const [row] = await this.db.query(
      `SELECT a.state,a.result,a.model,a.reviewed,a.suspicious_evidence AS "suspiciousEvidence" FROM plog_analysis a JOIN plogs p ON p.id=a.plog_id
      WHERE p.user_id=$1 AND p.id=$2`,
      [owner, id],
    );
    if (!row) throw new NotFoundException();
    return row;
  }
  @Get('plogs/:id/analysis')
  async analysis(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string) {
    const data = await this.owned(req.user.id, id);
    const impacts = await this.db.query(carbon + ' WHERE d.plog_id=$1', [id]);
    return { ...data, impacts };
  }
  @Post('plogs/:id/analysis/retry')
  async retry(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string) {
    await this.owned(req.user.id, id);
    await this.db.query(
      "UPDATE plog_analysis SET state='queued',attempts=0,next_run=now() WHERE plog_id=$1 AND state='failed'",
      [id],
    );
  }
  @Post('plogs/:id/analysis/review')
  async review(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string) {
    await this.owned(req.user.id, id);
    await this.db.query(
      "UPDATE plog_analysis SET state='review',reviewed=false WHERE plog_id=$1 AND state='ready'",
      [id],
    );
  }
  @Get('impact/factors')
  factors() {
    return this.db.query(
      'SELECT region,material,pathway,version,source FROM disposal_factors ORDER BY region,material,pathway',
    );
  }
  @Put('plogs/:id/disposal')
  async disposal(
    @Req() req: AuthenticatedRequest,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() input: DisposalInput,
  ) {
    const row = await this.owned(req.user.id, id);
    if (!row.result?.items.some((i: { material: string }) => i.material === input.material))
      throw new BadRequestException('Choose a detected material');
    const { material, region, baseline, actual, version, massKg } = input;
    const factors = await this.db.query(
      'SELECT pathway FROM disposal_factors WHERE material=$1 AND region=$2 AND version=$3 AND pathway=ANY($4)',
      [material, region, version, [baseline, actual]],
    );
    if (factors.length !== new Set([baseline, actual]).size)
      throw new BadRequestException('Unsupported pathways');
    await this.db.query(
      `INSERT INTO plog_disposal VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(plog_id,material)
      DO UPDATE SET region=excluded.region,mass_kg=excluded.mass_kg,baseline=excluded.baseline,actual=excluded.actual,factor_version=excluded.factor_version`,
      [id, material, region, massKg, baseline, actual, version],
    );
    return this.analysis(req, id);
  }
  @Get('leaderboard')
  async leaderboard(@Req() req: AuthenticatedRequest, @Query('period') period = 'week') {
    if (!['week', 'month', 'all'].includes(period)) throw new BadRequestException('Invalid period');
    const [rules] = await this.db.query(
      'SELECT version,material_points,carbon_points_per_kg FROM impact_rules WHERE active',
    );
    const [pending] = await this.db.query(
      "SELECT count(*)::int AS n FROM plog_analysis a JOIN plogs p ON p.id=a.plog_id WHERE p.user_id=$1 AND a.state<>'ready' AND ($2='all' OR p.ended_at >= (date_trunc(CASE WHEN $2='month' THEN 'month' ELSE 'week' END,now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'))",
      [req.user.id, period],
    );
    if (!rules) return { items: [], mine: null, pending: pending.n, rules: null };
    const ranked = await this.db.query(
      `WITH qualifying AS (
      SELECT p.id,p.user_id,coalesce(p.completed_at,p.ended_at) AS accepted_at,a.result FROM plogs p JOIN plog_analysis a ON a.plog_id=p.id WHERE a.state='ready' AND
      ($2='all' OR p.ended_at >= (date_trunc(CASE WHEN $2='month' THEN 'month' ELSE 'week' END, now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'))
    ), detections AS (
      SELECT q.id,q.user_id,obj->>'material' AS material,(obj->>'count')::int AS quantity,
        NOT EXISTS (
          SELECT 1 FROM jsonb_array_elements_text(obj->'photoIds') AS view(photo)
          JOIN garbage_evidence e ON e.id=view.photo::uuid
          WHERE EXISTS (SELECT 1 FROM garbage_evidence prior JOIN plogs p ON p.id=prior.plog_id
            WHERE prior.sha256=e.sha256 AND prior.plog_id<>q.id AND p.status='completed'
            AND (coalesce(p.completed_at,p.ended_at),p.id)<(q.accepted_at,q.id))
          OR EXISTS (SELECT 1 FROM spot_observations o WHERE o.photo_id=e.id AND o.outcome='cleaned' AND NOT o.resolved)
        ) AS eligible
      FROM qualifying q CROSS JOIN LATERAL jsonb_array_elements(q.result->'items') obj
    ), credit AS (
      SELECT id,user_id,material,sum(quantity) FILTER (WHERE eligible) AS quantity,bool_and(eligible) AS whole_material
      FROM detections GROUP BY id,user_id,material HAVING bool_or(eligible)
    ), totals AS (
      SELECT c.user_id,round(sum(c.quantity*coalesce(($3::jsonb->>c.material)::numeric,0) +
        CASE WHEN whole_material THEN coalesce(k."avoidedKg",0)*$4::numeric ELSE 0 END)::numeric,2)::float8 AS score
      FROM credit c LEFT JOIN (${carbon}) k ON k.plog_id=c.id AND k.material=c.material GROUP BY c.user_id
    ), ranks AS (SELECT t.*,rank() OVER (ORDER BY score DESC)::int AS rank FROM totals t)
    SELECT r.rank,r.score,coalesce(nullif(u.display_name,''),'Plogger '||left(u.id::text,6)) AS name,u.id=$1 AS mine
    FROM ranks r JOIN users u ON u.id=r.user_id WHERE r.rank<=100 OR u.id=$1 ORDER BY r.rank,u.id`,
      [req.user.id, period, JSON.stringify(rules.material_points), rules.carbon_points_per_kg],
    );
    return {
      items: ranked.slice(0, 100),
      mine: ranked.find((r: { mine: boolean }) => r.mine) ?? null,
      pending: pending.n,
      rules,
    };
  }
}
