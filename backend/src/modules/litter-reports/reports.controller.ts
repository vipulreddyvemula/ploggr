import {
  Body,
  Controller,
  Delete,
  Get,
  Header,
  Headers,
  HttpCode,
  Param,
  Patch,
  ParseIntPipe,
  ParseUUIDPipe,
  Post,
  Put,
  Query,
  Req,
  StreamableFile,
  UploadedFiles,
  UseGuards,
  UseInterceptors,
} from '@nestjs/common';
import { FilesInterceptor } from '@nestjs/platform-express';
import { AuthGuard, type AuthenticatedRequest } from '../auth/auth.guard';
import type { PhotoUpload } from '../evidence/evidence.service';
import { CollectionFields, DiscoverQuery, MapQuery, ReportPageQuery, SpotFields, ObservationInput } from './reports.dto';
import { ReportsService } from './reports.service';

@Controller('litter-reports')
@UseGuards(AuthGuard)
export class ReportsController {
  constructor(private readonly reports: ReportsService) {}

  @Get()
  @Header('Cache-Control', 'private, no-store')
  list(@Req() req: AuthenticatedRequest, @Query() query: DiscoverQuery) {
    return this.reports.list(req.user.id, query);
  }
  @Get('mine')
  @Header('Cache-Control', 'private, no-store')
  mine(@Req() req: AuthenticatedRequest, @Query() query: ReportPageQuery) {
    return this.reports.mine(req.user.id, query.before);
  }
  @Get('clusters')
  clusters(@Query() bounds: MapQuery) { return this.reports.clusters(bounds); }
  @Get('nearby')
  nearby(@Req() req: AuthenticatedRequest, @Query('lat') lat: string, @Query('lon') lon: string) {
    return this.reports.nearby(req.user.id, lat?.trim()?Number(lat):NaN, lon?.trim()?Number(lon):NaN);
  }
  @Put(':id/observations/:observation')
  observe(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string,
    @Param('observation', ParseUUIDPipe) observation: string, @Body() body: ObservationInput, @Headers('x-plog-device') recorder?: string) {
    return this.reports.observe(req.user.id,id,observation,body,recorder);
  }
  @Get(':id')
  @Header('Cache-Control', 'private, no-store')
  detail(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string) {
    return this.reports.detail(req.user.id, id);
  }
  @Get(':id/history')
  @Header('Cache-Control', 'private, no-store')
  history(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string) {
    return this.reports.history(req.user.id, id);
  }

  @Patch(':id')
  edit(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string, @Body() fields: SpotFields) {
    return this.reports.edit(req.user.id, id, fields);
  }

  @Get(':id/photos/:position')
  @Header('Cache-Control', 'private, no-store')
  @Header('X-Content-Type-Options', 'nosniff')
  async photo(@Param('id', ParseUUIDPipe) id: string, @Param('position', ParseIntPipe) position: number) {
    return new StreamableFile(await this.reports.image(id, position), { type: 'image/jpeg' });
  }
  @Put(':id')
  @UseInterceptors(
    FilesInterceptor('photos', 6, {
      limits: { files: 6, fields: 8, fileSize: 8 * 1024 * 1024, fieldSize: 4096 },
    }),
  )
  publish(
    @Req() req: AuthenticatedRequest,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() fields: SpotFields,
    @UploadedFiles() files: PhotoUpload[],
  ) {
    return this.reports.publish(req.user.id, id, fields, files);
  }
  @Put(':id/collection')
  collection(
    @Req() req: AuthenticatedRequest,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() fields: CollectionFields,
    @Headers('x-plog-device') recorder?: string,
  ) {
    return this.reports.collection(req.user.id, id, fields, recorder);
  }
  @Delete(':id')
  @HttpCode(204)
  withdraw(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string) {
    return this.reports.withdraw(req.user.id, id);
  }
  @Delete(':id/draft')
  @HttpCode(204)
  cancelDraft(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string) {
    return this.reports.cancelDraft(req.user.id, id);
  }
  @Post(':id/flags')
  @HttpCode(204)
  flag(@Req() req: AuthenticatedRequest, @Param('id', ParseUUIDPipe) id: string) {
    return this.reports.flag(req.user.id, id);
  }
}
