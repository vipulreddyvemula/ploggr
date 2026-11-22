import {
  Check, Column, Entity, Index, JoinColumn, ManyToOne,
  type Point, PrimaryColumn, PrimaryGeneratedColumn,
} from 'typeorm';
import { User } from '../users/user.entity';

@Entity('plogs')
@Index('plogs_one_active_per_user', ['user'], { unique: true, where: "status = 'active'" })
@Check('plogs_lifecycle_check', `(status = 'active' AND ended_at IS NULL) OR
  (status = 'completed' AND ended_at IS NOT NULL AND ended_at >= started_at)`)
@Check('plogs_duration_check', 'duration_seconds >= 0')
@Check('plogs_distance_check', "distance_meters >= 0 AND distance_meters < 'Infinity'::double precision")
export class Plog {
  @PrimaryGeneratedColumn('uuid', { primaryKeyConstraintName: 'plogs_pkey' })
  id!: string;

  @Index('plogs_user_idx')
  @ManyToOne(() => User, { nullable: false, onDelete: 'CASCADE' })
  @JoinColumn({ name: 'user_id', foreignKeyConstraintName: 'plogs_user_fk' })
  user!: User;

  @Column('text', { default: 'active' })
  status!: 'active' | 'completed';

  @Column('timestamptz', { name: 'started_at', default: () => 'now()' })
  startedAt!: Date;

  @Column('timestamptz', { name: 'ended_at', nullable: true })
  endedAt!: Date | null;

  @Column('integer', { name: 'duration_seconds', default: 0 })
  durationSeconds!: number;

  @Column('integer', { name:'segment_starts', array:true, default:()=>"'{}'" })
  segmentStarts!: number[];

  @Column('double precision', { name: 'distance_meters', default: 0 })
  distanceMeters!: number;
}

@Entity('plog_route_points')
@Check('plog_route_points_sequence_check', 'sequence >= 0')
@Check('plog_route_points_location_check', 'NOT ST_IsEmpty(location::geometry)')
export class PlogRoutePoint {
  @PrimaryColumn('uuid', { name: 'plog_id', primaryKeyConstraintName: 'plog_route_points_pkey' })
  plogId!: string;

  @ManyToOne(() => Plog, { nullable: false, onDelete: 'CASCADE' })
  @JoinColumn({ name: 'plog_id', foreignKeyConstraintName: 'plog_route_points_plog_fk' })
  plog!: Plog;

  @PrimaryColumn('integer', { primaryKeyConstraintName: 'plog_route_points_pkey' })
  sequence!: number;

  @Column('geography', { spatialFeatureType: 'Point', srid: 4326 })
  location!: Point;
}
