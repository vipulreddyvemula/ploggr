import { BadRequestException, ConflictException } from '@nestjs/common';
import { isUUID } from 'class-validator';

export function deviceId(value?: string) {
  if (value == null) return null;
  if (!isUUID(value, '4')) throw new BadRequestException('Invalid recording device');
  return value.toLowerCase();
}

export function requireRecorder(recordingDevice: string | null, supplied?: string) {
  if (recordingDevice && recordingDevice !== deviceId(supplied)) {
    throw new ConflictException('This Plog is recording on another device');
  }
}
