import { Body, Controller, Delete, Get, Header, Headers, HttpCode, Param, ParseUUIDPipe, Put, Req, StreamableFile, UploadedFile, UseGuards, UseInterceptors } from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { AuthGuard, type AuthenticatedRequest } from '../auth/auth.guard';
import { EvidenceService, type PhotoUpload } from './evidence.service';

@Controller('plogs/:plogId/evidence')
@UseGuards(AuthGuard)
export class EvidenceController {
  constructor(private readonly evidence: EvidenceService) {}

  @Get()
  @Header('Cache-Control', 'private, no-store')
  list(@Req() req: AuthenticatedRequest, @Param('plogId', ParseUUIDPipe) plogId: string) {
    return this.evidence.list(req.user.id, plogId);
  }

  @Get(':id')
  @Header('Cache-Control', 'private, no-store')
  @Header('X-Content-Type-Options', 'nosniff')
  async image(@Req() req: AuthenticatedRequest, @Param('plogId', ParseUUIDPipe) plogId: string,
    @Param('id', ParseUUIDPipe) id: string) {
    const image = await this.evidence.image(req.user.id, plogId, id);
    return new StreamableFile(image.bytes, { type: image.mediaType, length: image.bytes.length });
  }

  @Delete(':id')
  @HttpCode(204)
  remove(@Req() req: AuthenticatedRequest, @Param('plogId', ParseUUIDPipe) plogId: string,
    @Param('id', ParseUUIDPipe) id: string, @Headers('x-plog-device') recorder?: string) {
    return this.evidence.remove(req.user.id, plogId, id, recorder);
  }

  @Put(':id')
  @Header('Cache-Control', 'no-store')
  @UseInterceptors(FileInterceptor('photo', { limits: { fileSize: 8 * 1024 * 1024, files: 1, fields: 1, fieldSize: 2048 } }))
  upload(@Req() req: AuthenticatedRequest, @Param('plogId', ParseUUIDPipe) plogId: string,
    @Param('id', ParseUUIDPipe) id: string, @Body('capture') capture: unknown, @UploadedFile() file?: PhotoUpload,
    @Headers('x-plog-device') recorder?: string) {
    return this.evidence.upload(req.user.id, plogId, id, file, capture, recorder);
  }
}
