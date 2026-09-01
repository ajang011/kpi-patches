-- =====================================================================
-- 16_APPLY_V4_11_FIX_BACKUP_NOTIFY_BUG.sql
-- =====================================================================
-- BUG FOUND: kpi_template_bod_notify() (the trigger that fires whenever
-- a KPI template enters 'for_review') had:
--
--   for v_backup_id in
--     select approver_id from public.kpi_bod_backup_approvers_for_department(new.department_id)
--     ...
--
-- kpi_bod_backup_approvers_for_department() RETURNS SETOF uuid -- a
-- plain list of UUIDs, not a table with a column literally named
-- "approver_id". Selecting a non-existent "approver_id" column threw:
-- "column approver_id does not exist" (42703) -- which is exactly the
-- error hit while submitting a KPI template, since this trigger fires
-- on every INSERT with status = 'for_review'.
--
-- FIX: reference the function's scalar output correctly via a range
-- alias, the same pattern already used correctly elsewhere in
-- 15_APPLY_V4_10.
--
-- Run this AFTER 10/11/12/14/15 have already been applied.
-- Safe to re-run.
-- =====================================================================

create or replace function public.kpi_template_bod_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_department_name text;
  v_app_url text;
  v_link text;
  v_approver_id uuid;
  v_backup_id uuid;
begin
  if new.status = 'for_review' and (tg_op = 'INSERT' or old.status is distinct from 'for_review') then

    delete from public.kpi_template_approvals where template_id = new.id;

    select name into v_department_name from public.departments where id = new.department_id;
    select value into v_app_url from public.app_settings where key = 'kpi_app_url';
    v_app_url := nullif(trim(coalesce(v_app_url, '')), '');

    v_link := case
      when v_app_url is not null then v_app_url || '/?view=bod_approvals&template=' || new.id::text
      else 'Open the KPI system and go to KPI Approvals to review.'
    end;

    v_approver_id := public.kpi_bod_approver_for_department(new.department_id);

    if v_approver_id is not null then
      insert into public.kpi_notifications (employee_id, recipient_id, notification_type, title, body, created_by)
      values (
        new.uploaded_by,
        v_approver_id,
        'next_quarter_template_ready',
        'KPI template awaiting your approval',
        coalesce(v_department_name, 'A department') || ' submitted its ' || new.target_quarter || ' ' ||
          new.target_year || ' KPI template ("' || new.title || '") for your approval. ' ||
          'Please sign in and approve, disapprove, or edit it. ' || v_link,
        new.uploaded_by
      );
    end if;

    for v_backup_id in
      select bid
      from public.kpi_bod_backup_approvers_for_department(new.department_id) as bid
      where bid is distinct from v_approver_id
    loop
      insert into public.kpi_notifications (employee_id, recipient_id, notification_type, title, body, created_by)
      values (
        new.uploaded_by,
        v_backup_id,
        'next_quarter_template_ready',
        'KPI template awaiting approval (you are a backup approver)',
        coalesce(v_department_name, 'A department') || ' submitted its ' || new.target_quarter || ' ' ||
          new.target_year || ' KPI template ("' || new.title || '") for approval. ' ||
          'You are the backup approver for this division. ' || v_link,
        new.uploaded_by
      );
    end loop;

  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- VERIFICATION -- run after applying
-- ---------------------------------------------------------------------
-- Re-run the debug insert to confirm the trigger no longer errors:
--
-- insert into public.kpi_templates (
--   department_id, target_year, target_quarter, title, file_name,
--   template_payload, notes, status, uploaded_by, version
-- )
-- values (
--   '10000000-0000-0000-0000-000000000004', 2026, 'Q4', 'Debug Trigger Test 2',
--   'debug.csv', '[]'::jsonb, 'debug', 'for_review',
--   (select id from public.employees where email = 'hradmin.demo@ewhc.local'),
--   999
-- )
-- returning id;
--
-- If it returns an id with no error, the fix worked. Clean it up after:
-- delete from public.kpi_templates where title = 'Debug Trigger Test 2';

notify pgrst, 'reload schema';
