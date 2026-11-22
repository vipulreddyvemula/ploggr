import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { EvidenceModule } from '../evidence/evidence.module';
import { ReviewController } from './review.controller';
import { CommunityController } from './community.controller';
import { ImpactController } from './impact.controller';
import { PlacesController } from './places.controller';
import { AnalysisWorker } from './analysis.service';

@Module({
  imports: [AuthModule, EvidenceModule],
  controllers: [ReviewController, CommunityController, ImpactController, PlacesController],
  providers: [AnalysisWorker],
})
export class FieldModule {}
