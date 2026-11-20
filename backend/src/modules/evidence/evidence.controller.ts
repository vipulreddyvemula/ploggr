import { Controller, Header, Param, ParseUUIDPipe, Put, Req, UploadedFile, UseGuards, UseInterceptors } from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { AuthGuard, type AuthenticatedRequest } from '../auth/auth.guard';
import { EvidenceService, type PhotoUpload } from './evidence.service';

@Controller('plogs/:plogId/evidence')
@UseGuards(AuthGuard)
export class EvidenceController {
  constructor(private readonly evidence: EvidenceService) {}

  @Put(':id')
  @Header('Cache-Control', 'no-store')
  @UseInterceptors(FileInterceptor('photo', { limits: { fileSize: 8 * 1024 * 1024, files: 1, fields: 0 } }))
  upload(@Req() req: AuthenticatedRequest, @Param('plogId', ParseUUIDPipe) plogId: string,
    @Param('id', ParseUUIDPipe) id: string, @UploadedFile() file?: PhotoUpload) {
    return this.evidence.upload(req.user.id, plogId, id, file);
  }
}
