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
  const PAGE = 25;
  const MIN_SCHEDULE_AHEAD = 300; // scheduled starts must be at least 5 minutes ahead
  const MAX_SCHEDULE_AHEAD = 364 * 86400; // contract allows 365 days; keep a day of clock-skew margin
  const MIN_DURATION = 60;
  const MAX_DURATION = 3650 * 86400;

  const state = {
    abi: null,
    rpc: null,
    read: null,
    account: null,
    chainId: null,
    browser: null,
  };

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
  const fmtDate = (ts) => new Date(ts * 1000).toLocaleString();
  const shortAddr = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;
  function fmtDuration(sec) {
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

  /* ---------- toasts and error messages ---------- */

  const toastBox = () => $("#toasts");
  function toast(kind, message, href) {
    const el = h("div", { class: `toast ${kind}` });
    setToast(el, kind, message, href);
    toastBox().append(el);
    return el;
  }
  function setToast(el, kind, message, href) {
    el.className = `toast ${kind}`;
    const kids = [h("button", { type: "button", "aria-label": "Dismiss", onclick: () => el.remove() }, "×"), message];
    if (href) kids.push(" ", h("a", { href, target: "_blank", rel: "noopener noreferrer" }, "View on explorer"));
    el.replaceChildren(...kids);
    clearTimeout(el._t);
    if (kind !== "pending") el._t = setTimeout(() => el.remove(), kind === "error" ? 25000 : 12000);
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
    } catch (e) {
      state.account = null;
    }
    updateWalletUi();
  }

  async function connect() {
    const eth = injected();
    if (!eth) {
      toast("error", "No wallet found. Install MetaMask or Rabby in this browser, then reload the page.");
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
      toast("error", "No wallet found. Install MetaMask or Rabby in this browser, then reload the page.");
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
      btn.textContent = shortAddr(state.account);
      btn.title = state.account;
      btn.disabled = true;
      btn.classList.remove("btn-primary");
    } else {
      btn.textContent = "Connect wallet";
      btn.title = "";
      btn.disabled = false;
      btn.classList.add("btn-primary");
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
  async function sendTx(label, send) {
    const write = await getWrite();
    if (!write) return null;
    const t = toast("pending", `${label}: confirm in your wallet…`);
    try {
      const tx = await send(write);
      setToast(t, "pending", `${label}: waiting for confirmation…`, txUrl(tx.hash));
      const rc = await tx.wait();
      if (!rc || rc.status !== 1) throw new Error("Transaction reverted");
      setToast(t, "success", `${label}: done.`, txUrl(tx.hash));
      return rc;
    } catch (e) {
      setToast(t, "error", humanError(e));
      return null;
    }
  }

  /* ---------- router ---------- */

  let cleanup = null;
  const routes = { create: viewCreate, outgoing: viewOutgoing, incoming: viewLater, stream: viewLater, "how-it-works": viewLater };

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
    cleanup = routes[name](root, arg) || null;
  }

  function viewLater(root) {
    root.append(h("div", { class: "card empty" }, "This view is coming in the next build step."));
  }

  const connectPrompt = (text) =>
    h("div", { class: "card empty" },
      h("p", null, text),
      h("button", { type: "button", class: "btn btn-primary", onclick: connect }, "Connect wallet"));

  /* ---------- Create view ---------- */

  const PRESETS = [
    { key: "demo", label: "10 min (demo)", sec: 600 },
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
    const balanceHint = h("p", { class: "hint" });
    const customNum = h("input", { type: "number", min: "1", step: "any", value: "1", "aria-label": "Custom duration" });
    const customUnit = h("select", { "aria-label": "Custom duration unit" },
      Object.keys(UNITS).map((u) => h("option", { value: u, selected: u === "hours" }, u)));
    const customRow = h("div", { class: "row", hidden: true }, customNum, customUnit);
    const scheduled = h("input", { type: "datetime-local", id: "start-at", hidden: true });
    const cancelable = h("input", { type: "checkbox", id: "cancelable", checked: true });
    const summary = h("div", { class: "summary", hidden: true });
    const problems = h("ul", { class: "errors", hidden: true });
    const submit = h("button", { type: "button", class: "btn btn-primary btn-block", disabled: true }, "Create stream");
    const result = h("div");

    const presetBtns = PRESETS.map((p) =>
      h("button", { type: "button", class: "chip", "data-key": p.key, "aria-pressed": String(p.key === preset),
        onclick: () => { preset = p.key; customRow.hidden = preset !== "custom"; for (const b of presetBtns) b.setAttribute("aria-pressed", String(b.dataset.key === preset)); update(); } },
      p.label));
    const startBtns = ["now", "scheduled"].map((m) =>
      h("button", { type: "button", class: "chip", "data-mode": m, "aria-pressed": String(m === startMode),
        onclick: () => {
          startMode = m;
          scheduled.hidden = m !== "scheduled";
          if (m === "scheduled" && !scheduled.value) scheduled.value = toLocalInput(Date.now() + 15 * 60000);
          for (const b of startBtns) b.setAttribute("aria-pressed", String(b.dataset.mode === startMode));
          update();
        } },
      m === "now" ? "Start now" : "Scheduled"));

    function readForm() {
      const errs = [];
      let ready = true;
      const p = { recipient: null, deposit: null, duration: null, start: 0, cancelable: cancelable.checked };

      // Recipient
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

      // Amount
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

      // Duration
      let dur;
      if (preset === "custom") {
        const n = Number(customNum.value);
        dur = Number.isFinite(n) && n > 0 ? Math.round(n * UNITS[customUnit.value]) : NaN;
      } else dur = PRESETS.find((x) => x.key === preset).sec;
      if (!Number.isFinite(dur)) { ready = false; }
      else if (dur < MIN_DURATION || dur > MAX_DURATION) {
        errs.push("The duration must be between 1 minute and 3650 days.");
        ready = false;
      } else p.duration = dur;

      // Start
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

    function update() {
      const { p, errs, ready } = readForm();
      problems.replaceChildren(...errs.map((m) => h("li", null, m)));
      problems.hidden = errs.length === 0;
      submit.disabled = !ready;

      if (p.deposit && p.duration && p.recipient) {
        const startTs = p.start || nowSec();
        const endTs = startTs + p.duration;
        const d = BigInt(p.duration);
        const day = (p.deposit * 86400n) / d;
        const sec = p.deposit / d;
        summary.hidden = false;
        summary.classList.toggle("cant", !p.cancelable);
        summary.replaceChildren(
          "From ", h("strong", null, p.start ? fmtDate(startTs) : `now (${fmtDate(startTs)})`),
          " to ", h("strong", null, fmtDate(endTs)), ", ",
          h("strong", { class: "mono", title: p.recipient }, shortAddr(p.recipient)),
          " will receive ", h("strong", null, `${fmt(p.deposit, 4)} zkLTC`),
          ` (${fmtDuration(p.duration)}), about `, h("strong", null, `${fmtRate(day)} per day`),
          ` (${fmtRate(sec)} per second). You `,
          h("strong", null, p.cancelable ? "CAN" : "CANNOT"),
          p.cancelable
            ? " cancel and take back the part that has not streamed yet."
            : " cancel: once created, the whole amount goes to the recipient over time and you cannot take it back.",
        );
      } else summary.hidden = true;
    }

    async function refreshBalance() {
      if (!state.account) { balance = null; balanceHint.textContent = "Connect your wallet to see your balance."; return; }
      try {
        const b = await state.rpc.getBalance(state.account);
        if (!alive) return;
        balance = b;
        balanceHint.replaceChildren(`Your balance: ${fmt(b)} zkLTC. Keep a little for network fees.`);
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
        result.replaceChildren(h("div", { class: "card" },
          h("h2", null, id != null ? `Stream #${id} created` : "Stream created"),
          h("p", null, "The recipient can now withdraw what has streamed at any time."),
          h("div", { class: "actions" },
            h("a", { class: "btn btn-primary", href: "#/outgoing" }, "See my outgoing streams"),
            h("a", { class: "btn", href: txUrl(rc.hash), target: "_blank", rel: "noopener noreferrer" }, "Transaction on explorer"))));
        refreshBalance();
      }
      update();
    });

    for (const el of [recipient, amount, customNum, customUnit, scheduled, cancelable]) {
      el.addEventListener("input", update);
      el.addEventListener("change", update);
    }

    root.append(
      h("h1", null, "Create a stream"),
      h("p", { class: "muted" }, "Lock zkLTC for one recipient. It unlocks linearly, every second, until the end time."),
      h("div", { class: "card" },
        h("label", { for: "recipient" }, "Recipient address"), recipient,
        h("label", { for: "amount" }, "Amount (zkLTC)"), amount, balanceHint,
        h("label", null, "Duration"), h("div", { class: "chips" }, presetBtns), customRow,
        h("label", null, "Start"), h("div", { class: "chips" }, startBtns), scheduled,
        h("label", { class: "toggle", for: "cancelable" }, cancelable,
          h("span", null, h("b", null, "Cancelable. "),
            "If on, you can stop the stream at any time and get the unstreamed part back; what already streamed stays with the recipient. If off, the deposit is committed and cannot be taken back. You can also give up the right to cancel later (“renounce”).")),
        summary, problems, submit),
      result,
    );
    update();
    refreshBalance();
    return () => { alive = false; };
  }

  /* ---------- Outgoing view ---------- */

  function viewOutgoing(root) {
    if (!state.account) { root.append(h("h1", null, "Outgoing streams"), connectPrompt("Connect your wallet to see the streams you created.")); return; }

    const account = state.account;
    const streams = new Map(); // id (string) -> stream
    const cards = new Map(); // id (string) -> { el, refs }
    let order = []; // ids, newest first
    let nextEnd = 0; // sentIds index below which older streams are still unloaded
    let hideDust = true;
    let alive = true;
    let loading = false;

    const list = h("div");
    const status = h("p", { class: "muted small" });
    const moreBtn = h("button", { type: "button", class: "btn", hidden: true, onclick: () => loadMore() }, "Load older streams");
    const dustBox = h("input", { type: "checkbox", id: "dust", checked: true });
    dustBox.addEventListener("change", () => { hideDust = dustBox.checked; applyAll(); });

    root.append(
      h("h1", null, "Outgoing streams"),
      h("p", { class: "muted" }, "Streams you created. Paying out sends the streamed amount to the recipient on their behalf."),
      h("div", { class: "list-tools" },
        h("label", { for: "dust" }, dustBox, "Hide dust (less than 0.0001 zkLTC)"), status),
      list, moreBtn,
    );

    async function fetchStream(id) {
      const raw = await state.read.getStream(id);
      const s = normStream(id, raw);
      streams.set(String(id), s);
      return s;
    }

    async function loadMore() {
      if (loading) return;
      loading = true;
      moreBtn.disabled = true;
      try {
        const start = Math.max(0, nextEnd - PAGE);
        const ids = await state.read.sentIds(account, start, nextEnd - start);
        const fresh = [...ids].reverse();
        await Promise.all(fresh.map(fetchStream));
        if (!alive) return;
        for (const id of fresh) {
          order.push(String(id));
          const card = buildCard(String(id));
          cards.set(String(id), card);
          list.append(card.el);
        }
        nextEnd = start;
        applyAll();
      } catch (e) {
        status.textContent = humanError(e);
      } finally {
        loading = false;
        moreBtn.disabled = false;
        moreBtn.hidden = nextEnd === 0;
      }
    }

    async function refreshAll() {
      try {
        await Promise.all(order.map(fetchStream));
        if (alive) applyAll();
      } catch { /* keep showing the last known data */ }
    }

    function buildCard(id) {
      const refs = {};
      const idLink = h("a", { href: `#/stream/${id}` }, `Stream #${id}`);
      refs.badge = h("span", { class: "badge" });
      refs.bar = h("div");
      const kv = (key, label) => { refs[key] = h("b"); return h("div", null, h("span", null, label), refs[key]); };
      refs.recipient = h("div", null, h("span", null, "Recipient"), h("b"));
      refs.cancel = h("button", { type: "button", class: "btn btn-danger btn-sm", onclick: () => doCancel(id) }, "Cancel stream");
      refs.renounce = h("button", { type: "button", class: "btn btn-sm", onclick: () => doRenounce(id) }, "Renounce cancel");
      refs.pay = h("button", { type: "button", class: "btn btn-primary btn-sm", onclick: () => doPay(id) }, "Pay out now");
      const el = h("div", { class: "card" },
        h("div", { class: "stream-head" }, idLink, refs.badge),
        h("div", { class: "progress" }, refs.bar),
        h("div", { class: "kv" },
          refs.recipient,
          kv("deposit", "Deposit"), kv("streamed", "Streamed"), kv("withdrawn", "Withdrawn by recipient"),
          kv("payable", "Ready to pay out"), kv("refundable", "You can still take back"),
          kv("start", "Start"), kv("end", "End"), kv("cancelable", "Cancelable")),
        h("div", { class: "actions" }, refs.pay, refs.cancel, refs.renounce));
      return { el, refs };
    }

    function updateCard(id, now) {
      const s = streams.get(id);
      const { el, refs } = cards.get(id);
      const net = s.deposit - s.refunded;
      el.hidden = hideDust && net < DUST;
      const st = statusAt(s, now);
      const label = s.canceled && st === "Depleted" ? "Canceled" : st;
      refs.badge.textContent = label;
      refs.badge.className = `badge ${label.toLowerCase()}`;
      const streamed = streamedAt(s, now);
      const pct = s.deposit === 0n ? 0 : Number((streamed * 10000n) / s.deposit) / 100;
      refs.bar.style.width = `${pct}%`;
      const withdrawable = withdrawableAt(s, now);
      const refundable = refundableAt(s, now);
      const r = refs.recipient.lastChild;
      if (!r.firstChild) r.append(addrLink(s.recipient));
      refs.deposit.textContent = `${fmt(s.deposit)} zkLTC`;
      refs.streamed.textContent = `${fmt(streamed, 6)} zkLTC`;
      refs.withdrawn.textContent = `${fmt(s.withdrawn)} zkLTC`;
      refs.payable.textContent = `${fmt(withdrawable, 6)} zkLTC`;
      refs.refundable.textContent = `${fmt(refundable, 6)} zkLTC`;
      refs.start.textContent = fmtDate(s.startTime);
      refs.end.textContent = fmtDate(s.endTime);
      refs.cancelable.textContent = s.canceled ? "Canceled" : refundable > 0n ? "Yes" : s.cancelable ? "Not any more (ended)" : "No (final)";
      refs.pay.hidden = withdrawable <= 0n;
      refs.cancel.hidden = refundable <= 0n;
      refs.renounce.hidden = refundable <= 0n;
    }

    function applyAll() {
      const now = nowSec();
      let hidden = 0;
      for (const id of order) {
        updateCard(id, now);
        if (cards.get(id).el.hidden) hidden++;
      }
      const total = order.length;
      status.textContent = total === 0 ? "" : `${total - hidden} shown${hidden ? `, ${hidden} hidden as dust` : ""}`;
      if (total === 0 && nextEnd === 0 && !loading) {
        list.replaceChildren(h("div", { class: "card empty" }, h("p", null, "You have not created any streams yet."), h("a", { class: "btn btn-primary", href: "#/create" }, "Create one")));
      }
    }

    async function afterTx() { await refreshAll(); }

    async function doCancel(id) {
      const s = streams.get(id);
      const refundable = refundableAt(s, nowSec());
      const msg = `Cancel stream #${id}?\n\nYou get back about ${fmt(refundable, 6)} zkLTC now. What has already streamed stays withdrawable by the recipient. This cannot be undone.`;
      if (!window.confirm(msg)) return;
      if (await sendTx(`Cancel stream #${id}`, (c) => c.cancel(id))) await afterTx();
    }
    async function doRenounce(id) {
      const msg = `Give up the right to cancel stream #${id}?\n\nAfter this the whole deposit will go to the recipient over time and you can never take it back. This cannot be undone.`;
      if (!window.confirm(msg)) return;
      if (await sendTx(`Renounce stream #${id}`, (c) => c.renounce(id))) await afterTx();
    }
    async function doPay(id) {
      const s = streams.get(id);
      const msg = `Pay out about ${fmt(withdrawableAt(s, nowSec()), 6)} zkLTC to ${s.recipient}?\n\nThe money always goes to the recipient, not to you.`;
      if (!window.confirm(msg)) return;
      if (await sendTx(`Pay out stream #${id}`, (c) => c.withdrawMax(id))) await afterTx();
    }

    (async () => {
      try {
        nextEnd = Number(await state.read.sentCount(account));
      } catch (e) { status.textContent = humanError(e); return; }
      if (!alive) return;
      if (nextEnd === 0) { applyAll(); return; }
      await loadMore();
    })();

    const tick = setInterval(() => { if (order.length) applyAll(); }, 1000);
    const sync = setInterval(refreshAll, 15000);
    return () => { alive = false; clearInterval(tick); clearInterval(sync); };
  }

  /* ---------- boot ---------- */

  async function boot() {
    try {
      const res = await fetch("abi/LitStreams.json");
      state.abi = await res.json();
    } catch {
      $("#view").replaceChildren(h("div", { class: "card empty" }, "Could not load the contract ABI. Reload the page."));
      return;
    }
    const provider = new ethers.JsonRpcProvider(cfg.rpcUrl, cfg.chainId, { staticNetwork: true });
    state.rpc = provider;
    state.read = new ethers.Contract(cfg.contractAddress, state.abi, provider);

    $("#footer-contract").replaceChildren("Contract ", addrLink(cfg.contractAddress));
    $("#connect-btn").addEventListener("click", connect);

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
