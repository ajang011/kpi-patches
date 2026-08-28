-- =====================================================================
-- 12_APPLY_V4_7_BACKUP_BOD_APPROVER.sql
-- =====================================================================
-- Adds a backup approver for KPI template approvals: if the primary BOD
-- member for a division (TRD/ITT/JCP) is unavailable, the HR Admin
-- account (hradmin.demo@ewhc.local) can step in and approve/disapprove/
-- edit on their behalf for ANY division.
--
-- Run this AFTER 10_APPLY_V4_5... and 11_APPLY_V4_6... have already
-- been applied. Non-destructive, safe to re-run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) MARK THE HR ADMIN ACCOUNT AS A KPI BOD APPROVER (BACKUP ROLE)
-- ---------------------------------------------------------------------

alter table public.employees
  add column if not exists is_kpi_bod_backup boolean not null default false;

update public.employees
set is_kpi_bod_approver = true,
    is_kpi_bod_backup = true
where lower(email) = 'hradmin.demo@ewhc.local';

-- ---------------------------------------------------------------------
-- 2) WHICH DIVISIONS EACH BACKUP APPROVER COVERS
-- ---------------------------------------------------------------------

create table if not exists public.kpi_bod_backup_scope (
  id uuid primary key default gen_random_uuid(),
  approver_id uuid not null references public.employees(id) on delete cascade,
  owner_code text not null check (owner_code in ('TRD','ITT','JCP')),
  constraint uq_kpi_bod_backup_scope unique (approver_id, owner_code)
);

alter table public.kpi_bod_backup_scope enable row level security;

drop policy if exists kpi_bod_backup_scope_select on public.kpi_bod_backup_scope;
create policy kpi_bod_backup_scope_select
on public.kpi_bod_backup_scope
for select
to authenticated
using (true);

drop policy if exists kpi_bod_backup_scope_manage on public.kpi_bod_backup_scope;
create policy kpi_bod_backup_scope_manage
on public.kpi_bod_backup_scope
for all
to authenticated
using (public.current_user_can_admin_kpi())
with check (public.current_user_can_admin_kpi());

grant select on public.kpi_bod_backup_scope to authenticated;
grant insert, update, delete on public.kpi_bod_backup_scope to authenticated;

-- HR Admin backs up all 3 divisions.
insert into public.kpi_bod_backup_scope (approver_id, owner_code)
select e.id, code.owner_code
from public.employees e
cross join (values ('TRD'), ('ITT'), ('JCP')) as code(owner_code)
where lower(e.email) = 'hradmin.demo@ewhc.local'
on conflict (approver_id, owner_code) do nothing;

-- ---------------------------------------------------------------------
-- 3) WIDEN THE PERMISSION CHECK: PRIMARY OWNER *OR* A BACKUP APPROVER
--    (Every other function -- bod_decide_kpi_template, edit, approve
--     all, and the templates RLS policy -- already calls this one
--     function, so they all inherit backup coverage automatically.)
-- ---------------------------------------------------------------------

create or replace function public.current_user_is_kpi_bod_approver_for_department(p_department_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    coalesce(public.kpi_bod_approver_for_department(p_department_id) = public.current_employee_id(), false)
    or exists (
      select 1
      from public.kpi_bod_backup_scope bs
      join public.department_executive_classification dec on dec.owner_code = bs.owner_code
      where dec.department_id = p_department_id
        and bs.approver_id = public.current_employee_id()
    );
$$;

grant execute on function public.current_user_is_kpi_bod_approver_for_department(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 4) HELPER: LIST BACKUP APPROVERS FOR A DEPARTMENT (used by notify)
-- ---------------------------------------------------------------------

create or replace function public.kpi_bod_backup_approvers_for_department(p_department_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select distinct bs.approver_id
  from public.kpi_bod_backup_scope bs
  join public.department_executive_classification dec on dec.owner_code = bs.owner_code
  join public.employees e on e.id = bs.approver_id
  where dec.department_id = p_department_id
    and e.is_active = true;
$$;

grant execute on function public.kpi_bod_backup_approvers_for_department(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 5) NOTIFY THE PRIMARY *AND* ANY BACKUP APPROVERS ON SUBMISSION
-- ---------------------------------------------------------------------

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
      select approver_id from public.kpi_bod_backup_approvers_for_department(new.department_id)
      where approver_id is distinct from v_approver_id
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
-- 6) VERIFICATION -- run after applying
-- ---------------------------------------------------------------------
-- select e.email, bs.owner_code
-- from public.kpi_bod_backup_scope bs
-- join public.employees e on e.id = bs.approver_id
-- order by bs.owner_code;
--
-- Expect 3 rows, all for hradmin.demo@ewhc.local (TRD, ITT, JCP).

notify pgrst, 'reload schema';
