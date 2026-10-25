-- 08: Save the date (separate link per household, sent to the household lead by text)
-- Safe to run more than once.

-- 1. Columns ------------------------------------------------------------------
alter table public.invites add column if not exists std_code text unique;
alter table public.invites add column if not exists std_sent_at timestamptz;
alter table public.invites add column if not exists std_opened_at timestamptz;
alter table public.invites add column if not exists std_answer text;          -- saved | cant | some
alter table public.invites add column if not exists std_answered_at timestamptz;
alter table public.guests  add column if not exists std_cant boolean not null default false;

-- 2. Short random codes, e.g. "k7m2qx" (no 0/o/1/l/i to avoid mix-ups) ---------
create or replace function public.new_std_code() returns text
language plpgsql volatile set search_path = public as $$
declare c text; abc text := 'abcdefghjkmnpqrstuvwxyz23456789';
begin
  loop
    c := '';
    for k in 1..6 loop c := c || substr(abc, 1 + floor(random() * length(abc))::int, 1); end loop;
    exit when not exists (select 1 from public.invites where std_code = c);
  end loop;
  return c;
end $$;

create or replace function public.make_std_code() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.std_code is null or new.std_code = '' then new.std_code := public.new_std_code(); end if;
  return new;
end $$;
drop trigger if exists invites_std_code on public.invites;
create trigger invites_std_code before insert on public.invites
for each row execute function public.make_std_code();

do $$ declare r record; begin
  for r in select id from public.invites where std_code is null loop
    update public.invites set std_code = public.new_std_code() where id = r.id;
  end loop;
end $$;

-- 3. Guest side: open the save the date, and answer it ------------------------
create or replace function public.get_std(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.invites;
begin
  update public.invites set std_opened_at = coalesce(std_opened_at, now())
   where std_code = lower(trim(p_code)) returning * into v;
  if v.id is null then return null; end if;
  return jsonb_build_object(
    'answer', v.std_answer, 'answered_at', v.std_answered_at,
    'guests', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'age_group', g.age_group, 'cant', g.std_cant)
                         order by g.sort_order, g.created_at)
                        from public.guests g where g.invite_id = v.id and not g.is_plus_one), '[]'::jsonb));
end $$;

create or replace function public.answer_std(p_code text, p_answer text, p_cant jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.invites; n int;
begin
  select * into v from public.invites where std_code = lower(trim(p_code));
  if v.id is null then raise exception 'Not found'; end if;
  if p_answer not in ('saved', 'cant', 'some') then raise exception 'Bad answer'; end if;
  update public.guests g set std_cant = case
           when p_answer = 'cant' then true
           when p_answer = 'some' then g.id::text in (select jsonb_array_elements_text(coalesce(p_cant, '[]'::jsonb)))
           else false end
   where g.invite_id = v.id and not g.is_plus_one;
  if p_answer = 'some' then
    select count(*) into n from public.guests where invite_id = v.id and not is_plus_one and std_cant;
    if n = 0 then p_answer := 'saved';
    elsif n = (select count(*) from public.guests where invite_id = v.id and not is_plus_one) then p_answer := 'cant'; end if;
  end if;
  update public.invites set std_answer = p_answer, std_answered_at = now(),
         std_opened_at = coalesce(std_opened_at, now()) where id = v.id;
  return public.get_std(p_code);
end $$;

revoke all on function public.get_std(text), public.answer_std(text, text, jsonb), public.new_std_code(), public.make_std_code() from public, anon, authenticated;
grant execute on function public.get_std(text), public.answer_std(text, text, jsonb) to anon, authenticated;

-- 4. Admin: mark a batch as sent (or not sent) --------------------------------
create or replace function public.admin_mark_std_sent(p_list jsonb, p_sent boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_check();
  update public.invites set std_sent_at = case when p_sent then coalesce(std_sent_at, now()) end
   where id::text in (select jsonb_array_elements_text(p_list));
end $$;
revoke all on function public.admin_mark_std_sent(jsonb, boolean) from public, anon, authenticated;
grant execute on function public.admin_mark_std_sent(jsonb, boolean) to authenticated;

-- 5. Reset test also clears the save the date ---------------------------------
create or replace function public.admin_reset_test(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c text;
begin
  perform public.admin_check();
  select code into c from public.invites where id = p_id;
  if c is null or c not like 'test%' then
    raise exception 'Only test invites can be reset';
  end if;
  delete from public.guests where invite_id = p_id and is_plus_one;
  update public.guests set attending = null, dietary = null, std_cant = false where invite_id = p_id;
  update public.invites set responded_at = null, message = null,
         first_opened_at = null, last_opened_at = null,
         std_sent_at = null, std_opened_at = null, std_answer = null, std_answered_at = null where id = p_id;
  delete from public.rsvp_log where invite_id = p_id;
  return public.admin_invite_json(p_id);
end $$;
revoke all on function public.admin_reset_test(uuid) from public, anon, authenticated;
grant execute on function public.admin_reset_test(uuid) to authenticated;
