# Paula & Doug · 7th August 2027

Wedding invitation and RSVP site.

- Guest page: `https://dougandpaula.github.io/?g=<personal code>`
- Admin page: `https://dougandpaula.github.io/admin.html`
- Data lives in Supabase (guest list, RSVPs, gift details). Nothing private is stored in this repository.
- `supabase/01_setup.sql` recreates the database structure if ever needed.
- `.github/workflows/keep-awake.yml` pings the database every 3 days so the free Supabase project doesn't pause.
