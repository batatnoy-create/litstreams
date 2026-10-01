/* LitStreams dApp. Static, no build step, no analytics, nothing stored in localStorage.
 * Reads go through the public RPC (works without a wallet); writes go through the injected wallet. */
(() => {
  "use strict";

  const cfg = window.LITSTREAMS_CONFIG;
  const { ethers } = window;

  const CHAIN = {
    chainId: "0x" + cfg.chainId.toString(16),
    chainName: "LitVM LiteForge",
    nativeCurrency: { name: "zkLTC", symbol: "zkLTC", decimals: 18 },
    rpcUrls: [cfg.rpcUrl],
    blockExplorerUrls: [cfg.explorer],
  };

  const DUST = 10n ** 14n; // 0.0001 zkLTC
  const GAS_RESERVE = 3n * 10n ** 15n; // kept back by the "Max" button
  const PAGE = 25;
  const MIN_SCHEDULE_AHEAD = 300; // scheduled starts must be at least 5 minutes ahead
  const MAX_SCHEDULE_AHEAD = 364 * 86400; // contract allows 365 days; keep a day of clock-skew margin
  const MIN_DURATION = 60;
  const MAX_DURATION = 3650 * 86400;

  const state = { abi: null, rpc: null, read: null, account: null, chainId: null, browser: null };

  /* ---------- tiny DOM helpers ---------- */

  function h(tag, props, ...kids) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(props || {})) {
      if (v == null || v === false) continue;
      if (k === "class") el.className = v;
      else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
      else if (v === true) el.setAttribute(k, "");
      else el.setAttribute(k, v);
    }
    for (const kid of kids.flat()) {
      if (kid == null || kid === false) continue;
      el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
    }
    return el;
  }
  const $ = (sel, root = document) => root.querySelector(sel);
  /** Sets text only when it changed, so per-frame updates stay cheap. */
  function setText(el, text) {
    if (el.__t !== text) { el.__t = text; el.textContent = text; }
  }
  /** Static, trusted SVG paths only (never chain data). */
  function icon(path) {
    const el = h("span", { class: "ico" });
    el.innerHTML = `<svg viewBox="0 0 24 24" aria-hidden="true">${path}</svg>`;
    return el;
  }
  const ICONS = {
    out: '<path d="M7 17 17 7M8 7h9v9"/>',
    in: '<path d="M17 7 7 17M16 17H7V8"/>',
    wallet: '<path d="M4 7a2 2 0 0 1 2-2h11v4"/><path d="M4 7v10a2 2 0 0 0 2 2h13a1 1 0 0 0 1-1V10a1 1 0 0 0-1-1H6a2 2 0 0 1-2-2Z"/><path d="M16 14h.01"/>',
    search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
  };

  /* ---------- formatting ---------- */

  function fmt(wei, dp = 4) {
    const [i, f = ""] = ethers.formatEther(wei).split(".");
    const out = dp ? `${i}.${(f + "0".repeat(dp)).slice(0, dp)}` : i;
    if (wei > 0n && /^0(\.0*)?$/.test(out)) return `<0.${"0".repeat(dp - 1)}1`;
    return out;
  }
  function fmtRate(wei) {
    let s = fmt(wei, 8);
    if (s.startsWith("<")) return s;
    s = s.replace(/0+$/, "");
    const dec = (s.split(".")[1] || "").length;
    return dec < 4 ? s + "0".repeat(4 - dec) : s;
  }
  const DATE_FMT = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit" });
  const fmtDate = (ts) => DATE_FMT.format(new Date(ts * 1000));
  const shortAddr = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;
  function fmtDuration(sec) {
    sec = Math.max(0, Math.floor(sec));
    const units = [["d", 86400], ["h", 3600], ["min", 60], ["s", 1]];
    const parts = [];
    for (const [name, size] of units) {
      const n = Math.floor(sec / size);
      if (n > 0) { parts.push(`${n} ${name}`); sec -= n * size; }
      if (parts.length === 2) break;
    }
    return parts.join(" ") || "0 s";
  }
  const addrLink = (a) => h("a", { href: `${cfg.explorer}/address/${a}`, target: "_blank", rel: "noopener noreferrer", title: a, class: "mono" }, shortAddr(a));
  const txUrl = (hash) => `${cfg.explorer}/tx/${hash}`;
  const nowSec = () => Math.floor(Date.now() / 1000);

  /* ---------- stream math (mirrors the contract, BigInt) ---------- */

  function streamedAt(s, now) {
    if (s.canceled) return s.deposit - s.refunded;
    if (now <= s.startTime) return 0n;
    if (now >= s.endTime) return s.deposit;
    return (s.deposit * BigInt(now - s.startTime)) / BigInt(s.endTime - s.startTime);
  }
  /** Same formula at millisecond resolution, for smooth live counters (display only). */
  function streamedAtMs(s, ms) {
    if (s.canceled) return s.deposit - s.refunded;
    const st = BigInt(s.startTime) * 1000n;
    const en = BigInt(s.endTime) * 1000n;
    const n = BigInt(Math.floor(ms));
    if (n <= st) return 0n;
    if (n >= en) return s.deposit;
    return (s.deposit * (n - st)) / (en - st);
  }
  const withdrawableAt = (s, now) => streamedAt(s, now) - s.withdrawn;
  function refundableAt(s, now) {
    return s.cancelable && !s.canceled && now < s.endTime ? s.deposit - streamedAt(s, now) : 0n;
  }
  function statusAt(s, now) {
    if (s.withdrawn + s.refunded === s.deposit) return "Depleted";
    if (s.canceled) return "Canceled";
    if (now < s.startTime) return "Pending";
    if (now >= s.endTime) return "Settled";
    return "Streaming";
  }
  const statusLabel = (s, now) => {
    const st = statusAt(s, now);
    return s.canceled && st === "Depleted" ? "Canceled" : st;
  };
  function normStream(id, r) {
    return {
      id: BigInt(id),
      sender: r.sender,
      startTime: Number(r.startTime),
      endTime: Number(r.endTime),
      cancelable: r.cancelable,
      canceled: r.canceled,
      recipient: r.recipient,
      deposit: r.deposit,
      withdrawn: r.withdrawn,
      refunded: r.refunded,
    };
  }
  async function fetchStream(id) {
    return normStream(id, await state.read.getStream(id));
  }

  /* ---------- live ticker and counters ---------- */

  function startTicker(fn) {
    let on = true;
    const loop = () => {
      if (!on) return;
      fn(Date.now());
      requestAnimationFrame(loop);
    };
    requestAnimationFrame(loop);
    return () => { on = false; };
  }

  function counter(big) {
    const main = h("span");
    const dim = h("span", { class: "num-dim" });
    const el = h("div", { class: `num${big ? " big" : ""}` }, main, dim, h("span", { class: "num-unit" }, "zkLTC"));
    return {
      el,
      set(wei) {
        const [i, f = ""] = ethers.formatEther(wei).split(".");
        const d = (f + "00000000").slice(0, 8);
        setText(main, `${i}.${d.slice(0, 4)}`);
        setText(dim, d.slice(4));
      },
    };
  }

  function statusBadge() {
    const el = h("span", { class: "badge" });
    return {
      el,
      set(label) {
        setText(el, label);
        const cls = `badge ${label.toLowerCase()}`;
        if (el.className !== cls) el.className = cls;
      },
    };
  }

  function progressBar() {
    const streamed = h("i", { class: "fill-s" });
    const withdrawn = h("i", { class: "fill-w" });
    const el = h("div", { class: "bar" }, streamed, withdrawn);
    return {
      el,
      set(s, streamedWei, live) {
        const pct = (v) => (s.deposit === 0n ? 0 : Number((v * 10000n) / s.deposit) / 100);
        const a = `${pct(streamedWei)}%`;
        const b = `${pct(s.withdrawn)}%`;
        if (streamed.__w !== a) { streamed.__w = a; streamed.style.width = a; }
        if (withdrawn.__w !== b) { withdrawn.__w = b; withdrawn.style.width = b; }
        el.classList.toggle("live", live);
      },
    };
  }

  /* ---------- toasts, dialog, error messages ---------- */

  function toast(kind, message, href) {
    const el = h("div", { class: `toast ${kind}` });
    setToast(el, kind, message, href);
    $("#toasts").append(el);
    return el;
  }
  function setToast(el, kind, message, href) {
    el.className = `toast ${kind}`;
    const kids = [h("button", { type: "button", class: "x", "aria-label": "Dismiss", onclick: () => el.remove() }, "×"), message];
    if (href) kids.push(" ", h("a", { href, target: "_blank", rel: "noopener noreferrer" }, "View on explorer"));
    el.replaceChildren(...kids);
    clearTimeout(el._t);
    if (kind !== "pending") el._t = setTimeout(() => el.remove(), kind === "error" ? 25000 : 12000);
  }

  function confirmDialog({ title, body, confirm = "Confirm", danger = false }) {
    return new Promise((resolve) => {
      const d = $("#dialog");
      d.returnValue = "";
      d.replaceChildren(
        h("h2", null, title),
        h("p", null, body),
        h("div", { class: "dialog-actions" },
          h("button", { type: "button", class: "btn", onclick: () => d.close("no") }, "Not now"),
          h("button", { type: "button", class: `btn ${danger ? "btn-danger-solid" : "btn-primary"}`, onclick: () => d.close("ok") }, confirm)),
      );
      d.addEventListener("close", () => resolve(d.returnValue === "ok"), { once: true });
      d.showModal();
    });
  }

  const ERROR_TEXT = {
    ZeroRecipient: "The recipient cannot be the zero address.",
    SelfStream: "You cannot stream to yourself. Use a different recipient address.",
    InvalidRecipient: "That recipient address is not allowed.",
    ZeroDeposit: "The amount must be greater than zero.",
    DepositTooLarge: "That amount is too large.",
    StartInPast: "The start time is already in the past. Pick a later time or start now.",
    StartTooFar: "The start time is too far in the future (the maximum is 365 days).",
    DurationOutOfRange: "The duration must be between 1 minute and 10 years.",
    StreamNotFound: "This stream does not exist.",
    NotSender: "Only the sender of this stream can do that.",
    NotCancelable: "This stream is not cancelable.",
    AlreadyCanceled: "This stream was already canceled.",
    StreamEnded: "This stream has already ended, so it can no longer be canceled.",
    ZeroAmount: "There is nothing to withdraw yet.",
    AmountExceedsWithdrawable: "That is more than what is currently withdrawable.",
    TransferFailed: "The zkLTC transfer failed because the receiving address rejected it.",
    DirectTransferNotAllowed: "Do not send zkLTC to the contract directly. Use “Create stream”.",
    ReentrancyGuardReentrantCall: "The call was blocked by the reentrancy guard.",
  };

  function humanError(e) {
    if (!e) return "Something went wrong.";
    if (e.code === "ACTION_REJECTED" || e.code === 4001 || e.info?.error?.code === 4001) {
      return "You rejected the request in your wallet. Nothing was sent.";
    }
    if (e.revert?.name && ERROR_TEXT[e.revert.name]) return ERROR_TEXT[e.revert.name];
    for (const data of [e.data, e.error?.data, e.info?.error?.data, e.info?.error?.data?.data]) {
      if (typeof data === "string" && data.startsWith("0x") && state.read) {
        try {
          const parsed = state.read.interface.parseError(data);
          if (parsed && ERROR_TEXT[parsed.name]) return ERROR_TEXT[parsed.name];
        } catch { /* not one of our errors */ }
      }
    }
    if (e.code === "INSUFFICIENT_FUNDS") return "Not enough zkLTC in your wallet for this amount plus network fees.";
    if (e.code === "NETWORK_ERROR" || e.code === "SERVER_ERROR" || e.code === "TIMEOUT") {
      return "Could not reach the LitVM network. Check your connection and try again.";
    }
    if (e.code === -32002) return "Your wallet already has a pending request. Open it and finish or reject it first.";
    return `Transaction failed: ${(e.shortMessage || e.message || "unknown error").slice(0, 160)}`;
  }

  /* ---------- wallet and network ---------- */

  const injected = () => window.ethereum || null;

  async function syncWallet() {
    const eth = injected();
    if (!eth) return;
    try {
      state.chainId = parseInt(await eth.request({ method: "eth_chainId" }), 16);
      const accts = await eth.request({ method: "eth_accounts" });
      state.account = accts && accts[0] ? ethers.getAddress(accts[0]) : null;
      state.browser = new ethers.BrowserProvider(eth, "any");
    } catch {
      state.account = null;
    }
    updateWalletUi();
  }

  async function connect() {
    const eth = injected();
    if (!eth) {
      toast("error", "No wallet found. Open this page in your wallet's browser (MetaMask, Rabby) or install a wallet extension, then reload.");
      return;
    }
    try {
      await eth.request({ method: "eth_requestAccounts" });
      await syncWallet();
      rerender();
    } catch (e) {
      toast("error", humanError(e));
    }
  }

  async function switchNetwork() {
    const eth = injected();
    if (!eth) {
      toast("error", "No wallet found. Open this page in your wallet's browser (MetaMask, Rabby) or install a wallet extension, then reload.");
      return false;
    }
    try {
      await eth.request({ method: "wallet_switchEthereumChain", params: [{ chainId: CHAIN.chainId }] });
    } catch (e) {
      if (e.code === 4001) { toast("error", humanError(e)); return false; }
      try {
        await eth.request({ method: "wallet_addEthereumChain", params: [CHAIN] });
      } catch (e2) {
        toast("error", humanError(e2));
        return false;
      }
    }
    await syncWallet();
    return state.chainId === cfg.chainId;
  }

  function updateWalletUi() {
    const btn = $("#connect-btn");
    if (state.account) {
      const hue = (i) => (parseInt(state.account.slice(i, i + 2), 16) / 255) * 360;
      const right = state.chainId === cfg.chainId;
      btn.className = "btn wallet-btn";
      btn.title = `${state.account}\nClick to copy`;
      btn.replaceChildren(
        h("span", { class: "avatar", style: `background:linear-gradient(135deg,hsl(${hue(2)} 70% 62%),hsl(${hue(4)} 70% 42%))` }),
        h("span", { class: "addr mono" }, shortAddr(state.account)),
        h("span", { class: `dot ${right ? "ok" : "warn"}`, title: right ? "Connected to LitVM LiteForge" : "Wrong network" }),
      );
    } else {
      btn.className = "btn btn-primary";
      btn.title = "";
      btn.replaceChildren("Connect wallet");
    }
    const banner = $("#net-banner");
    const wrong = injected() && state.chainId != null && state.chainId !== cfg.chainId;
    banner.hidden = !wrong;
    if (wrong) {
      banner.replaceChildren(
        `Your wallet is on the wrong network (chain ${state.chainId}). LitStreams runs on LitVM LiteForge testnet (chain ${cfg.chainId}).`,
        h("button", { type: "button", class: "btn btn-sm", onclick: switchNetwork }, "Add / switch to LitVM LiteForge"),
      );
    }
  }

  async function onWalletClick() {
    if (!state.account) { connect(); return; }
    try {
      await navigator.clipboard.writeText(state.account);
      toast("success", "Address copied.");
    } catch { /* clipboard not available */ }
  }

  /** Returns a contract bound to the wallet signer, or null if the user must still connect / switch. */
  async function getWrite() {
    if (!state.account) {
      await connect();
      if (!state.account) return null;
    }
    if (state.chainId !== cfg.chainId) {
      if (!(await switchNetwork())) return null;
    }
    const signer = await state.browser.getSigner();
    return new ethers.Contract(cfg.contractAddress, state.abi, signer);
  }

  /** Runs a transaction with pending / success / error feedback. Returns the receipt or null. */
  async function sendTx(label, send, done) {
    const write = await getWrite();
    if (!write) return null;
    const t = toast("pending", `${label}: confirm in your wallet…`);
    try {
      const tx = await send(write);
      setToast(t, "pending", `${label}: waiting for confirmation…`, txUrl(tx.hash));
      const rc = await tx.wait();
      if (!rc || rc.status !== 1) throw new Error("Transaction reverted");
      setToast(t, "success", done ? done(rc) : `${label}: done.`, txUrl(tx.hash));
      return rc;
    } catch (e) {
      setToast(t, "error", humanError(e));
      return null;
    }
  }

  /** Returns the first event with this name emitted by the LitStreams contract in a receipt, or null. */
  function eventIn(rc, name) {
    for (const log of rc.logs) {
      if (log.address.toLowerCase() !== cfg.contractAddress.toLowerCase()) continue;
      try {
        const ev = state.read.interface.parseLog(log);
        if (ev && ev.name === name) return ev;
      } catch { /* other event */ }
    }
    return null;
  }

  /* ---------- shared stream actions (Withdraw / Pay out / Cancel / Renounce) ---------- */

  /** ctx.get() returns the latest stream; ctx.after() re-reads data after a transaction. */
  function buildActions(ctx) {
    let busy = false;
    const mk = (cls, label, kind) => h("button", { type: "button", class: `btn btn-sm ${cls}`, onclick: () => run(kind) }, label);
    const withdraw = mk("btn-primary", "Withdraw", "withdraw");
    const pay = mk("btn-primary", "Pay out now", "pay");
    const cancel = mk("btn-danger", "Cancel stream", "cancel");
    const renounce = mk("", "Give up cancel right", "renounce");
    renounce.title = "Makes the stream permanent. It does NOT stop the stream.";
    const el = h("div", { class: "actions" }, withdraw, pay, cancel, renounce);
    const all = [withdraw, pay, cancel, renounce];

    async function run(kind) {
      if (busy) return;
      const s = ctx.get();
      const id = s.id.toString();
      const now = nowSec();
      let send;
      let label;
      let done;
      if (kind === "cancel") {
        const ok = await confirmDialog({
          title: `Cancel stream #${id}?`,
          body: `You get back about ${fmt(refundableAt(s, now), 6)} zkLTC right now. What has already streamed stays withdrawable by the recipient. This cannot be undone.`,
          confirm: "Cancel stream",
          danger: true,
        });
        if (!ok) return;
        label = `Cancel stream #${id}`;
        send = (c) => c.cancel(id);
      } else if (kind === "renounce") {
        const ok = await confirmDialog({
          title: `Give up the right to cancel stream #${id}?`,
          body: "This does NOT stop the stream: it keeps flowing to the recipient exactly as before. You just lose the ability to cancel it, so the whole deposit will go to the recipient and you can never take it back. To stop a stream, use “Cancel stream” instead. This cannot be undone.",
          confirm: "Give up cancel right",
          danger: true,
        });
        if (!ok) return;
        label = `Renounce stream #${id}`;
        send = (c) => c.renounce(id);
        done = () => `Stream #${id} is now permanent: you can no longer cancel it. It keeps streaming to the recipient.`;
      } else {
        label = kind === "withdraw" ? `Withdraw from stream #${id}` : `Pay out stream #${id}`;
        send = (c) => c.withdrawMax(id);
        done = (rc) => {
          const ev = eventIn(rc, "Withdrawn");
          const amt = ev ? `${fmt(ev.args.amount, 6)} zkLTC` : "The streamed amount";
          return `${amt} sent to the recipient (${shortAddr(s.recipient)}). The stream keeps running, so new money accrues every second.`;
        };
      }
      busy = true;
      for (const b of all) b.disabled = true;
      try {
        if (await sendTx(label, send, done)) await ctx.after();
      } finally {
        busy = false;
        for (const b of all) b.disabled = false;
      }
    }

    return {
      el,
      update(s, now) {
        const me = state.account;
        const isSender = !!me && me === s.sender;
        const isRecipient = !!me && me === s.recipient;
        const can = withdrawableAt(s, now) > 0n;
        const refundable = refundableAt(s, now) > 0n;
        withdraw.hidden = !(me && isRecipient && can);
        pay.hidden = !(me && !isRecipient && can);
        setText(pay, isSender ? "Pay out now" : "Pay out to recipient");
        cancel.hidden = !(isSender && refundable);
        renounce.hidden = !(isSender && refundable);
      },
    };
  }

  /* ---------- router ---------- */

  let cleanup = null;
  const routes = {
    create: viewCreate,
    outgoing: (root) => viewList(root, "out"),
    incoming: (root) => viewList(root, "in"),
    stream: viewStream,
    "how-it-works": viewHow,
  };

  function parseHash() {
    const parts = location.hash.replace(/^#\/?/, "").split("/");
    return { name: routes[parts[0]] ? parts[0] : "create", arg: parts[1] };
  }
  function rerender() {
    if (cleanup) { try { cleanup(); } catch { /* ignore */ } cleanup = null; }
    const { name, arg } = parseHash();
    for (const a of document.querySelectorAll("nav a")) a.classList.toggle("active", a.dataset.route === name);
    const root = $("#view");
    root.replaceChildren();
    window.scrollTo(0, 0);
    cleanup = routes[name](root, arg) || null;
  }

  const pageHead = (title, lead) => h("div", { class: "page-head" }, h("h1", { class: "grad-text" }, title), lead ? h("p", { class: "lead" }, lead) : null);

  const connectPrompt = (title, text) =>
    h("div", { class: "card empty" },
      icon(ICONS.wallet),
      h("h2", null, title),
      h("p", null, text),
      h("button", { type: "button", class: "btn btn-primary", onclick: connect }, "Connect wallet"));

  /* ---------- Create view ---------- */

  const PRESETS = [
    { key: "demo", label: "10 min · demo", sec: 600 },
    { key: "1h", label: "1 hour", sec: 3600 },
    { key: "1d", label: "1 day", sec: 86400 },
    { key: "7d", label: "7 days", sec: 7 * 86400 },
    { key: "30d", label: "30 days", sec: 30 * 86400 },
    { key: "365d", label: "365 days", sec: 365 * 86400 },
    { key: "custom", label: "Custom", sec: null },
  ];
  const UNITS = { minutes: 60, hours: 3600, days: 86400 };
  const toLocalInput = (ms) => new Date(ms - new Date(ms).getTimezoneOffset() * 60000).toISOString().slice(0, 16);

  function viewCreate(root) {
    let preset = "demo";
    let startMode = "now";
    let balance = null;
    let alive = true;

    const recipient = h("input", { type: "text", id: "recipient", placeholder: "0x…", autocomplete: "off", spellcheck: "false" });
    const amount = h("input", { type: "text", id: "amount", inputmode: "decimal", placeholder: "0.005", autocomplete: "off" });
    const maxBtn = h("button", { type: "button", class: "chip-btn", hidden: true, onclick: () => {
      if (balance != null && balance > GAS_RESERVE) { amount.value = ethers.formatEther(balance - GAS_RESERVE); update(); }
    } }, "Max");
    const balanceHint = h("p", { class: "hint" });
    const customNum = h("input", { type: "number", min: "1", step: "any", value: "1", "aria-label": "Custom duration" });
    const customUnit = h("select", { "aria-label": "Custom duration unit" },
      Object.keys(UNITS).map((u) => h("option", { value: u, selected: u === "hours" }, u)));
    const customRow = h("div", { class: "row", style: "margin-top:.6rem", hidden: true }, customNum, customUnit);
    const scheduled = h("input", { type: "datetime-local", id: "start-at", style: "margin-top:.6rem", hidden: true });
    const cancelable = h("input", { type: "checkbox", id: "cancelable", class: "switch", checked: true });
    const previewBody = h("div");
    const problems = h("ul", { class: "errors", hidden: true });
    const submit = h("button", { type: "button", class: "btn btn-primary btn-block", disabled: true }, "Create stream");
    const result = h("div");

    const presetBtns = PRESETS.map((p) =>
      h("button", { type: "button", class: "seg-btn", "data-key": p.key, "aria-pressed": String(p.key === preset),
        onclick: () => {
          preset = p.key;
          customRow.hidden = preset !== "custom";
          for (const b of presetBtns) b.setAttribute("aria-pressed", String(b.dataset.key === preset));
          update();
        } }, p.label));
    const startBtns = ["now", "scheduled"].map((m) =>
      h("button", { type: "button", class: "seg-btn", "data-mode": m, "aria-pressed": String(m === startMode),
        onclick: () => {
          startMode = m;
          scheduled.hidden = m !== "scheduled";
          if (m === "scheduled" && !scheduled.value) scheduled.value = toLocalInput(Date.now() + 15 * 60000);
          for (const b of startBtns) b.setAttribute("aria-pressed", String(b.dataset.mode === startMode));
          update();
        } }, m === "now" ? "Start now" : "Schedule"));

    function readForm() {
      const errs = [];
      let ready = true;
      const p = { recipient: null, deposit: null, duration: null, start: 0, cancelable: cancelable.checked };

      const rv = recipient.value.trim();
      let rOk = false;
      if (!rv) ready = false;
      else if (!ethers.isAddress(rv)) errs.push("The recipient is not a valid address. Check for typos (a wrong checksum is rejected).");
      else {
        const addr = ethers.getAddress(rv);
        if (addr === ethers.ZeroAddress) errs.push("The recipient cannot be the zero address.");
        else if (state.account && addr === state.account) errs.push("You cannot stream to your own address.");
        else if (addr === ethers.getAddress(cfg.contractAddress)) errs.push("The recipient cannot be the LitStreams contract.");
        else { p.recipient = addr; rOk = true; }
      }
      recipient.classList.toggle("invalid", !!rv && !rOk);
      if (!rOk) ready = false;

      const av = amount.value.trim().replace(",", ".");
      let aOk = false;
      if (!av) ready = false;
      else if (!/^\d*\.?\d{0,18}$/.test(av) || av === ".") errs.push("The amount must be a number with at most 18 decimals.");
      else {
        const wei = ethers.parseEther(av);
        if (wei === 0n) errs.push("The amount must be greater than zero.");
        else if (balance != null && wei > balance) errs.push(`The amount is more than your balance (${fmt(balance)} zkLTC).`);
        else { p.deposit = wei; aOk = true; }
      }
      amount.classList.toggle("invalid", !!av && !aOk);
      if (!aOk) ready = false;

      let dur;
      if (preset === "custom") {
        const n = Number(customNum.value);
        dur = Number.isFinite(n) && n > 0 ? Math.round(n * UNITS[customUnit.value]) : NaN;
      } else dur = PRESETS.find((x) => x.key === preset).sec;
      if (!Number.isFinite(dur)) ready = false;
      else if (dur < MIN_DURATION || dur > MAX_DURATION) {
        errs.push("The duration must be between 1 minute and 3650 days.");
        ready = false;
      } else p.duration = dur;

      if (startMode === "scheduled") {
        const ms = scheduled.value ? new Date(scheduled.value).getTime() : NaN;
        if (Number.isNaN(ms)) ready = false;
        else {
          const ts = Math.floor(ms / 1000);
          if (ts < nowSec() + MIN_SCHEDULE_AHEAD) { errs.push("A scheduled start must be at least 5 minutes from now. Choose “Start now” to begin immediately."); ready = false; }
          else if (ts > nowSec() + MAX_SCHEDULE_AHEAD) { errs.push("A scheduled start can be at most 364 days from now."); ready = false; }
          else p.start = ts;
        }
      }
      return { p, errs, ready };
    }

    const stat = (label, value) => h("div", { class: "stat" }, h("span", null, label), h("b", null, value));

    function update() {
      const { p, errs, ready } = readForm();
      problems.replaceChildren(...errs.map((m) => h("li", null, m)));
      problems.hidden = errs.length === 0;
      submit.disabled = !ready;

      if (p.deposit && p.duration && p.recipient) {
        const startTs = p.start || nowSec();
        const endTs = startTs + p.duration;
        const d = BigInt(p.duration);
        previewBody.replaceChildren(
          h("p", { class: "summary-text" },
            "From ", h("strong", null, p.start ? fmtDate(startTs) : `now (${fmtDate(startTs)})`),
            " to ", h("strong", null, fmtDate(endTs)), ", ",
            h("strong", { class: "mono", title: p.recipient }, shortAddr(p.recipient)),
            " will receive ", h("strong", null, `${fmt(p.deposit, 4)} zkLTC`),
            ` over ${fmtDuration(p.duration)}: about `, h("strong", null, `${fmtRate((p.deposit * 86400n) / d)} per day`),
            ` (${fmtRate(p.deposit / d)} per second). You `,
            h("strong", null, p.cancelable ? "CAN" : "CANNOT"),
            p.cancelable ? " cancel and take back the part that has not streamed yet." : " cancel and take back the unstreamed part.",
          ),
          h("div", { class: "stat-grid" },
            stat("Per second", fmtRate(p.deposit / d)),
            stat("Per hour", fmtRate((p.deposit * 3600n) / d)),
            stat("Per day", fmtRate((p.deposit * 86400n) / d)),
            stat("Per 30 days", fmtRate((p.deposit * 2592000n) / d)),
            stat("Starts", p.start ? fmtDate(startTs) : "On confirmation"),
            stat("Ends", p.start ? fmtDate(endTs) : `~${fmtDate(endTs)}`)),
          h("div", { class: `mode-note${p.cancelable ? "" : " cant"}` },
            p.cancelable
              ? "Cancelable: you can stop this stream at any time and get the unstreamed part back."
              : "Not cancelable: the full amount is committed to the recipient and cannot be taken back."),
        );
      } else previewBody.replaceChildren(h("p", { class: "placeholder" }, "Fill in the recipient and amount to see a plain-English summary of your stream before you sign."));
    }

    async function refreshBalance() {
      if (!state.account) { balance = null; balanceHint.textContent = "Connect your wallet to see your balance."; maxBtn.hidden = true; return; }
      try {
        const b = await state.rpc.getBalance(state.account);
        if (!alive) return;
        balance = b;
        balanceHint.textContent = `Balance: ${fmt(b)} zkLTC. Keep a little for network fees.`;
        maxBtn.hidden = b <= GAS_RESERVE;
      } catch { balanceHint.textContent = ""; }
      update();
    }

    submit.addEventListener("click", async () => {
      const { p, ready } = readForm();
      if (!ready || !p.recipient) return;
      submit.disabled = true;
      result.replaceChildren();
      const rc = await sendTx("Create stream", (c) => c.createStream(p.recipient, p.start, p.duration, p.cancelable, { value: p.deposit }));
      if (rc) {
        let id = null;
        for (const log of rc.logs) {
          if (log.address.toLowerCase() !== cfg.contractAddress.toLowerCase()) continue;
          try {
            const ev = state.read.interface.parseLog(log);
            if (ev && ev.name === "StreamCreated") id = ev.args.id;
          } catch { /* other event */ }
        }
        result.replaceChildren(h("div", { class: "card", style: "margin-top:1rem" },
          h("h2", { class: "ok" }, id != null ? `Stream #${id} created` : "Stream created"),
          h("p", { class: "muted" }, "The recipient can now withdraw what has streamed at any time. Share the stream page so they can watch it tick."),
          h("div", { class: "actions" },
            id != null ? h("a", { class: "btn btn-primary btn-sm", href: `#/stream/${id}` }, "Open stream page") : null,
            h("a", { class: "btn btn-sm", href: "#/outgoing" }, "My outgoing streams"),
            h("a", { class: "btn btn-sm", href: txUrl(rc.hash), target: "_blank", rel: "noopener noreferrer" }, "Transaction"))));
        refreshBalance();
      }
      update();
    });

    for (const el of [recipient, amount, customNum, customUnit, scheduled, cancelable]) {
      el.addEventListener("input", update);
      el.addEventListener("change", update);
    }

    root.append(
      pageHead("Stream money by the second", "Lock zkLTC for one recipient. It unlocks linearly, every second, until the end time. Get paid in hard money, every second."),
      h("div", { class: "grid-2" },
        h("div", { class: "card" },
          h("div", { class: "field" }, h("label", { for: "recipient" }, "Recipient address"), recipient),
          h("div", { class: "field" },
            h("label", { for: "amount" }, "Amount"),
            h("div", { class: "input-wrap" }, amount, h("div", { class: "suffix" }, maxBtn, "zkLTC")),
            balanceHint),
          h("div", { class: "field" }, h("span", { class: "label" }, "Duration"), h("div", { class: "seg" }, presetBtns), customRow),
          h("div", { class: "field" }, h("span", { class: "label" }, "Start"), h("div", { class: "seg" }, startBtns), scheduled),
          h("label", { class: "toggle-card", for: "cancelable" },
            cancelable,
            h("div", null, h("b", null, "Cancelable"),
              h("span", { class: "t" }, "On: you can stop the stream any time and take back the unstreamed part. Off: the deposit is committed. You can also give up the right to cancel later (“renounce”).")))),
        h("div", { class: "sticky" },
          h("div", { class: "card" }, h("h3", { style: "margin-bottom:.75rem" }, "Review"), previewBody, problems, submit),
          result)),
    );
    update();
    refreshBalance();
    return () => { alive = false; };
  }

  /* ---------- Outgoing / Incoming lists ---------- */

  function buildCard(id, mode, ctx) {
    const out = mode === "out";
    let s = null;
    const badge = statusBadge();
    const hero = counter(false);
    const bar = progressBar();
    const party = h("span", { class: "sc-party" });
    const lock = h("span", { class: "badge locked", title: "The sender gave up the right to cancel" }, "Non-cancelable");
    const v = {};
    const kv = (key, label) => { v[key] = h("b"); return h("div", null, h("span", null, label), v[key]); };
    const actions = buildActions({ get: () => s, after: ctx.after });
    const el = h("div", { class: "card stream-card" },
      h("div", { class: "sc-top" }, h("a", { class: "sc-id", href: `#/stream/${id}` }, `#${id}`), badge.el, lock, party),
      h("div", { class: "hero" }, h("div", { class: "hero-label" }, out ? "Streamed so far" : "Available to withdraw"), hero.el),
      bar.el,
      h("div", { class: "kv" },
        kv("deposit", "Deposit"), kv("withdrawn", out ? "Paid out so far" : "Withdrawn so far"),
        kv("ready", out ? "Ready to pay out" : "Available now"),
        kv("rest", out ? "You can take back" : "Still to stream"),
        kv("start", "Start"), kv("end", "End"), kv("cancelable", "Cancelable")),
      actions.el);

    return {
      el,
      get net() { return s.deposit - s.refunded; },
      get stream() { return s; },
      setData(next) {
        const first = s === null;
        s = next;
        if (first) {
          party.append(out ? "To " : "From ", addrLink(out ? s.recipient : s.sender));
          setText(v.start, fmtDate(s.startTime));
          setText(v.end, fmtDate(s.endTime));
        }
        setText(v.deposit, `${fmt(s.deposit)} zkLTC`);
        setText(v.withdrawn, `${fmt(s.withdrawn, 6)} zkLTC`);
      },
      tick(ms) {
        const now = Math.floor(ms / 1000);
        const streamed = streamedAtMs(s, ms);
        const avail = streamed > s.withdrawn ? streamed - s.withdrawn : 0n;
        const label = statusLabel(s, now);
        badge.set(label);
        lock.hidden = s.cancelable || s.canceled;
        setText(v.ready, `${fmt(avail, 6)} zkLTC`);
        hero.set(out ? streamed : avail);
        bar.set(s, streamed, label === "Streaming");
        const refundable = refundableAt(s, now);
        setText(v.rest, out ? `${fmt(refundable, 6)} zkLTC` : `${fmt(s.deposit - s.refunded - streamed, 6)} zkLTC`);
        setText(v.cancelable, s.canceled ? "Canceled" : refundable > 0n ? "Yes" : s.cancelable ? "Not any more (ended)" : "No (final)");
        actions.update(s, now);
        return avail;
      },
    };
  }

  function viewList(root, mode) {
    const out = mode === "out";
    const title = out ? "Outgoing streams" : "Incoming streams";
    const head = pageHead(title, out
      ? "Streams you created. Paying out sends what has streamed to the recipient on their behalf."
      : "Money streaming to you. Watch it grow and withdraw whenever you like.");
    if (!state.account) {
      root.append(head, connectPrompt(out ? "Connect to see your outgoing streams" : "Connect to see your incoming streams",
        "Read-only streams can also be opened by link, no wallet needed."));
      return;
    }

    const account = state.account;
    const countFn = out ? "sentCount" : "receivedCount";
    const idsFn = out ? "sentIds" : "receivedIds";
    const cards = new Map(); // id -> card
    const order = [];
    let nextEnd = 0;
    let hideDust = true;
    let alive = true;
    let loading = false;

    const list = h("div");
    const status = h("span", { class: "muted small" });
    const moreBtn = h("button", { type: "button", class: "btn", hidden: true, onclick: () => loadMore() }, "Load older streams");
    const dustBox = h("input", { type: "checkbox", class: "switch", id: "dust", checked: true });
    dustBox.addEventListener("change", () => { hideDust = dustBox.checked; refreshVisibility(); });
    const emptyEl = h("div", { class: "card empty", hidden: true });
    const totals = counter(false);
    const totalsBox = h("div", { class: "card totals", hidden: true }, h("div", { class: "hero-label" }, "Available to withdraw now"), totals.el);
    const skeletons = [h("div", { class: "card skeleton" }), h("div", { class: "card skeleton" })];

    root.append(
      head,
      ...(out ? [] : [totalsBox]),
      h("div", { class: "list-tools" },
        h("label", { class: "inline", for: "dust" }, dustBox, "Hide dust (under 0.0001 zkLTC)"), status),
      emptyEl, ...skeletons, list, h("div", { style: "text-align:center;margin-top:1rem" }, moreBtn),
    );

    const ctx = { after: () => refreshAll() };

    function refreshVisibility() {
      let shown = 0;
      let hidden = 0;
      for (const id of order) {
        const c = cards.get(id);
        const hide = hideDust && c.net < DUST;
        c.el.hidden = hide;
        if (hide) hidden++; else shown++;
      }
      setText(status, order.length ? `${shown} shown${hidden ? ` · ${hidden} hidden as dust` : ""}` : "");
      const noneYet = order.length === 0 && nextEnd === 0 && !loading;
      const allHidden = order.length > 0 && shown === 0 && nextEnd === 0;
      emptyEl.hidden = !(noneYet || allHidden);
      if (noneYet) {
        emptyEl.replaceChildren(icon(out ? ICONS.out : ICONS.in),
          h("h2", null, out ? "No outgoing streams yet" : "No incoming streams yet"),
          h("p", null, out ? "Create your first stream in a few seconds." : "When someone streams zkLTC to your address, it shows up here."),
          out ? h("a", { class: "btn btn-primary", href: "#/create" }, "Create a stream") : null);
      } else if (allHidden) {
        emptyEl.replaceChildren(icon(ICONS.search), h("h2", null, "Everything here is dust"),
          h("p", null, "All streams are below 0.0001 zkLTC. Turn off “Hide dust” to see them."));
      }
    }

    async function loadMore() {
      if (loading) return;
      loading = true;
      moreBtn.disabled = true;
      try {
        const start = Math.max(0, nextEnd - PAGE);
        const ids = await state.read[idsFn](account, start, nextEnd - start);
        const fresh = [...ids].reverse();
        const data = await Promise.all(fresh.map(fetchStream));
        if (!alive) return;
        fresh.forEach((rawId, i) => {
          const id = String(rawId);
          const card = buildCard(id, mode, ctx);
          card.setData(data[i]);
          card.tick(Date.now());
          cards.set(id, card);
          order.push(id);
          list.append(card.el);
        });
        nextEnd = start;
      } catch (e) {
        setText(status, humanError(e));
      } finally {
        loading = false;
        moreBtn.disabled = false;
        moreBtn.hidden = nextEnd === 0;
        for (const sk of skeletons) sk.remove();
        if (alive) refreshVisibility();
      }
    }

    async function refreshAll() {
      try {
        const data = await Promise.all(order.map(fetchStream));
        if (!alive) return;
        order.forEach((id, i) => cards.get(id).setData(data[i]));
        refreshVisibility();
      } catch { /* keep showing the last known data */ }
    }

    (async () => {
      try {
        nextEnd = Number(await state.read[countFn](account));
      } catch (e) {
        for (const sk of skeletons) sk.remove();
        setText(status, humanError(e));
        return;
      }
      if (!alive) return;
      if (nextEnd === 0) { for (const sk of skeletons) sk.remove(); refreshVisibility(); return; }
      await loadMore();
    })();

    const stopTicker = startTicker((ms) => {
      let sum = 0n;
      for (const id of order) {
        const c = cards.get(id);
        const avail = c.tick(ms);
        if (!c.el.hidden) sum += avail;
      }
      if (!out) {
        totalsBox.hidden = order.length === 0;
        totals.set(sum);
      }
    });
    const sync = setInterval(refreshAll, 15000);
    return () => { alive = false; stopTicker(); clearInterval(sync); };
  }

  /* ---------- Stream page (public, read-only without a wallet) ---------- */

  function viewStream(root, arg) {
    if (!/^\d{1,18}$/.test(arg || "")) {
      root.append(h("div", { class: "card empty" }, icon(ICONS.search), h("h2", null, "Invalid stream link"),
        h("p", null, "Stream ids are plain numbers, for example #/stream/1."), h("a", { class: "btn btn-primary", href: "#/create" }, "Create a stream")));
      return;
    }
    const id = BigInt(arg);
    let alive = true;
    let s = null;
    let stopTicker = null;
    let sync = null;
    const holder = h("div");
    root.append(h("div", { class: "card skeleton" }), holder);

    async function load() {
      try {
        s = await fetchStream(id);
      } catch (e) {
        if (!alive) return;
        root.replaceChildren(h("div", { class: "card empty" }, icon(ICONS.search),
          h("h2", null, `Stream #${id} not found`),
          h("p", null, humanError(e).startsWith("Transaction failed") ? "Could not load this stream. Try again in a moment." : humanError(e)),
          h("a", { class: "btn btn-primary", href: "#/create" }, "Create a stream")));
        return;
      }
      if (!alive) return;
      build();
    }

    function build() {
      root.replaceChildren();
      const badge = statusBadge();
      const streamedC = counter(true);
      const availC = counter(true);
      const bar = progressBar();
      const timeline = h("span");
      const v = {};
      const row = (key, label, content) => { v[key] = content || h("dd"); return [h("dt", null, label), v[key]]; };
      const actions = buildActions({ get: () => s, after: refresh });
      const youTag = (a) => (state.account && state.account === a ? h("span", { class: "muted" }, " (you)") : null);
      const created = h("dd", null, "…");
      const dur = BigInt(s.endTime - s.startTime);

      root.append(
        h("div", { class: "crumb" },
          h("h1", { class: "grad-text" }, `Stream #${id}`), badge.el, h("span", { class: "spacer" }),
          h("button", { type: "button", class: "btn btn-sm", onclick: async () => {
            try { await navigator.clipboard.writeText(location.href); toast("success", "Link copied. Anyone can open it, no wallet needed."); } catch { toast("error", "Could not copy the link."); }
          } }, "Copy link")),
        h("div", { class: "card" },
          h("div", { class: "hero-grid" },
            h("div", null, h("div", { class: "hero-label" }, "Streamed so far"), streamedC.el),
            h("div", null, h("div", { class: "hero-label" }, "Available to withdraw"), availC.el)),
          bar.el,
          h("div", { class: "timeline" }, h("span", null, `Start ${fmtDate(s.startTime)}`), timeline, h("span", null, `End ${fmtDate(s.endTime)}`)),
          actions.el),
        ...(state.account ? [] : [h("p", { class: "hint", style: "margin-top:.75rem" }, "Read-only view. Connect a wallet to withdraw, pay out or cancel.")]),
        h("div", { class: "card", style: "margin-top:1rem" },
          h("h3", { style: "margin-bottom:.9rem" }, "Details"),
          h("dl", { class: "dl" },
            h("dt", null, "Sender"), h("dd", null, addrLink(s.sender), youTag(s.sender)),
            h("dt", null, "Recipient"), h("dd", null, addrLink(s.recipient), youTag(s.recipient)),
            row("deposit", "Deposit"), row("withdrawn", "Withdrawn"),
            s.canceled ? row("refunded", "Refunded to sender") : null,
            h("dt", null, "Rate"), h("dd", null, dur > 0n ? `${fmtRate((s.deposit * 86400n) / dur)} per day · ${fmtRate(s.deposit / dur)} per second` : "n/a"),
            h("dt", null, "Duration"), h("dd", null, fmtDuration(s.endTime - s.startTime)),
            row("cancelable", "Cancelable"),
            h("dt", null, "Contract"), h("dd", null, addrLink(cfg.contractAddress)),
            h("dt", null, "Created in"), created)),
      );

      const render = (ms) => {
        const now = Math.floor(ms / 1000);
        const streamed = streamedAtMs(s, ms);
        const avail = streamed > s.withdrawn ? streamed - s.withdrawn : 0n;
        const label = statusLabel(s, now);
        badge.set(label);
        streamedC.set(streamed);
        availC.set(avail);
        bar.set(s, streamed, label === "Streaming");
        if (s.canceled) setText(timeline, "Canceled");
        else if (now < s.startTime) setText(timeline, `Starts in ${fmtDuration(s.startTime - now)}`);
        else if (now < s.endTime) setText(timeline, `Ends in ${fmtDuration(s.endTime - now)}`);
        else setText(timeline, `Ended ${fmtDuration(now - s.endTime)} ago`);
        setText(v.deposit, `${fmt(s.deposit, 6)} zkLTC`);
        setText(v.withdrawn, `${fmt(s.withdrawn, 6)} zkLTC`);
        if (v.refunded) setText(v.refunded, `${fmt(s.refunded, 6)} zkLTC`);
        const refundable = refundableAt(s, now);
        setText(v.cancelable, s.canceled ? "Canceled" : refundable > 0n ? "Yes, the sender can still cancel" : s.cancelable ? "No longer (stream ended)" : "No (final)");
        actions.update(s, now);
      };
      render(Date.now());
      stopTicker = startTicker(render);
      sync = setInterval(refresh, 15000);

      // Best effort: find the creation transaction from the StreamCreated event.
      state.read.queryFilter(state.read.filters.StreamCreated(id), cfg.deployBlock, "latest")
        .then((logs) => {
          if (!alive || !logs.length) { created.textContent = "n/a"; return; }
          created.replaceChildren(h("a", { class: "mono", href: txUrl(logs[0].transactionHash), target: "_blank", rel: "noopener noreferrer" }, `tx ${shortAddr(logs[0].transactionHash)}`));
        })
        .catch(() => { if (alive) created.textContent = "n/a"; });
    }

    async function refresh() {
      try {
        const next = await fetchStream(id);
        if (alive) s = next;
      } catch { /* keep last known data */ }
    }

    load();
    return () => { alive = false; if (stopTicker) stopTicker(); if (sync) clearInterval(sync); };
  }

  /* ---------- How it works ---------- */

  function viewHow(root) {
    const step = (n, title, text) => h("div", { class: "card step" }, h("div", { class: "n" }, n), h("h3", null, title), h("p", null, text));
    const risk = (title, text) => h("li", null, h("b", null, title), text);
    root.append(
      pageHead("How it works", "LitStreams moves native zkLTC from a sender to a recipient continuously, second by second, with no middleman."),
      h("div", { class: "steps" },
        step(1, "Lock", "The sender deposits zkLTC into the contract and picks a recipient, a start and a duration."),
        step(2, "Stream", "From the start, the recipient's share grows every second, in a straight line, until the end. No keepers, no fees."),
        step(3, "Withdraw", "The recipient withdraws what has streamed at any time. Anyone can trigger a payout, but the money always goes to the recipient."),
        step(4, "Cancel (optional)", "If the stream is cancelable, the sender can stop it. The unstreamed part returns to the sender; the streamed part stays with the recipient.")),
      h("div", { class: "card" },
        h("h2", null, "Read this before you use it"),
        h("ul", { class: "risks" },
          risk("Testnet only. No real value. ", "This runs on the LitVM LiteForge testnet. zkLTC here is not worth anything. Do not send real funds anywhere."),
          risk("Unaudited. ", "The contract was reviewed internally and tested heavily, but it has not had an external audit. There is no mainnet version."),
          risk("Cancelable vs. not cancelable. ", "A cancelable stream can be stopped by the sender at any moment, so the recipient should only count on what has already streamed. A non-cancelable stream is a commitment: the sender can never take the money back. A sender can also “renounce” the right to cancel later."),
          risk("Losing the recipient key. ", "The recipient address cannot be changed. If its key is lost, the streamed money is stuck forever. The sender can only reclaim the unstreamed part, and only if the stream is cancelable."),
          risk("Time comes from the sequencer. ", "Streams run on block timestamps from the LitVM sequencer, not on your clock. Counters on this site use your device clock and re-sync with the chain, so they can differ by a second or two."),
          risk("Rounding. ", "Amounts round down until the stream ends. After the end time the recipient can withdraw exactly the full deposit."),
          risk("Spam streams. ", "Anyone can create tiny streams to any address. The lists on this site hide “dust” (under 0.0001 zkLTC) by default."),
          risk("Trust assumptions. ", "LitVM uses an AnyTrust data layer and a bridge, which add their own trust assumptions. The LitStreams contract itself has no owner, no admin, no pause, no upgrades and no fees."))),
      h("p", { class: "hint", style: "margin-top:1rem" }, "Contract: ", addrLink(cfg.contractAddress), " (source verified on the explorer)."),
    );
  }

  /* ---------- boot ---------- */

  async function boot() {
    try {
      const res = await fetch("abi/LitStreams.json");
      state.abi = await res.json();
    } catch {
      $("#view").replaceChildren(h("div", { class: "card empty" }, h("h2", null, "Could not load the contract ABI"), h("p", null, "Reload the page.")));
      return;
    }
    state.rpc = new ethers.JsonRpcProvider(cfg.rpcUrl, cfg.chainId, { staticNetwork: true });
    state.read = new ethers.Contract(cfg.contractAddress, state.abi, state.rpc);

    $("#footer-contract").replaceChildren("Contract ", addrLink(cfg.contractAddress));
    $("#connect-btn").addEventListener("click", onWalletClick);

    const eth = injected();
    if (eth && eth.on) {
      eth.on("accountsChanged", async () => { await syncWallet(); rerender(); });
      eth.on("chainChanged", async () => { await syncWallet(); rerender(); });
    }
    await syncWallet();
    window.addEventListener("hashchange", rerender);
    rerender();
  }

  boot();
})();
