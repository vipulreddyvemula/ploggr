import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { APP_FILTER } from '@nestjs/core';
import { HttpExceptionFilter } from './common/filters/http-exception.filter';
import { validateEnvironment } from './config/environment';
import { environmentFileOptions } from './config/environment-file';
import { DatabaseModule } from './database/database.module';
import { HealthModule } from './modules/health/health.module';
import { AuthModule } from './modules/auth/auth.module';
import { UsersModule } from './modules/users/users.module';
import { EvidenceModule } from './modules/evidence/evidence.module';
import { FieldModule } from './modules/field/field.module';
import { ReportsModule } from './modules/litter-reports/reports.module';
import { PlogsModule } from './modules/plogs/plogs.module';

@Module({
  imports: [
    ConfigModule.forRoot({
      ...environmentFileOptions(),
      isGlobal: true,
      cache: true,
      validate: validateEnvironment,
    }),
    DatabaseModule,
    HealthModule,
    UsersModule,
    AuthModule,
    PlogsModule,
    EvidenceModule,
    ReportsModule,
    FieldModule,
  ],
  providers: [{ provide: APP_FILTER, useClass: HttpExceptionFilter }],
})
export class AppModule {}
