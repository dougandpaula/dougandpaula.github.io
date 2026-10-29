-- 16: View-only admin logins. Editors can change things; viewers can only look.
-- Safe to run more than once.
alter table public.admins add column if not exists role text not null default 'editor';

create or replace function public.is_editor() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins
                 where email = lower(coalesce(auth.jwt()->>'email', '')) and role = 'editor')
$$;
revoke all on function public.is_editor() from public, anon, authenticated;
grant execute on function public.is_editor() to authenticated;

-- Every change goes through admin_check, so it now needs an editor ...
create or replace function public.admin_check() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_editor() then raise exception 'Not authorised' using errcode = '42501'; end if;
end $$;

-- ... and looking only needs any admin login
create or replace function public.admin_view_check() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not authorised' using errcode = '42501'; end if;
end $$;

create or replace function public.admin_data() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_view_check();
  return jsonb_build_object(
    'invites', coalesce((select jsonb_agg(public.admin_invite_json(id)
                 order by case when priority ~ '^[0-9.]+$' then priority::numeric else 999 end, household_name)
               from public.invites), '[]'::jsonb),
    'settings', coalesce((select jsonb_object_agg(key, value) from public.settings), '{}'::jsonb),
    'role', case when public.is_editor() then 'editor' else 'viewer' end);
end $$;

create or replace function public.admin_rsvp_log(p_invite uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_view_check();
  return coalesce((select jsonb_agg(jsonb_build_object(
            'invite_id', l.invite_id, 'household', l.household, 'submitted_at', l.submitted_at,
            'confirmed', l.confirmed, 'confirm_text', l.confirm_text, 'answers', l.answers)
          order by l.submitted_at desc)
          from public.rsvp_log l where p_invite is null or l.invite_id = p_invite), '[]'::jsonb);
end $$;

create or replace function public.admin_todos() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_view_check();
  return coalesce((select jsonb_agg(to_jsonb(t) order by t.due nulls last, t.created_at) from public.todos t), '[]'::jsonb);
end $$;

revoke all on function public.admin_view_check(), public.admin_invite_json(uuid) from public, anon, authenticated;
grant execute on function public.admin_view_check() to authenticated;

-- Direct table access: anyone logged in as an admin can read, only editors can change
drop policy if exists admin_all on public.invites;
drop policy if exists admin_all on public.guests;
drop policy if exists admin_all on public.settings;
do $$ declare t text; begin
  foreach t in array array['invites', 'guests', 'settings'] loop
    execute format('drop policy if exists admin_read on public.%I', t);
    execute format('drop policy if exists editor_insert on public.%I', t);
    execute format('drop policy if exists editor_update on public.%I', t);
    execute format('drop policy if exists editor_delete on public.%I', t);
    execute format('create policy admin_read on public.%I for select to authenticated using (public.is_admin())', t);
    execute format('create policy editor_insert on public.%I for insert to authenticated with check (public.is_editor())', t);
    execute format('create policy editor_update on public.%I for update to authenticated using (public.is_editor()) with check (public.is_editor())', t);
    execute format('create policy editor_delete on public.%I for delete to authenticated using (public.is_editor())', t);
  end loop;
end $$;
