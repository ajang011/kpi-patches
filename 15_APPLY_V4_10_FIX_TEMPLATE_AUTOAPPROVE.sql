-- =====================================================================
-- 15_APPLY_V4_10_FIX_TEMPLATE_AUTOAPPROVE.sql
-- =====================================================================
-- BUG FOUND: save_kpi_template() had legacy logic from before the BOD
-- workflow existed:
--
--   v_status := case when public.current_user_can_admin_kpi() then
--               'approved' else 'for_review' end;
--
-- current_user_can_admin_kpi() is true for HR Admin / Executive-flagged
-- accounts in general -- NOT specific to the correct BOD approver for
-- that department. So when hradmin.demo@ewhc.local (which has HR Admin
-- Control access) submitted HR's own template, it was auto-approved on
-- the spot and never entered 'for_review' -- which is why it never
-- reached cfo.admin@ewhc.local's KPI Approvals queue.
--
-- FIX: a template is only ever auto-approved if the uploader IS the
-- correct BOD approver (or their backup) for that exact department.
-- Every other uploader -- including HR Admin, Executives, anyone else
-- with legacy admin flags -- now always goes through 'for_review' and
-- gets routed to the correct BOD member.
--
-- Run this AFTER 10/11/12/14 have already been applied. Safe to re-run.
-- =====================================================================

create or replace function public.save_kpi_template(
  p_department_id uuid,
  p_target_year int,
  p_target_quarter text,
  p_title text,
  p_file_name text,
  p_template_payload jsonb,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := public.current_employee_id();
  v_template_id uuid;
  v_version int;
  v_status text;
begin
  if p_target_quarter not in ('Q1','Q2','Q3','Q4') then
    raise exception 'Invalid target quarter: %', p_target_quarter;
  end if;

  if not public.current_user_can_submit_kpi_template_for_department(p_department_id) then
    raise exception 'Only HR/Admin, Department Head, or the Department Primary Grader can upload templates for this department.';
  end if;

  if exists (
    select 1 from public.kpi_templates
    where department_id = p_department_id
      and target_year = p_target_year
      and target_quarter = p_target_quarter
      and status in ('approved','activated')
  ) and not (
    public.current_user_can_admin_kpi()
    or public.current_user_is_kpi_bod_approver_for_department(p_department_id)
  ) then
    raise exception 'An approved or activated template already exists for this department and period. Ask the Board approver or HR/Admin to return or supersede it.';
  end if;

  select coalesce(max(version), 0) + 1 into v_version
  from public.kpi_templates
  where department_id = p_department_id
    and target_year = p_target_year
    and target_quarter = p_target_quarter;

  -- Only the department's own assigned Board approver (or backup) can
  -- self-approve on upload. Everyone else -- including HR Admin,
  -- Executives, or any other legacy admin-flagged account -- always
  -- goes through the Board review queue.
  v_status := case
    when public.current_user_is_kpi_bod_approver_for_department(p_department_id) then 'approved'
    else 'for_review'
  end;

  insert into public.kpi_templates (
    department_id, target_year, target_quarter, title, file_name,
    template_payload, notes, status, uploaded_by, version
  )
  values (
    p_department_id, p_target_year, p_target_quarter, trim(p_title), p_file_name,
    coalesce(p_template_payload, '[]'::jsonb), nullif(trim(coalesce(p_notes, '')), ''), v_status, v_user, v_version
  )
  returning id into v_template_id;

  insert into public.kpi_audit_events (event_type, department_id, actor_id, reason, after_data)
  values ('kpi_template_saved', p_department_id, v_user, p_notes,
          jsonb_build_object('template_id', v_template_id, 'target_year', p_target_year, 'target_quarter', p_target_quarter, 'version', v_version, 'status', v_status));

  -- NOTE: the dedicated trg_kpi_template_bod_notify trigger (added in
  -- 10_APPLY_V4_5) already fires on this INSERT when v_status =
  -- 'for_review' and notifies the correct department-scoped Board
  -- approver + backup. This block only adds a general-visibility
  -- notice; it is not the primary approval routing mechanism.
  if v_status = 'for_review' then
    insert into public.kpi_notifications (employee_id, recipient_id, notification_type, title, body, created_by)
    select distinct
      v_user,
      e.id,
      'next_quarter_template_ready',
      'KPI template submitted for review',
      'A ' || p_target_quarter || ' ' || p_target_year || ' KPI template was submitted and needs Board review.',
      v_user
    from public.employees e
    join public.roles r on r.id = e.role_id
    where e.is_active = true
      and r.name in ('executive','hr_admin');
  else
    insert into public.kpi_notifications (employee_id, recipient_id, notification_type, title, body, created_by)
    select distinct
      v_user,
      recipient_id,
      'next_quarter_template_ready',
      'KPI template approved',
      'The ' || p_target_quarter || ' ' || p_target_year || ' KPI template has been approved and is locked until the quarter begins.',
      v_user
    from (
      select v_user as recipient_id
      union
      select e.id
      from public.employees e
      join public.roles r on r.id = e.role_id
      where e.is_active = true
        and e.department_id = p_department_id
        and r.name = 'department_head'
      union
      select distinct e.default_primary_grader_id
      from public.employees e
      where e.is_active = true
        and e.department_id = p_department_id
        and e.default_primary_grader_id is not null
      union
      select e.id
      from public.employees e
      join public.roles r on r.id = e.role_id
      where e.is_active = true
        and r.name in ('executive','hr_admin')
    ) recipients
    where recipient_id is not null;
  end if;

  return v_template_id;
end;
$$;

grant execute on function public.save_kpi_template(uuid, int, text, text, text, jsonb, text) to authenticated;

-- ---------------------------------------------------------------------
-- FIX EXISTING MIS-ROUTED TEMPLATES ALREADY SITTING IN 'approved'
-- ---------------------------------------------------------------------
-- The HR Q2 2026 template (and any other still-untouched template that
-- was auto-approved this way, i.e. NOT actually reviewed by its real
-- Board approver) should be sent back into the review queue so it
-- reaches the correct BOD member. This targets templates that:
--   - are currently 'approved'
--   - were uploaded by someone who is NOT the department's real BOD
--     approver
--   - have never been activated (activated_period_id is null) and
--     have no recorded Board decision
-- Review the SELECT output first before uncommenting the UPDATE.

-- Preview affected rows (checks whether the UPLOADER was actually the
-- correct Board approver/backup for that department -- not whether the
-- account running this query happens to be):
select t.id, t.title, t.status, t.target_quarter, t.target_year,
       d.name as department_name, e.email as uploaded_by_email
from public.kpi_templates t
join public.departments d on d.id = t.department_id
join public.employees e on e.id = t.uploaded_by
where t.status = 'approved'
  and t.activated_period_id is null
  and not exists (
    select 1 from public.kpi_template_approvals a where a.template_id = t.id
  )
  and t.uploaded_by is distinct from public.kpi_bod_approver_for_department(t.department_id)
  and not exists (
    select 1 from public.kpi_bod_backup_approvers_for_department(t.department_id) backup_id
    where backup_id = t.uploaded_by
  )
order by t.uploaded_at desc;

-- Uncomment and run separately once you've reviewed the list above:
--
-- update public.kpi_templates t
-- set status = 'for_review'
-- where t.status = 'approved'
--   and t.activated_period_id is null
--   and not exists (
--     select 1 from public.kpi_template_approvals a where a.template_id = t.id
--   );

notify pgrst, 'reload schema';
