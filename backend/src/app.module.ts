import { Module } from '@nestjs/common';
import { HealthController } from './modules/health/health.controller';
import { MmoModule } from './modules/mmo/mmo.module';

@Module({
  imports: [MmoModule],
  controllers: [HealthController],
})
export class AppModule {}
