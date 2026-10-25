-- 07: Reset button for test invites only (code starts with "test")
-- Safe to run more than once.
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
  update public.guests set attending = null, dietary = null where invite_id = p_id;
  update public.invites set responded_at = null, message = null,
         first_opened_at = null, last_opened_at = null where id = p_id;
  delete from public.rsvp_log where invite_id = p_id;
  return public.admin_invite_json(p_id);
end $$;
revoke all on function public.admin_reset_test(uuid) from public, anon, authenticated;
grant execute on function public.admin_reset_test(uuid) to authenticated;
