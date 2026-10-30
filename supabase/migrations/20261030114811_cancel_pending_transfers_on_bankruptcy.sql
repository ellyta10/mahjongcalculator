
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
  update public.chip_transfer_requests set status='declined',reviewed_by=v_user_id,reviewed_at=now()
  where round_id=v_round.id and status='pending' and (from_round_player_id=v_player.id or to_round_player_id=v_player.id);
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
