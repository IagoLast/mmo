import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';

async function bootstrap(): Promise<void> {
  const app = await NestFactory.create(AppModule);
  // PORT is what every PaaS and container runtime injects; HTTP_PORT stays
  // first so the existing dev scripts keep their 3100.
  const port = Number(process.env.HTTP_PORT ?? process.env.PORT ?? 3000);
  // Without this, onApplicationShutdown never fires and a SIGTERM from Docker
  // leaves players' sockets hanging until the container is killed.
  app.enableShutdownHooks();
  await app.listen(port, process.env.HOST ?? '0.0.0.0');
}

void bootstrap();
