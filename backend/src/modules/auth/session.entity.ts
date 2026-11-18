import { Column, Entity, Index, JoinColumn, ManyToOne, PrimaryColumn, PrimaryGeneratedColumn } from 'typeorm';
import { User } from '../users/user.entity';

@Entity('auth_sessions')
export class AuthSession {
  @PrimaryGeneratedColumn('uuid', { primaryKeyConstraintName: 'auth_sessions_pkey' })
  id!: string;

  @Index('auth_sessions_user_idx')
  @ManyToOne(() => User, { nullable: false, onDelete: 'CASCADE' })
  @JoinColumn({ name: 'user_id', foreignKeyConstraintName: 'auth_sessions_user_fk' })
  user!: User;
}

@Entity('auth_refresh_tokens')
export class RefreshCredential {
  @PrimaryColumn('text', { primaryKeyConstraintName: 'auth_refresh_tokens_pkey' })
  digest!: string;

  @Index('auth_refresh_session_idx')
  @ManyToOne(() => AuthSession, { nullable: false, onDelete: 'CASCADE' })
  @JoinColumn({ name: 'session_id', foreignKeyConstraintName: 'auth_refresh_session_fk' })
  session!: AuthSession;

  @Column('uuid', { name: 'request_id', nullable: true })
  requestId!: string | null;

  @Column('bytea', { name: 'encrypted_successor', nullable: true, select: false })
  encryptedSuccessor!: Buffer | null;
}
