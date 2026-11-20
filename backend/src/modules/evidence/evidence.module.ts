import { Module } from '@nestjs/common';
import { EvidenceStorage } from './evidence-storage';

@Module({ providers: [EvidenceStorage], exports: [EvidenceStorage] })
export class EvidenceModule {}
