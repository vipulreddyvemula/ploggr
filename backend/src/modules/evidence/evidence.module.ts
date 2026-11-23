import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { EvidenceMaintenance } from './evidence-maintenance';
import { EvidenceService } from './evidence.service';
import { EvidenceController } from './evidence.controller';
import { EvidenceStorage } from './evidence-storage';

@Module({ imports: [AuthModule], controllers: [EvidenceController], providers: [EvidenceStorage, EvidenceService, EvidenceMaintenance], exports: [EvidenceStorage] })
export class EvidenceModule {}
