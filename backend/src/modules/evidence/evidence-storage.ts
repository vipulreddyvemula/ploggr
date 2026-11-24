import { Injectable, NotFoundException, OnModuleDestroy, ServiceUnavailableException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { ManagedIdentityCredential } from '@azure/identity';
import { ContainerClient, RestError } from '@azure/storage-blob';
import { PutObjectCommand, GetObjectCommand, DeleteObjectCommand, S3Client, S3ServiceException } from '@aws-sdk/client-s3';
import type { Environment } from '../../config/environment';

@Injectable()
export class EvidenceStorage implements OnModuleDestroy {
  private readonly client?: S3Client;
  private readonly bucket?: string;
  private readonly blob?: ContainerClient;

  constructor(config: ConfigService<Environment, true>) {
    const blobContainer = config.get('evidenceBlobContainer', { infer: true });
    if (blobContainer) {
      this.blob = new ContainerClient(blobContainer,
        new ManagedIdentityCredential({ clientId: process.env.AZURE_CLIENT_ID }));
      return;
    }
    const options = config.get('evidenceStorage', { infer: true });
    if (!options) return;
    this.bucket = options.bucket;
    this.client = new S3Client({ region: options.region, endpoint: options.endpoint,
      credentials: options.credentials, forcePathStyle: Boolean(options.endpoint), maxAttempts: 2 });
  }

  async put(key: string, bytes: Buffer, contentType: string): Promise<void> {
    if (!this.client && !this.blob) throw new ServiceUnavailableException('Image storage is unavailable');
    try {
      const abortSignal = AbortSignal.timeout(30000);
      if (this.blob) {
        await this.blob.getBlockBlobClient(key).uploadData(bytes, {
          blobHTTPHeaders: { blobContentType: contentType }, abortSignal,
        });
      } else {
        await this.client!.send(new PutObjectCommand({ Bucket: this.bucket, Key: key, Body: bytes, ContentType: contentType }),
          { abortSignal });
      }
    } catch {
      throw new ServiceUnavailableException('Image storage is unavailable');
    }
  }

  async read(key: string): Promise<Buffer> {
    if (!this.client && !this.blob) throw new ServiceUnavailableException('Image storage is unavailable');
    try {
      const abortSignal = AbortSignal.timeout(30000);
      if (this.blob) return await this.blob.getBlobClient(key).downloadToBuffer(0, undefined, { abortSignal });
      const result = await this.client!.send(new GetObjectCommand({ Bucket: this.bucket, Key: key }), { abortSignal });
      if (!result.Body) throw new Error('Empty storage response');
      return Buffer.from(await result.Body.transformToByteArray());
    } catch (error) {
      if ((error instanceof S3ServiceException && error.$metadata.httpStatusCode === 404) ||
        (error instanceof RestError && error.code === 'BlobNotFound')) throw new NotFoundException();
      throw new ServiceUnavailableException('Image storage is unavailable');
    }
  }

  async delete(key: string): Promise<void> {
    const abortSignal = AbortSignal.timeout(10000);
    if (this.blob) {
      await this.blob.getBlobClient(key).deleteIfExists({ abortSignal });
      return;
    }
    if (!this.client) throw new ServiceUnavailableException('Image storage is unavailable');
    await this.client.send(new DeleteObjectCommand({ Bucket: this.bucket, Key: key }),
      { abortSignal });
  }

  onModuleDestroy() { this.client?.destroy(); }
}
