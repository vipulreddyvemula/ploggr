import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { PlogsController } from './plogs.controller';
import { PlogsService } from './plogs.service';

@Module({ imports: [AuthModule], controllers: [PlogsController], providers: [PlogsService] })
export class PlogsModule {}
