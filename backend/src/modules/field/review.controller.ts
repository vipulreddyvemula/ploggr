import {
  BadRequestException,
  Body,
  ConflictException,
  Controller,
  ForbiddenException,
  Get,
  Header,
  NotFoundException,
  Param,
  ParseUUIDPipe,
  Put,
  Req,
  StreamableFile,
  UseGuards,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  IsArray,
  IsIn,
  IsInt,
  IsOptional,
  IsString,
  IsUUID,
  Length,
  Max,
  Min,
  ValidateIf,
  ValidateNested,
} from 'class-validator';
import { DataSource } from 'typeorm';
import { AuthGuard, type AuthenticatedRequest } from '../auth/auth.guard';
import { EvidenceStorage } from '../evidence/evidence-storage';
import { litterTypes, materials } from './litter-classification';

function itemKey(item: ReviewedItem) {
  return JSON.stringify([item.label.trim(), item.material, item.type ?? 'Other', item.count, [...new Set(item.photoIds)].sort()]);
}


class ReviewedItem {
  @IsString() @Length(1, 80) label!: string;
  @IsIn(materials) material!: string;
  @IsOptional() @IsIn(litterTypes) type?: string;
  @ValidateIf((item: ReviewedItem) => item.count !== null)
  @IsInt() @Min(1) @Max(1000) count!: number | null;
  @IsArray() @ArrayMaxSize(6) @IsUUID('4', { each: true }) photoIds!: string[];
}
class Decision {
  @IsArray()
  @ArrayMaxSize(200)
  @ValidateNested({ each: true })
  @Type(() => ReviewedItem)
  items!: ReviewedItem[];
}
@Controller('moderation/analysis')
@UseGuards(AuthGuard)
export class ReviewController {
  constructor(
    private readonly db: DataSource,
    private readonly config: ConfigService,
    private readonly storage: EvidenceStorage,
  ) {}
  private authorize(id: string) {
    if (
      !(this.config.get<string>('MODERATOR_IDS') ?? '')
        .split(',')
        .map((s) => s.trim())
        .includes(id)
    )
      throw new ForbiddenException();
  }
  @Get() async queue(@Req() req: AuthenticatedRequest) {
    this.authorize(req.user.id);
    return this.db.query(
      `SELECT plog_id AS id,result,review_note AS "reviewNote" FROM plog_analysis
      WHERE state='review' ORDER BY (review_note IS NOT NULL) DESC,next_run LIMIT 50`,
    );
  }
  @Get(':id/photos') async photos(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string) {
    this.authorize(req.user.id);
    return this.db.query(
      `SELECT e.id FROM garbage_evidence e JOIN plog_analysis a ON a.plog_id=e.plog_id WHERE a.plog_id=$1 AND a.state='review' ORDER BY e.created_at,e.id`,
      [id],
    );
  }
  @Get(':id/photos/:photo')
  @Header('Cache-Control', 'private, no-store')
  async image(
    @Req() req: AuthenticatedRequest,
    @Param('id', ParseUUIDPipe) id: string,
    @Param('photo', ParseUUIDPipe) photo: string,
  ) {
    this.authorize(req.user.id);
    const [r] = await this.db.query(
      `SELECT e.storage_key,e.media_type FROM garbage_evidence e JOIN plog_analysis a ON a.plog_id=e.plog_id WHERE a.plog_id=$1 AND a.state='review' AND e.id=$2`,
      [id, photo],
    );
    if (!r) throw new NotFoundException();
    return new StreamableFile(await this.storage.read(r.storage_key), { type: r.media_type });
  }
  @Put(':id') async decide(
    @Req() req: AuthenticatedRequest,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: Decision,
  ) {
    this.authorize(req.user.id);
    await this.db.transaction(async (tx) => {
      const [job] = await tx.query(
        "SELECT result FROM plog_analysis WHERE plog_id=$1 AND state='review' FOR UPDATE",
        [id],
      );
      if (!job) throw new ConflictException();
      const photos = await tx.query(
        'SELECT id FROM garbage_evidence WHERE plog_id=$1 AND uploaded_at IS NOT NULL',
        [id],
      );
      const valid = new Set(photos.map((p: { id: string }) => p.id));
      if (dto.items.some((i) => !i.photoIds.length || i.photoIds.some((p) => !valid.has(p))))
        throw new BadRequestException('Choose supporting pickup photos');
      const previous = new Map<string, Record<string, unknown>>(
        (job.result?.items ?? []).map((item: ReviewedItem & Record<string, unknown>) => [itemKey(item), item]),
      );
      const seen = new Set<string>();
      const items = dto.items.map((item) => {
        const key = itemKey(item);
        if (seen.has(key)) throw new BadRequestException('Combine duplicate item groups');
        seen.add(key);
        const type = item.type ?? 'Other';
        const certain = item.count !== null && item.material !== 'Unknown'
          && type !== 'Unsorted waste' && type !== 'Unrecognized object';
        const prior = previous.get(key);
        return {
          weight: prior?.weight ?? null,
          potentialImpact: certain ? prior?.potentialImpact ?? null : null,
          box: prior?.box,
          label: item.label.trim(),
          material: item.material,
          type,
          count: item.count,
          photoIds: prior?.photoIds ?? [...new Set(item.photoIds)],
          certain,
        };
      });
      await tx.query("UPDATE plog_analysis SET result=$2,reviewed=true,state='ready',review_note=NULL WHERE plog_id=$1", [
        id,
        JSON.stringify({
          version: job.result?.version,
          quality: !items.length ? 'empty' : items.every((i) => i.certain) ? 'clear' : 'unclear',
          items,
        }),
      ]);
    });
  }
}
