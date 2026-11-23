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
  IsInt,
  IsOptional,
  IsString,
  IsUUID,
  Max,
  MaxLength,
  Min,
  ValidateNested,
} from 'class-validator';

const categories = ['Plastic', 'Paper', 'Glass', 'Metal', 'E-waste', 'Other'];

export class SpotFields {
  @IsOptional() @IsString() @MaxLength(4096) captures?: string;
  @IsOptional() @IsUUID('4') previousReportId?: string;
  @IsOptional() @IsIn(['gps','manual']) locationSource?: 'gps' | 'manual';

  @IsOptional() @IsString() @MaxLength(160) place?: string;
  @IsLatitude() latitude!: string;
  @IsLongitude() longitude!: string;
  @IsIn(categories) category!: string;
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

export class DiscoverQuery extends MapQuery {
  @IsOptional() @IsIn(categories) category?: string;
  @IsOptional() @IsIn(['active', 'open', 'verification', 'collected'])
  status?: 'active' | 'open' | 'verification' | 'collected';
  @IsOptional() @IsIn(['nearest', 'newest']) sort?: 'nearest' | 'newest';
  @IsOptional() @IsLatitude() lat?: string;
  @IsOptional() @IsLongitude() lon?: string;
  @IsOptional() @Type(() => Number) @IsInt() @Min(1) @Max(50000) radius?: number;
  @IsOptional() @Type(() => Number) @IsInt() @Min(1) @Max(365) ageDays?: number;
  @IsOptional() @Type(() => Number) @IsInt() @Min(1) @Max(500) limit?: number;
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
