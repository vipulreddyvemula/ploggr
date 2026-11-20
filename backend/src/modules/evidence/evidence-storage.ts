import { Injectable, NotFoundException, OnModuleDestroy, ServiceUnavailableException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PutObjectCommand, GetObjectCommand, S3Client, S3ServiceException } from '@aws-sdk/client-s3';
import type { Environment } from '../../config/environment';

@Injectable()
export class EvidenceStorage implements OnModuleDestroy {
  private readonly client?: S3Client;
  private readonly bucket?: string;

  constructor(config: ConfigService<Environment, true>) {
    const options = config.get('evidenceStorage', { infer: true });
    if (!options) return;
    this.bucket = options.bucket;
    this.client = new S3Client({ region: options.region, endpoint: options.endpoint,
      credentials: options.credentials, forcePathStyle: Boolean(options.endpoint), maxAttempts: 2 });
  }

  async put(key: string, bytes: Buffer, contentType: string): Promise<void> {
    if (!this.client) throw new ServiceUnavailableException('Image storage is unavailable');
    try {
      await this.client.send(new PutObjectCommand({ Bucket: this.bucket, Key: key, Body: bytes, ContentType: contentType }),
        { abortSignal: AbortSignal.timeout(30000) });
    } catch {
      throw new ServiceUnavailableException('Image storage is unavailable');
    }
  }

  async read(key: string): Promise<Buffer> {
    if (!this.client) throw new ServiceUnavailableException('Image storage is unavailable');
    try {
      const result = await this.client.send(new GetObjectCommand({ Bucket: this.bucket, Key: key }),
        { abortSignal: AbortSignal.timeout(30000) });
      if (!result.Body) throw new Error('Empty storage response');
      return Buffer.from(await result.Body.transformToByteArray());
    } catch (error) {
      if (error instanceof S3ServiceException && error.$metadata.httpStatusCode === 404) throw new NotFoundException();
      throw new ServiceUnavailableException('Image storage is unavailable');
    }
  }

  onModuleDestroy() { this.client?.destroy(); }
}
