-- 15: Wedding to-do list with costs. Safe to run more than once (the starter list is only added once).
create table if not exists public.todos (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  category text,
  due date,
  owner text,                 -- Doug | Paula | Both
  supplier text,              -- name, phone, email, booking ref
  cost numeric(10,2),         -- quoted / agreed total
  paid numeric(10,2),         -- paid so far
  notes text,
  done_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.todos enable row level security;
revoke all on public.todos from anon, authenticated;

create or replace function public.admin_todos() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_check();
  return coalesce((select jsonb_agg(to_jsonb(t) order by t.due nulls last, t.created_at) from public.todos t), '[]'::jsonb);
end $$;

create or replace function public.admin_save_todo(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare tid uuid := nullif(p->>'id', '')::uuid;
begin
  perform public.admin_check();
  if tid is null then
    insert into public.todos (title) values (coalesce(nullif(trim(p->>'title'), ''), 'New task')) returning id into tid;
  end if;
  update public.todos set
    title = coalesce(nullif(trim(p->>'title'), ''), title),
    category = nullif(trim(p->>'category'), ''),
    due = nullif(p->>'due', '')::date,
    owner = nullif(p->>'owner', ''),
    supplier = nullif(trim(p->>'supplier'), ''),
    cost = nullif(p->>'cost', '')::numeric,
    paid = nullif(p->>'paid', '')::numeric,
    notes = nullif(trim(p->>'notes'), ''),
    done_at = case when (p->>'done')::boolean then coalesce(done_at, now()) else null end
  where id = tid;
  return (select to_jsonb(t) from public.todos t where t.id = tid);
end $$;

create or replace function public.admin_delete_todo(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_check();
  delete from public.todos where id = p_id;
end $$;

revoke all on function public.admin_todos(), public.admin_save_todo(jsonb), public.admin_delete_todo(uuid) from public, anon, authenticated;
grant execute on function public.admin_todos(), public.admin_save_todo(jsonb), public.admin_delete_todo(uuid) to authenticated;

-- Starter list (dates are suggestions, change them freely)
insert into public.todos (category, title, due, owner, supplier, notes)
select * from (values
  ('Venue', 'Read the Wedding Journal thoroughly', date '2026-11-30', 'Both', null, 'Paying the deposit counts as accepting it. A revised copy is coming next month.'),
  ('Venue', 'Second venue payment (same as the first deposit)', date '2027-01-01', 'Both', 'Friern Manor · 01268 494204 · weddings@friernmanor.com', 'Due no later than 1st January 2027. Pay through the portal.'),
  ('Venue', 'Planning Meeting Questionnaire', date '2027-04-24', 'Both', 'Friern Manor portal', 'Sent before the planning meeting.'),
  ('Venue', 'Planning meeting with the Wedding Co-ordinators', date '2027-05-01', 'Both', 'Friern Manor · 01268 494204', '10–14 weeks before (May 2027). Menu, bar, candles, free-from plates and the day confirmed. Pro-forma invoice follows within 10 working days.'),
  ('Venue', 'Decide the bar: pay bar, account bar, tokens or soft drinks', date '2027-05-01', 'Both', null, 'Bar tab is settled on the night by card. Interim payments may be asked for between £2,500 and £3,250.'),
  ('Venue', 'Candles for the candelabras', date '2027-05-01', 'Both', 'Friern Manor', '£6 per candelabra (about 5 hours) or £9.50 to keep them lit all evening.'),
  ('Venue', 'Card box: hire Midnight Star post box or make a sealed box', date '2027-05-01', 'Both', 'Midnight Star · 07961 969490', 'Essential: the venue needs a secure box for cards. Tell guests not to post cards to the venue.'),
  ('Venue', 'Room Reservations Form (extra bedrooms)', date '2027-05-15', 'Both', 'Wedding portal · TO DO tab', 'At least 12 weeks before, or the rooms are released.'),
  ('Venue', 'Pay the pro-forma invoice balance', date '2027-07-10', 'Both', 'Friern Manor', '28 days before the wedding.'),
  ('Venue', 'Nominate our "responsible person" for the day', date '2027-07-01', 'Both', null, 'One guest the venue can go to if needed (not us).'),
  ('Venue', 'Final numbers and confirmation meeting', date '2027-07-30', 'Both', 'Friern Manor', '7–10 days before. Numbers are final after this. Hand over the guest book, pen and small items. Don''t forget to count ourselves.'),
  ('Legal', 'Book the registrar', date '2026-11-15', 'Both', 'Essex Registration Service · 0345 603 7632 · essex.gov.uk', 'Choose "Approved Premises" and 3pm (must match the contract).'),
  ('Legal', 'Give notice of marriage (both of us, in person)', date '2027-06-30', 'Both', 'Local register office', 'Within 12 months and no later than 29 days before (by 9th July 2027). A fee for each of us.'),
  ('Legal', 'Registrar ceremony planner: readings, vows, music, witnesses', date '2027-06-01', 'Both', 'Essex Registration Service', 'Readings, personal vows and music must be approved by the registrar. Nothing religious.'),
  ('Ceremony', 'Choose ceremony music (arrival, two for signing, exit)', date '2027-05-01', 'Both', 'Paul Bleach · 07721 588451', null),
  ('Ceremony', 'Choose witnesses (2 to 4)', date '2027-05-01', 'Both', null, 'At least two adults.'),
  ('Ceremony', 'Ushers (one from each side) and buttonholes', date '2027-06-01', 'Both', null, 'Ushers seat guests and hand out buttonholes.'),
  ('Suppliers', 'Wedding insurance (with public liability)', date '2026-11-30', 'Both', null, 'The venue strongly recommends it, and it''s needed for any of our own decorations or games.'),
  ('Suppliers', 'Photographer', date '2026-12-31', 'Both', 'David Tinkler · 07841 599629 · david@davidtinkler.com', 'Venue approved. Also offers "The Under Cover Guest" social media content.'),
  ('Suppliers', 'Pianist (the piano man)', date '2026-12-31', 'Both', 'Paul Bleach · 07721 588451 · pianoman@blueyonder.co.uk', 'Only the resident pianists can play the venue''s pianos.'),
  ('Suppliers', 'DJ', date '2026-12-31', 'Both', 'Midnight Star · Paul Hooper · 07961 969490 · midnightstardj@gmail.com', 'Venue approved. Also dancefloor, selfie pod, post box.'),
  ('Suppliers', 'Flowers', date '2027-02-28', 'Both', 'Designer Flowers Essex · Stacey Stevens · 07960 804496', null),
  ('Suppliers', 'Cake', date '2027-03-31', 'Both', 'Essex County Cakes · Gordon Harwood · 07599 274330', 'Free tasting of eleven flavours.'),
  ('Suppliers', 'Hair and make-up (with trials)', date '2027-03-31', 'Paula', null, 'Plan timings: the suite may not be available early.'),
  ('Suppliers', 'Children: event nannies? (possibly)', date '2027-03-31', 'Both', 'Little Petals Event Nannies · 07985 350047', null),
  ('Guests', 'Send the save the dates', date '2026-11-30', 'Both', null, null),
  ('Guests', 'Mark definite no''s as declined and decide promotions', date '2027-01-15', 'Both', null, null),
  ('Guests', 'Send the ceremony invitations', date '2027-01-31', 'Both', null, null),
  ('Guests', 'Send the evening (garden party) invitations', date '2027-02-28', 'Both', null, null),
  ('Guests', 'RSVP deadline', date '2027-04-01', 'Both', null, null),
  ('Guests', 'Chase outstanding replies', date '2027-04-08', 'Both', null, null),
  ('Guests', 'Free-from buffet plates: order with names', date '2027-05-01', 'Both', 'Friern Manor', 'From the RSVPs. A small supplement each.'),
  ('Personal', 'Rings (possibly)', date '2027-05-31', 'Both', null, null),
  ('Personal', 'Outfits (possibly)', date '2027-03-31', 'Both', null, null),
  ('Personal', 'Honeymoon (possibly)', date '2027-03-31', 'Both', null, null)
) v(category, title, due, owner, supplier, notes)
where not exists (select 1 from public.todos);
