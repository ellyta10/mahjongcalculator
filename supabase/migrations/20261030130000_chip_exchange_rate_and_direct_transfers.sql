-- Chip Exchange: per-room locked rate and atomic direct transfers.
-- Applied to the mahjong-development Supabase project.

alter table public.rooms
  add column if not exists chip_rate bigint not null default 1000;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.rooms'::regclass
      and conname='rooms_chip_rate_positive'
  ) then
    alter table public.rooms
      add constraint rooms_chip_rate_positive
      check (chip_rate > 0 and chip_rate <= 1000000000);
  end if;
end $$;

comment on column public.rooms.chip_rate is
  'Immutable per-room rupiah value of one chip, selected when the room is created.';

create or replace function private.guard_room_chip_rate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if new.chip_rate is distinct from old.chip_rate then
    if exists (
      select 1 from public.rounds r
       where r.room_id = old.id and r.status <> 'setup'
    ) or exists (
      select 1 from public.audit_log a
       where a.room_id = old.id and a.event_type = 'starting_balances_set'
    ) or exists (
      select 1 from public.chip_ledger l
       where l.room_id = old.id
    ) then
      raise exception 'Rate chip sudah dikunci setelah modal awal disimpan atau permainan dimulai.'
        using errcode = '55000';
    end if;
  end if;
  return new;
end;
$function$;

drop trigger if exists rooms_guard_chip_rate on public.rooms;
create trigger rooms_guard_chip_rate
before update of chip_rate on public.rooms
for each row execute function private.guard_room_chip_rate();

create or replace function public.create_chip_exchange_room(
  p_name text,
  p_host_display_name text,
  p_host_pin text,
  p_host_seat_no smallint,
  p_chip_rate bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_result jsonb;
  v_room_id uuid;
begin
  if p_chip_rate is null or p_chip_rate <= 0 or p_chip_rate > 1000000000 then
    raise exception 'Rate chip harus berupa angka positif maksimal Rp1.000.000.000.'
      using errcode='22023';
  end if;

  v_result := public.create_room(
    p_name,
    p_host_display_name,
    p_host_pin,
    'dealer_player',
    p_host_seat_no,
    0
  );

  v_room_id := (v_result->>'room_id')::uuid;
  update public.rooms
     set chip_rate = p_chip_rate
   where id = v_room_id
     and created_by = auth.uid();

  if not found then
    raise exception 'Gagal menyimpan rate Room.' using errcode='55000';
  end if;

  return v_result || jsonb_build_object('chip_rate', p_chip_rate);
end;
$function$;

create or replace function private.queue_zero_balance_bankruptcy()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_balance numeric;
  v_user_id uuid;
  v_name text;
begin
  -- Zero balance is normal in a direct chip-exchange game.
  if new.from_round_player_id is null
     or new.entry_type not in ('payment','dealer_adjustment') then
    return new;
  end if;

  select rp.user_id,rp.display_name into v_user_id,v_name
    from public.round_players rp
   where rp.id=new.from_round_player_id
   for update;
  if not found then return new; end if;

  select b.current_balance into v_balance
    from public.round_player_balances b
   where b.round_player_id=new.from_round_player_id;
  if coalesce(v_balance,0)>0 then return new; end if;

  if exists(
    select 1 from public.bankruptcy_requests br
     where br.round_id=new.round_id
       and br.round_player_id=new.from_round_player_id
       and br.status='requested'
  ) then
    update public.bankruptcy_requests
       set request_type='auto_zero'
     where round_id=new.round_id
       and round_player_id=new.from_round_player_id
       and status='requested';
  else
    insert into public.bankruptcy_requests(
      room_id,round_id,round_player_id,requested_by,request_type
    )
    values(
      new.room_id,new.round_id,new.from_round_player_id,v_user_id,'auto_zero'
    );
  end if;

  update public.round_players
     set bankrupt_requested_at=coalesce(bankrupt_requested_at,now())
   where id=new.from_round_player_id;

  insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details)
  values(
    new.room_id,new.round_id,v_user_id,'bankruptcy_auto_zero_detected',
    jsonb_build_object(
      'round_player_id',new.from_round_player_id,
      'display_name',v_name,
      'ledger_entry_id',new.id
    )
  );
  return new;
end;
$function$;

create or replace function public.send_chip_transfer(
  p_round_id uuid,
  p_to_user_id uuid,
  p_amount_chips bigint,
  p_client_request_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_round public.rounds%rowtype;
  v_room public.rooms%rowtype;
  v_user_id uuid;
  v_from_id uuid;
  v_to_id uuid;
  v_balance numeric;
  v_existing uuid;
  v_entry_id uuid;
  v_amount numeric;
begin
  if p_amount_chips is null or p_amount_chips <= 0 then
    raise exception 'Jumlah chips harus lebih dari 0.' using errcode='22023';
  end if;
  if p_client_request_id is null then
    raise exception 'Request ID wajib diisi.' using errcode='22023';
  end if;

  select * into v_round
    from public.rounds
   where id = p_round_id
   for update;
  if not found then
    raise exception 'Ronde tidak ditemukan.' using errcode='22023';
  end if;

  v_user_id := private.assert_room_role(v_round.room_id, array['player']::text[]);

  select * into v_room
    from public.rooms
   where id = v_round.room_id
   for update;
  if not found
     or v_room.status <> 'open'
     or v_room.active_round_id is distinct from v_round.id
     or v_round.status <> 'active' then
    raise exception 'Transfer hanya tersedia saat permainan berlangsung.' using errcode='55000';
  end if;

  if p_to_user_id is null or p_to_user_id = v_user_id then
    raise exception 'Pilih Player lain sebagai penerima.' using errcode='22023';
  end if;

  select id into v_from_id
    from public.round_players
   where room_id = v_round.room_id
     and round_id = v_round.id
     and user_id = v_user_id;

  select rp.id into v_to_id
    from public.round_players rp
    join public.room_members rm
      on rm.room_id = rp.room_id and rm.user_id = rp.user_id
   where rp.room_id = v_round.room_id
     and rp.round_id = v_round.id
     and rp.user_id = p_to_user_id
     and rm.member_status = 'active'
     and (rm.role = 'player' or (rm.role = 'dealer' and rm.seat_no is not null));

  if v_from_id is null or v_to_id is null then
    raise exception 'Pengirim dan penerima harus Player aktif di ronde ini.' using errcode='42501';
  end if;

  perform 1
    from public.round_players
   where id in (v_from_id, v_to_id)
   order by id
   for update;

  -- Re-check idempotency after acquiring locks to avoid duplicate retries.
  select id into v_existing
    from public.chip_ledger
   where room_id = v_round.room_id
     and created_by = v_user_id
     and client_request_id = p_client_request_id
     and entry_type = 'player_transfer';
  if v_existing is not null then
    return v_existing;
  end if;

  select current_balance into v_balance
    from public.round_player_balances
   where round_player_id = v_from_id;

  v_amount := p_amount_chips::numeric * v_room.chip_rate;
  if v_amount > 9223372036854775807 then
    raise exception 'Nominal transfer terlalu besar.' using errcode='22003';
  end if;
  if coalesce(v_balance, 0) < v_amount then
    raise exception 'Saldo chips tidak mencukupi.' using errcode='22023';
  end if;

  insert into public.chip_ledger(
    room_id, round_id, entry_type, from_round_player_id, to_round_player_id,
    amount, payment_report_id, created_by, memo, client_request_id
  )
  values (
    v_round.room_id, v_round.id, 'player_transfer', v_from_id, v_to_id,
    v_amount::bigint, null, v_user_id,
    'Transfer langsung: ' || p_amount_chips::text || ' chips @ Rp' || v_room.chip_rate::text,
    p_client_request_id
  )
  returning id into v_entry_id;

  insert into public.audit_log(room_id, round_id, actor_user_id, event_type, details)
  values (
    v_round.room_id, v_round.id, v_user_id, 'chip_transfer_sent',
    jsonb_build_object(
      'ledger_entry_id', v_entry_id,
      'from_round_player_id', v_from_id,
      'to_round_player_id', v_to_id,
      'amount_chips', p_amount_chips,
      'chip_rate', v_room.chip_rate
    )
  );

  return v_entry_id;
end;
$function$;

revoke execute on function public.create_chip_exchange_room(text,text,text,smallint,bigint) from public, anon;
grant execute on function public.create_chip_exchange_room(text,text,text,smallint,bigint) to authenticated;
revoke execute on function public.send_chip_transfer(uuid,uuid,bigint,uuid) from public, anon;
grant execute on function public.send_chip_transfer(uuid,uuid,bigint,uuid) to authenticated;
revoke execute on function public.create_room(text,text,text,text,smallint,bigint) from public, anon;
grant execute on function public.create_room(text,text,text,text,smallint,bigint) to authenticated;
