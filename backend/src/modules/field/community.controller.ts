import {
  BadRequestException,
  Body,
  ConflictException,
  Controller,
  Delete,
  ForbiddenException,
  Get,
  NotFoundException,
  Param,
  ParseUUIDPipe,
  Put,
  Query,
  Req,
  UseGuards,
} from '@nestjs/common';
import {
  IsBoolean,
  IsDateString,
  IsInt,
  IsNumber,
  IsOptional,
  IsString,
  IsUUID,
  Length,
  Max,
  Min,
} from 'class-validator';
import { Transform } from 'class-transformer';
import { ConfigService } from '@nestjs/config';
import { DataSource } from 'typeorm';
import { AuthGuard, type AuthenticatedRequest } from '../auth/auth.guard';

const trimmed = () => Transform(({ value }) => (typeof value === 'string' ? value.trim() : value));
class NameInput {
  @trimmed() @IsString() @Length(1, 50) name!: string;
}
class PostInput {
  @trimmed() @IsString() @Length(1, 1000) body!: string;
  @IsOptional() @IsUUID('4') plogId?: string;
}
class CommentInput {
  @trimmed() @IsString() @Length(1, 500) body!: string;
}
class Toggle {
  @IsBoolean() selected!: boolean;
}
class EventInput {
  @trimmed() @IsString() @Length(2, 80) title!: string;
  @trimmed() @IsString() @Length(1, 160) place!: string;
  @IsDateString() startsAt!: string;
  @IsNumber() @Min(-90) @Max(90) latitude!: number;
  @IsNumber() @Min(-180) @Max(180) longitude!: number;
}
class ChallengeInput {
  @trimmed() @IsString() @Length(2, 80) title!: string;
  @IsInt() @Min(1) @Max(1000) goal!: number;
  @IsDateString() startsAt!: string;
  @IsDateString() endsAt!: string;
}
const alias = "coalesce(u.display_name,'Plogger '||left(u.id::text,6))";

@Controller()
@UseGuards(AuthGuard)
export class CommunityController {
  constructor(
    private readonly db: DataSource,
    private readonly config: ConfigService,
  ) {}
  private moderator(id: string) {
    return (this.config.get<string>('MODERATOR_IDS') ?? '')
      .split(',')
      .map((x) => x.trim())
      .includes(id);
  }
  @Get('profile')
  async profile(@Req() req: AuthenticatedRequest) {
    const [row] = await this.db.query('SELECT display_name AS name FROM users WHERE id=$1', [req.user.id]);
    return { ...row, moderator: this.moderator(req.user.id) };
  }
  @Put('profile')
  async rename(@Req() req: AuthenticatedRequest, @Body() input: NameInput) {
    await this.db.query('UPDATE users SET display_name=$2 WHERE id=$1', [req.user.id, input.name]);
    return this.profile(req);
  }
  @Get('community/posts')
  async feed(
    @Req() req: AuthenticatedRequest,
    @Query('mine') mine?: string,
    @Query('before') before?: string,
  ) {
    if (before && !/^[a-f0-9-]{36}$/i.test(before)) throw new BadRequestException();
    const rows = await this.db.query(
      `SELECT p.id,p.body,p.plog_id AS "plogId",p.created_at AS "createdAt",${alias} AS author,
      activity.distance_meters AS "meters",activity.duration_seconds AS "seconds",u.id=$1 AS mine,(SELECT count(*)::int FROM post_reactions WHERE post_id=p.id) AS likes,
      EXISTS(SELECT 1 FROM post_reactions WHERE post_id=p.id AND user_id=$1) AS liked,
      (SELECT count(*)::int FROM post_comments WHERE post_id=p.id) AS comments
      FROM community_posts p JOIN users u ON u.id=p.author_id LEFT JOIN plogs activity ON activity.id=p.plog_id WHERE NOT hidden AND (NOT $2::boolean OR author_id=$1)
      AND ($3::uuid IS NULL OR (p.created_at,p.id)<(SELECT created_at,id FROM community_posts WHERE id=$3))
      ORDER BY p.created_at DESC,p.id DESC LIMIT 26`,
      [req.user.id, mine === 'true', before ?? null],
    );
    return { items: rows.slice(0, 25), next: rows.length > 25 ? rows[24].id : null };
  }
  private async post(id: string) {
    const [row] = await this.db.query('SELECT author_id FROM community_posts WHERE id=$1 AND NOT hidden', [
      id,
    ]);
    if (!row) throw new NotFoundException();
    return row;
  }
  @Put('community/posts/:id')
  async publish(
    @Req() req: AuthenticatedRequest,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() input: PostInput,
  ) {
    const rows = await this.db.query(
      `INSERT INTO community_posts(id,author_id,body,plog_id)
      SELECT $1,$2,$3,$4 WHERE $4::uuid IS NULL OR EXISTS(SELECT 1 FROM plogs WHERE id=$4 AND user_id=$2 AND status='completed')
      ON CONFLICT(id) DO UPDATE SET body=excluded.body WHERE community_posts.author_id=excluded.author_id AND NOT community_posts.hidden RETURNING id`,
      [id, req.user.id, input.body, input.plogId ?? null],
    );
    if (!rows.length) throw new ConflictException();
    return { id };
  }
  @Delete('community/posts/:id')
  async remove(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string) {
    const row = await this.post(id);
    if (row.author_id !== req.user.id && !this.moderator(req.user.id)) throw new ForbiddenException();
    await this.db.query('UPDATE community_posts SET hidden=true WHERE id=$1', [id]);
  }
  @Put('community/posts/:id/reaction')
  async react(
    @Req() req: AuthenticatedRequest,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: Toggle,
  ) {
    await this.post(id);
    await this.db.query(
      body.selected
        ? 'INSERT INTO post_reactions VALUES($1,$2) ON CONFLICT DO NOTHING'
        : 'DELETE FROM post_reactions WHERE post_id=$1 AND user_id=$2',
      [id, req.user.id],
    );
  }
  @Put('community/posts/:id/flag')
  async flag(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string) {
    await this.post(id);
    await this.db.query('INSERT INTO post_flags VALUES($1,$2) ON CONFLICT DO NOTHING', [id, req.user.id]);
  }
  @Get('community/posts/:id/comments')
  async comments(@Param('id', ParseUUIDPipe) id: string) {
    await this.post(id);
    return this.db.query(
      `SELECT c.id,c.body,c.created_at AS "createdAt",${alias} AS author FROM post_comments c JOIN users u ON u.id=c.user_id
      WHERE post_id=$1 ORDER BY c.created_at DESC,c.id LIMIT 100`,
      [id],
    );
  }
  @Put('community/posts/:id/comments/:comment')
  async comment(
    @Req() req: AuthenticatedRequest,
    @Param('id', ParseUUIDPipe) id: string,
    @Param('comment', ParseUUIDPipe) comment: string,
    @Body() body: CommentInput,
  ) {
    await this.post(id);
    const rows = await this.db.query(
      `INSERT INTO post_comments(id,post_id,user_id,body) VALUES($1,$2,$3,$4)
      ON CONFLICT(id) DO UPDATE SET body=post_comments.body WHERE (post_comments.post_id,post_comments.user_id,post_comments.body)=
      (excluded.post_id,excluded.user_id,excluded.body) RETURNING id`,
      [comment, id, req.user.id, body.body],
    );
    if (!rows.length) throw new ConflictException('This comment was already submitted');
  }
  @Get('events')
  events(@Req() req: AuthenticatedRequest) {
    return this.db.query(
      `SELECT e.id,e.title,e.place,e.latitude,e.longitude,e.starts_at AS "startsAt",${alias} AS organizer,
      e.organizer=$1 AS mine,(SELECT count(*)::int FROM event_rsvps WHERE event_id=e.id) AS going,
      EXISTS(SELECT 1 FROM event_rsvps WHERE event_id=e.id AND user_id=$1) AS joined
      FROM cleanup_events e JOIN users u ON u.id=e.organizer WHERE NOT cancelled AND starts_at>now()-interval '1 day'
      ORDER BY starts_at,id LIMIT 100`,
      [req.user.id],
    );
  }
  @Put('events/:id')
  async event(
    @Req() req: AuthenticatedRequest,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: EventInput,
  ) {
    const rows = await this.db.query(
      `INSERT INTO cleanup_events(id,organizer,title,place,starts_at,latitude,longitude) VALUES($1,$2,$3,$4,$5,$6,$7)
      ON CONFLICT(id) DO UPDATE SET title=excluded.title,place=excluded.place,starts_at=excluded.starts_at,latitude=excluded.latitude,longitude=excluded.longitude
      WHERE cleanup_events.organizer=excluded.organizer AND NOT cleanup_events.cancelled RETURNING id`,
      [id, req.user.id, body.title, body.place, body.startsAt, body.latitude, body.longitude],
    );
    if (!rows.length) throw new ConflictException();
    return { id };
  }
  @Delete('events/:id')
  async cancel(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string) {
    const rows = await this.db.query(
      'WITH c AS (UPDATE cleanup_events SET cancelled=true WHERE id=$1 AND organizer=$2 RETURNING id) SELECT * FROM c',
      [id, req.user.id],
    );
    if (!rows.length) throw new NotFoundException();
  }
  @Put('events/:id/rsvp')
  async rsvp(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string, @Body() body: Toggle) {
    const [event] = await this.db.query(
      'SELECT id FROM cleanup_events WHERE id=$1 AND NOT cancelled AND starts_at>now()',
      [id],
    );
    if (!event) throw new NotFoundException();
    await this.db.query(
      body.selected
        ? 'INSERT INTO event_rsvps VALUES($1,$2) ON CONFLICT DO NOTHING'
        : 'DELETE FROM event_rsvps WHERE event_id=$1 AND user_id=$2',
      [id, req.user.id],
    );
  }
  @Get('challenges')
  challenges(@Req() req: AuthenticatedRequest) {
    return this.db.query(
      `SELECT c.id,c.title,c.goal,c.starts_at AS "startsAt",c.ends_at AS "endsAt",c.organizer=$1 AS mine,
      (SELECT count(*)::int FROM plogs p WHERE p.user_id=$1 AND p.status='completed' AND p.ended_at BETWEEN c.starts_at AND c.ends_at) AS progress
      FROM cleanup_challenges c ORDER BY c.ends_at DESC LIMIT 100`,
      [req.user.id],
    );
  }
  @Put('challenges/:id')
  async challenge(
    @Req() req: AuthenticatedRequest,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: ChallengeInput,
  ) {
    if (Date.parse(body.endsAt) <= Date.parse(body.startsAt))
      throw new BadRequestException('End must follow start');
    const rows = await this.db.query(
      `INSERT INTO cleanup_challenges VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(id) DO UPDATE SET
      title=excluded.title,goal=excluded.goal,starts_at=excluded.starts_at,ends_at=excluded.ends_at WHERE cleanup_challenges.organizer=$2 RETURNING id`,
      [id, req.user.id, body.title, body.goal, body.startsAt, body.endsAt],
    );
    if (!rows.length) throw new ConflictException();
    return { id };
  }
  @Get('badges')
  async badges(@Req() req: AuthenticatedRequest) {
    const [row] = await this.db.query(
      `SELECT
      (SELECT ended_at FROM plogs WHERE user_id=$1 AND status='completed' ORDER BY ended_at LIMIT 1) AS first,
      (SELECT ended_at FROM plogs WHERE user_id=$1 AND status='completed' ORDER BY ended_at OFFSET 4 LIMIT 1) AS fifth,
      (SELECT min(created_at) FROM spot_observations WHERE resolved AND user_id=$1) AS cleanup,
      (SELECT min(created_at) FROM community_posts WHERE author_id=$1 AND NOT hidden) AS shared,
      (SELECT count(*)::int FROM plogs WHERE user_id=$1 AND status='completed') AS walks`,
      [req.user.id],
    );
    return [
      {
        name: 'First Plog',
        rule: 'Complete a Plog with a pickup photo.',
        earned: row.first,
        progress: Math.min(row.walks, 1),
        goal: 1,
      },
      {
        name: 'Five clean walks',
        rule: 'Complete five Plogs.',
        earned: row.fifth,
        progress: Math.min(row.walks, 5),
        goal: 5,
      },
      {
        name: 'Spot cleaner',
        rule: 'Clear a reported litter spot.',
        earned: row.cleanup,
        progress: Number(!!row.cleanup),
        goal: 1,
      },
      {
        name: 'Community voice',
        rule: 'Share a community post.',
        earned: row.shared,
        progress: Number(!!row.shared),
        goal: 1,
      },
    ];
  }
  @Get('moderation')
  async moderation(@Req() req: AuthenticatedRequest) {
    if (!this.moderator(req.user.id)) throw new ForbiddenException();
    const posts = await this.db.query(
      'SELECT p.id,p.body FROM community_posts p WHERE NOT hidden AND EXISTS(SELECT 1 FROM post_flags f WHERE f.post_id=p.id) LIMIT 100',
    );
    const reports = await this.db
      .query(`SELECT r.id,r.category,r.place FROM litter_reports r WHERE r.status='open' AND
      (EXISTS(SELECT 1 FROM litter_report_flags WHERE report_id=r.id) OR
      (SELECT count(DISTINCT user_id) FROM spot_observations WHERE report_id=r.id AND outcome='missing' AND created_at>coalesce(r.last_seen_at,r.created_at))>=2) LIMIT 100`);
    return { posts, reports };
  }
  @Put('moderation/:kind/:id/keep')
  async keep(
    @Req() req: AuthenticatedRequest,
    @Param('kind') kind: string,
    @Param('id', ParseUUIDPipe) id: string,
  ) {
    if (!this.moderator(req.user.id)) throw new ForbiddenException();
    if (kind !== 'reports' && kind !== 'posts') throw new BadRequestException();
    await this.db.transaction(async (tx) => {
      if (kind === 'posts') {
        await tx.query('DELETE FROM post_flags WHERE post_id=$1', [id]);
        return;
      }
      await tx.query("UPDATE litter_reports SET last_seen_at=now() WHERE id=$1 AND status='open'", [id]);
      await tx.query('DELETE FROM litter_report_flags WHERE report_id=$1', [id]);
    });
  }
  @Delete('moderation/reports/:id')
  async hideReport(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string) {
    if (!this.moderator(req.user.id)) throw new ForbiddenException();
    await this.db.query("UPDATE litter_reports SET status='hidden' WHERE id=$1", [id]);
  }
}
