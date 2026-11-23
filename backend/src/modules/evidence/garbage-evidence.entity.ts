import {
  Check, Column, CreateDateColumn, Entity, Index, JoinColumn, ManyToOne, PrimaryGeneratedColumn, Unique,
} from 'typeorm';
import type { CaptureMetadata } from './capture-metadata';
import { Plog } from '../plogs/plog.entity';

@Entity('garbage_evidence')
@Index('garbage_evidence_sha_idx', ['sha256'])
@Index('garbage_evidence_phash_bucket', { synchronize: false })
@Unique('garbage_evidence_storage_key_key', ['storageKey'])
@Check('garbage_evidence_reference_check', "storage_key <> '' AND storage_key = btrim(storage_key)")
@Check('garbage_evidence_metadata_check', "byte_size > 0 AND media_type <> '' AND sha256 ~ '^[0-9a-f]{64}$'")
export class GarbageEvidence {
  @PrimaryGeneratedColumn('uuid', { primaryKeyConstraintName: 'garbage_evidence_pkey' })
  id!: string;

  @Index('garbage_evidence_plog_idx')
  @ManyToOne(() => Plog, { nullable: false, onDelete: 'CASCADE' })
  @JoinColumn({ name: 'plog_id', foreignKeyConstraintName: 'garbage_evidence_plog_fk' })
  plog!: Plog;

  @Column('text', { name: 'storage_key' })
  storageKey!: string;

  @Column('text', { name: 'media_type' })
  mediaType!: string;

  @Column('integer', { name: 'byte_size' })
  byteSize!: number;

  @Column('text')
  sha256!: string;

  @Column('jsonb', { nullable: true })
  capture!: CaptureMetadata | null;

  @Column('text', { name: 'perceptual_hash', nullable: true })
  perceptualHash!: string | null;

  @CreateDateColumn({ type: 'timestamptz', name: 'created_at', default: () => 'now()' })
  createdAt!: Date;

  @Column('timestamptz', { name: 'uploaded_at', nullable: true })
  uploadedAt!: Date | null;
}
