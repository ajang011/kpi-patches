-- =====================================================================
-- 14b_APPLY_V4_9_BACKFILL_LOCKED_PERIODS.sql
-- =====================================================================
-- 14_APPLY_V4_9_KPI_VERSIONED_DEFINITIONS.sql already created the
-- kpi_definition_versions table, the resolve function, and the updated
-- activate_kpi_templates_for_period function successfully. Only its
-- backfill step failed for assignments in LOCKED periods (e.g. Q1
-- 2026), because of the existing trg_prevent_locked_assignment_changes
-- safety trigger blocking any write to kpi_assignments once a period
-- is locked.
--
-- This file finishes that backfill safely: it briefly disables that
-- one trigger, sets kpi_version_id (a new, purely additive metadata
-- column -- it does not touch rating, weight, target, or any graded
-- value), then immediately re-enables the trigger. No other protection
-- is weakened.
--
-- Safe to re-run.
-- =====================================================================

alter table public.kpi_assignments disable trigger trg_prevent_locked_assignment_changes;

do $$
declare
  v_kpi record;
  v_version_id uuid;
  v_backfilled int := 0;
begin
  for v_kpi in
    select k.id as kpi_id, k.code, k.description, k.objective, k.kpi_goal, k.measurement_tool, k.frequency_of_monitoring
    from public.kpis k
    where exists (
      select 1 from public.kpi_assignments ka where ka.kpi_id = k.id and ka.kpi_version_id is null
    )
  loop
    select id into v_version_id
    from public.kpi_definition_versions
    where kpi_code = v_kpi.code
    order by version_number asc
    limit 1;

    if v_version_id is null then
      insert into public.kpi_definition_versions (
        kpi_code, version_number, description, objective, kpi_goal,
        measurement_tool, frequency_of_monitoring
      )
      values (
        v_kpi.code, 1, v_kpi.description, v_kpi.objective, v_kpi.kpi_goal,
        v_kpi.measurement_tool, v_kpi.frequency_of_monitoring
      )
      returning id into v_version_id;
    end if;

    update public.kpi_assignments
    set kpi_version_id = v_version_id
    where kpi_id = v_kpi.kpi_id
      and kpi_version_id is null;

    get diagnostics v_backfilled = row_count;
    raise notice 'Backfilled % assignment(s) for KPI code %', v_backfilled, v_kpi.code;
  end loop;
end $$;

alter table public.kpi_assignments enable trigger trg_prevent_locked_assignment_changes;

-- ---------------------------------------------------------------------
-- VERIFICATION
-- ---------------------------------------------------------------------
-- select count(*) as total_assignments,
--        count(kpi_version_id) as with_version
-- from public.kpi_assignments;
-- (Both numbers should now match.)

notify pgrst, 'reload schema';
