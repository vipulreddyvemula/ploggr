import { Body, Controller, Get, Header, HttpCode, Param, ParseUUIDPipe, Post, Query, Req, UseGuards } from '@nestjs/common';
import { AuthGuard, type AuthenticatedRequest } from '../auth/auth.guard';
import { FinishPlogDto } from './plog.dto';
import { PlogsService } from './plogs.service';

@Controller('plogs')
@UseGuards(AuthGuard)
export class PlogsController {
  constructor(private readonly plogs: PlogsService) {}

  @Post()
  @Header('Cache-Control', 'no-store')
  start(@Req() req: AuthenticatedRequest) { return this.plogs.start(req.user.id); }

  @Get('active')
  @Header('Cache-Control', 'no-store')
  active(@Req() req: AuthenticatedRequest) { return this.plogs.active(req.user.id); }

  @Get()
  @Header('Cache-Control', 'no-store')
  completed(@Req() req: AuthenticatedRequest, @Query('before', new ParseUUIDPipe({ optional: true })) before?: string) {
    return this.plogs.completed(req.user.id, before);
  }

  @Get(':id')
  @Header('Cache-Control', 'no-store')
  detail(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string) {
    return this.plogs.detail(req.user.id, id);
  }

  @Post(':id/finish')
  @HttpCode(200)
  @Header('Cache-Control', 'no-store')
  finish(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string, @Body() dto: FinishPlogDto) {
    return this.plogs.finish(req.user.id, id, dto);
  }
}
