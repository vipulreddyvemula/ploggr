export type WeightEstimate = { estimateKg: number; minKg: number; maxKg: number };

export type PotentialImpact = {
  verification: 'unverified';
  avoidedKg: number;
  minKg: number;
  maxKg: number;
  baseline: string;
  alternative: string;
  region: string;
  version: string;
  source: string;
};

// EPA WARM v16, Exhibit 1-1. Values are MTCO₂e per US short ton of waste.
const source = 'https://www.epa.gov/system/files/documents/2024-01/warm_management_practices_v16_dec.pdf';
const scenarioFactors = [
  { material: 'PET plastic', types: ['Bottle'], landfill: 0.02, alternativeFactor: -1.04 },
  { material: 'HDPE plastic', types: ['Bottle'], landfill: 0.02, alternativeFactor: -0.76 },
  { material: 'PP plastic', types: ['Bottle', 'Takeaway container'], landfill: 0.02, alternativeFactor: -0.79 },
  { material: 'Cardboard', types: ['Box'], landfill: 0.18, alternativeFactor: -3.14 },
  { material: 'Glass', types: ['Bottle', 'Jar'], landfill: 0.02, alternativeFactor: -0.28 },
  { material: 'Aluminum', types: ['Can'], landfill: 0.02, alternativeFactor: -9.13 },
  { material: 'Steel', types: ['Can'], landfill: 0.02, alternativeFactor: -1.83 },
  { material: 'Rubber', types: ['Tire'], landfill: 0.02, alternativeFactor: -0.38 },
  { material: 'Organic', types: ['Food scraps'], landfill: 0.50, alternativeFactor: -0.15, alternative: 'Composting' },
];

export function potentialImpact(material: string, type: string, weight: WeightEstimate | null): PotentialImpact | null {
  const scenario = scenarioFactors.find((factor) => factor.material === material && factor.types.includes(type));
  if (!weight || !scenario) return null;
  const avoidedPerKg = (scenario.landfill - scenario.alternativeFactor) * 1000 / 907.18474;
  return {
    verification: 'unverified',
    avoidedKg: weight.estimateKg * avoidedPerKg,
    minKg: weight.minKg * avoidedPerKg,
    maxKg: weight.maxKg * avoidedPerKg,
    baseline: 'Landfill',
    alternative: scenario.alternative ?? 'Recycling',
    region: 'US national average',
    version: 'EPA WARM v16',
    source,
  };
}
