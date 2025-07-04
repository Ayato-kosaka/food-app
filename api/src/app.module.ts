import { Module } from '@nestjs/common';
import { AppController } from './app.controller';
import { AppService } from './app.service';
import { LoggerModule } from './lib/logger/logger.module';
import { V1Module } from './v1/v1.module';
import { V2Module } from './v2/v2.module';

@Module({
  imports: [LoggerModule, V1Module, V2Module],
  controllers: [AppController],
  providers: [AppService],
})
export class AppModule {}
