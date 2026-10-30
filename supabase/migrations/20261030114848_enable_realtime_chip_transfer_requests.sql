do $block$
begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime')
    and not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='chip_transfer_requests') then
  alter publication supabase_realtime add table public.chip_transfer_requests;
 end if;
end;
$block$;
