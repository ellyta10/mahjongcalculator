alter table public.rooms
  add column if not exists dealer_mode text not null default 'dealer_only',
  add column if not exists default_starting_balance bigint not null default 0;

alter table public.rooms
  drop constraint if exists rooms_dealer_mode_check,
  add constraint rooms_dealer_mode_check check (dealer_mode in ('dealer_only','dealer_player')),
  drop constraint if exists rooms_default_starting_balance_check,
  add constraint rooms_default_starting_balance_check
    check (default_starting_balance >= 0 and default_starting_balance % 1000 = 0);

alter table public.room_members drop constraint if exists room_members_check;
alter table public.room_members
  add constraint room_members_check check (
    (role = 'player' and seat_no between 1 and 4)
    or (role = 'dealer' and (seat_no is null or seat_no between 1 and 4))
    or (role = 'viewer' and seat_no is null)
  );

drop index if exists public.room_player_seat_once_idx;
create unique index if not exists room_member_active_seat_once_idx
  on public.room_members(room_id, seat_no)
  where seat_no is not null and member_status = 'active';

create or replace function private.assert_room_role(p_room_id uuid, p_allowed_roles text[])
returns uuid language plpgsql security definer set search_path to ''
as $function$
declare v_user_id uuid := auth.uid();
begin
  if v_user_id is null then raise exception 'Authentication required.' using errcode = '28000'; end if;
  if not exists (
    select 1 from public.room_members rm
    where rm.room_id=p_room_id and rm.user_id=v_user_id and rm.member_status='active'
      and (rm.role=any(p_allowed_roles) or (rm.role='dealer' and rm.seat_no is not null and 'player'=any(p_allowed_roles)))
  ) then raise exception 'Active room membership with the required role is required.' using errcode = '42501'; end if;
  return v_user_id;
end;
$function$;

drop function if exists public.create_room(text,text,text);
create function public.create_room(
  p_name text,p_dealer_display_name text,p_dealer_pin text,p_dealer_mode text,p_dealer_seat_no smallint,p_starting_balance bigint
)
returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_room_id uuid;
  v_round_id uuid;
  v_code text := upper(encode(extensions.gen_random_bytes(16), 'hex'));
  v_mode text := lower(btrim(coalesce(p_dealer_mode, '')));
begin
  if v_user_id is null or coalesce((auth.jwt()->>'is_anonymous')::boolean,false) is not true then raise exception 'Guest session required.' using errcode = '28000'; end if;
  if p_name is null or char_length(btrim(p_name)) not between 1 and 80 then raise exception 'Room name must contain 1 to 80 characters.' using errcode = '22023'; end if;
  if p_dealer_display_name is null or char_length(btrim(p_dealer_display_name)) not between 1 and 40 then raise exception 'Dealer name must contain 1 to 40 characters.' using errcode = '22023'; end if;
  if p_dealer_pin is null or p_dealer_pin !~ '^[0-9]{6}$' then raise exception 'PIN Dealer harus terdiri dari 6 angka.' using errcode = '22023'; end if;
  if v_mode not in ('dealer_only','dealer_player') then raise exception 'Pilih mode Dealer yang valid.' using errcode = '22023'; end if;
  if p_starting_balance is null or p_starting_balance < 0 or p_starting_balance % 1000 <> 0 then raise exception 'Modal awal harus berupa angka non-negatif kelipatan Rp1.000.' using errcode = '22023'; end if;
  if v_mode='dealer_player' and (p_dealer_seat_no is null or p_dealer_seat_no not between 1 and 4) then raise exception 'Dealer yang ikut bermain harus memilih kursi 1 sampai 4.' using errcode = '22023'; end if;
  if v_mode='dealer_only' and p_dealer_seat_no is not null then raise exception 'Dealer Only tidak menggunakan kursi pemain.' using errcode = '22023'; end if;

  insert into public.rooms(name,invite_code_hash,created_by,dealer_mode,default_starting_balance)
  values(btrim(p_name),encode(extensions.digest(v_code,'sha256'),'hex'),v_user_id,v_mode,p_starting_balance)
  returning id into v_room_id;
  insert into private.room_dealer_credentials(room_id,pin_hash)
  values(v_room_id,extensions.crypt(p_dealer_pin,extensions.gen_salt('bf',12)));
  insert into public.room_members(room_id,user_id,role,seat_no,display_name)
  values(v_room_id,v_user_id,'dealer',p_dealer_seat_no,btrim(p_dealer_display_name));
  insert into public.rounds(room_id,round_no,status) values(v_room_id,1,'setup') returning id into v_round_id;
  if v_mode='dealer_player' then
    insert into public.round_players(room_id,round_id,user_id,seat_no,display_name,starting_balance)
    values(v_room_id,v_round_id,v_user_id,p_dealer_seat_no,btrim(p_dealer_display_name),p_starting_balance);
  end if;
  update public.rooms set active_round_id=v_round_id where id=v_room_id;
  insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details)
  values(v_room_id,v_round_id,v_user_id,'room_created',jsonb_build_object('room_name',btrim(p_name),'round_no',1,'dealer_mode',v_mode,'dealer_seat_no',p_dealer_seat_no,'default_starting_balance',p_starting_balance));
  return jsonb_build_object('room_id',v_room_id,'invite_code',v_code);
end;
$function$;
revoke all on function public.create_room(text,text,text,text,smallint,bigint) from public,anon;
grant execute on function public.create_room(text,text,text,text,smallint,bigint) to authenticated;

create or replace function public.join_room_by_code(p_invite_code text,p_display_name text,p_role text,p_seat_no smallint default null)
returns uuid language plpgsql security definer set search_path to ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_code text := upper(btrim(coalesce(p_invite_code,'')));
  v_role text := lower(btrim(coalesce(p_role,'')));
  v_room_id uuid; v_round_id uuid; v_round_status text; v_room_status text; v_default_balance bigint;
  v_existing_user_id uuid; v_existing_role text; v_existing_seat smallint; v_existing_name text; v_rows integer;
begin
  if v_user_id is null or coalesce((auth.jwt()->>'is_anonymous')::boolean,false) is not true then raise exception 'Guest session required.' using errcode = '28000'; end if;
  if char_length(v_code) not between 12 and 64 or v_code !~ '^[A-Z0-9-]+$' then raise exception 'Kode room tidak valid.' using errcode = '22023'; end if;
  if p_display_name is null or char_length(btrim(p_display_name)) not between 1 and 40 then raise exception 'Nama harus berisi 1 sampai 40 karakter.' using errcode = '22023'; end if;
  if v_role not in ('player','viewer') then raise exception 'Role yang dapat bergabung hanya Player atau Viewer.' using errcode = '22023'; end if;
  if v_role='viewer' and p_seat_no is not null then raise exception 'Viewer tidak menggunakan kursi.' using errcode = '22023'; end if;

  select r.id,r.active_round_id,r.status,r.default_starting_balance into v_room_id,v_round_id,v_room_status,v_default_balance
  from public.rooms r where r.invite_code_hash=encode(extensions.digest(v_code,'sha256'),'hex') for update;
  if v_room_id is null or v_round_id is null or v_room_status<>'open' then raise exception 'Room tidak ditemukan atau sudah ditutup.' using errcode = '22023'; end if;
  select r.status into v_round_status from public.rounds r where r.id=v_round_id and r.room_id=v_room_id for update;
  if not found or v_round_status='archived' then raise exception 'Room tidak memiliki ronde yang dapat diikuti.' using errcode = '22023'; end if;

  select rm.user_id,rm.role,rm.seat_no,rm.display_name into v_existing_user_id,v_existing_role,v_existing_seat,v_existing_name
  from public.room_members rm where rm.room_id=v_room_id and rm.member_status='active' and lower(rm.display_name)=lower(btrim(p_display_name)) for update;
  if found then
    if v_existing_role<>v_role then raise exception 'Nama ini sudah terdaftar dengan role berbeda.' using errcode = '22023'; end if;
    if v_existing_user_id=v_user_id then return v_room_id; end if;
    if exists(select 1 from public.room_members x where x.room_id=v_room_id and x.user_id=v_user_id) then raise exception 'Guest ini sudah menjadi anggota Room.' using errcode = '23505'; end if;
    update public.room_members set user_id=v_user_id,joined_at=now(),left_at=null
    where room_id=v_room_id and user_id=v_existing_user_id and member_status='active';
    get diagnostics v_rows=row_count;
    if v_rows<>1 then raise exception 'Gagal memulihkan identitas pemain. Coba lagi.' using errcode = '40001'; end if;
    insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details)
    values(v_room_id,v_round_id,v_user_id,'guest_identity_reclaimed',jsonb_build_object('role',v_role,'seat_no',v_existing_seat,'display_name',v_existing_name,'previous_user_id',v_existing_user_id));
    return v_room_id;
  end if;

  if v_role='player' and (p_seat_no is null or p_seat_no not between 1 and 4) then raise exception 'Player baru harus memilih kursi 1 sampai 4.' using errcode = '22023'; end if;
  if exists(select 1 from public.room_members rm where rm.room_id=v_room_id and rm.member_status='active' and lower(rm.display_name)=lower(btrim(p_display_name))) then raise exception 'Nama sudah digunakan di Room ini.' using errcode = '23505'; end if;
  if v_role='player' and v_round_status<>'setup' then raise exception 'Player baru hanya dapat bergabung sebelum ronde dimulai.' using errcode = '22023'; end if;
  if v_role='player' and exists(select 1 from public.room_members rm where rm.room_id=v_room_id and rm.seat_no=p_seat_no and rm.member_status='active') then raise exception 'Kursi Player sudah terisi.' using errcode = '23505'; end if;
  if exists(select 1 from public.room_members rm where rm.room_id=v_room_id and rm.user_id=v_user_id) then raise exception 'Guest ini sudah terdaftar di Room.' using errcode = '23505'; end if;

  insert into public.room_members(room_id,user_id,role,seat_no,display_name) values(v_room_id,v_user_id,v_role,p_seat_no,btrim(p_display_name));
  if v_role='player' then
    insert into public.round_players(room_id,round_id,user_id,seat_no,display_name,starting_balance)
    values(v_room_id,v_round_id,v_user_id,p_seat_no,btrim(p_display_name),v_default_balance);
  end if;
  insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details)
  values(v_room_id,v_round_id,v_user_id,'room_member_joined',jsonb_build_object('role',v_role,'seat_no',p_seat_no));
  return v_room_id;
end;
$function$;

create or replace function public.start_round(p_round_id uuid)
returns void language plpgsql security definer set search_path to ''
as $function$
declare v_round public.rounds%rowtype; v_user_id uuid; v_count integer;
begin
  select * into v_round from public.rounds r where r.id=p_round_id for update;
  if not found then raise exception 'Round not found.' using errcode = '22023'; end if;
  v_user_id:=private.assert_room_role(v_round.room_id,array['dealer']::text[]);
  if v_round.status<>'setup' then raise exception 'Only a setup round can be started.' using errcode = '55000'; end if;
  if not exists(select 1 from public.rooms rm where rm.id=v_round.room_id and rm.active_round_id=v_round.id and rm.status='open') then raise exception 'This is not the room''s current open round.' using errcode = '55000'; end if;
  select count(*) into v_count from public.room_members rm where rm.room_id=v_round.room_id and rm.seat_no is not null and rm.member_status='active';
  if v_count<>4 then raise exception 'Exactly four active seated players are required to start.' using errcode = '55000'; end if;
  select count(*) into v_count
  from public.round_players rp join public.room_members rm
    on rm.room_id=rp.room_id and rm.user_id=rp.user_id and rm.member_status='active' and rm.seat_no=rp.seat_no
   and (rm.role='player' or (rm.role='dealer' and rm.seat_no is not null))
  where rp.room_id=v_round.room_id and rp.round_id=v_round.id;
  if v_count<>4 then raise exception 'Four matching player snapshots are required.' using errcode = '55000'; end if;
  update public.rounds set status='active',started_by=v_user_id,started_at=now() where id=v_round.id;
  insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details)
  values(v_round.room_id,v_round.id,v_user_id,'round_started',jsonb_build_object('round_no',v_round.round_no));
end;
$function$;

create or replace function public.archive_round_and_start_next(p_round_id uuid)
returns uuid language plpgsql security definer set search_path to ''
as $function$
declare
  v_round public.rounds%rowtype; v_user_id uuid; v_room_active_round_id uuid; v_room_status text;
  v_new_round_id uuid; v_default_balance bigint;
begin
  select * into v_round from public.rounds r where r.id=p_round_id for update;
  if not found then raise exception 'Round not found.' using errcode = '22023'; end if;
  v_user_id:=private.assert_room_role(v_round.room_id,array['dealer']::text[]);
  if v_round.status<>'closing' then raise exception 'Only a closing round can be archived.' using errcode = '55000'; end if;
  select rm.status,rm.active_round_id,rm.default_starting_balance into v_room_status,v_room_active_round_id,v_default_balance
  from public.rooms rm where rm.id=v_round.room_id for update;
  if not found or v_room_status<>'open' or v_room_active_round_id is distinct from v_round.id then raise exception 'This is not the room''s current open round.' using errcode = '55000'; end if;
  if exists(select 1 from public.payment_reports pr where pr.room_id=v_round.room_id and pr.round_id=v_round.id and pr.status='pending') then raise exception 'Review or reject all pending payment reports before archiving.' using errcode = '55000'; end if;
  if exists(select 1 from public.bankruptcy_requests br where br.room_id=v_round.room_id and br.round_id=v_round.id and br.status='requested') then raise exception 'Review all pending bankruptcy requests before archiving.' using errcode = '55000'; end if;
  if not exists(select 1 from public.bankruptcy_requests br where br.room_id=v_round.room_id and br.round_id=v_round.id and br.status='accepted') then raise exception 'At least one bankruptcy request must be accepted before archiving.' using errcode = '55000'; end if;
  if v_round.round_no=2147483647 then raise exception 'Maximum round number reached; a new round cannot be created.' using errcode = '22003'; end if;
  if exists(select 1 from public.round_player_balances b where b.room_id=v_round.room_id and b.round_id=v_round.id and (b.current_balance<0 or b.current_balance>9223372036854775807::numeric)) then raise exception 'A player balance is outside the supported bigint range; correct the ledger before archiving.' using errcode = '22003'; end if;

  update public.round_players rp set final_balance=b.current_balance::bigint,net_result=(b.current_balance-rp.starting_balance)::bigint
  from public.round_player_balances b where rp.room_id=v_round.room_id and rp.round_id=v_round.id and b.round_player_id=rp.id;
  update public.rounds set status='archived',archived_by=v_user_id,archived_at=now() where id=v_round.id;
  insert into public.rounds(room_id,round_no,status) values(v_round.room_id,v_round.round_no+1,'setup') returning id into v_new_round_id;
  update public.rooms set active_round_id=v_new_round_id where id=v_round.room_id;
  insert into public.round_players(room_id,round_id,user_id,seat_no,display_name,starting_balance)
  select rm.room_id,v_new_round_id,rm.user_id,rm.seat_no,rm.display_name,v_default_balance
  from public.room_members rm where rm.room_id=v_round.room_id and rm.seat_no is not null and rm.member_status='active';
  insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details)
  values(v_round.room_id,v_round.id,v_user_id,'round_archived',jsonb_build_object('archived_round_no',v_round.round_no));
  insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details)
  values(v_round.room_id,v_new_round_id,v_user_id,'next_round_created',jsonb_build_object('round_no',v_round.round_no+1));
  return v_new_round_id;
end;
$function$;

comment on column public.rooms.dealer_mode is 'dealer_only or dealer_player; dealer_player means the Dealer occupies one of the four player seats.';
comment on column public.rooms.default_starting_balance is 'Default starting balance in IDR for each seated player; must be a multiple of Rp1,000.';