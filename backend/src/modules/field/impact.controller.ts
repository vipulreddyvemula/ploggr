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
import { ConfigService } from '@nestjs/config';
import { IsIn, IsNumber, IsOptional, IsString, Length, Max, MaxLength, Min } from 'class-validator';
import { DataSource } from 'typeorm';
import { AuthGuard, type AuthenticatedRequest } from '../auth/auth.guard';
import { analysisVersion } from './analysis.service';
import { cleanupRewards, defaultRewardRules, rewardLimits } from './cleanup-rewards';
import { litterTypes, materials } from './litter-classification';

class AnalysisReport {
  @IsOptional() @IsString() @MaxLength(500) note?: string;
}

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
  constructor(
    private readonly db: DataSource,
    private readonly config: ConfigService,
  ) {}
  private async rules() {
    const [rules] = await this.db.query(
      'SELECT version,material_points,carbon_points_per_kg FROM impact_rules WHERE active',
    );
    return rules ?? defaultRewardRules;
  }
  private async owned(owner: string, id: string) {
    const [row] = await this.db.query(
      `SELECT a.result FROM plog_analysis a JOIN plogs p ON p.id=a.plog_id
      WHERE p.user_id=$1 AND p.id=$2`,
      [owner, id],
    );
    if (!row) throw new NotFoundException();
    return row;
  }
  @Get('plogs/:id/analysis')
  async analysis(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string) {
    const rules = await this.rules();
    const [data] = await this.db.query(`WITH activities AS (
      SELECT p.id,p.user_id,coalesce(p.completed_at,p.ended_at) AS accepted_at,
        a.state,a.result,a.model,a.reviewed,a.suspicious_evidence,a.review_note,a.attempts,a.next_run
      FROM plogs p JOIN plog_analysis a ON a.plog_id=p.id WHERE p.id=$2 AND p.user_id=$1
      AND p.status='completed'
    ), ${cleanupRewards}
    SELECT activity.state,activity.result,activity.model,activity.reviewed,
      activity.suspicious_evidence AS "suspiciousEvidence",activity.review_note IS NOT NULL AS reported,points.score,points.verified,
      CASE WHEN activity.state='queued' AND activity.attempts>0 THEN activity.next_run END AS "retryAt",
      coalesce((SELECT jsonb_agg(k ORDER BY k.material) FROM (${carbon} WHERE d.plog_id=activity.id) k),'[]') AS impacts
    FROM activities activity JOIN points ON points.id=activity.id`,
    [req.user.id, id, JSON.stringify(rules.material_points), rules.carbon_points_per_kg]);
    if (!data) throw new NotFoundException();
    const { score, verified, ...analysis } = data;
    const { state, reviewed, suspiciousEvidence } = analysis;
    const awards = state === 'ready' && score > 0 && (!suspiciousEvidence || reviewed);
    const pending = verified && ['queued', 'processing', 'review', 'failed'].includes(state);
    return {
      ...analysis,
      configured: Boolean(this.config.get<string>('GEMINI_API_KEY')),
      canUpdate: state === 'ready' && !reviewed && analysis.result?.version !== analysisVersion,
      reward: {
        status: awards ? 'earned' : pending ? 'pending' : 'ineligible',
        earnedPoints: awards ? score : 0,
        pendingPoints: pending && score > 0 ? score : null,
      },
    };
  }
  @Post('plogs/:id/analysis/retry')
  async retry(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string) {
    await this.owned(req.user.id, id);
    await this.db.query(
      `UPDATE plog_analysis SET state='queued',attempts=0,next_run=now(),result=NULL,model=NULL
      WHERE plog_id=$1 AND (state='failed' OR (state='ready' AND NOT reviewed
        AND result->>'version' IS DISTINCT FROM $2))`,
      [id, String(analysisVersion)],
    );
  }
  @Post('plogs/:id/analysis/review')
  async review(
    @Req() req: AuthenticatedRequest,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() input: AnalysisReport,
  ) {
    await this.owned(req.user.id, id);
    await this.db.query(
      `UPDATE plog_analysis SET state='review',reviewed=false,review_note=$2,next_run=now()
      WHERE plog_id=$1 AND state IN ('ready','review') AND review_note IS NULL`,
      [id, input?.note?.trim() || 'The Plog owner reported an incorrect prediction.'],
    );
  }
  @Get('impact/classification')
  classification() {
    return { materials, types: litterTypes };
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
    if (!row.result?.items?.some((i: { material: string }) => i.material === input.material))
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
    const rules = await this.rules();
    const cutoff = `($2='all' OR p.ended_at >=
      (date_trunc(CASE WHEN $2='month' THEN 'month' ELSE 'week' END,now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'))`;
    const [[pending], ranked] = await Promise.all([
      this.db.query(`SELECT count(*)::int AS n FROM plog_analysis a JOIN plogs p ON p.id=a.plog_id
        WHERE p.user_id=$1 AND ${cutoff} AND a.state IN ('queued','processing','review') AND EXISTS (
            SELECT 1 FROM spot_observations o WHERE o.plog_id=p.id AND o.verification='verified'
              AND o.outcome='cleaned' AND o.resolved)`, [req.user.id, period]),
      this.db.query(`WITH activities AS (
        SELECT p.id,p.user_id,coalesce(p.completed_at,p.ended_at) AS accepted_at,a.result,a.state
        FROM plogs p JOIN plog_analysis a ON a.plog_id=p.id
        WHERE p.status='completed' AND a.state='ready' AND (NOT a.suspicious_evidence OR a.reviewed) AND ${cutoff}
      ), ${cleanupRewards}, totals AS (
        SELECT user_id,round(sum(score)::numeric,2)::float8 AS score FROM points WHERE score>0 GROUP BY user_id
      ), ranks AS (
        SELECT t.*,rank() OVER (ORDER BY score DESC)::int AS rank FROM totals t
      )
      SELECT r.rank,r.score,coalesce(nullif(u.display_name,''),'Plogger '||left(u.id::text,6)) AS name,u.id=$1 AS mine
      FROM ranks r JOIN users u ON u.id=r.user_id WHERE r.rank<=100 OR u.id=$1 ORDER BY r.rank,u.id`,
      [req.user.id, period, JSON.stringify(rules.material_points), rules.carbon_points_per_kg]),
    ]);
    return {
      items: ranked.filter((r: { rank: number }) => r.rank <= 100).slice(0, 100),
      mine: ranked.find((r: { mine: boolean }) => r.mine) ?? null,
      pending: pending.n,
      rules: { ...rules, ...rewardLimits },
    };
  }
}
