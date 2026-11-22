import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { EvidenceModule } from '../evidence/evidence.module';
import { ReportsController } from './reports.controller';
import { ReportsService } from './reports.service';

@Module({
  imports: [AuthModule, EvidenceModule],
  controllers: [ReportsController],
  providers: [ReportsService],
})
export class ReportsModule {}
