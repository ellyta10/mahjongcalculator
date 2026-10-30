
alter table public.bankruptcy_requests add column if not exists request_type text not null default 'manual';
alter table public.bankruptcy_requests drop constraint if exists bankruptcy_requests_request_type_check;
alter table public.bankruptcy_requests add constraint bankruptcy_requests_request_type_check check (request_type in ('manual','auto_zero'));

alter table public.chip_ledger drop constraint if exists chip_ledger_check;
alter table public.chip_ledger add constraint chip_ledger_check check (
 (entry_type='payment' and from_round_player_id is not null and to_round_player_id is not null and from_round_player_id<>to_round_player_id and payment_report_id is not null)
 or (entry_type in ('dealer_adjustment','bankruptcy_reset') and ((from_round_player_id is null)<>(to_round_player_id is null)) and payment_report_id is null)
 or (entry_type='player_transfer' and from_round_player_id is not null and to_round_player_id is not null and from_round_player_id<>to_round_player_id and payment_report_id is null)
);
alter table public.chip_ledger drop constraint if exists chip_ledger_entry_type_check;
alter table public.chip_ledger add constraint chip_ledger_entry_type_check check (entry_type in ('payment','dealer_adjustment','player_transfer','bankruptcy_reset'));

create table public.chip_transfer_requests (
 id uuid primary key default gen_random_uuid(),
 room_id uuid not null,
 round_id uuid not null,
 from_round_player_id uuid not null,
 to_round_player_id uuid not null,
 amount_chips bigint not null check(amount_chips>0),
 status text not null default 'pending' check(status in ('pending','accepted','declined')),
 created_by uuid not null references auth.users(id) on delete restrict,
 reviewed_by uuid references auth.users(id) on delete restrict,
 client_request_id uuid not null,
 created_at timestamptz not null default now(),
 reviewed_at timestamptz,
 constraint chip_transfer_requests_distinct_players check(from_round_player_id<>to_round_player_id),
 constraint chip_transfer_requests_review_state check((status='pending' and reviewed_by is null and reviewed_at is null) or (status in ('accepted','declined') and reviewed_by is not null and reviewed_at is not null)),
 constraint chip_transfer_requests_room_round_fk foreign key(room_id,round_id) references public.rounds(room_id,id) on delete restrict,
 constraint chip_transfer_requests_from_player_fk foreign key(room_id,round_id,from_round_player_id) references public.round_players(room_id,round_id,id) on delete restrict,
 constraint chip_transfer_requests_to_player_fk foreign key(room_id,round_id,to_round_player_id) references public.round_players(room_id,round_id,id) on delete restrict,
 constraint chip_transfer_requests_idempotency unique(room_id,created_by,client_request_id)
);
create index chip_transfer_requests_round_status_created_idx on public.chip_transfer_requests(room_id,round_id,status,created_at desc);
create index chip_transfer_requests_to_player_status_idx on public.chip_transfer_requests(to_round_player_id,status);
alter table public.chip_transfer_requests enable row level security;
revoke all on public.chip_transfer_requests from anon,authenticated;
grant select on public.chip_transfer_requests to authenticated;
create policy chip_transfer_requests_room_member_select on public.chip_transfer_requests for select to authenticated
using(exists(select 1 from public.room_members rm where rm.room_id=chip_transfer_requests.room_id and rm.user_id=(select auth.uid()) and rm.member_status='active'));

create or replace function private.queue_zero_balance_bankruptcy()
returns trigger language plpgsql security definer set search_path to ''
as $function$
declare v_balance numeric; v_user_id uuid; v_name text;
begin
 if new.from_round_player_id is null or new.entry_type not in ('payment','player_transfer','dealer_adjustment') then return new; end if;
 select b.current_balance,rp.user_id,rp.display_name into v_balance,v_user_id,v_name
 from public.round_player_balances b join public.round_players rp on rp.id=b.round_player_id
 where b.round_player_id=new.from_round_player_id for update of rp;
 if not found or v_balance>0 then return new; end if;
 if not exists(select 1 from public.bankruptcy_requests br where br.round_id=new.round_id and br.round_player_id=new.from_round_player_id and br.status='requested') then
  insert into public.bankruptcy_requests(room_id,round_id,round_player_id,requested_by,request_type)
  values(new.room_id,new.round_id,new.from_round_player_id,v_user_id,'auto_zero');
  update public.round_players set bankrupt_requested_at=coalesce(bankrupt_requested_at,now()) where id=new.from_round_player_id;
  insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details)
  values(new.room_id,new.round_id,v_user_id,'bankruptcy_auto_zero_detected',jsonb_build_object('round_player_id',new.from_round_player_id,'display_name',v_name,'ledger_entry_id',new.id));
 end if;
 return new;
end;
$function$;
drop trigger if exists chip_ledger_queue_zero_bankruptcy on public.chip_ledger;
create trigger chip_ledger_queue_zero_bankruptcy after insert on public.chip_ledger for each row execute function private.queue_zero_balance_bankruptcy();
revoke all on function private.queue_zero_balance_bankruptcy() from public,anon,authenticated;

create or replace function public.request_bankruptcy(p_round_id uuid)
returns uuid language plpgsql security definer set search_path to ''
as $function$
declare v_round public.rounds%rowtype; v_user_id uuid; v_player_id uuid; v_request_id uuid;
begin
 select * into v_round from public.rounds r where r.id=p_round_id for update;
 if not found then raise exception 'Round not found.' using errcode='22023'; end if;
 v_user_id:=private.assert_room_role(v_round.room_id,array['player']::text[]);
 if v_round.status not in ('active','setup') or not exists(select 1 from public.rooms rm where rm.id=v_round.room_id and rm.active_round_id=v_round.id and rm.status='open') then
  raise exception 'Bankruptcy can be requested only in the current open round.' using errcode='55000';
 end if;
 select rp.id into v_player_id from public.round_players rp where rp.room_id=v_round.room_id and rp.round_id=v_round.id and rp.user_id=v_user_id for update;
 if not found then raise exception 'Player snapshot not found for this round.' using errcode='42501'; end if;
 select br.id into v_request_id from public.bankruptcy_requests br where br.round_id=v_round.id and br.round_player_id=v_player_id and br.status='requested' order by br.requested_at desc limit 1;
 if found then return v_request_id; end if;
 insert into public.bankruptcy_requests(room_id,round_id,round_player_id,requested_by,request_type)
 values(v_round.room_id,v_round.id,v_player_id,v_user_id,'manual') returning id into v_request_id;
 update public.round_players set bankrupt_requested_at=now() where id=v_player_id;
 insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details)
 values(v_round.room_id,v_round.id,v_user_id,'bankruptcy_requested',jsonb_build_object('request_id',v_request_id,'round_player_id',v_player_id,'request_type','manual'));
 return v_request_id;
end;
$function$;

create or replace function public.review_bankruptcy_request(p_request_id uuid,p_accept boolean)
returns uuid language plpgsql security definer set search_path to ''
as $function$
declare v_head record; v_round public.rounds%rowtype; v_request public.bankruptcy_requests%rowtype; v_user_id uuid;
 v_room public.rooms%rowtype; v_player public.round_players%rowtype; v_balance numeric; v_target bigint; v_delta numeric;
begin
 if p_accept is null then raise exception 'Decision is required.' using errcode='22023'; end if;
 select br.room_id,br.round_id into v_head from public.bankruptcy_requests br where br.id=p_request_id;
 if not found then raise exception 'Bankruptcy request not found.' using errcode='22023'; end if;
 select * into v_round from public.rounds r where r.id=v_head.round_id and r.room_id=v_head.room_id for update;
 if not found then raise exception 'Round not found.' using errcode='22023'; end if;
 v_user_id:=private.assert_room_role(v_round.room_id,array['dealer']::text[]);
 select * into v_room from public.rooms rm where rm.id=v_round.room_id for update;
 if not found or v_room.status<>'open' or v_room.active_round_id is distinct from v_round.id or v_round.status not in ('active','setup') then
  raise exception 'This is not the current open round.' using errcode='55000';
 end if;
 select * into v_request from public.bankruptcy_requests br where br.id=p_request_id and br.room_id=v_round.room_id and br.round_id=v_round.id for update;
 if not found or v_request.status<>'requested' then raise exception 'Bankruptcy request has already been reviewed.' using errcode='55000'; end if;
 if v_request.request_type='auto_zero' and not p_accept then raise exception 'Saldo 0 wajib di-reset. Permintaan otomatis tidak dapat ditolak.' using errcode='55000'; end if;
 select * into v_player from public.round_players rp where rp.id=v_request.round_player_id for update;
 if not found then raise exception 'Player snapshot not found.' using errcode='22023'; end if;
 update public.bankruptcy_requests set status=case when p_accept then 'accepted' else 'declined' end,reviewed_by=v_user_id,reviewed_at=now() where id=v_request.id;
 if p_accept then
  select b.current_balance into v_balance from public.round_player_balances b where b.round_player_id=v_player.id;
  v_balance:=coalesce(v_balance,0); v_target:=v_room.default_starting_balance; v_delta:=v_target::numeric-v_balance;
  if v_delta>0 then
   insert into public.chip_ledger(room_id,round_id,entry_type,from_round_player_id,to_round_player_id,amount,payment_report_id,created_by,memo)
   values(v_round.room_id,v_round.id,'bankruptcy_reset',null,v_player.id,v_delta::bigint,null,v_user_id,'Reset saldo ke modal awal Room setelah bangkrut');
  elsif v_delta<0 then
   insert into public.chip_ledger(room_id,round_id,entry_type,from_round_player_id,to_round_player_id,amount,payment_report_id,created_by,memo)
   values(v_round.room_id,v_round.id,'bankruptcy_reset',v_player.id,null,abs(v_delta)::bigint,null,v_user_id,'Reset saldo ke modal awal Room setelah bangkrut');
  end if;
  update public.round_players set bankrupt_requested_at=now() where id=v_player.id;
 else
  update public.round_players rp set bankrupt_requested_at=null where rp.id=v_player.id
   and not exists(select 1 from public.bankruptcy_requests br where br.round_player_id=rp.id and br.status='requested');
 end if;
 insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details)
 values(v_round.room_id,v_round.id,v_user_id,case when p_accept then 'bankruptcy_reset_accepted' else 'bankruptcy_request_declined' end,
 jsonb_build_object('request_id',v_request.id,'round_player_id',v_player.id,'request_type',v_request.request_type,'reset_balance',case when p_accept then v_target else null end));
 return v_request.id;
end;
$function$;

create or replace function public.request_chip_transfer(p_round_id uuid,p_to_user_id uuid,p_amount_chips bigint,p_client_request_id uuid)
returns uuid language plpgsql security definer set search_path to ''
as $function$
declare v_round public.rounds%rowtype; v_room public.rooms%rowtype; v_user_id uuid; v_from_id uuid; v_to_id uuid; v_balance numeric; v_request_id uuid; v_value numeric;
begin
 if p_amount_chips is null or p_amount_chips<=0 then raise exception 'Jumlah chips harus lebih dari 0.' using errcode='22023'; end if;
 if p_amount_chips>9223372036854775 then raise exception 'Jumlah chips terlalu besar.' using errcode='22003'; end if;
 if p_client_request_id is null then raise exception 'Request ID is required.' using errcode='22023'; end if;
 select * into v_round from public.rounds r where r.id=p_round_id for update;
 if not found then raise exception 'Round not found.' using errcode='22023'; end if;
 v_user_id:=private.assert_room_role(v_round.room_id,array['player']::text[]);
 select * into v_room from public.rooms rm where rm.id=v_round.room_id for update;
 if not found or v_room.status<>'open' or v_room.active_round_id is distinct from v_round.id or v_round.status not in ('active','setup') then
  raise exception 'Transfer hanya tersedia di Room aktif.' using errcode='55000';
 end if;
 if p_to_user_id is null or p_to_user_id=v_user_id then raise exception 'Pilih Player lain sebagai penerima.' using errcode='22023'; end if;
 select rp.id into v_from_id from public.round_players rp where rp.room_id=v_round.room_id and rp.round_id=v_round.id and rp.user_id=v_user_id;
 select rp.id into v_to_id from public.round_players rp join public.room_members rm on rm.room_id=rp.room_id and rm.user_id=rp.user_id
 where rp.room_id=v_round.room_id and rp.round_id=v_round.id and rp.user_id=p_to_user_id and rm.member_status='active'
 and (rm.role='player' or (rm.role='dealer' and rm.seat_no is not null));
 if v_from_id is null or v_to_id is null then raise exception 'Pengirim dan penerima harus Player aktif di ronde ini.' using errcode='42501'; end if;
 perform 1 from public.round_players rp where rp.id in (v_from_id,v_to_id) order by rp.id for update;
 if exists(select 1 from public.bankruptcy_requests br where br.round_id=v_round.id and br.round_player_id in (v_from_id,v_to_id) and br.status='requested') then
  raise exception 'Transfer tidak tersedia selama salah satu Player menunggu proses reset bangkrut.' using errcode='55000';
 end if;
 select b.current_balance into v_balance from public.round_player_balances b where b.round_player_id=v_from_id;
 v_value:=p_amount_chips::numeric*1000;
 if coalesce(v_balance,0)<v_value then raise exception 'Saldo chips tidak mencukupi.' using errcode='22023'; end if;
 insert into public.chip_transfer_requests(room_id,round_id,from_round_player_id,to_round_player_id,amount_chips,status,created_by,client_request_id)
 values(v_round.room_id,v_round.id,v_from_id,v_to_id,p_amount_chips,'pending',v_user_id,p_client_request_id)
 on conflict(room_id,created_by,client_request_id) do nothing returning id into v_request_id;
 if v_request_id is null then
  select id into v_request_id from public.chip_transfer_requests where room_id=v_round.room_id and created_by=v_user_id and client_request_id=p_client_request_id;
 end if;
 insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details)
 values(v_round.room_id,v_round.id,v_user_id,'chip_transfer_requested',jsonb_build_object('transfer_id',v_request_id,'from_round_player_id',v_from_id,'to_round_player_id',v_to_id,'amount_chips',p_amount_chips));
 return v_request_id;
end;
$function$;

create or replace function public.review_chip_transfer(p_transfer_id uuid,p_accept boolean)
returns uuid language plpgsql security definer set search_path to ''
as $function$
declare v_transfer public.chip_transfer_requests%rowtype; v_round public.rounds%rowtype; v_room public.rooms%rowtype; v_user_id uuid; v_balance numeric; v_value numeric;
begin
 if p_accept is null then raise exception 'Decision is required.' using errcode='22023'; end if;
 select * into v_transfer from public.chip_transfer_requests t where t.id=p_transfer_id for update;
 if not found then raise exception 'Transfer request not found.' using errcode='22023'; end if;
 v_user_id:=private.assert_room_role(v_transfer.room_id,array['player']::text[]);
 if not exists(select 1 from public.round_players rp where rp.id=v_transfer.to_round_player_id and rp.user_id=v_user_id) then
  raise exception 'Hanya Player penerima yang dapat menyetujui atau menolak transfer.' using errcode='42501';
 end if;
 select * into v_round from public.rounds r where r.id=v_transfer.round_id and r.room_id=v_transfer.room_id for update;
 if not found then raise exception 'Round not found.' using errcode='22023'; end if;
 select * into v_room from public.rooms rm where rm.id=v_transfer.room_id for update;
 if not found or v_room.status<>'open' or v_room.active_round_id is distinct from v_round.id or v_round.status not in ('active','setup') then
  raise exception 'Transfer hanya dapat diproses di Room aktif.' using errcode='55000';
 end if;
 if v_transfer.status<>'pending' then raise exception 'Permintaan transfer sudah diproses.' using errcode='55000'; end if;
 perform 1 from public.round_players rp where rp.id in (v_transfer.from_round_player_id,v_transfer.to_round_player_id) order by rp.id for update;
 if p_accept then
  if exists(select 1 from public.bankruptcy_requests br where br.round_id=v_round.id and br.round_player_id in (v_transfer.from_round_player_id,v_transfer.to_round_player_id) and br.status='requested') then
   raise exception 'Transfer tidak dapat disetujui selama proses bangkrut/reset masih berlangsung.' using errcode='55000';
  end if;
  select b.current_balance into v_balance from public.round_player_balances b where b.round_player_id=v_transfer.from_round_player_id;
  v_value:=v_transfer.amount_chips::numeric*1000;
  if coalesce(v_balance,0)<v_value then raise exception 'Saldo pengirim tidak lagi mencukupi.' using errcode='22023'; end if;
  insert into public.chip_ledger(room_id,round_id,entry_type,from_round_player_id,to_round_player_id,amount,payment_report_id,created_by,memo)
  values(v_transfer.room_id,v_transfer.round_id,'player_transfer',v_transfer.from_round_player_id,v_transfer.to_round_player_id,v_value::bigint,null,v_user_id,'Transfer antar-Player: '||v_transfer.amount_chips::text||' chips');
 end if;
 update public.chip_transfer_requests set status=case when p_accept then 'accepted' else 'declined' end,reviewed_by=v_user_id,reviewed_at=now() where id=v_transfer.id;
 insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details)
 values(v_transfer.room_id,v_transfer.round_id,v_user_id,case when p_accept then 'chip_transfer_accepted' else 'chip_transfer_declined' end,jsonb_build_object('transfer_id',v_transfer.id,'amount_chips',v_transfer.amount_chips));
 return v_transfer.id;
end;
$function$;

create or replace function public.close_round(p_round_id uuid)
returns void language plpgsql security definer set search_path to ''
as $function$
declare v_round public.rounds%rowtype; v_user_id uuid; v_room public.rooms%rowtype;
begin
 select * into v_round from public.rounds r where r.id=p_round_id for update;
 if not found then raise exception 'Round not found.' using errcode='22023'; end if;
 v_user_id:=private.assert_room_role(v_round.room_id,array['dealer']::text[]);
 select * into v_room from public.rooms rm where rm.id=v_round.room_id for update;
 if not found or v_room.status<>'open' or v_room.active_round_id is distinct from v_round.id then raise exception 'This is not the current open round.' using errcode='55000'; end if;
 if v_round.status<>'active' then raise exception 'Only an active round can be closed.' using errcode='55000'; end if;
 if exists(select 1 from public.payment_reports pr where pr.room_id=v_round.room_id and pr.round_id=v_round.id and pr.status='pending') then raise exception 'Review all pending payment reports before closing.' using errcode='55000'; end if;
 if exists(select 1 from public.bankruptcy_requests br where br.room_id=v_round.room_id and br.round_id=v_round.id and br.status='requested') then raise exception 'Review all pending bankruptcy/reset requests before closing.' using errcode='55000'; end if;
 if exists(select 1 from public.chip_transfer_requests tr where tr.room_id=v_round.room_id and tr.round_id=v_round.id and tr.status='pending') then raise exception 'Review all pending chip transfers before closing.' using errcode='55000'; end if;
 update public.rounds set status='closing',close_requested_by=v_user_id,closing_at=now() where id=v_round.id;
 insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details) values(v_round.room_id,v_round.id,v_user_id,'round_closing_started',jsonb_build_object('round_no',v_round.round_no));
end;
$function$;

create or replace function public.archive_round_and_start_next(p_round_id uuid)
returns uuid language plpgsql security definer set search_path to ''
as $function$
declare v_round public.rounds%rowtype; v_user_id uuid; v_room public.rooms%rowtype; v_new_round_id uuid; v_default_balance bigint;
begin
 select * into v_round from public.rounds r where r.id=p_round_id for update;
 if not found then raise exception 'Round not found.' using errcode='22023'; end if;
 v_user_id:=private.assert_room_role(v_round.room_id,array['dealer']::text[]);
 if v_round.status<>'closing' then raise exception 'Only a closing round can be archived.' using errcode='55000'; end if;
 select * into v_room from public.rooms rm where rm.id=v_round.room_id for update;
 if not found or v_room.status<>'open' or v_room.active_round_id is distinct from v_round.id then raise exception 'This is not the current open round.' using errcode='55000'; end if;
 if exists(select 1 from public.payment_reports pr where pr.room_id=v_round.room_id and pr.round_id=v_round.id and pr.status='pending') then raise exception 'Review or reject all pending payment reports before archiving.' using errcode='55000'; end if;
 if exists(select 1 from public.bankruptcy_requests br where br.room_id=v_round.room_id and br.round_id=v_round.id and br.status='requested') then raise exception 'Review all pending bankruptcy/reset requests before archiving.' using errcode='55000'; end if;
 if exists(select 1 from public.chip_transfer_requests tr where tr.room_id=v_round.room_id and tr.round_id=v_round.id and tr.status='pending') then raise exception 'Review all pending chip transfers before archiving.' using errcode='55000'; end if;
 if v_round.round_no=2147483647 then raise exception 'Maximum round number reached; a new round cannot be created.' using errcode='22003'; end if;
 if exists(select 1 from public.round_player_balances b where b.room_id=v_round.room_id and b.round_id=v_round.id and (b.current_balance<0 or b.current_balance>9223372036854775807::numeric)) then raise exception 'A player balance is outside the supported bigint range; correct the ledger before archiving.' using errcode='22003'; end if;
 update public.round_players rp set final_balance=b.current_balance::bigint,net_result=(b.current_balance-rp.starting_balance)::bigint
 from public.round_player_balances b where rp.room_id=v_round.room_id and rp.round_id=v_round.id and b.round_player_id=rp.id;
 update public.rounds set status='archived',archived_by=v_user_id,archived_at=now() where id=v_round.id;
 insert into public.rounds(room_id,round_no,status) values(v_round.room_id,v_round.round_no+1,'setup') returning id into v_new_round_id;
 update public.rooms set active_round_id=v_new_round_id where id=v_round.room_id;
 insert into public.round_players(room_id,round_id,user_id,seat_no,display_name,starting_balance)
 select rm.room_id,v_new_round_id,rm.user_id,rm.seat_no,rm.display_name,v_room.default_starting_balance
 from public.room_members rm where rm.room_id=v_round.room_id and rm.seat_no is not null and rm.member_status='active';
 insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details) values(v_round.room_id,v_round.id,v_user_id,'round_archived',jsonb_build_object('archived_round_no',v_round.round_no));
 insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details) values(v_round.room_id,v_new_round_id,v_user_id,'next_round_created',jsonb_build_object('round_no',v_round.round_no+1));
 return v_new_round_id;
end;
$function$;

revoke all on function public.request_bankruptcy(uuid) from public,anon;
revoke all on function public.review_bankruptcy_request(uuid,boolean) from public,anon;
revoke all on function public.request_chip_transfer(uuid,uuid,bigint,uuid) from public,anon;
revoke all on function public.review_chip_transfer(uuid,boolean) from public,anon;
revoke all on function public.close_round(uuid) from public,anon;
grant execute on function public.request_bankruptcy(uuid) to authenticated;
grant execute on function public.review_bankruptcy_request(uuid,boolean) to authenticated;
grant execute on function public.request_chip_transfer(uuid,uuid,bigint,uuid) to authenticated;
grant execute on function public.review_chip_transfer(uuid,boolean) to authenticated;
grant execute on function public.close_round(uuid) to authenticated;
