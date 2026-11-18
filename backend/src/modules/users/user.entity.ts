import { Check, Column, Entity, PrimaryGeneratedColumn, Unique } from 'typeorm';

@Entity('users')
@Unique('users_email_key', ['email'])
@Check('users_email_canonical', `"email" <> '' AND "email" = lower(btrim("email"))`)
export class User {
  @PrimaryGeneratedColumn('uuid', { primaryKeyConstraintName: 'users_pkey' })
  id!: string;

  @Column('text')
  email!: string;

  @Column('text', { name: 'password_hash', select: false })
  passwordHash?: string;
}
