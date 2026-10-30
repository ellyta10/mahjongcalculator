create policy room_dealer_credentials_deny_direct_access
on private.room_dealer_credentials
for all
to anon, authenticated
using (false)
with check (false);