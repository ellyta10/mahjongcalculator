/* Mahjong Room shared client adapter.
 * Phase 1: shared authenticated Supabase client for Host / Player / Viewer.
 * No direct table writes: all mutations must go through approved RPC functions.
 * This file intentionally does not change database schema or legacy data.
 */
(function (global) {
  "use strict";

  const SUPABASE_URL = "https://civbnpdjdvyttaxzgwgs.supabase.co";
  const SUPABASE_KEY = "sb_publishable_EAws4HgYAu3-9xL12c7ohQ_81Yd9Qdt";
  const CLIENT_KEY = "__mahjongRoomClientV1";

  if (global[CLIENT_KEY]) return;

  let db = null;
  let initPromise = null;
  const subscriptions = new Map();

  function getClient() {
    if (!global.supabase || typeof global.supabase.createClient !== "function") {
      throw new Error("Supabase JS belum dimuat.");
    }
    if (!db) {
      db = global.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
        auth: {
          persistSession: true,
          autoRefreshToken: true,
          detectSessionInUrl: false
        },
        realtime: { params: { eventsPerSecond: 10 } }
      });
    }
    return db;
  }

  async function init() {
    if (initPromise) return initPromise;
    initPromise = (async function () {
      const client = getClient();
      const current = await client.auth.getSession();
      if (current.error) throw current.error;

      let session = current.data && current.data.session;
      if (session && session.user && session.user.is_anonymous) {
        return { client, session, user: session.user };
      }

      // This app uses guest accounts. Do not silently replace a non-guest identity.
      if (session) {
        throw new Error("Sesi akun non-guest terdeteksi. Keluar dengan sengaja sebelum masuk sebagai tamu.");
      }

      const signed = await client.auth.signInAnonymously();
      if (signed.error) throw signed.error;
      session = signed.data && signed.data.session;
      if (!session || !session.user) throw new Error("Sesi tamu gagal dibuat.");
      return { client, session, user: session.user };
    })().catch(function (error) {
      initPromise = null;
      throw error;
    });
    return initPromise;
  }

  async function rpc(name, args, options) {
    const context = await init();
    const allowed = new Set([
      "create_chip_exchange_room", "create_room", "join_room_by_code",
      "reclaim_dealer_room", "set_starting_balances", "start_round",
      "submit_round_calculation", "review_round_calculation",
      "declare_winners_and_obligations", "request_chip_transfer",
      "send_chip_transfer", "review_chip_transfer", "cancel_chip_transfer",
      "submit_payment_report", "review_payment_report", "record_external_payment",
      "cancel_payment_obligation", "request_bankruptcy",
      "review_bankruptcy_request", "close_round", "archive_round_and_start_next"
    ]);
    if (!allowed.has(name)) throw new Error("RPC tidak diizinkan oleh adapter: " + name);
    const result = await context.client.rpc(name, args || {});
    if (result.error) throw result.error;
    return result.data;
  }

  async function getMembership(roomId) {
    const context = await init();
    const result = await context.client
      .from("room_members")
      .select("room_id,user_id,role,seat_no,display_name,member_status")
      .eq("room_id", roomId)
      .eq("user_id", context.user.id)
      .eq("member_status", "active")
      .maybeSingle();
    if (result.error) throw result.error;
    return result.data;
  }

  async function getRoomSnapshot(roomId) {
    const context = await init();
    const membership = await getMembership(roomId);
    if (!membership) throw new Error("Akun ini bukan anggota aktif Room tersebut.");

    const [room, rounds] = await Promise.all([
      context.client.from("rooms")
        .select("id,name,status,active_round_id,dealer_mode,default_starting_balance,chip_rate")
        .eq("id", roomId).maybeSingle(),
      context.client.from("rounds")
        .select("id,room_id,round_no,status,started_at,closing_at,archived_at")
        .eq("room_id", roomId).order("round_no", { ascending: false })
    ]);
    if (room.error) throw room.error;
    if (rounds.error) throw rounds.error;
    return { membership, room: room.data, rounds: rounds.data || [] };
  }

  function subscribeRoom(roomId, onChange) {
    const client = getClient();
    const key = String(roomId);
    if (subscriptions.has(key)) {
      client.removeChannel(subscriptions.get(key));
      subscriptions.delete(key);
    }
    const channel = client.channel("mahjong-room-" + key);
    // rooms is keyed by id; child tables are filtered by room_id.
    channel.on("postgres_changes", {
      event: "*", schema: "public", table: "rooms", filter: "id=eq." + key
    }, function (payload) {
      if (typeof onChange === "function") onChange({ table: "rooms", payload });
    });
    [
      "room_members", "rounds", "round_players", "round_winners",
      "payment_obligations", "payment_reports", "chip_ledger",
      "bankruptcy_requests", "round_calculation_submissions",
      "chip_transfer_requests", "audit_log"
    ].forEach(function (table) {
      channel.on("postgres_changes", {
        event: "*", schema: "public", table: table, filter: "room_id=eq." + key
      }, function (payload) {
        if (typeof onChange === "function") onChange({ table, payload });
      });
    });
    channel.subscribe(function (status, error) {
      if (typeof onChange === "function") onChange({
        table: "__subscription__",
        payload: { status: status, error: error || null }
      });
    });
    subscriptions.set(key, channel);
    return function unsubscribe() {
      if (subscriptions.get(key) === channel) subscriptions.delete(key);
      client.removeChannel(channel);
    };
  }

  global[CLIENT_KEY] = {
    init,
    rpc,
    getMembership,
    getRoomSnapshot,
    subscribeRoom,
    getClient,
    version: "1.0.0"
  };
})(window);
