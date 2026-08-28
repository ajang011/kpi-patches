-- =====================================================================
-- 10_APPLY_V4_5_BOD_KPI_TEMPLATE_APPROVAL.sql
-- =====================================================================
-- Adds a 3-person Board of Directors (BOD) approval workflow for KPI
-- templates submitted by Department Heads, on top of the existing
-- V4.4 package. Non-destructive: only adds columns, tables, functions,
-- a trigger, and a widened RLS policy. Safe to re-run.
--
-- What this delivers:
--   1) An APPROVED template automatically becomes the operative KPI
--      set for the quarter it was submitted for (immediately if that
--      quarter's grading period is already open, otherwise it stays
--      "approved" and the existing auto-activation job switches it on
--      the moment that quarter starts -- unchanged V4.4 behavior).
--   2) Exactly the 3 designated BOD accounts are notified by email/
--      in-app notification whenever a Head submits (or resubmits) a
--      template, with a link to open the approval screen and sign in.
--   3) Each BOD member gets Approve / Disapprove / Edit actions per
--      template, plus an "Approve All" bulk action for their pending
--      queue.
--
-- Run this AFTER 01_CLEAN_RESET_AND_INSTALL.sql (or 04/06/08 patches)
-- have already been applied.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0) OPTIONAL APP SETTINGS TABLE (used to build the email link)
-- ---------------------------------------------------------------------

create table if not exists public.app_settings (
  key text primary key,
  value text,
  updated_at timestamptz not null default now()
);

insert into public.app_settings (key, value)
values ('kpi_app_url', '')
on conflict (key) do nothing;

alter table public.app_settings enable row level security;

drop policy if exists app_settings_read_all on public.app_settings;
create policy app_settings_read_all
on public.app_settings
for select
to authenticated
using (true);

drop policy if exists app_settings_manage_admin on public.app_settings;
create policy app_settings_manage_admin
on public.app_settings
for all
to authenticated
using (public.current_user_can_admin_kpi())
with check (public.current_user_can_admin_kpi());

grant select on public.app_settings to authenticated;
grant insert, update on public.app_settings to authenticated;

-- After running this file, set your real app URL once, e.g.:
--   update public.app_settings set value = 'https://kpi.yourcompany.com'
--   where key = 'kpi_app_url';

-- ---------------------------------------------------------------------
-- 1) DESIGNATE THE 3 BOD APPROVERS
-- ---------------------------------------------------------------------

alter table public.employees
  add column if not exists is_kpi_bod_approver boolean not null default false;

create index if not exists idx_employees_kpi_bod_approver
  on public.employees(is_kpi_bod_approver)
  where is_kpi_bod_approver = true;

-- Seed with the 3 existing top-level accounts (TRD / ITT / JCP).
-- Change or add emails here if the real BOD members differ.
update public.employees
set is_kpi_bod_approver = true
where lower(email) in (
  'executive.admin@ewhc.local',
  'cfo.admin@ewhc.local',
  'execvp.admin@ewhc.local'
);

create or replace function public.current_user_is_kpi_bod_approver()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (
      select e.is_kpi_bod_approver
      from public.employees e
      where e.id = public.current_employee_id()
        and e.is_active = true
    ),
    false
  );
$$;

grant execute on function public.current_user_is_kpi_bod_approver() to authenticated;

create or replace function public.kpi_bod_required_approvals()
returns int
language sql
stable
security definer
set search_path = public
as $$
  select greatest(
    1,
    (select count(*)::int from public.employees where is_kpi_bod_approver = true and is_active = true)
  );
$$;

grant execute on function public.kpi_bod_required_approvals() to authenticated;

-- ---------------------------------------------------------------------
-- 2) PER-APPROVER DECISION LOG
-- ---------------------------------------------------------------------

create table if not exists public.kpi_template_approvals (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.kpi_templates(id) on delete cascade,
  approver_id uuid not null references public.employees(id) on delete restrict,
  decision text not null check (decision in ('approved', 'disapproved')),
  comments text,
  decided_at timestamptz not null default now(),
  constraint uq_kpi_template_approval unique (template_id, approver_id)
);

create index if not exists idx_kpi_template_approvals_template
  on public.kpi_template_approvals(template_id);

alter table public.kpi_template_approvals enable row level security;

drop policy if exists kpi_template_approvals_select on public.kpi_template_approvals;
create policy kpi_template_approvals_select
on public.kpi_template_approvals
for select
to authenticated
using (
  public.current_user_is_kpi_bod_approver()
  or public.current_user_can_admin_kpi()
  or exists (
    select 1
    from public.kpi_templates t
    where t.id = template_id
      and t.department_id = (select e.department_id from public.employees e where e.id = public.current_employee_id())
  )
);

drop policy if exists kpi_template_approvals_manage on public.kpi_template_approvals;
create policy kpi_template_approvals_manage
on public.kpi_template_approvals
for all
to authenticated
using (public.current_user_is_kpi_bod_approver() or public.current_user_can_admin_kpi())
with check (public.current_user_is_kpi_bod_approver() or public.current_user_can_admin_kpi());

grant select, insert, update, delete on public.kpi_template_approvals to authenticated;

-- ---------------------------------------------------------------------
-- 3) LET BOD APPROVERS SEE ALL TEMPLATES (NOT ONLY THEIR OWN DEPT)
-- ---------------------------------------------------------------------

drop policy if exists kpi_templates_select_scope on public.kpi_templates;
create policy kpi_templates_select_scope
on public.kpi_templates
for select
to authenticated
using (
  public.current_user_can_manage_periods()
  or public.current_user_is_kpi_bod_approver()
  or department_id = (select e.department_id from public.employees e where e.id = public.current_employee_id())
);

-- ---------------------------------------------------------------------
-- 4) NOTIFY THE 3 BOD APPROVERS WHENEVER A TEMPLATE ENTERS REVIEW
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
begin
  if new.status = 'for_review' and (tg_op = 'INSERT' or old.status is distinct from 'for_review') then

    -- A (re)submission starts a fresh review round.
    delete from public.kpi_template_approvals where template_id = new.id;

    select name into v_department_name from public.departments where id = new.department_id;
    select value into v_app_url from public.app_settings where key = 'kpi_app_url';
    v_app_url := nullif(trim(coalesce(v_app_url, '')), '');

    v_link := case
      when v_app_url is not null then v_app_url || '/?view=bod_approvals&template=' || new.id::text
      else 'Open the KPI system and go to KPI Approvals to review.'
    end;

    insert into public.kpi_notifications (employee_id, recipient_id, notification_type, title, body, created_by)
    select
      new.uploaded_by,
      e.id,
      'next_quarter_template_ready',
      'KPI template awaiting your Board approval',
      coalesce(v_department_name, 'A department') || ' submitted its ' || new.target_quarter || ' ' ||
        new.target_year || ' KPI template ("' || new.title || '") for Board review. ' ||
        'Please sign in and approve, disapprove, or edit it. ' || v_link,
      new.uploaded_by
    from public.employees e
    where e.is_kpi_bod_approver = true
      and e.is_active = true;

  end if;

  return new;
end;
$$;

drop trigger if exists trg_kpi_template_bod_notify on public.kpi_templates;
create trigger trg_kpi_template_bod_notify
after insert or update of status on public.kpi_templates
for each row execute function public.kpi_template_bod_notify();

-- ---------------------------------------------------------------------
-- 5) WIDEN activate_kpi_templates_for_period SO A FINAL BOD APPROVAL
--    CAN IMMEDIATELY ACTIVATE THE TEMPLATE FOR AN ALREADY-OPEN QUARTER
-- ---------------------------------------------------------------------

create or replace function public.activate_kpi_templates_for_period(p_period_id uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_period public.grading_periods%rowtype;
  v_template record;
  v_row jsonb;
  v_employee record;
  v_kpi_id uuid;
  v_assignment_id uuid;
  v_created int := 0;
  v_weight numeric;
  v_weight_text text;
  v_code text;
  v_title text;
  v_description text;
  v_target text;
  v_assignee text;
  v_grader uuid;
  v_backup uuid;
  v_backup_active boolean;
begin
  if not (public.current_user_can_admin_kpi() or public.current_user_is_kpi_bod_approver()) then
    raise exception 'Only Executive/HR Admin users or Board approvers can activate KPI templates.';
  end if;

  select * into v_period from public.grading_periods where id = p_period_id;
  if v_period.id is null then
    raise exception 'Selected grading period not found.';
  end if;
  if v_period.status is distinct from 'open' then
    raise exception 'Templates can only be activated for an open period.';
  end if;

  for v_template in
    select distinct on (department_id) *
    from public.kpi_templates
    where target_year = v_period.year
      and target_quarter = v_period.quarter
      and status = 'approved'
    order by department_id, version desc, uploaded_at desc
  loop
    if public.is_department_period_locked(p_period_id, v_template.department_id) then
      raise exception 'Cannot activate template for a department that is already locked.';
    end if;

    for v_row in select value from jsonb_array_elements(coalesce(v_template.template_payload, '[]'::jsonb))
    loop
      v_title := coalesce(nullif(v_row ->> 'KPI Title', ''), nullif(v_row ->> 'Title', ''), nullif(v_row ->> 'KPI Code', ''), 'Template KPI');
      v_description := coalesce(nullif(v_row ->> 'KPI Description', ''), nullif(v_row ->> 'Description', ''), v_title);
      v_target := coalesce(nullif(v_row ->> 'Target', ''), nullif(v_row ->> 'KPI Goal', ''), nullif(v_row ->> 'Goal', ''));
      v_assignee := lower(trim(coalesce(v_row ->> 'Assigned Role / Employee', v_row ->> 'Assigned Employee', v_row ->> 'Role', '')));
      v_weight_text := nullif(regexp_replace(coalesce(v_row ->> 'Weight', '1'), '[^0-9\.]', '', 'g'), '');
      v_weight := coalesce(v_weight_text::numeric, 1);
      if v_weight > 1 then
        v_weight := round(v_weight / 100.0, 4);
      end if;
      if v_weight <= 0 or v_weight > 1 then
        raise exception 'Invalid template KPI weight % in template %.', v_weight, v_template.title;
      end if;

      v_code := upper(regexp_replace(coalesce(nullif(v_row ->> 'KPI Code', ''), 'TPL-' || substr(md5(v_template.department_id::text || v_title), 1, 10)), '[^A-Za-z0-9_-]+', '_', 'g'));

      insert into public.kpis (code, description, objective, kpi_goal, measurement_tool, frequency_of_monitoring, is_active)
      values (
        v_code,
        v_description,
        nullif(v_row ->> 'Objective', ''),
        v_target,
        coalesce(nullif(v_row ->> 'Measurement Method', ''), nullif(v_row ->> 'Measurement Tool', '')),
        nullif(v_row ->> 'Frequency', ''),
        true
      )
      on conflict (code) do update
      set description = excluded.description,
          objective = excluded.objective,
          kpi_goal = excluded.kpi_goal,
          measurement_tool = excluded.measurement_tool,
          frequency_of_monitoring = excluded.frequency_of_monitoring,
          is_active = true
      returning id into v_kpi_id;

      for v_employee in
        select e.id, e.manager_id, e.default_primary_grader_id, e.default_backup_grader_id, e.default_backup_grader_active, e.evaluation_assignment_notes
        from public.employees e
        join public.roles r on r.id = e.role_id
        where e.is_active = true
          and e.department_id = v_template.department_id
          and (
            v_assignee = ''
            or v_assignee in ('all','all employees','department','department staff','staff','care team','team')
            or lower(e.email) = v_assignee
            or lower(e.full_name) = v_assignee
            or lower(replace(r.name, '_', ' ')) = v_assignee
            or lower(r.name) = replace(v_assignee, ' ', '_')
          )
      loop
        v_grader := coalesce(v_employee.default_primary_grader_id, v_employee.manager_id);
        v_backup := v_employee.default_backup_grader_id;
        v_backup_active := coalesce(v_employee.default_backup_grader_active, false);

        if v_grader is null then
          continue;
        end if;

        insert into public.kpi_assignments (
          period_id, employee_id, kpi_id, grader_id, target, weight,
          backup_grader_id, backup_grader_active, grader_assignment_notes
        )
        values (
          p_period_id, v_employee.id, v_kpi_id, v_grader, v_target, v_weight,
          v_backup, v_backup_active, nullif(trim(coalesce(v_employee.evaluation_assignment_notes, '')), '')
        )
        on conflict (period_id, employee_id, kpi_id) do update
        set grader_id = excluded.grader_id,
            target = excluded.target,
            weight = excluded.weight,
            backup_grader_id = excluded.backup_grader_id,
            backup_grader_active = excluded.backup_grader_active,
            grader_assignment_notes = excluded.grader_assignment_notes,
            updated_at = now()
        returning id into v_assignment_id;

        v_created := v_created + 1;
      end loop;
    end loop;

    update public.kpi_templates
    set status = 'activated',
        activated_period_id = p_period_id,
        reviewed_by = coalesce(reviewed_by, public.current_employee_id()),
        reviewed_at = coalesce(reviewed_at, now())
    where id = v_template.id;

    update public.kpi_templates
    set superseded_by = v_template.id
    where department_id = v_template.department_id
      and target_year = v_template.target_year
      and target_quarter = v_template.target_quarter
      and id <> v_template.id
      and status in ('draft','for_review','returned');

    insert into public.kpi_audit_events (event_type, period_id, department_id, actor_id, after_data)
    values ('kpi_template_activated', p_period_id, v_template.department_id, public.current_employee_id(),
            jsonb_build_object('template_id', v_template.id, 'version', v_template.version));
  end loop;

  return v_created;
end;
$$;

grant execute on function public.activate_kpi_templates_for_period(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 6) CORE DECISION RPC: APPROVE / DISAPPROVE
-- ---------------------------------------------------------------------

create or replace function public.bod_decide_kpi_template(
  p_template_id uuid,
  p_decision text,
  p_comments text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := public.current_employee_id();
  v_template public.kpi_templates%rowtype;
  v_required int;
  v_approved_count int;
  v_period_id uuid;
  v_activated_count int := 0;
  v_clean_comments text := nullif(trim(coalesce(p_comments, '')), '');
begin
  if not public.current_user_is_kpi_bod_approver() then
    raise exception 'Only designated Board of Directors approvers can decide on KPI templates.';
  end if;

  if p_decision not in ('approved', 'disapproved') then
    raise exception 'Invalid decision. Use approved or disapproved.';
  end if;

  select * into v_template from public.kpi_templates where id = p_template_id for update;
  if v_template.id is null then
    raise exception 'KPI template not found.';
  end if;

  if v_template.status <> 'for_review' then
    raise exception 'Only templates that are currently for review can be decided on.';
  end if;

  insert into public.kpi_template_approvals (template_id, approver_id, decision, comments)
  values (p_template_id, v_user, p_decision, v_clean_comments)
  on conflict (template_id, approver_id)
  do update set decision = excluded.decision, comments = excluded.comments, decided_at = now();

  -- ---------------- DISAPPROVE: return immediately to the Head ----------------
  if p_decision = 'disapproved' then
    update public.kpi_templates
    set status = 'returned',
        reviewed_by = v_user,
        reviewed_at = now(),
        notes = coalesce(v_clean_comments, notes)
    where id = p_template_id;

    delete from public.kpi_template_approvals where template_id = p_template_id;

    insert into public.kpi_audit_events (event_type, department_id, actor_id, reason, after_data)
    values ('kpi_template_returned_by_bod', v_template.department_id, v_user, v_clean_comments,
            jsonb_build_object('template_id', p_template_id, 'version', v_template.version));

    insert into public.kpi_notifications (employee_id, recipient_id, notification_type, title, body, created_by)
    select
      v_template.uploaded_by,
      recipient_id,
      'rating_returned',
      'KPI template returned by the Board',
      'Your ' || v_template.target_quarter || ' ' || v_template.target_year || ' KPI template ("' || v_template.title || '") was returned by the Board of Directors.' ||
        case when v_clean_comments is not null then ' Reason: ' || v_clean_comments else '' end,
      v_user
    from (
      select v_template.uploaded_by as recipient_id
      union
      select e.id from public.employees e
      join public.roles r on r.id = e.role_id
      where e.is_active = true and e.department_id = v_template.department_id and r.name = 'department_head'
    ) recipients
    where recipient_id is not null;

    return jsonb_build_object('status', 'returned');
  end if;

  -- ---------------- APPROVE: count toward the unanimous requirement ----------------
  select public.kpi_bod_required_approvals() into v_required;
  select count(*) into v_approved_count
  from public.kpi_template_approvals
  where template_id = p_template_id and decision = 'approved';

  if v_approved_count < v_required then
    return jsonb_build_object('status', 'pending', 'approvals', v_approved_count, 'required', v_required);
  end if;

  -- All BOD approvers are in: finalize the template.
  update public.kpi_templates
  set status = 'approved',
      reviewed_by = v_user,
      reviewed_at = now()
  where id = p_template_id;

  insert into public.kpi_audit_events (event_type, department_id, actor_id, after_data)
  values ('kpi_template_approved_by_bod', v_template.department_id, v_user,
          jsonb_build_object('template_id', p_template_id, 'version', v_template.version, 'approvals', v_approved_count));

  insert into public.kpi_notifications (employee_id, recipient_id, notification_type, title, body, created_by)
  select
    v_template.uploaded_by,
    recipient_id,
    'next_quarter_template_ready',
    'KPI template approved by the Board',
    'The ' || v_template.target_quarter || ' ' || v_template.target_year || ' KPI template ("' || v_template.title ||
      '") has been approved by all ' || v_required || ' Board approvers and will be used as the official KPI set for that quarter.',
    v_user
  from (
    select v_template.uploaded_by as recipient_id
    union
    select e.id from public.employees e
    join public.roles r on r.id = e.role_id
    where e.is_active = true and e.department_id = v_template.department_id and r.name = 'department_head'
    union
    select e.id from public.employees e where e.is_kpi_bod_approver = true and e.is_active = true
  ) recipients
  where recipient_id is not null;

  -- Requirement: an approved template becomes the KPI used for the quarter
  -- it was submitted for. If that quarter is already open, switch it on now.
  select id into v_period_id
  from public.grading_periods
  where year = v_template.target_year
    and quarter = v_template.target_quarter
    and status = 'open';

  if v_period_id is not null then
    select public.activate_kpi_templates_for_period(v_period_id) into v_activated_count;
  end if;

  return jsonb_build_object(
    'status', 'approved',
    'approvals', v_approved_count,
    'required', v_required,
    'activated_assignments', coalesce(v_activated_count, 0)
  );
end;
$$;

grant execute on function public.bod_decide_kpi_template(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 7) "APPROVE ALL" BULK ACTION FOR A BOD MEMBER'S PENDING QUEUE
-- ---------------------------------------------------------------------

create or replace function public.bod_approve_all_pending_kpi_templates(p_comments text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := public.current_employee_id();
  v_template_id uuid;
  v_result jsonb;
  v_total int := 0;
  v_finalized int := 0;
begin
  if not public.current_user_is_kpi_bod_approver() then
    raise exception 'Only designated Board of Directors approvers can approve KPI templates.';
  end if;

  for v_template_id in
    select t.id
    from public.kpi_templates t
    where t.status = 'for_review'
      and not exists (
        select 1 from public.kpi_template_approvals a
        where a.template_id = t.id and a.approver_id = v_user
      )
    order by t.uploaded_at asc
  loop
    v_result := public.bod_decide_kpi_template(v_template_id, 'approved', p_comments);
    v_total := v_total + 1;
    if (v_result ->> 'status') = 'approved' then
      v_finalized := v_finalized + 1;
    end if;
  end loop;

  return jsonb_build_object('processed', v_total, 'fully_approved', v_finalized);
end;
$$;

grant execute on function public.bod_approve_all_pending_kpi_templates(text) to authenticated;

-- ---------------------------------------------------------------------
-- 8) LET A BOD APPROVER (OR HR/ADMIN) EDIT A TEMPLATE WHILE FOR REVIEW
-- ---------------------------------------------------------------------

create or replace function public.bod_update_kpi_template(
  p_template_id uuid,
  p_title text default null,
  p_notes text default null,
  p_template_payload jsonb default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := public.current_employee_id();
  v_template public.kpi_templates%rowtype;
begin
  if not (public.current_user_is_kpi_bod_approver() or public.current_user_can_admin_kpi()) then
    raise exception 'Only Board approvers or HR/Admin can edit a KPI template under review.';
  end if;

  select * into v_template from public.kpi_templates where id = p_template_id for update;
  if v_template.id is null then
    raise exception 'KPI template not found.';
  end if;

  if v_template.status <> 'for_review' then
    raise exception 'Only templates that are currently for review can be edited here.';
  end if;

  update public.kpi_templates
  set title = coalesce(nullif(trim(p_title), ''), title),
      notes = coalesce(p_notes, notes),
      template_payload = coalesce(p_template_payload, template_payload)
  where id = p_template_id;

  -- Content changed: require every Board approver to review the new version.
  delete from public.kpi_template_approvals where template_id = p_template_id;

  insert into public.kpi_audit_events (event_type, department_id, actor_id, after_data)
  values ('kpi_template_edited_by_bod', v_template.department_id, v_user,
          jsonb_build_object('template_id', p_template_id, 'version', v_template.version));

  return true;
end;
$$;

grant execute on function public.bod_update_kpi_template(uuid, text, text, jsonb) to authenticated;

notify pgrst, 'reload schema';
-- =====================================================================
-- 11_APPLY_V4_6_DEPARTMENT_SCOPED_BOD_APPROVAL.sql
-- =====================================================================
-- Changes the KPI template approval model from "all 3 BOD must approve
-- every template" to "the ONE BOD member who owns that department's
-- division approves it" -- using the existing
-- public.department_executive_classification table (owner_code:
-- TRD / ITT / JCP) that already matches your division breakdown.
--
-- Run this AFTER 10_APPLY_V4_5_BOD_KPI_TEMPLATE_APPROVAL.sql.
-- Non-destructive, safe to re-run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) TAG EACH BOD ACCOUNT WITH THE DIVISION THEY OWN
-- ---------------------------------------------------------------------

alter table public.employees
  add column if not exists kpi_bod_owner_code text
  check (kpi_bod_owner_code in ('TRD','ITT','JCP'));

update public.employees set kpi_bod_owner_code = 'TRD' where lower(email) = 'executive.admin@ewhc.local';
update public.employees set kpi_bod_owner_code = 'ITT' where lower(email) = 'cfo.admin@ewhc.local';
update public.employees set kpi_bod_owner_code = 'JCP' where lower(email) = 'execvp.admin@ewhc.local';

-- ---------------------------------------------------------------------
-- 2) LOOK UP WHICH BOD MEMBER OWNS A GIVEN DEPARTMENT
-- ---------------------------------------------------------------------

create or replace function public.kpi_bod_approver_for_department(p_department_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select e.id
  from public.employees e
  join public.department_executive_classification dec on dec.owner_code = e.kpi_bod_owner_code
  where dec.department_id = p_department_id
    and e.is_kpi_bod_approver = true
    and e.is_active = true
  limit 1;
$$;

grant execute on function public.kpi_bod_approver_for_department(uuid) to authenticated;

create or replace function public.current_user_is_kpi_bod_approver_for_department(p_department_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.kpi_bod_approver_for_department(p_department_id) = public.current_employee_id(), false);
$$;

grant execute on function public.current_user_is_kpi_bod_approver_for_department(uuid) to authenticated;

-- A template now only needs ONE decision (the owning BOD member's).
create or replace function public.kpi_bod_required_approvals()
returns int
language sql
stable
security definer
set search_path = public
as $$
  select 1;
$$;

-- ---------------------------------------------------------------------
-- 3) BOD MEMBERS ONLY SEE TEMPLATES FROM THEIR OWN DIVISION
-- ---------------------------------------------------------------------

drop policy if exists kpi_templates_select_scope on public.kpi_templates;
create policy kpi_templates_select_scope
on public.kpi_templates
for select
to authenticated
using (
  public.current_user_can_manage_periods()
  or public.current_user_is_kpi_bod_approver_for_department(department_id)
  or department_id = (select e.department_id from public.employees e where e.id = public.current_employee_id())
);

-- ---------------------------------------------------------------------
-- 4) NOTIFY ONLY THE OWNING BOD MEMBER (NOT ALL 3, NOT HR)
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

  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 5) DECISION RPC NOW CHECKS THE DIVISION OWNER, NOT "ANY BOD MEMBER"
-- ---------------------------------------------------------------------

create or replace function public.bod_decide_kpi_template(
  p_template_id uuid,
  p_decision text,
  p_comments text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := public.current_employee_id();
  v_template public.kpi_templates%rowtype;
  v_required int;
  v_approved_count int;
  v_period_id uuid;
  v_activated_count int := 0;
  v_clean_comments text := nullif(trim(coalesce(p_comments, '')), '');
begin
  if p_decision not in ('approved', 'disapproved') then
    raise exception 'Invalid decision. Use approved or disapproved.';
  end if;

  select * into v_template from public.kpi_templates where id = p_template_id for update;
  if v_template.id is null then
    raise exception 'KPI template not found.';
  end if;

  if not public.current_user_is_kpi_bod_approver_for_department(v_template.department_id) then
    raise exception 'Only the Board member assigned to this department''s division can decide on this KPI template.';
  end if;

  if v_template.status <> 'for_review' then
    raise exception 'Only templates that are currently for review can be decided on.';
  end if;

  insert into public.kpi_template_approvals (template_id, approver_id, decision, comments)
  values (p_template_id, v_user, p_decision, v_clean_comments)
  on conflict (template_id, approver_id)
  do update set decision = excluded.decision, comments = excluded.comments, decided_at = now();

  if p_decision = 'disapproved' then
    update public.kpi_templates
    set status = 'returned',
        reviewed_by = v_user,
        reviewed_at = now(),
        notes = coalesce(v_clean_comments, notes)
    where id = p_template_id;

    delete from public.kpi_template_approvals where template_id = p_template_id;

    insert into public.kpi_audit_events (event_type, department_id, actor_id, reason, after_data)
    values ('kpi_template_returned_by_bod', v_template.department_id, v_user, v_clean_comments,
            jsonb_build_object('template_id', p_template_id, 'version', v_template.version));

    insert into public.kpi_notifications (employee_id, recipient_id, notification_type, title, body, created_by)
    select
      v_template.uploaded_by,
      recipient_id,
      'rating_returned',
      'KPI template returned by the Board',
      'Your ' || v_template.target_quarter || ' ' || v_template.target_year || ' KPI template ("' || v_template.title || '") was returned.' ||
        case when v_clean_comments is not null then ' Reason: ' || v_clean_comments else '' end,
      v_user
    from (
      select v_template.uploaded_by as recipient_id
      union
      select e.id from public.employees e
      join public.roles r on r.id = e.role_id
      where e.is_active = true and e.department_id = v_template.department_id and r.name = 'department_head'
    ) recipients
    where recipient_id is not null;

    return jsonb_build_object('status', 'returned');
  end if;

  select public.kpi_bod_required_approvals() into v_required;
  select count(*) into v_approved_count
  from public.kpi_template_approvals
  where template_id = p_template_id and decision = 'approved';

  if v_approved_count < v_required then
    return jsonb_build_object('status', 'pending', 'approvals', v_approved_count, 'required', v_required);
  end if;

  update public.kpi_templates
  set status = 'approved',
      reviewed_by = v_user,
      reviewed_at = now()
  where id = p_template_id;

  insert into public.kpi_audit_events (event_type, department_id, actor_id, after_data)
  values ('kpi_template_approved_by_bod', v_template.department_id, v_user,
          jsonb_build_object('template_id', p_template_id, 'version', v_template.version));

  insert into public.kpi_notifications (employee_id, recipient_id, notification_type, title, body, created_by)
  select
    v_template.uploaded_by,
    recipient_id,
    'next_quarter_template_ready',
    'KPI template approved',
    'The ' || v_template.target_quarter || ' ' || v_template.target_year || ' KPI template ("' || v_template.title ||
      '") has been approved and will be used as the official KPI set for that quarter.',
    v_user
  from (
    select v_template.uploaded_by as recipient_id
    union
    select e.id from public.employees e
    join public.roles r on r.id = e.role_id
    where e.is_active = true and e.department_id = v_template.department_id and r.name = 'department_head'
  ) recipients
  where recipient_id is not null;

  select id into v_period_id
  from public.grading_periods
  where year = v_template.target_year
    and quarter = v_template.target_quarter
    and status = 'open';

  if v_period_id is not null then
    select public.activate_kpi_templates_for_period(v_period_id) into v_activated_count;
  end if;

  return jsonb_build_object(
    'status', 'approved',
    'approvals', v_approved_count,
    'required', v_required,
    'activated_assignments', coalesce(v_activated_count, 0)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 6) "APPROVE ALL" NOW ONLY TOUCHES TEMPLATES IN THE CALLER'S OWN
--    DIVISION
-- ---------------------------------------------------------------------

create or replace function public.bod_approve_all_pending_kpi_templates(p_comments text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := public.current_employee_id();
  v_template_id uuid;
  v_result jsonb;
  v_total int := 0;
  v_finalized int := 0;
begin
  for v_template_id in
    select t.id
    from public.kpi_templates t
    where t.status = 'for_review'
      and public.current_user_is_kpi_bod_approver_for_department(t.department_id)
    order by t.uploaded_at asc
  loop
    v_result := public.bod_decide_kpi_template(v_template_id, 'approved', p_comments);
    v_total := v_total + 1;
    if (v_result ->> 'status') = 'approved' then
      v_finalized := v_finalized + 1;
    end if;
  end loop;

  return jsonb_build_object('processed', v_total, 'fully_approved', v_finalized);
end;
$$;

-- ---------------------------------------------------------------------
-- 7) EDIT PERMISSION ALSO SCOPED TO THE OWNING BOD MEMBER
-- ---------------------------------------------------------------------

create or replace function public.bod_update_kpi_template(
  p_template_id uuid,
  p_title text default null,
  p_notes text default null,
  p_template_payload jsonb default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := public.current_employee_id();
  v_template public.kpi_templates%rowtype;
begin
  select * into v_template from public.kpi_templates where id = p_template_id for update;
  if v_template.id is null then
    raise exception 'KPI template not found.';
  end if;

  if not (public.current_user_is_kpi_bod_approver_for_department(v_template.department_id) or public.current_user_can_admin_kpi()) then
    raise exception 'Only the Board member assigned to this division, or HR/Admin, can edit this KPI template.';
  end if;

  if v_template.status <> 'for_review' then
    raise exception 'Only templates that are currently for review can be edited here.';
  end if;

  update public.kpi_templates
  set title = coalesce(nullif(trim(p_title), ''), title),
      notes = coalesce(p_notes, notes),
      template_payload = coalesce(p_template_payload, template_payload)
  where id = p_template_id;

  delete from public.kpi_template_approvals where template_id = p_template_id;

  insert into public.kpi_audit_events (event_type, department_id, actor_id, after_data)
  values ('kpi_template_edited_by_bod', v_template.department_id, v_user,
          jsonb_build_object('template_id', p_template_id, 'version', v_template.version));

  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- 8) VERIFICATION -- run these after applying to confirm the mapping
-- ---------------------------------------------------------------------
-- select email, kpi_bod_owner_code from public.employees where is_kpi_bod_approver = true;
-- select dec.display_name, dec.owner_code, e.email as approver_email
-- from public.department_executive_classification dec
-- left join public.employees e on e.kpi_bod_owner_code = dec.owner_code and e.is_kpi_bod_approver = true
-- order by dec.sort_order;

notify pgrst, 'reload schema';
