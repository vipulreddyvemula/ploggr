import { Transform } from 'class-transformer';
import { IsEmail, IsString, IsUUID, Length, Matches, MaxLength } from 'class-validator';

export class LoginDto {
  @Transform(({ value }) => typeof value === 'string' ? value.trim() : value)
  @IsEmail()
  @MaxLength(254)
  email!: string;

  @IsString()
  @Length(1, 128)
  password!: string;
}

export class SignupDto extends LoginDto {
  @Length(15, 128)
  declare password: string;
}

export class RefreshCredentialDto {
  @IsString()
  @Matches(/^[A-Za-z0-9_-]{43}$/)
  refreshToken!: string;
}

export class RefreshDto extends RefreshCredentialDto {
  @IsUUID('4')
  requestId!: string;
}
