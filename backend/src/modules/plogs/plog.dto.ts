import { Type } from 'class-transformer';
import {
  ArrayMaxSize, IsArray, IsInt, IsISO8601, IsNumber, IsObject, Matches, Max, Min, ValidateNested,
} from 'class-validator';

class RouteFix {
  @IsNumber() @Min(-90) @Max(90)
  latitude!: number;

  @IsNumber() @Min(-180) @Max(180)
  longitude!: number;
}

export class FinishPlogDto {
  @IsISO8601({ strict: true })
  @Matches(/T.*(?:Z|[+-]\d{2}:\d{2})$/)
  endedAt!: string;

  @IsInt() @Min(0) @Max(2147483647)
  durationSeconds!: number;

  @IsNumber() @Min(0)
  distanceMeters!: number;

  @IsArray() @ArrayMaxSize(20000) @IsObject({ each: true })
  @ValidateNested({ each: true }) @Type(() => RouteFix)
  route!: RouteFix[];
}
