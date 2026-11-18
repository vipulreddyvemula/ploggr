import { ConflictException, Injectable, UnauthorizedException } from '@nestjs/common';
import { argon2id, hash, verify } from 'argon2';
import { DataSource, QueryFailedError } from 'typeorm';
import { UsersService } from '../users/users.service';
import { LoginDto, SignupDto } from './auth.dto';
import { SessionService } from './session.service';

const hashing = { type: argon2id, memoryCost: 19456, timeCost: 2, parallelism: 1 } as const;

@Injectable()
export class AuthService {
  private readonly dummyHash = hash('invalid-account-timing-padding', hashing);

  constructor(private readonly db: DataSource, private readonly users: UsersService, private readonly sessions: SessionService) {}

  async signup({ email, password }: SignupDto) {
    const passwordHash = await hash(password, hashing);
    try {
      return await this.db.transaction(async manager => {
        const user = await this.users.create({ email, passwordHash }, manager);
        return this.sessions.issue(manager, user);
      });
    } catch (error) {
      if (error instanceof QueryFailedError && (error.driverError as { code?: string }).code === '23505'
        && (error.driverError as { constraint?: string }).constraint === 'users_email_key') throw new ConflictException('Email already registered');
      throw error;
    }
  }

  async login({ email, password }: LoginDto) {
    const user = await this.users.findForAuthentication(email);
    const matches = await verify(user?.passwordHash ?? await this.dummyHash, password);
    if (!matches || !user?.passwordHash) throw new UnauthorizedException('Invalid email or password');
    return this.db.transaction(manager => this.sessions.issue(manager, user));
  }
}
