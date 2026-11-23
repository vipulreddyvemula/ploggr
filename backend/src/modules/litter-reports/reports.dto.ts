import { Type } from 'class-transformer';
import { GpsSample } from '../evidence/capture-metadata';
import {
  ArrayMaxSize,
  ArrayMinSize,
  ArrayUnique,
  IsArray,
  IsIn,
  IsLatitude,
  IsLongitude,
  IsOptional,
  IsString,
  IsUUID,
  MaxLength,
  ValidateNested,
} from 'class-validator';

export class SpotFields {
  @IsOptional() @IsString() @MaxLength(4096) captures?: string;
  @IsOptional() @IsUUID('4') previousReportId?: string;
  @IsOptional() @IsIn(['gps','manual']) locationSource?: 'gps' | 'manual';

  @IsOptional() @IsString() @MaxLength(160) place?: string;
  @IsLatitude() latitude!: string;
  @IsLongitude() longitude!: string;
  @IsIn(['Plastic', 'Paper', 'Glass', 'Metal', 'E-waste', 'Other']) category!: string;
  @IsString() @MaxLength(250) notes!: string;
}

export class CollectionFields extends SpotFields {
  @IsUUID() plogId!: string;
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(6)
  @ArrayUnique()
  @IsUUID('4', { each: true })
  photoIds!: string[];
}

export class MapQuery {
  @IsLatitude() south!: string;
  @IsLatitude() north!: string;
  @IsLongitude() west!: string;
  @IsLongitude() east!: string;
}

export class ObservationInput {
  @IsIn(['cleaned','remains','missing','present']) outcome!: 'cleaned' | 'remains' | 'missing' | 'present';
  @IsOptional() @IsUUID('4') photoId?: string;
  @IsOptional() @IsUUID('4') plogId?: string;
  @IsOptional() @ValidateNested() @Type(() => GpsSample) gps?: GpsSample;
}

export class ReportPageQuery {
  @IsOptional() @IsUUID() before?: string;
}
