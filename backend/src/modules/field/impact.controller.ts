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
import { activityFields, cleanupRewards, receiptBreakdown, rewardLimits } from './cleanup-rewards';
import { GamificationService, officialChallenges } from './gamification';
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
    private readonly gamification: GamificationService,
  ) {}
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
    const [data] = await this.db.query(`WITH activities AS (
      SELECT ${activityFields} FROM plogs p WHERE p.user_id=$1 AND p.status='completed'
        AND p.ended_at >= (SELECT date_trunc('week',ended_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
          FROM plogs WHERE id=$2 AND user_id=$1)
        AND p.ended_at <= (SELECT ended_at FROM plogs WHERE id=$2 AND user_id=$1)
    ), ${cleanupRewards}, ${officialChallenges}
    SELECT job.state,job.result,job.model,job.reviewed,job.suspicious_evidence AS "suspiciousEvidence",
      job.review_note IS NOT NULL AS reported,l.score::float8,l.eligible,l.reward_status AS "rewardStatus",
      l.reward_policy AS policy,l.challenge_points::int AS "challengePoints",
      coalesce((SELECT jsonb_agg(jsonb_build_object('title',title,'points',bonus) ORDER BY kind)
        FROM challenge_awards c WHERE c.id=l.id),'[]') AS "challengeAwards",
      ${receiptBreakdown} AS breakdown,saved.updated_at AS "receiptUpdatedAt",
      CASE WHEN l.eligible THEN jsonb_build_object('estimatedKg',l.estimated_weight,'reviewedKg',l.reviewed_weight,'measuredKg',l.measured_weight,
        'potentialCo2eKg',l.potential_savings,'weightMaterials',l.weight_materials,'materials',l.materials)
      END AS impact,
      CASE WHEN job.state='queued' AND job.attempts>0 THEN job.next_run END AS "retryAt",
      coalesce((SELECT jsonb_agg(k ORDER BY k.material) FROM (${carbon} WHERE d.plog_id=l.id) k),'[]') AS impacts
    FROM scored l JOIN plog_analysis job ON job.plog_id=l.id
    LEFT JOIN plog_reward_receipts saved ON saved.plog_id=l.id WHERE l.id=$2`, [req.user.id,id]);
    if (!data) throw new NotFoundException();
    const { score, eligible, breakdown, policy, rewardStatus, ...analysis } = data;
    const { state, reviewed } = analysis;
    const pending = rewardStatus === 'pending';
    return {
      ...analysis,
      configured: Boolean(this.config.get<string>('GEMINI_API_KEY')),
      canUpdate: state === 'ready' && !reviewed && analysis.result?.version !== analysisVersion,
      reward: {
        status: rewardStatus,
        earnedPoints: score,
        pendingPoints: pending && breakdown.items > 0 ? Math.round((breakdown.items+breakdown.impact)*100)/100 : null,
        breakdown: eligible ? breakdown : null,
        rules: { ...policy, ...rewardLimits },
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
    return this.gamification.leaderboard(req.user.id,period);
  }
}
