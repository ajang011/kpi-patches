-- =====================================================================
-- 15b_APPLY_V4_10_NARROW_AUTOAPPROVE_TO_PRIMARY_ONLY.sql
-- =====================================================================
-- 15_APPLY_V4_10_FIX_TEMPLATE_AUTOAPPROVE.sql fixed the "any admin
-- auto-approves" bug, but its replacement check
-- (current_user_is_kpi_bod_approver_for_department) counts BACKUP
-- approvers too. Since hradmin.demo@ewhc.local is the backup for ALL
-- THREE divisions (TRD/ITT/JCP), it was still treated as "a valid
-- approver for every department" and therefore still self-approved
-- its own uploads -- which is exactly why the HR templates never
-- reached cfo.admin@ewhc.local's queue.
--
-- FIX: self-approve-on-upload now only applies to the exact PRIMARY
-- owner of that department (executive.admin / cfo.admin /
-- execvp.admin), never to a backup. Backups can still approve or
-- disapprove from the KPI Approvals queue when needed -- they just
-- can no longer bypass review by uploading it themselves.
--
-- Run this AFTER 15_APPLY_V4_10_FIX_TEMPLATE_AUTOAPPROVE.sql.
-- Safe to re-run.
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

  -- Only the department's EXACT PRIMARY Board owner can self-approve
  -- on upload -- backups (e.g. the HR Admin universal backup) can
  -- still decide via the KPI Approvals queue, but can never bypass
  -- review simply by being the one who uploaded it.
  v_status := case
    when public.kpi_bod_approver_for_department(p_department_id) = v_user then 'approved'
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
-- CORRECTED PREVIEW: reroute anything 'approved' where the uploader
-- was NOT the exact primary owner (backups no longer count as a free
-- pass), never activated, and never actually reviewed by anyone.
-- ---------------------------------------------------------------------

select t.id, t.title, t.status, t.target_quarter, t.target_year,
       d.name as department_name, e.email as uploaded_by_email,
       eo.email as correct_primary_approver_email
from public.kpi_templates t
join public.departments d on d.id = t.department_id
join public.employees e on e.id = t.uploaded_by
left join public.employees eo on eo.id = public.kpi_bod_approver_for_department(t.department_id)
where t.status = 'approved'
  and t.activated_period_id is null
  and not exists (
    select 1 from public.kpi_template_approvals a where a.template_id = t.id
  )
  and t.uploaded_by is distinct from public.kpi_bod_approver_for_department(t.department_id)
order by t.uploaded_at desc;

-- Once you've reviewed the list above, run this separately to reroute
-- them into the correct Board approver's queue:
--
-- update public.kpi_templates t
-- set status = 'for_review'
-- where t.status = 'approved'
--   and t.activated_period_id is null
--   and not exists (
--     select 1 from public.kpi_template_approvals a where a.template_id = t.id
--   )
--   and t.uploaded_by is distinct from public.kpi_bod_approver_for_department(t.department_id);

notify pgrst, 'reload schema';
