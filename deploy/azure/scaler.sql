\set ON_ERROR_STOP on
-- Run as ploggr_field. The scaler receives one number and has no table grants.
BEGIN;
CREATE OR REPLACE FUNCTION public.ploggr_field_work_due()
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = pg_catalog
AS $$
BEGIN
  IF to_regclass('public.plog_analysis') IS NULL THEN
    RETURN 0;
  END IF;
  RETURN (
    EXISTS (SELECT 1 FROM public.plog_analysis WHERE state IN ('queued', 'processing') AND next_run <= now()) OR
    EXISTS (SELECT 1 FROM public.evidence_deletion_queue WHERE next_attempt <= now()) OR
    EXISTS (SELECT 1 FROM public.plogs WHERE status = 'active' AND started_at < now() - interval '7 days') OR
    EXISTS (SELECT 1 FROM public.litter_reports WHERE collection_plog_id IS NULL AND status = 'uploading'
      AND created_at < now() - interval '2 days') OR
    EXISTS (SELECT 1 FROM public.garbage_evidence e JOIN public.plogs p ON p.id = e.plog_id
      WHERE e.uploaded_at IS NULL AND e.created_at < now() - interval '2 days' AND p.status = 'active')
  )::integer::bigint;
END;
$$;
REVOKE ALL ON FUNCTION public.ploggr_field_work_due() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ploggr_field_work_due() TO ploggr_field_scaler;
COMMIT;
