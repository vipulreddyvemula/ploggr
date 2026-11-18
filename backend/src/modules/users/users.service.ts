import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Equal, Raw, Repository, type FindOptionsWhere } from 'typeorm';
import { User } from './user.entity';

export type UserIdentity = Pick<User, 'id' | 'email'>;

const identityFields: (keyof UserIdentity)[] = ['id', 'email'];
const normalizedEmail = 'lower(btrim(:email))';

@Injectable()
export class UsersService {
  constructor(@InjectRepository(User) private readonly users: Repository<User>) {}

  async create({ email, passwordHash }: { email: string; passwordHash: string }): Promise<UserIdentity> {
    const result = await this.users.createQueryBuilder()
      .insert()
      .values({ email: () => normalizedEmail, passwordHash })
      .setParameter('email', email)
      .returning(identityFields)
      .execute();

    const [identity]: UserIdentity[] = result.raw;
    return identity;
  }

  findById(id: string): Promise<UserIdentity | null> {
    return this.findOne({ id: Equal(id) });
  }

  findByEmail(email: string): Promise<UserIdentity | null> {
    return this.findOne({ email: Raw(column => `${column} = ${normalizedEmail}`, { email }) });
  }

  private async findOne(where: FindOptionsWhere<User>): Promise<UserIdentity | null> {
    const user = await this.users.findOne({ select: identityFields, where });
    return user && { id: user.id, email: user.email };
  }
}
