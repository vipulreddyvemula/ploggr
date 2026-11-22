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
} from 'class-validator';

export class SpotFields {
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
  @IsIn(['cleaned','remains','missing']) outcome!: 'cleaned' | 'remains' | 'missing';
  @IsOptional() @IsUUID('4') photoId?: string;
}

export class ReportPageQuery {
  @IsOptional() @IsUUID() before?: string;
}
