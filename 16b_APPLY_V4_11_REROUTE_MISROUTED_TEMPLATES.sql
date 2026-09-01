-- =====================================================================
-- 16b_APPLY_V4_11_REROUTE_MISROUTED_TEMPLATES.sql
-- =====================================================================
-- The trg_prevent_locked_template_overwrite safety trigger blocks any
-- UPDATE that moves a template OUT of 'approved' status (except into
-- 'activated') -- by design, to stop accidental edits to
-- already-approved templates.
--
-- For this one-time correction (routing templates that were wrongly
-- auto-approved by the pre-fix bug back into the correct BOD's review
-- queue), we briefly disable that one trigger, run the reroute, then
-- immediately re-enable it. No other protection is weakened.
--
-- Safe to re-run (re-running finds nothing left to reroute).
-- =====================================================================

alter table public.kpi_templates disable trigger trg_prevent_locked_template_overwrite;

update public.kpi_templates t
set status = 'for_review'
where t.status = 'approved'
  and t.activated_period_id is null
  and t.target_quarter in ('Q1','Q2','Q3')
  and not exists (
    select 1 from public.kpi_template_approvals a where a.template_id = t.id
  )
  and t.uploaded_by is distinct from public.kpi_bod_approver_for_department(t.department_id);

alter table public.kpi_templates enable trigger trg_prevent_locked_template_overwrite;

-- ---------------------------------------------------------------------
-- VERIFICATION
-- ---------------------------------------------------------------------
-- select status, count(*) from public.kpi_templates
-- where target_quarter in ('Q1','Q2','Q3')
-- group by status order by status;
--
-- select t.title, t.target_quarter, t.target_year, d.name as department_name,
--        eo.email as now_pending_with
-- from public.kpi_templates t
-- join public.departments d on d.id = t.department_id
-- left join public.employees eo on eo.id = public.kpi_bod_approver_for_department(t.department_id)
-- where t.status = 'for_review'
-- order by t.target_year, t.target_quarter;

notify pgrst, 'reload schema';
