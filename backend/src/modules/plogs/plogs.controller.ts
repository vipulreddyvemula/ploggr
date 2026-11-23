import { Body, Controller, Delete, Get, Header, Headers, HttpCode, Param, ParseUUIDPipe, Post, Query, Req, UseGuards } from '@nestjs/common';
import { AuthGuard, type AuthenticatedRequest } from '../auth/auth.guard';
import { FinishPlogDto } from './plog.dto';
import { PlogsService } from './plogs.service';

@Controller('plogs')
@UseGuards(AuthGuard)
export class PlogsController {
  constructor(private readonly plogs: PlogsService) {}

  @Post()
  @Header('Cache-Control', 'no-store')
  start(@Req() req: AuthenticatedRequest, @Headers('x-plog-device') recorder?: string) {
    return this.plogs.start(req.user.id, recorder);
  }

  @Get('summary')
  @Header('Cache-Control','private, no-store')
  totals(@Req() req: AuthenticatedRequest, @Query('include') include?: string) {
    return this.plogs.totals(req.user.id, include === 'progress');
  }

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

  @Delete(':id')
  @HttpCode(204)
  @Header('Cache-Control', 'no-store')
  cancel(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string,
    @Headers('x-plog-device') recorder?: string) {
    return this.plogs.cancel(req.user.id, id, recorder);
  }

  @Post(':id/transfer')
  @HttpCode(200)
  @Header('Cache-Control', 'no-store')
  transfer(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string,
    @Headers('x-plog-device') recorder?: string) {
    return this.plogs.transfer(req.user.id, id, recorder);
  }

  @Post(':id/finish')
  @HttpCode(200)
  @Header('Cache-Control', 'no-store')
  finish(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string, @Body() dto: FinishPlogDto,
    @Headers('x-plog-device') recorder?: string) {
    return this.plogs.finish(req.user.id, id, dto, recorder);
  }
}
