-- Instant player-to-player chip transfers with dealer-only audited reversals.
alter table public.chip_ledger
 add column if not exists client_request_id uuid,
 add column if not exists reversal_of_ledger_id uuid references public.chip_ledger(id) on delete restrict;
alter table public.chip_ledger drop constraint if exists chip_ledger_check;
alter table public.chip_ledger add constraint chip_ledger_check check (
 (entry_type='payment' and from_round_player_id is not null and to_round_player_id is not null and from_round_player_id<>to_round_player_id and payment_report_id is not null)
 or (entry_type in ('dealer_adjustment','bankruptcy_reset') and ((from_round_player_id is null)<>(to_round_player_id is null)) and payment_report_id is null)
 or (entry_type in ('player_transfer','transfer_reversal') and from_round_player_id is not null and to_round_player_id is not null and from_round_player_id<>to_round_player_id and payment_report_id is null)
);
alter table public.chip_ledger drop constraint if exists chip_ledger_entry_type_check;
alter table public.chip_ledger add constraint chip_ledger_entry_type_check check(entry_type in ('payment','dealer_adjustment','player_transfer','bankruptcy_reset','transfer_reversal'));
create unique index if not exists chip_ledger_transfer_idempotency_idx on public.chip_ledger(room_id,created_by,client_request_id) where client_request_id is not null and entry_type='player_transfer';
create unique index if not exists chip_ledger_single_reversal_idx on public.chip_ledger(reversal_of_ledger_id) where reversal_of_ledger_id is not null;

create or replace function public.send_chip_transfer(p_round_id uuid,p_to_user_id uuid,p_amount_chips bigint,p_client_request_id uuid)
returns uuid language plpgsql security definer set search_path to ''
as $function$
declare v_round public.rounds%rowtype; v_room public.rooms%rowtype; v_user_id uuid; v_from_id uuid; v_to_id uuid; v_balance numeric; v_existing uuid; v_entry_id uuid; v_amount numeric;
begin
 if p_amount_chips is null or p_amount_chips<=0 then raise exception 'Jumlah chips harus lebih dari 0.' using errcode='22023'; end if;
 if p_amount_chips>9223372036854775 then raise exception 'Jumlah chips terlalu besar.' using errcode='22003'; end if;
 if p_client_request_id is null then raise exception 'Request ID wajib diisi.' using errcode='22023'; end if;
 select * into v_round from public.rounds where id=p_round_id for update;
 if not found then raise exception 'Ronde tidak ditemukan.' using errcode='22023'; end if;
 v_user_id:=private.assert_room_role(v_round.room_id,array['player']::text[]);
 select * into v_room from public.rooms where id=v_round.room_id for update;
 if not found or v_room.status<>'open' or v_room.active_round_id is distinct from v_round.id or v_round.status not in ('active','setup') then raise exception 'Transfer hanya tersedia di Room dan ronde aktif.' using errcode='55000'; end if;
 select id into v_existing from public.chip_ledger where room_id=v_round.room_id and created_by=v_user_id and client_request_id=p_client_request_id and entry_type='player_transfer';
 if v_existing is not null then return v_existing; end if;
 if p_to_user_id is null or p_to_user_id=v_user_id then raise exception 'Pilih Player lain sebagai penerima.' using errcode='22023'; end if;
 select id into v_from_id from public.round_players where room_id=v_round.room_id and round_id=v_round.id and user_id=v_user_id;
 select rp.id into v_to_id from public.round_players rp join public.room_members rm on rm.room_id=rp.room_id and rm.user_id=rp.user_id where rp.room_id=v_round.room_id and rp.round_id=v_round.id and rp.user_id=p_to_user_id and rm.member_status='active' and (rm.role='player' or (rm.role='dealer' and rm.seat_no is not null));
 if v_from_id is null or v_to_id is null then raise exception 'Pengirim dan penerima harus Player aktif di ronde ini.' using errcode='42501'; end if;
 perform 1 from public.round_players where id in (v_from_id,v_to_id) order by id for update;
 if exists(select 1 from public.bankruptcy_requests where round_id=v_round.id and round_player_id in (v_from_id,v_to_id) and status='requested') then raise exception 'Transfer tidak tersedia selama proses reset bangkrut berlangsung.' using errcode='55000'; end if;
 select current_balance into v_balance from public.round_player_balances where round_player_id=v_from_id;
 v_amount:=p_amount_chips::numeric*1000;
 if coalesce(v_balance,0)<v_amount then raise exception 'Saldo chips tidak mencukupi.' using errcode='22023'; end if;
 insert into public.chip_ledger(room_id,round_id,entry_type,from_round_player_id,to_round_player_id,amount,payment_report_id,created_by,memo,client_request_id)
 values(v_round.room_id,v_round.id,'player_transfer',v_from_id,v_to_id,v_amount::bigint,null,v_user_id,'Transfer langsung: '||p_amount_chips::text||' chips',p_client_request_id) returning id into v_entry_id;
 insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details) values(v_round.room_id,v_round.id,v_user_id,'chip_transfer_sent',jsonb_build_object('ledger_entry_id',v_entry_id,'from_round_player_id',v_from_id,'to_round_player_id',v_to_id,'amount_chips',p_amount_chips));
 return v_entry_id;
end;
$function$;

create or replace function public.cancel_chip_transfer(p_ledger_entry_id uuid,p_reason text)
returns uuid language plpgsql security definer set search_path to ''
as $function$
declare v_original public.chip_ledger%rowtype; v_round public.rounds%rowtype; v_room public.rooms%rowtype; v_user_id uuid; v_recipient_balance numeric; v_reversal_id uuid; v_reason text:=nullif(btrim(p_reason),'');
begin
 if v_reason is null or length(v_reason)>500 then raise exception 'Alasan pembatalan wajib diisi (maksimal 500 karakter).' using errcode='22023'; end if;
 select * into v_original from public.chip_ledger where id=p_ledger_entry_id for update;
 if not found or v_original.entry_type<>'player_transfer' or v_original.from_round_player_id is null or v_original.to_round_player_id is null then raise exception 'Transaksi transfer tidak ditemukan atau tidak dapat dibatalkan.' using errcode='22023'; end if;
 select * into v_round from public.rounds where id=v_original.round_id and room_id=v_original.room_id for update;
 if not found then raise exception 'Ronde tidak ditemukan.' using errcode='22023'; end if;
 v_user_id:=private.assert_room_role(v_original.room_id,array['dealer']::text[]);
 select * into v_room from public.rooms where id=v_original.room_id for update;
 if not found or v_room.status<>'open' or v_room.active_round_id is distinct from v_round.id or v_round.status not in ('active','setup') then raise exception 'Transfer hanya dapat dibatalkan pada ronde aktif.' using errcode='55000'; end if;
 if exists(select 1 from public.chip_ledger where reversal_of_ledger_id=v_original.id) then raise exception 'Transfer ini sudah pernah dibatalkan.' using errcode='55000'; end if;
 perform 1 from public.round_players where id in (v_original.from_round_player_id,v_original.to_round_player_id) order by id for update;
 select current_balance into v_recipient_balance from public.round_player_balances where round_player_id=v_original.to_round_player_id;
 if coalesce(v_recipient_balance,0)<v_original.amount then raise exception 'Saldo penerima tidak cukup untuk reversal. Minta penerima mengembalikan chips terlebih dahulu.' using errcode='55000'; end if;
 insert into public.chip_ledger(room_id,round_id,entry_type,from_round_player_id,to_round_player_id,amount,payment_report_id,created_by,memo,reversal_of_ledger_id)
 values(v_original.room_id,v_original.round_id,'transfer_reversal',v_original.to_round_player_id,v_original.from_round_player_id,v_original.amount,null,v_user_id,'Pembatalan transfer '||v_original.id::text||': '||v_reason,v_original.id) returning id into v_reversal_id;
 insert into public.audit_log(room_id,round_id,actor_user_id,event_type,details) values(v_original.room_id,v_original.round_id,v_user_id,'chip_transfer_cancelled',jsonb_build_object('original_ledger_entry_id',v_original.id,'reversal_ledger_entry_id',v_reversal_id,'reason',v_reason,'amount',v_original.amount));
 return v_reversal_id;
end;
$function$;
revoke all on function public.send_chip_transfer(uuid,uuid,bigint,uuid) from public,anon;
revoke all on function public.cancel_chip_transfer(uuid,text) from public,anon;
grant execute on function public.send_chip_transfer(uuid,uuid,bigint,uuid) to authenticated;
grant execute on function public.cancel_chip_transfer(uuid,text) to authenticated;
