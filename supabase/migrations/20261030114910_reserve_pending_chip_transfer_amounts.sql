
create or replace function public.request_chip_transfer(p_round_id uuid,p_to_user_id uuid,p_amount_chips bigint,p_client_request_id uuid)
returns uuid language plpgsql security definer set search_path to ''
as $function$
declare v_round public.rounds%rowtype; v_room public.rooms%rowtype; v_user_id uuid; v_from_id uuid; v_to_id uuid;
 v_balance numeric; v_pending_chips numeric; v_request_id uuid; v_value numeric;
begin
 if p_amount_chips is null or p_amount_chips<=0 then raise exception 'Jumlah chips harus lebih dari 0.' using errcode='22023'; end if;
 if p_amount_chips>9223372036854775 then raise exception 'Jumlah chips terlalu besar.' using errcode='22003'; end if;
 if p_client_request_id is null then raise exception 'Request ID is required.' using errcode='22023'; end if;
 select * into v_round from public.rounds r where r.id=p_round_id for update;
 if not found then raise exception 'Round not found.' using errcode='22023'; end if;
 v_user_id:=private.assert_room_role(v_round.room_id,array['player']::text[]);
 select * into v_room from public.rooms rm where rm.id=v_round.room_id for update;
 if not found or v_room.status<>'open' or v_room.active_round_id is distinct from v_round.id or v_round.status not in ('active','setup') then raise exception 'Transfer hanya tersedia di Room aktif.' using errcode='55000'; end if;
 if p_to_user_id is null or p_to_user_id=v_user_id then raise exception 'Pilih Player lain sebagai penerima.' using errcode='22023'; end if;
 select t.id into v_request_id from public.chip_transfer_requests t where t.room_id=v_round.room_id and t.created_by=v_user_id and t.client_request_id=p_client_request_id;
 if found then return v_request_id; end if;
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
 select coalesce(sum(t.amount_chips),0) into v_pending_chips from public.chip_transfer_requests t where t.from_round_player_id=v_from_id and t.status='pending';
 v_value:=p_amount_chips::numeric*1000;
 if coalesce(v_balance,0)-(v_pending_chips*1000)<v_value then
  raise exception 'Saldo tersedia tidak mencukupi setelah memperhitungkan transfer yang masih menunggu.' using errcode='22023';
 end if;
 insert into public.chip_transfer_requests(room_id,round_id,from_round_player_id,to_round_player_id,amount_chips,status,created_by,client_request_id)
 values(v_round.room_id,v_round.id,v_from_id,v_to_id,p_amount_chips,'pending',v_user_id,p_client_request_id) returning id into v_request_id;
 insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details)
 values(v_round.room_id,v_round.id,v_user_id,'chip_transfer_requested',jsonb_build_object('transfer_id',v_request_id,'from_round_player_id',v_from_id,'to_round_player_id',v_to_id,'amount_chips',p_amount_chips));
 return v_request_id;
end;
$function$;
