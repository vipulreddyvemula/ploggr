import { readFile } from 'node:fs/promises';
import { DataSource } from 'typeorm';
import { materials } from '../modules/field/litter-classification';
import source from './data-source';

type Factor = {
  region: string;
  material: string;
  pathway: string;
  factor: number;
  source: string;
  version: string;
};
type Rule = { version: string; materialPoints: Record<string, number>; carbonPointsPerKg: number };
type Policy = { factors?: Factor[]; rules?: Rule };
const label = (v: unknown) => typeof v === 'string' && v.trim().length > 0 && v.length <= 80;
const points = (v: unknown) => typeof v === 'number' && Number.isFinite(v) && v >= 0;
export async function importPolicy(db: DataSource, policy: Policy) {
  const { factors = [], rules } = policy;
  if (!Array.isArray(factors) || (!rules && !factors.length))
    throw new Error('Supply factors or scoring rules');
  if (
    factors.some(
      (f) =>
        !label(f.region) ||
        !materials.includes(f.material) ||
        !label(f.pathway) ||
        !label(f.version) ||
        !Number.isFinite(f.factor) ||
        typeof f.source !== 'string' ||
        !/^https:\/\//.test(f.source),
    )
  )
    throw new Error('Invalid disposal factor or source URL');
  if (
    rules &&
    (!label(rules.version) ||
      !points(rules.carbonPointsPerKg) ||
      !rules.materialPoints ||
      !Object.keys(rules.materialPoints).length ||
      Object.entries(rules.materialPoints).some(([k, v]) => !materials.includes(k) || !points(v)))
  )
    throw new Error('Invalid scoring rules');
  await db.transaction(async (tx) => {
    await tx.query("SELECT pg_advisory_xact_lock(hashtext('ploggr-impact-policy'))");
    for (const f of factors) {
      const rows = await tx.query(
        `INSERT INTO disposal_factors VALUES($1,$2,$3,$4,$5,$6)
        ON CONFLICT(region,material,pathway,version) DO UPDATE SET source=excluded.source
        WHERE disposal_factors.source=excluded.source AND disposal_factors.factor=excluded.factor RETURNING version`,
        [f.region, f.material, f.pathway, f.factor, f.source, f.version],
      );
      if (!rows.length) throw new Error('Use a new version when changing a published factor');
    }
    if (rules) {
      await tx.query('UPDATE impact_rules SET active=false WHERE active');
      const rows = await tx.query(
        `INSERT INTO impact_rules VALUES($1,$2,$3,true) ON CONFLICT(version) DO UPDATE SET active=true
        WHERE impact_rules.material_points=excluded.material_points AND impact_rules.carbon_points_per_kg=excluded.carbon_points_per_kg RETURNING version`,
        [rules.version, JSON.stringify(rules.materialPoints), rules.carbonPointsPerKg],
      );
      if (!rows.length) throw new Error('Use a new version when changing published rules');
    }
  });
}
async function main() {
  if (!process.argv[2]) throw new Error('Pass the path to an approved policy JSON file');
  const policy = JSON.parse(await readFile(process.argv[2], 'utf8'));
  await source.initialize();
  try {
    await importPolicy(source, policy);
  } finally {
    await source.destroy();
  }
}
if (require.main === module)
  main().catch((e) => {
    console.error(e instanceof Error ? e.message : 'Could not load policy');
    process.exitCode = 1;
  });
