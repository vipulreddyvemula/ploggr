import { Body, Controller, Get, Header, HttpCode, Post, Req, UseGuards } from '@nestjs/common';
import { LoginDto, RefreshCredentialDto, RefreshDto, SignupDto } from './auth.dto';
import { AuthGuard, type AuthenticatedRequest } from './auth.guard';
import { AuthService } from './auth.service';
import { SessionService } from './session.service';

@Controller('auth')
export class AuthController {
  constructor(private readonly auth: AuthService, private readonly sessions: SessionService) {}

  @Post('signup')
  @Header('Cache-Control', 'no-store')
  signup(@Body() dto: SignupDto) { return this.auth.signup(dto); }

  @Post('login')
  @HttpCode(200)
  @Header('Cache-Control', 'no-store')
  login(@Body() dto: LoginDto) { return this.auth.login(dto); }

  @Post('refresh')
  @HttpCode(200)
  @Header('Cache-Control', 'no-store')
  refresh(@Body() dto: RefreshDto) { return this.sessions.refresh(dto.refreshToken, dto.requestId); }

  @Post('logout')
  @HttpCode(204)
  logout(@Body() dto: RefreshCredentialDto) { return this.sessions.revoke(dto.refreshToken); }

  @Get('me')
  @UseGuards(AuthGuard)
  @Header('Cache-Control', 'no-store')
  me(@Req() request: AuthenticatedRequest) { return request.user; }
}
