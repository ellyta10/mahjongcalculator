-- Reset Host/Player chip-exchange rooms after two hours without a saved activity.
-- The room row is retained under its previous code so existing clients can receive
-- the inactive state; state.code is cleared so a subsequent game gets a new code.

create extension if not exists pg_cron with schema pg_catalog;

create or replace function public.reset_inactive_chip_exchange_rooms()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  affected integer := 0;
begin
  update public.chip_exchange_preview_rooms as r
  set
    state = r.state || jsonb_build_object(
      'room', '',
      'host', '',
      'rate', 0,
      'started', false,
      'finished', false,
      'code', '',
      'history', '[]'::jsonb,
      'joinRequests', '[]'::jsonb,
      'hostJoins', false,
      'hostSeat', 0,
      'players', coalesce(
        (
          select jsonb_agg(
            (p.value - array[
              'name', 'chips', 'chipCounts', 'initialChips',
              'initialChipCounts', 'bankrupt', 'joined'
            ]) || jsonb_build_object(
              'name', 'Player ' || p.ordinality,
              'chips', 0,
              'chipCounts', '{}'::jsonb,
              'initialChips', 0,
              'initialChipCounts', '{}'::jsonb,
              'bankrupt', false,
              'joined', false
            )
            order by p.ordinality
          )
          from jsonb_array_elements(coalesce(r.state->'players', '[]'::jsonb))
            with ordinality as p(value, ordinality)
        ),
        '[]'::jsonb
      )
    ),
    updated_at = now()
  where coalesce((r.state->>'started')::boolean, false) = true
    and r.updated_at <= now() - interval '2 hours';

  get diagnostics affected = row_count;
  return affected;
end;
$function$;

-- Prevent an old browser tab from reviving a room after the scheduled reset.
create or replace function public.prevent_reset_room_revival()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $guard$
begin
  if coalesce((old.state->>'started')::boolean, false) = false
     and coalesce(old.state->>'code', '') = ''
     and coalesce((new.state->>'started')::boolean, false) = true then
    raise exception 'Room sudah di-reset karena tidak aktif. Buat room baru dengan kode baru.';
  end if;
  return new;
end;
$guard$;

drop trigger if exists prevent_reset_room_revival on public.chip_exchange_preview_rooms;
create trigger prevent_reset_room_revival
before update on public.chip_exchange_preview_rooms
for each row execute function public.prevent_reset_room_revival();

revoke all on function public.reset_inactive_chip_exchange_rooms() from public;
revoke all on function public.reset_inactive_chip_exchange_rooms() from anon;
revoke all on function public.reset_inactive_chip_exchange_rooms() from authenticated;

do $schedule$
declare
  existing_job bigint;
begin
  select jobid into existing_job
  from cron.job
  where jobname = 'mahjong-chip-room-inactivity-reset'
  limit 1;

  if existing_job is not null then
    perform cron.unschedule(existing_job);
  end if;

  perform cron.schedule(
    'mahjong-chip-room-inactivity-reset',
    '* * * * *',
    'select public.reset_inactive_chip_exchange_rooms();'
  );
end;
$schedule$;
