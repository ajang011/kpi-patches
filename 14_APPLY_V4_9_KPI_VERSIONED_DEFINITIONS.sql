-- =====================================================================
-- 14_APPLY_V4_9_KPI_VERSIONED_DEFINITIONS.sql
-- =====================================================================
-- Replaces the plain-snapshot idea (13_APPLY_V4_8) with a proper
-- versioned KPI definition history -- the "Slowly Changing Dimension"
-- pattern used in payroll/finance/compliance systems.
--
-- Do NOT run 13_APPLY_V4_8_KPI_HISTORY_SNAPSHOT.sql -- this file
-- supersedes it entirely. If 13 was already applied, this file still
-- works correctly on top of it (it only adds a new column/table, does
-- not remove anything).
--
-- What this adds:
--   - public.kpi_definition_versions: an append-only table. Every time
--     a KPI's description/objective/target/measurement/frequency
--     actually changes, a NEW version row is created (v1, v2, v3...).
--     Unchanged re-submissions reuse the existing version -- no bloat.
--   - kpi_assignments.kpi_version_id: each assignment points to the
--     EXACT version that was in effect when it was activated. That
--     pointer never moves, so historical quarters can never drift,
--     while still keeping one clean, non-duplicated version history
--     per KPI code that you can query/report on directly.
--
-- Run this AFTER 10/11/12 have already been applied. Non-destructive,
-- safe to re-run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) VERSION HISTORY TABLE
-- ---------------------------------------------------------------------

create table if not exists public.kpi_definition_versions (
  id uuid primary key default gen_random_uuid(),
  kpi_code text not null,
  version_number int not null,
  description text not null,
  objective text,
  kpi_goal text,
  measurement_tool text,
  frequency_of_monitoring text,
  department_id uuid references public.departments(id) on delete set null,
  source_template_id uuid references public.kpi_templates(id) on delete set null,
  first_period_id uuid references public.grading_periods(id) on delete set null,
  created_at timestamptz not null default now(),
  created_by uuid references public.employees(id) on delete set null,
  constraint uq_kpi_definition_version unique (kpi_code, version_number)
);

create index if not exists idx_kpi_definition_versions_code on public.kpi_definition_versions(kpi_code);

alter table public.kpi_definition_versions enable row level security;

drop policy if exists kpi_definition_versions_select on public.kpi_definition_versions;
create policy kpi_definition_versions_select
on public.kpi_definition_versions
for select
to authenticated
using (true);

drop policy if exists kpi_definition_versions_manage on public.kpi_definition_versions;
create policy kpi_definition_versions_manage
on public.kpi_definition_versions
for all
to authenticated
using (public.current_user_can_admin_kpi() or public.current_user_is_kpi_bod_approver())
with check (public.current_user_can_admin_kpi() or public.current_user_is_kpi_bod_approver());

grant select on public.kpi_definition_versions to authenticated;
grant insert, update, delete on public.kpi_definition_versions to authenticated;

-- ---------------------------------------------------------------------
-- 2) POINT EACH ASSIGNMENT AT THE EXACT VERSION IN EFFECT
-- ---------------------------------------------------------------------

alter table public.kpi_assignments
  add column if not exists kpi_version_id uuid references public.kpi_definition_versions(id) on delete set null;

create index if not exists idx_kpi_assignments_kpi_version on public.kpi_assignments(kpi_version_id);

-- ---------------------------------------------------------------------
-- 3) RESOLVE-OR-CREATE A VERSION FOR A GIVEN KPI CODE + CONTENT
--    Reuses the latest version if the content is unchanged; otherwise
--    creates a new version row. Called from activation below.
-- ---------------------------------------------------------------------

create or replace function public.resolve_kpi_definition_version(
  p_code text,
  p_description text,
  p_objective text,
  p_goal text,
  p_measurement text,
  p_frequency text,
  p_department_id uuid,
  p_template_id uuid,
  p_period_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_latest public.kpi_definition_versions%rowtype;
  v_next_version int;
  v_id uuid;
begin
  select * into v_latest
  from public.kpi_definition_versions
  where kpi_code = p_code
  order by version_number desc
  limit 1;

  if v_latest.id is not null
     and coalesce(v_latest.description, '') = coalesce(p_description, '')
     and coalesce(v_latest.objective, '') = coalesce(p_objective, '')
     and coalesce(v_latest.kpi_goal, '') = coalesce(p_goal, '')
     and coalesce(v_latest.measurement_tool, '') = coalesce(p_measurement, '')
     and coalesce(v_latest.frequency_of_monitoring, '') = coalesce(p_frequency, '')
  then
    return v_latest.id;
  end if;

  v_next_version := coalesce(v_latest.version_number, 0) + 1;

  insert into public.kpi_definition_versions (
    kpi_code, version_number, description, objective, kpi_goal,
    measurement_tool, frequency_of_monitoring, department_id,
    source_template_id, first_period_id, created_by
  )
  values (
    p_code, v_next_version, p_description, p_objective, p_goal,
    p_measurement, p_frequency, p_department_id,
    p_template_id, p_period_id, public.current_employee_id()
  )
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.resolve_kpi_definition_version(text, text, text, text, text, text, uuid, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 4) BACKFILL: GIVE EVERY EXISTING ASSIGNMENT A VERSION 1, BUILT FROM
--    TODAY'S kpis TABLE (BEST AVAILABLE APPROXIMATION FOR OLD DATA --
--    SAME CAVEAT AS ANY RETROACTIVE FIX: WE CANNOT RECOVER TEXT THAT
--    WAS NEVER RECORDED). ONE VERSION ROW PER DISTINCT CODE, REUSED
--    ACROSS ALL MATCHING ASSIGNMENTS -- NOT ONE PER ASSIGNMENT.
-- ---------------------------------------------------------------------

do $$
declare
  v_kpi record;
  v_version_id uuid;
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
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 5) ACTIVATION NOW RESOLVES (OR CREATES) A VERSION PER TEMPLATE ROW
--    AND STAMPS kpi_assignments.kpi_version_id -- NEVER TO CHANGE
--    AGAIN FOR THAT ASSIGNMENT.
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
  v_version_id uuid;
  v_assignment_id uuid;
  v_created int := 0;
  v_weight numeric;
  v_weight_text text;
  v_code text;
  v_title text;
  v_description text;
  v_target text;
  v_objective text;
  v_measurement text;
  v_frequency text;
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
      v_objective := nullif(v_row ->> 'Objective', '');
      v_measurement := coalesce(nullif(v_row ->> 'Measurement Method', ''), nullif(v_row ->> 'Measurement Tool', ''));
      v_frequency := nullif(v_row ->> 'Frequency', '');
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
        v_objective,
        v_target,
        v_measurement,
        v_frequency,
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

      v_version_id := public.resolve_kpi_definition_version(
        v_code, v_description, v_objective, v_target, v_measurement, v_frequency,
        v_template.department_id, v_template.id, p_period_id
      );

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
          period_id, employee_id, kpi_id, kpi_version_id, grader_id, target, weight,
          backup_grader_id, backup_grader_active, grader_assignment_notes
        )
        values (
          p_period_id, v_employee.id, v_kpi_id, v_version_id, v_grader, v_target, v_weight,
          v_backup, v_backup_active, nullif(trim(coalesce(v_employee.evaluation_assignment_notes, '')), '')
        )
        on conflict (period_id, employee_id, kpi_id) do update
        set grader_id = excluded.grader_id,
            target = excluded.target,
            weight = excluded.weight,
            backup_grader_id = excluded.backup_grader_id,
            backup_grader_active = excluded.backup_grader_active,
            grader_assignment_notes = excluded.grader_assignment_notes,
            kpi_version_id = excluded.kpi_version_id,
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
-- 6) VERIFICATION -- run after applying
-- ---------------------------------------------------------------------
-- -- Every assignment should now have a version pointer:
-- select count(*) as total_assignments,
--        count(kpi_version_id) as with_version
-- from public.kpi_assignments;
--
-- -- Full version history for one KPI code (replace with a real code):
-- select version_number, description, kpi_goal, created_at
-- from public.kpi_definition_versions
-- where kpi_code = 'YOUR-CODE-HERE'
-- order by version_number;

notify pgrst, 'reload schema';
