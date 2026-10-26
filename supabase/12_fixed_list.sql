-- 12: Fixed invite list. Households only move between the invite list and reserves when you press a button.
-- Safe to run more than once. (The admin page fills this in from the current list the first time it opens.)
alter table public.invites add column if not exists on_list boolean;

create or replace function public.admin_set_list(p_list jsonb, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_check();
  update public.invites set on_list = p_on where id::text in (select jsonb_array_elements_text(p_list));
end $$;
revoke all on function public.admin_set_list(jsonb, boolean) from public, anon, authenticated;
grant execute on function public.admin_set_list(jsonb, boolean) to authenticated;
