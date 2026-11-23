import { BadRequestException, Body, Controller, Get, Injectable, Put, Query, Req, UseGuards } from '@nestjs/common';
import { IsIn, IsInt, Max, Min } from 'class-validator';
import { DataSource } from 'typeorm';
import { AuthGuard, type AuthenticatedRequest } from '../auth/auth.guard';
import { activityFields, cleanupRewards, rewardLimits } from './cleanup-rewards';

const personalLedger = `WITH activities AS (
  SELECT ${activityFields} FROM plogs p WHERE p.status='completed' AND p.user_id=$1
), ${cleanupRewards}`;

export const officialChallenges = `
  challenge_definitions (kind,title,cadence,unit,goal,bonus) AS (VALUES
    ('daily-cleanup','Daily cleanup','day','verified cleanups',1,3),
    ('daily-collection','Daily collection','day','accepted items',5,2),
    ('weekly-consistency','Weekly consistency','week','active days',3,10)
  ), challenge_inputs AS (
    SELECT d.*,l.user_id,l.id,l.ended_at,l.approved_at,
      date_trunc(d.cadence,l.ended_at AT TIME ZONE 'UTC') AS period_start,
      CASE d.kind WHEN 'daily-cleanup' THEN l.cleanup_count
        WHEN 'daily-collection' THEN l.item_count ELSE 1 END AS amount,
      row_number() OVER (PARTITION BY d.kind,l.user_id,date_trunc('day',l.ended_at AT TIME ZONE 'UTC')
        ORDER BY l.ended_at,l.id) AS day_order
    FROM ledger l CROSS JOIN challenge_definitions d CROSS JOIN gamification_season s
    WHERE l.eligible AND l.ended_at>=s.starts_at AND l.ended_at<=now()
  ), challenge_steps AS (
    SELECT *, sum(amount) OVER challenge_window AS progress,
      max(approved_at) OVER challenge_window AS unlocked_at
    FROM challenge_inputs WHERE cadence='day' OR day_order=1
    WINDOW challenge_window AS (PARTITION BY kind,user_id,period_start ORDER BY ended_at,id ROWS UNBOUNDED PRECEDING)
  ), challenge_awards AS (
    SELECT * FROM challenge_steps WHERE progress>=goal AND progress-amount<goal
  ), scored AS (
    SELECT l.*,coalesce(b.points,0) AS challenge_points
    FROM ledger l LEFT JOIN (
      SELECT id,sum(bonus) AS points FROM challenge_awards GROUP BY id
    ) b ON b.id=l.id
  )
`;

const metrics = `jsonb_build_object(
  'completedPlogs',count(l.id),
  'verifiedCleanups',coalesce(sum(l.cleanup_count),0),
  'distanceMeters',coalesce(sum(l.distance_meters),0),
  'activeSeconds',coalesce(sum(l.duration_seconds),0),
  'items',coalesce(sum(l.item_count) FILTER (WHERE l.eligible),0),
  'estimatedKg',sum(l.estimated_weight) FILTER (WHERE l.eligible),
  'reviewedKg',sum(l.reviewed_weight) FILTER (WHERE l.eligible),
  'measuredKg',sum(l.measured_weight) FILTER (WHERE l.eligible),
  'potentialCo2eKg',sum(l.potential_savings) FILTER (WHERE l.eligible),
  'weightMaterials',coalesce(sum(l.weight_materials) FILTER (WHERE l.eligible),0),
  'materials',coalesce(sum(l.materials) FILTER (WHERE l.eligible),0),
  'cleanupPoints',coalesce(sum(l.score),0),
  'challengePoints',coalesce(sum(l.challenge_points),0),
  'points',coalesce(sum(l.score+l.challenge_points),0)
)`;

export const gamificationSummary = `${personalLedger}, ${officialChallenges}
  SELECT ${metrics} AS progress FROM scored l WHERE l.ended_at<=now()`;

const periodBounds = `
  clock AS (
    SELECT now() AT TIME ZONE 'UTC' AS instant,
      CASE WHEN $2='month' THEN 'month' ELSE 'week' END AS cadence,
      CASE WHEN $2='month' THEN interval '1 month' ELSE interval '1 week' END AS span
  ), bounds AS (
    SELECT instant,date_trunc(cadence,instant) AS start_at,span FROM clock
  )
`;

export function validatePeriod(period: string) {
  if (!['week','month','all'].includes(period)) throw new BadRequestException('Invalid period');
}

class GoalInput {
  @IsIn(['day','week']) cadence!: 'day' | 'week';
  @IsInt() @Min(1) @Max(100) target!: number;
}

@Injectable()
export class GamificationService {
  constructor(private readonly db: DataSource) {}

  async leaderboard(user: string, period: string) {
    validatePeriod(period);
    const [result] = await this.db.query(`WITH ${periodBounds}, activities AS (
      SELECT ${activityFields} FROM plogs p CROSS JOIN bounds
      WHERE p.status='completed' AND p.ended_at<=now()
        AND ($2='all' OR p.ended_at>=((start_at-interval '6 days') AT TIME ZONE 'UTC'))
    ), ${cleanupRewards}, ${officialChallenges}, totals AS (
      SELECT l.user_id, sum(l.score+l.challenge_points) AS score, ${metrics} AS impact
      FROM scored l CROSS JOIN bounds
      WHERE ($2='all' OR l.ended_at>=start_at AT TIME ZONE 'UTC')
      GROUP BY l.user_id HAVING sum(l.score+l.challenge_points)>0
    ), ranked AS (
      SELECT rank() OVER (ORDER BY score DESC)::int AS rank, score,
        CASE WHEN u.id=$1 THEN impact ELSE impact - ARRAY[
          'completedPlogs','verifiedCleanups','distanceMeters','activeSeconds','items','weightMaterials','materials'
        ] END AS impact,
        coalesce(nullif(u.display_name,''),'Plogger '||left(u.id::text,6)) AS name,
        u.id=$1 AS mine,u.id
      FROM totals t JOIN users u ON u.id=t.user_id
    ) SELECT current_cleanup_policy() AS policy,
      coalesce((SELECT jsonb_agg(to_jsonb(top)-'id' ORDER BY rank,id) FROM
        (SELECT * FROM ranked ORDER BY rank,id LIMIT 100) top),'[]') AS items,
      (SELECT to_jsonb(r)-'id' FROM ranked r WHERE mine) AS mine,
      (SELECT count(*)::int FROM scored l CROSS JOIN bounds WHERE user_id=$1 AND verified
        AND ($2='all' OR l.ended_at>=start_at AT TIME ZONE 'UTC')
        AND state IN ('queued','processing','review','failed')) AS pending`, [user,period]);
    const { policy, ...rankings } = result;
    return { ...rankings, rules: { ...policy, ...rewardLimits } };
  }

  async progress(user: string, period: string) {
    validatePeriod(period);
    const [row] = await this.db.query(`${personalLedger}, ${officialChallenges}, ${periodBounds},
      goal AS (
        SELECT g.*,date_trunc(g.cadence,now() AT TIME ZONE 'UTC') AS starts,
          CASE g.cadence WHEN 'week' THEN 7 ELSE 1 END AS days
        FROM (SELECT coalesce((SELECT cadence FROM cleanup_goals WHERE user_id=$1),'day') AS cadence,
                     (SELECT target FROM cleanup_goals WHERE user_id=$1) AS target) g
      ), active_periods AS (
        SELECT DISTINCT date_trunc(g.cadence,l.ended_at AT TIME ZONE 'UTC')::date AS day,g.days
        FROM ledger l CROSS JOIN goal g WHERE l.eligible AND l.ended_at<=now()
      ), islands AS (
        SELECT max(day) AS last_day,count(*)::int AS length FROM (
          SELECT day,day-(row_number() OVER (ORDER BY day)::int)*days AS group_start FROM active_periods
        ) d GROUP BY group_start
      ), series AS (
        SELECT bucket, step FROM bounds CROSS JOIN LATERAL (
          SELECT CASE WHEN $2='all' THEN interval '1 month' ELSE interval '1 day' END AS step
        ) granularity CROSS JOIN LATERAL generate_series(
          CASE WHEN $2='all' THEN date_trunc('month',instant)-interval '11 months' ELSE start_at END,
          instant,step
        ) bucket
      )
      SELECT
        CASE WHEN $2<>'all' THEN start_at AT TIME ZONE 'UTC' END AS "startsAt",
        CASE WHEN $2<>'all' THEN (start_at+span) AT TIME ZONE 'UTC' END AS "endsAt",
        (SELECT ${metrics} FROM scored l WHERE l.ended_at<=now()
          AND ($2='all' OR l.ended_at>=start_at AT TIME ZONE 'UTC')) AS totals,
        CASE WHEN $2<>'all' THEN (SELECT ${metrics} FROM scored l
          WHERE l.ended_at >= (start_at-span) AT TIME ZONE 'UTC'
          AND l.ended_at < least(start_at,start_at-span+(instant-start_at)) AT TIME ZONE 'UTC') END AS previous,
        (SELECT jsonb_agg(jsonb_build_object('startsAt',bucket AT TIME ZONE 'UTC','totals',t.data) ORDER BY bucket)
          FROM series CROSS JOIN LATERAL (
            SELECT ${metrics} AS data FROM scored l WHERE l.ended_at >= bucket AT TIME ZONE 'UTC'
              AND l.ended_at < (bucket+step) AT TIME ZONE 'UTC' AND l.ended_at<=now()
          ) t) AS series,
        (SELECT jsonb_build_object('target',target,'cadence',cadence,'endsAt',(starts+days*interval '1 day') AT TIME ZONE 'UTC',
          'progress',(SELECT coalesce(sum(cleanup_count),0) FROM ledger
            WHERE eligible AND ended_at>=starts AT TIME ZONE 'UTC' AND ended_at<=now()),
          'streak',(SELECT coalesce(max(length) FILTER (WHERE last_day>=starts::date-days),0) FROM islands),
          'longestStreak',(SELECT coalesce(max(length),0) FROM islands)) FROM goal) AS goal,
        (SELECT count(*)::int FROM ledger WHERE verified AND state IN ('queued','processing','review','failed')) AS pending,
        coalesce((SELECT jsonb_agg(jsonb_build_object('title',d.title,'goal',d.goal,'unit',d.unit,'bonus',d.bonus,
          'progress',coalesce(c.progress,0),'endsAt',(date_trunc(d.cadence,instant)+
            CASE d.cadence WHEN 'week' THEN interval '1 week' ELSE interval '1 day' END) AT TIME ZONE 'UTC')
          ORDER BY d.kind) FROM challenge_definitions d LEFT JOIN LATERAL (
            SELECT max(progress) AS progress FROM challenge_steps
            WHERE kind=d.kind AND period_start=date_trunc(d.cadence,instant)
          ) c ON true),'[]') AS "activeChallenges"
      FROM bounds`, [user,period]);
    return { period, ...row };
  }

  async goal(user: string, body: GoalInput) {
    await this.db.query(`INSERT INTO cleanup_goals(user_id,cadence,target) VALUES($1,$2,$3)
      ON CONFLICT(user_id) DO UPDATE SET cadence=excluded.cadence,target=excluded.target`,
    [user,body.cadence,body.target]);
    return this.progress(user,'week');
  }

  async challenges(user: string) {
    return this.db.query(`${personalLedger}, ${officialChallenges}, periods AS (
      SELECT d.*,period_start,period_start+(CASE cadence WHEN 'week' THEN interval '1 week' ELSE interval '1 day' END) AS period_end
      FROM challenge_definitions d CROSS JOIN LATERAL (
        SELECT date_trunc(cadence,now() AT TIME ZONE 'UTC') - offset_by *
          (CASE cadence WHEN 'week' THEN interval '1 week' ELSE interval '1 day' END) AS period_start
        FROM generate_series(0,CASE cadence WHEN 'week' THEN 8 ELSE 14 END) offset_by
      ) dates
    )
    SELECT kind||':'||period_start::date::text AS id,title,cadence,unit,goal,bonus,true AS official,
      greatest(period_start AT TIME ZONE 'UTC',s.starts_at) AS "startsAt",
      period_end AT TIME ZONE 'UTC' AS "endsAt", false AS mine,
      coalesce((SELECT max(progress)::int FROM challenge_steps c WHERE c.kind=p.kind AND c.period_start=p.period_start),0) AS progress,
      (SELECT unlocked_at FROM challenge_awards c WHERE c.kind=p.kind AND c.period_start=p.period_start) AS "completedAt",
      CASE WHEN EXISTS(SELECT 1 FROM challenge_awards c WHERE c.kind=p.kind AND c.period_start=p.period_start)
        THEN bonus ELSE 0 END AS "earnedPoints"
    FROM periods p CROSS JOIN gamification_season s WHERE period_end AT TIME ZONE 'UTC'>s.starts_at
    ORDER BY period_start DESC,kind`, [user]);
  }

  async badges(user: string) {
    const [data] = await this.db.query(`${personalLedger}, ${officialChallenges}, milestones AS (
      SELECT approved_at AS at,1 AS walks,cardinality(spots) AS cleanups,score AS points,0 AS challenges
      FROM ledger WHERE eligible AND ended_at<=now()
      UNION ALL
      SELECT unlocked_at,0,0,bonus,1 FROM challenge_awards
    ) SELECT
      coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY at) FROM milestones r),'[]') AS milestones,
      (SELECT min(greatest(p.created_at,l.approved_at)) FROM community_posts p
        LEFT JOIN ledger l ON l.id=p.plog_id WHERE p.author_id=$1 AND NOT p.hidden
        AND (p.plog_id IS NULL OR l.eligible)) AS shared`, [user]);
    const definitions = [
      ['First Plog','Complete your first eligible Plog.','walks',1],
      ['Five clean walks','Complete five eligible Plogs.','walks',5],
      ['Spot cleaner','Verify a reported litter cleanup.','cleanups',1],
      ['Neighborhood caretaker','Verify ten spot cleanups.','cleanups',10],
      ['Cleanup champion','Verify fifty spot cleanups.','cleanups',50],
      ['100 points','Earn 100 points.','points',100],
      ['500 points','Earn 500 points.','points',500],
      ['Challenge starter','Complete an official challenge.','challenges',1],
      ['Challenge regular','Complete ten official challenges.','challenges',10],
      ['Community voice','Share a post or an eligible Plog.','shared',1],
    ] as const;
    return definitions.map(([name,rule,metric,goal]) => {
      let earned: Date | string | null = null;
      let progress = 0;
      if (metric==='shared') {
        earned = data.shared;
        progress = Number(!!earned);
      } else {
        for (const row of data.milestones) {
          progress = Math.round((progress+row[metric])*100)/100;
          if (progress>=goal) {
            earned = row.at;
            break;
          }
        }
      }
      return { name,rule,goal,progress: Math.min(progress,goal),earned,
        status: earned ? 'earned' : progress>0 ? 'in_progress' : 'locked' };
    });
  }
}

@Controller()
@UseGuards(AuthGuard)
export class GamificationController {
  constructor(private readonly progressService: GamificationService) {}

  @Get('progress')
  progress(@Req() req: AuthenticatedRequest, @Query('period') period = 'week') {
    return this.progressService.progress(req.user.id,period);
  }

  @Put('profile/goal')
  goal(@Req() req: AuthenticatedRequest, @Body() body: GoalInput) {
    return this.progressService.goal(req.user.id,body);
  }
}
