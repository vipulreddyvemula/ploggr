import source from './data-source';

async function main() {
  const [action, id] = process.argv.slice(2);
  if (
    !(action === 'list' && !id) &&
    !(action === 'hide' && /^[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}$/i.test(id ?? ''))
  ) {
    throw new Error('Use list or hide <report-uuid>');
  }
  await source.initialize();
  try {
    if (action === 'list') {
      const reports =
        await source.query(`SELECT r.id, r.category, count(*)::int AS flags, min(f.created_at) AS first_flag
        FROM litter_report_flags f JOIN litter_reports r ON r.id=f.report_id
        WHERE r.status IN ('open','collected') GROUP BY r.id ORDER BY flags DESC, first_flag`);
      console.table(reports);
    } else {
      const [result] = await source.query(
        `WITH hidden AS (UPDATE litter_reports SET status='hidden'
        WHERE id=$1 AND status IN ('open','collected','hidden') RETURNING id) SELECT count(*)::int AS n FROM hidden`,
        [id],
      );
      if (!result.n) throw new Error('Visible report not found');
      console.log('Report hidden from the map, detail and photo endpoints.');
    }
  } finally {
    await source.destroy();
  }
}
main().catch((error) => {
  console.error(
    error instanceof Error &&
      ['Use list or hide <report-uuid>', 'Visible report not found'].includes(error.message)
      ? error.message
      : 'Report moderation failed',
  );
  process.exitCode = 1;
});
