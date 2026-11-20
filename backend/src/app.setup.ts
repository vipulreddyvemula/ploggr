import { INestApplication, ValidationPipe } from '@nestjs/common';
import { json, type RequestHandler } from 'express';

// Shared by the server and HTTP tests so the API contract stays identical.
export function configureApp(app: INestApplication): void {
  app.setGlobalPrefix('api');
  // Keep Nest's default JSON parser for other routes. Its Express adapter checks
  // installed middleware by function name, even for path-specific handlers.
  const routeJson = json({ limit: '2mb' });
  const parseFinish: RequestHandler = (req, res, next) => routeJson(req, res, next);
  app.use('/api/plogs/:id/finish', parseFinish);
  app.useGlobalPipes(
    new ValidationPipe({
      transform: true,
      whitelist: true,
      forbidNonWhitelisted: true,
      validationError: { target: false, value: false },
    }),
  );
}
