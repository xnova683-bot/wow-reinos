/* ================================================================
   REINOS DE AZEROTH - multijugador (Supabase + GitHub Pages)
   Recursos que suben solos + edificios y tropas con temporizador.
   ================================================================ */
const SB_URL = "https://upvqpyxscajqoszqsowa.supabase.co/rest/v1";
const KEY = "sb_publishable_SVq_ig5V7naKJojtdy78IA_uLLMntrI";

const $ = sel => document.querySelector(sel);
const esc = s => String(s == null ? "" : s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const un = n => Number(n || 0).toLocaleString("es", { maximumFractionDigits: 0 });
const fmt = n => Number(n || 0).toLocaleString("es", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
function tfmt(sec){
  sec = Math.max(0, Math.round(sec));
  if(sec < 60) return sec + "s";
  const m = Math.floor(sec / 60), s = sec % 60;
  if(m < 60) return m + "m " + String(s).padStart(2, "0") + "s";
  const h = Math.floor(m / 60);
  return h + "h " + String(m % 60).padStart(2, "0") + "m";
}

async function sbRpc(fn, body){
  const r = await fetch(`${SB_URL}/rpc/${fn}`, {
    method: "POST",
    headers: { "apikey": KEY, "Authorization": "Bearer " + KEY, "Content-Type": "application/json" },
    body: JSON.stringify(body || {})
  });
  const txt = await r.text();
  let data = null;
  try{ data = txt ? JSON.parse(txt) : null; }catch(_){ data = null; }
  if(!r.ok){
    let msg = "Error del servidor.";
    try{ if(data && data.message) msg = data.message; else if(typeof data === "string") msg = data; }catch(_){}
    throw new Error(msg);
  }
  return data;
}
async function pbkdf2Hex(pass, saltHex, iters){
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(pass), "PBKDF2", false, ["deriveBits"]);
  const salt = new Uint8Array(saltHex.match(/.{2}/g).map(h => parseInt(h, 16)));
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", salt, iterations: iters, hash: "SHA-256" }, key, 256);
  return [...new Uint8Array(bits)].map(b => b.toString(16).padStart(2, "0")).join("");
}
function newSalt(){
  const a = new Uint8Array(16);
  crypto.getRandomValues(a);
  return [...a].map(b => b.toString(16).padStart(2, "0")).join("");
}
function shortMsg(e){
  const m = (e && e.message) || "Algo falló.";
  return m.length > 170 ? m.slice(0, 167) + "…" : m;
}
let _toastT;
function toast(msg, bad){
  const t = $("#toast"); if(!t) return;
  t.textContent = msg; t.className = "toast" + (bad ? " bad" : "");
  clearTimeout(_toastT); _toastT = setTimeout(() => t.classList.add("hidden"), 2800);
}
function notice(el, text, cls){
  if(!el) return;
  el.textContent = text;
  el.className = "notice" + (cls ? " " + cls : "");
}
const hora = ms => { try{ return new Date(Number(ms)).toLocaleTimeString("es", { hour: "2-digit", minute: "2-digit" }); }catch(_){ return ""; } };
function modalClose(){ const m = $("#modal"); if(m) m.classList.add("hidden"); }
function modal(html){
  const m = $("#modal"), box = $("#modalBox"); if(!m || !box) return;
  box.innerHTML = html + '<div style="text-align:center;margin-top:16px"><button class="btn sm" id="modalClose">Cerrar</button></div>';
  m.classList.remove("hidden");
  const btn = box.querySelector("#modalClose"); if(btn) btn.onclick = modalClose;
  m.onclick = e => { if(e.target === m) modalClose(); };
}
function showScreen(id){
  ["screenPortal", "screenGame", "screenAcct"].forEach(s => {
    const el = document.getElementById(s); if(el) el.classList.toggle("hidden", s !== id);
  });
}

/* ---------------- datos del juego ---------------- */
const BLD = {
  mina:       { e: "⛏️", n: "Mina de Mineral", d: "Extrae mineral del subsuelo",      p: "+{v} mineral/h" },
  aserradero: { e: "🪵", n: "Aserradero",      d: "Corta madera para tus obras",      p: "+{v} madera/h" },
  tesoreria:  { e: "💰", n: "Tesorería",       d: "Genera oro para tu reino",         p: "+{v} oro/h" },
  almacen:    { e: "📦", n: "Almacén",         d: "Guarda más recursos",              p: "Capacidad: {v}" },
  cuartel:    { e: "⚔️", n: "Cuartel",         d: "Entrena a tus tropas",             p: "Necesario para tropas" },
  herreria:   { e: "🛠️", n: "Herrería",        d: "Forja acero: sube el daño de tus tropas", p: "+{v}% daño de tus tropas" },
  fortaleza:  { e: "🏯", n: "Fortaleza",       d: "Muros reforzados: tus tropas aguantan más", p: "+{v}% aguante (menos bajas)" },
  mercado:    { e: "🏪", n: "Mercado",         d: "Rutas comerciales: más producción de recursos", p: "+{v}% producción de recursos" },
  muralla:    { e: "🛡️", n: "Muralla",         d: "Protege tu reino",                 p: "Defensa de tu reino" }
};
const TRP = {
  soldado: { n: "Soldado", d: "Infantería básica", img: "img/soldado.jpg" },
  arquero: { n: "Arquero", d: "Ataca a distancia", img: "img/arquero.jpeg" },
  jinete:  { n: "Jinete",  d: "Carga rápida", img: "img/jinete.jpg" },
  mago:    { n: "Mago",    d: "Daño mágico", img: "img/mago.jpg" },
  paladin: { e: "🛡️", n: "Paladín", d: "Guerrero sagrado, brutal contra magos y dragones" },
  dragon:  { e: "🐉", n: "Dragón",  d: "Bestia legendaria, arrasa infantería y magos" }
};
const CTR = {
  soldado: { up: "🐎 jinete",                  dn: "🏹 arquero y 🐉 dragón" },
  arquero: { up: "🗡️ soldado, 🔮 mago y 🐉 dragón", dn: "🐎 jinete" },
  jinete:  { up: "🏹 arquero y 🛡️ paladín",    dn: "🗡️ soldado, 🔮 mago y 🐉 dragón" },
  mago:    { up: "🗡️ soldado y 🐎 jinete",     dn: "🏹 arquero, 🛡️ paladín y 🐉 dragón" },
  paladin: { up: "🔮 mago y 🐉 dragón",        dn: "🐎 jinete" },
  dragon:  { up: "🗡️ soldado, 🐎 jinete y 🔮 mago", dn: "🏹 arquero y 🛡️ paladín" }
};

/* posiciones FIJAS de los 20 castillos sobre el mapa (x, y) */
const SLOT_POS = [
  [-500,-380],[-180,-520],[140,-490],[430,-430],[600,-170],
  [620,120],[470,380],[200,520],[-90,560],[-380,500],
  [-600,250],[-620,-80],[-360,-150],[-140,-300],[120,-220],
  [350,-120],[330,170],[60,250],[-260,200],[250,-320]
];
/* PRNG con semilla fija -> decoraciones siempre en la misma posición */
function mulberry32(a){ return function(){ a |= 0; a = (a + 0x6D2B79F5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
const DECOS = (() => {
  const rnd = mulberry32(20240517), out = []; let tries = 0;
  while(out.length < 46 && tries < 1200){
    tries++;
    const ang = rnd() * Math.PI * 2, rad = 150 + rnd() * 560;
    const x = Math.cos(ang) * rad, y = Math.sin(ang) * rad;
    if(Math.hypot(x, y) < 165) continue;
    if(SLOT_POS.some(s => Math.hypot(s[0] - x, s[1] - y) < 96)) continue;
    if(out.some(d => Math.hypot(d.x - x, d.y - y) < 54)) continue;
    const r = rnd();
    const e = r < 0.52 ? "🌲" : r < 0.80 ? "🌳" : r < 0.92 ? "🪨" : "⛰️";
    out.push({ x: Math.round(x), y: Math.round(y), e, s: (e === "⛰️" ? 1.25 : 0.85 + rnd() * 0.5) });
  }
  return out;
})();

/* ---------------- portal (entrar / crear) ---------------- */
const Auth = {
  fac: null,
  init(){
    $("#tabLogin").onclick = () => this.tab("login");
    $("#tabReg").onclick = () => this.tab("reg");
    document.querySelectorAll(".facRow button").forEach(b => {
      b.onclick = () => {
        this.fac = b.dataset.fac;
        document.querySelectorAll(".facRow button").forEach(x => x.classList.toggle("on", x === b));
      };
    });
    $("#formLogin").onsubmit = e => { e.preventDefault(); this.login(); };
    $("#formReg").onsubmit = e => { e.preventDefault(); this.register(); };
    $("#btnLogout").onclick = () => this.logout();
    $("#btnLogout2").onclick = () => this.logout();
    $("#btnAcct").onclick = () => this.acct();
    $("#btnBack").onclick = () => showScreen("screenGame");
    $("#formPw").onsubmit = e => { e.preventDefault(); this.changePw(); };
    document.querySelectorAll(".gameTabs button").forEach(b => {
      b.onclick = () => {
        document.querySelectorAll(".gameTabs button").forEach(x => x.classList.toggle("on", x === b));
        Game.tab = b.dataset.tab;
        $("#tabBld").classList.toggle("hidden", Game.tab !== "bld");
        $("#tabTroop").classList.toggle("hidden", Game.tab !== "troop");
        $("#tabMap").classList.toggle("hidden", Game.tab !== "map");
        $("#tabMil").classList.toggle("hidden", Game.tab !== "mil");
        $("#tabAlly").classList.toggle("hidden", Game.tab !== "ally");
        $("#tabRank").classList.toggle("hidden", Game.tab !== "rank");
        if(Game.tab === "rank") Game.loadRank();
        if(Game.tab === "bld") Game.renderBld();
        if(Game.tab === "troop") Game.renderTroop();
        if(Game.tab === "map") Game.loadMap();
        if(Game.tab === "mil") Game.loadMil();
        if(Game.tab === "ally") Game.renderAlly(); else Game.stopChatPoll();
      };
    });
    this.portal();
    const tok = localStorage.getItem("wow_token");
    if(tok){
      sbRpc("wow_check", { p_token: tok })
        .then(me => { if(me && me.id) Game.start({ token: tok, ...me }); else this.portal(); })
        .catch(() => this.portal());
    }
  },
  tab(which){
    $("#tabLogin").classList.toggle("on", which === "login");
    $("#tabReg").classList.toggle("on", which === "reg");
    $("#formLogin").classList.toggle("hidden", which !== "login");
    $("#formReg").classList.toggle("hidden", which !== "reg");
  },
  portal(){
    showScreen("screenPortal");
    notice($("#liMsg"), ""); notice($("#rgMsg"), "");
  },
  async login(){
    const name = $("#liName").value.trim(), pass = $("#liPass").value;
    if(!name || !pass) return notice($("#liMsg"), "Escribe tu nombre y contraseña.", "danger");
    notice($("#liMsg"), "Entrando…");
    try{
      const salt = await sbRpc("wow_salt", { p_name: name });
      if(!salt) throw new Error("Nombre o contraseña incorrectos.");
      const hash = await pbkdf2Hex(pass, salt, 100000);
      const r = await sbRpc("wow_login", { p_name: name, p_hash: hash });
      localStorage.setItem("wow_token", r.token);
      notice($("#liMsg"), "");
      Game.start({ token: r.token, id: r.id, name: r.name, faction: r.faction });
    }catch(e){ notice($("#liMsg"), shortMsg(e), "danger"); }
  },
  async register(){
    const name = $("#rgName").value.trim(), realm = $("#rgRealm").value.trim(), p1 = $("#rgPass").value, p2 = $("#rgPass2").value;
    if(!name || name.length < 2) return notice($("#rgMsg"), "Escribe tu nombre de rey (así entrarás después).", "danger");
    if(!realm || realm.length < 2) return notice($("#rgMsg"), "Escribe el nombre de tu reino.", "danger");
    if(!p1 || p1.length < 4) return notice($("#rgMsg"), "La contraseña debe tener al menos 4 caracteres.", "danger");
    if(p1 !== p2) return notice($("#rgMsg"), "Las contraseñas no coinciden.", "danger");
    if(!this.fac) return notice($("#rgMsg"), "Elige tu bando: Alianza o Horda.", "danger");
    notice($("#rgMsg"), "Creando tu reino…");
    try{
      const salt = newSalt();
      const hash = await pbkdf2Hex(p1, salt, 100000);
      await sbRpc("wow_register", { p_name: name, p_realm: realm, p_faction: this.fac, p_salt: salt, p_hash: hash, p_now: Date.now() });
      const r = await sbRpc("wow_login", { p_name: name, p_hash: hash });
      localStorage.setItem("wow_token", r.token);
      notice($("#rgMsg"), "");
      Game.start({ token: r.token, id: r.id, name: r.name, faction: r.faction });
    }catch(e){ notice($("#rgMsg"), shortMsg(e), "danger"); }
  },
  async logout(){
    try{ await sbRpc("wow_logout", { p_token: Game.me && Game.me.token }); }catch(_){}
    localStorage.removeItem("wow_token");
    Game.stop();
    this.portal();
  },
  acct(){
    if(!Game.me) return;
    $("#acctInfo").textContent = "Reino: " + Game.me.name + " · Bando: " + (Game.me.faction === "horda" ? "Horda" : "Alianza");
    $("#pw1").value = ""; $("#pw2").value = "";
    notice($("#pwMsg"), "");
    showScreen("screenAcct");
  },
  async changePw(){
    const p1 = $("#pw1").value, p2 = $("#pw2").value;
    if(!p1 || p1.length < 4) return notice($("#pwMsg"), "La contraseña debe tener al menos 4 caracteres.", "danger");
    if(p1 !== p2) return notice($("#pwMsg"), "Las contraseñas no coinciden.", "danger");
    try{
      const salt = newSalt();
      const hash = await pbkdf2Hex(p1, salt, 100000);
      await sbRpc("wow_change_password", { p_token: Game.me.token, p_salt: salt, p_hash: hash });
      notice($("#pwMsg"), "¡Contraseña cambiada!", "ok");
    }catch(e){ notice($("#pwMsg"), shortMsg(e), "danger"); }
  }
};

/* ---------------- el reino ---------------- */
const Game = {
  me: null, st: null, stNow: 0, tab: "bld", timer: null, syncing: false, rankLoaded: false, mapList: [], chatTimer: null, mapRot: 0, mapTilt: 56,

  async start(me){
    this.me = me;
    showScreen("screenGame");
    $("#gName").textContent = me.name;
    const f = $("#gFac");
    f.textContent = me.faction === "horda" ? "⚔️ Horda" : "🛡️ Alianza";
    f.className = "facBadge " + (me.faction === "horda" ? "horda" : "alianza");
    const ab = $("#gAlly"); if(ab){ ab.textContent = ""; ab.style.display = "none"; }
    await this.refresh();
    this.loop();
  },
  stop(){ clearInterval(this.timer); this.timer = null; this.st = null; this.rankLoaded = false; },
  async refresh(){
    try{
      this.st = await sbRpc("wow_state", { p_token: this.me.token });
      this.stNow = Date.now();
      $("#gPts").textContent = un(this.st.points);
      const ab = $("#gAlly");
      if(ab){ ab.textContent = this.st.ally_tag ? "[" + this.st.ally_tag + "]" : ""; ab.style.display = this.st.ally_tag ? "" : "none"; }
      this.renderBld(); this.renderTroop(); this.tick();
      if(this.tab === "rank" && this.rankLoaded) this.loadRank();
      if(this.tab === "map") this.loadMap();
      if(this.tab === "mil") this.loadMil();
    }catch(e){ toast(shortMsg(e), true); }
  },
  loop(){
    clearInterval(this.timer);
    this.timer = setInterval(() => this.tick(), 500);
    setInterval(() => this.refresh(), 20000);
    this.tick();
  },
  tick(){
    const s = this.st; if(!s) return;
    const now = Date.now(), el = (now - this.stNow) / 3600000;
    const g = Math.min(s.gold + el * s.rate.gold, s.capacity);
    const w = Math.min(s.wood + el * s.rate.wood, s.capacity);
    const o = Math.min(s.ore  + el * s.rate.ore,  s.capacity);
    $("#rGold").textContent = fmt(g);  $("#rGoldH").textContent = "+" + un(s.rate.gold) + "/h";
    $("#rWood").textContent = fmt(w);  $("#rWoodH").textContent = "+" + un(s.rate.wood) + "/h";
    $("#rOre").textContent  = fmt(o);  $("#rOreH").textContent  = "+" + un(s.rate.ore) + "/h";
    $("#rCap").textContent  = un(s.capacity) + " máx.";
    const q = s.queue, box = $("#queueBox");
    if(q && q.finish){
      box.classList.remove("hidden");
      const label = q.kind === "build"
        ? "🔨 Construyendo: " + (BLD[q.ref] ? BLD[q.ref].n : q.ref)
        : "⚔️ Entrenando: " + (TRP[q.ref] ? q.qty + " " + TRP[q.ref].n + (q.qty === 1 ? "" : "s") : q.ref);
      $("#qLabel").textContent = label;
      const total = Math.max(1, q.finish - q.start), done = Math.max(0, now - q.start);
      $("#qFill").style.width = Math.min(100, done / total * 100) + "%";
      const rem = (q.finish - now) / 1000;
      $("#qTime").textContent = rem > 0 ? "⏳ " + tfmt(rem) + " restantes" : "¡Listo! sincronizando…";
      if(rem <= 0 && !this.syncing){ this.syncing = true; this.refresh().finally(() => { this.syncing = false; }); }
    }else{
      box.classList.add("hidden");
    }
    if(this.tab === "mil"){
      const due = this.updateMilTimers();
      if(due && !this.milSyncing){ this.milSyncing = true; this.loadMil().finally(() => { this.milSyncing = false; }); }
    }
  },

  /* ----- edificios ----- */
  renderBld(){
    const s = this.st; if(!s) return;
    const busy = !!s.queue;
    let html = '<div class="grid">';
    (s.buildings || []).forEach(b => {
      const m = BLD[b.key] || { e: "🏰", n: b.key, d: "" };
      const prod = b.key === "almacen" ? m.p.replace("{v}", un(b.prod))
                 : (b.prod > 0 ? m.p.replace("{v}", un(b.prod)) : m.d);
      const noG = s.gold < b.cost.gold, noW = s.wood < b.cost.wood, noO = s.ore < b.cost.ore;
      const can = !busy && !noG && !noW && !noO;
      html += `<div class="card">
        <div class="cardTop">
          <span class="emoji">${m.e}</span>
          <div><div class="bName">${m.n}<span class="lvl">Nv. ${b.level}</span></div>
          <div class="bDesc">${prod}</div></div>
        </div>
        <div class="cardBot">
          <div class="costs">
            <span class="c${noG ? " no" : ""}">💰 ${un(b.cost.gold)}</span>
            <span class="c${noW ? " no" : ""}">🪵 ${un(b.cost.wood)}</span>
            <span class="c${noO ? " no" : ""}">⛏️ ${un(b.cost.ore)}</span>
            <span class="c">⏱ ${tfmt(b.time)}</span>
          </div>
          <button class="btn sm" data-up="${b.key}" ${can ? "" : "disabled"}>⬆️ Subir</button>
        </div>
      </div>`;
    });
    html += "</div>";
    $("#tabBld").innerHTML = html;
    $("#tabBld").querySelectorAll("[data-up]").forEach(btn => {
      btn.onclick = () => this.build(btn.dataset.up);
    });
  },
  async build(k){
    toast("🔨 Construyendo…");
    try{ await sbRpc("wow_build", { p_token: this.me.token, p_key: k }); await this.refresh(); }
    catch(e){ toast(shortMsg(e), true); }
  },

  /* ----- tropas ----- */
  renderTroop(){
    const s = this.st; if(!s) return;
    const busy = !!s.queue;
    const barr = (s.buildings || []).find(b => b.key === "cuartel");
    const lvl = barr ? barr.level : 0;
    const unlocked = lvl >= 1;
    let html = "";
    if(!unlocked){
      html += `<div class="empty">⚔️ Necesitas al menos un <b>Cuartel</b> (nivel 1) para entrenar tropas.<br><br>Sube el Cuartel en la pestaña 🏰 Edificios.</div>`;
    }
    html += '<div class="grid">';
    (s.troops || []).forEach(t => {
      const m = TRP[t.key] || { e: "⚔️", n: t.key, d: "" };
      const c = CTR[t.key] || { up: "—", dn: "—" };
      const noG = s.gold < t.cost.gold, noW = s.wood < t.cost.wood, noO = s.ore < t.cost.ore;
      const head = `<div class="cardTop">
          ${m.img ? "" : `<span class="emoji">${m.e}</span>`}
          <div style="flex:1"><div class="bName">${m.n} <span class="troopQty">× ${un(t.qty)}</span></div>
          <div class="bDesc">${m.d}</div>
          <div class="bDesc" style="color:var(--gold)">⚔️ ATK ${un(t.atk)} · ❤️ HP ${un(t.hp)}</div>
          <div class="bDesc" style="color:var(--green)">▸ vence a ${c.up}</div>
          <div class="bDesc" style="color:var(--bad)">▸ teme a ${c.dn}</div></div>
        </div>
        <div class="cardBot">
          <div class="costs">
            <span class="c${noG ? " no" : ""}">💰 ${un(t.cost.gold)}</span>
            <span class="c${noW ? " no" : ""}">🪵 ${un(t.cost.wood)}</span>
            <span class="c${noO ? " no" : ""}">⛏️ ${un(t.cost.ore)}</span>
            <span class="c">⏱ ${t.time}s/ud</span>
          </div>
        </div>
        <div class="troopRow">
          <input id="qty_${t.key}" type="number" min="1" max="100000" value="10" ${(!unlocked || busy) ? "disabled" : ""}>
          <button class="btn sm" data-tr="${t.key}" ${(!unlocked || busy) ? "disabled" : ""}>⚔️ Entrenar</button>
        </div>`;
      html += m.img
        ? `<div class="card hasPic"><div class="picBody">${head}</div><div class="picSide"><img class="troopImg" src="${m.img}" alt="${m.n}"></div></div>`
        : `<div class="card">${head}</div>`;
    });
    html += "</div>";
    $("#tabTroop").innerHTML = html;
    $("#tabTroop").querySelectorAll("[data-tr]").forEach(btn => {
      btn.onclick = () => this.train(btn.dataset.tr);
    });
  },
  async train(k){
    const inp = document.getElementById("qty_" + k);
    const qty = Math.max(1, Math.min(100000, parseInt(inp && inp.value, 10) || 0));
    toast("⚔️ Entrenando " + qty + "…");
    try{ await sbRpc("wow_train", { p_token: this.me.token, p_key: k, p_qty: qty }); await this.refresh(); }
    catch(e){ toast(shortMsg(e), true); }
  },

  /* ----- ranking ----- */
  async loadRank(){
    try{
      const list = await sbRpc("wow_leaderboard", { p_token: this.me.token });
      this.rankLoaded = true;
      let html = '<table class="rank"><tr><th>#</th><th>Reino</th><th>Bando</th><th>Puntos</th><th>Nv.</th><th>Tropas</th></tr>';
      (list || []).forEach((r, i) => {
        const cls = r.me ? ' class="me"' : "";
        const fac = r.faction === "horda"
          ? '<span class="rankFac" style="background:var(--red)">Horda</span>'
          : '<span class="rankFac" style="background:var(--blue)">Alianza</span>';
        html += `<tr${cls}><td>${i + 1}</td><td>${r.name}${r.me ? " (tú)" : ""}</td><td>${fac}</td>
          <td><b>${un(r.points)}</b></td><td>${un(r.level_sum)}</td><td>${un(r.troops)}</td></tr>`;
      });
      html += "</table>";
      $("#tabRank").innerHTML = html || '<div class="empty">Aún no hay reinos en el ranking.</div>';
    }catch(e){ toast(shortMsg(e), true); }
  },

  /* ----- mapa ----- */
  async loadMap(){
    try{
      this.mapList = await sbRpc("wow_map", { p_token: this.me.token }) || [];
      this.renderMap();
    }catch(e){ toast(shortMsg(e), true); }
  },
  renderMap(){
    const N = SLOT_POS.length;
    const rot = this.mapRot || 0, tilt = this.mapTilt != null ? this.mapTilt : 56;
    const list = this.mapList || [];
    const bySlot = {};
    list.forEach(r => { const s = ((r.pos % N) + N) % N; if(bySlot[s] == null) bySlot[s] = r; });

    let pieces = "";
    DECOS.forEach(d => {
      pieces += `<div class="m3stand" style="--x:${d.x}px;--y:${d.y}px">
          <div class="m3dshadow"></div>
          <div class="m3deco" style="--s:${d.s.toFixed(2)}"><span class="e">${d.e}</span></div>
        </div>`;
    });
    for(let i = 0; i < N; i++){
      const x = SLOT_POS[i][0], y = SLOT_POS[i][1];
      const r = bySlot[i];
      if(r){
        const fac = r.faction === "horda" ? "horda" : "alianza";
        pieces += `<div class="m3stand" style="--x:${x}px;--y:${y}px">
            <div class="m3shadow"></div>
            <div class="m3bill ${fac}${r.me ? " me" : ""}" data-pos="${r.pos}">
              <div class="m3castle">🏰</div>
              <div class="m3name">${esc(r.name)}</div>
              ${r.alliance ? `<div class="m3tag">[${esc(r.alliance)}]</div>` : ""}
            </div>
          </div>`;
      }else{
        pieces += `<div class="m3stand" style="--x:${x}px;--y:${y}px">
            <div class="m3shadow"></div>
            <div class="m3bill empty"><div class="m3castle">🏰</div></div>
          </div>`;
      }
    }
    $("#tabMap").innerHTML = `
      <div class="map3d" id="m3root" style="--rotz:${rot}deg;--tilt:${tilt}deg">
        <div class="stars"></div>
        <div class="m3stage">
          <div class="m3ground"></div>
          <div class="m3shore"></div>
          <div class="m3stand" style="--x:0px;--y:0px">
            <div class="m3shadow central"></div>
            <div class="m3bill central">
              <div class="m3castle">🏯</div>
              <div class="m3name">TRONO DE AZEROTH</div>
            </div>
          </div>
          ${pieces}
        </div>
        <div class="mapHint3d">🗺️ 20 castillos repartidos por el mapa · 🏯 fortaleza central · arrastra para girar · toca un castillo para ver su ficha</div>
      </div>`;
    const root = document.getElementById("m3root");
    const fitScale = () => {
      const r = document.getElementById("m3root"); if(!r) return;
      const w = r.clientWidth || 820, h = r.clientHeight || 600;
      const s = Math.min(w / 1560, h / 1180);
      r.style.setProperty("--scale", Math.max(0.32, Math.min(1.05, s)).toFixed(3));
    };
    fitScale();
    if(!this._resizeHooked){ this._resizeHooked = true; window.addEventListener("resize", fitScale); }
    let dragging = false, moved = false, sx = 0, sy = 0, r0 = 0, t0 = 0;
    root.addEventListener("pointerdown", e => {
      dragging = true; moved = false; sx = e.clientX; sy = e.clientY;
      r0 = this.mapRot || 0; t0 = this.mapTilt != null ? this.mapTilt : 56;
      root.classList.add("grab");
      try{ root.setPointerCapture(e.pointerId); }catch(_){}
    });
    root.addEventListener("pointermove", e => {
      if(!dragging) return;
      const dx = e.clientX - sx, dy = e.clientY - sy;
      if(Math.abs(dx) + Math.abs(dy) > 4) moved = true;
      this.mapRot = r0 + dx * 0.4;
      this.mapTilt = Math.max(38, Math.min(72, t0 - dy * 0.15));
      root.style.setProperty("--rotz", this.mapRot.toFixed(1) + "deg");
      root.style.setProperty("--tilt", this.mapTilt.toFixed(1) + "deg");
    });
    const endDrag = () => { dragging = false; root.classList.remove("grab"); };
    root.addEventListener("pointerup", endDrag);
    root.addEventListener("pointercancel", endDrag);
    root.querySelectorAll(".m3bill[data-pos]").forEach(b => {
      b.onclick = () => { if(!moved) this.openProfile(parseInt(b.dataset.pos, 10)); };
    });
  },
  openProfile(pos){
    const r = (this.mapList || []).find(x => x.pos === pos); if(!r) return;
    const fac = r.faction === "horda" ? "⚔️ Horda" : "🛡️ Alianza";
    const myTag = (this.st && this.st.ally_tag) || "";
    const sameAlly = !!r.alliance && r.alliance === myTag;
    const canAtk = !r.me && !sameAlly;
    modal(`<h2 style="margin-top:0;color:var(--gold)">🏰 ${esc(r.name)}</h2>
      ${r.me ? '<p style="color:var(--green);margin:0 0 8px">Este es tu reino</p>' : ""}
      <div class="profRow"><span class="k">Bando</span><span class="v">${fac}</span></div>
      <div class="profRow"><span class="k">Puntos</span><span class="v">${un(r.points)}</span></div>
      <div class="profRow"><span class="k">Alianza</span><span class="v">${r.alliance ? "[" + esc(r.alliance) + "]" : "Sin alianza"}</span></div>
      ${canAtk ? `<div style="text-align:center;margin-top:14px;display:flex;gap:8px;justify-content:center;flex-wrap:wrap">
        <button class="btn" id="profAtk">⚔️ Atacar</button>
        <button class="btn sm" id="profSpy" style="align-self:center">🔍 Espiar (150 💰)</button></div>` : ""}
      ${sameAlly ? '<p style="text-align:center;color:var(--dim);font-size:12px;margin-top:10px">Es de tu alianza: no puedes atacarlo ni espiarlo.</p>' : ""}`);
    const ab = document.getElementById("profAtk");
    if(ab) ab.onclick = () => this.openAttack(r);
    const sb = document.getElementById("profSpy");
    if(sb) sb.onclick = () => this.openSpy(r);
  },
  async openSpy(r){
    if(!confirm("¿Enviar un espía a " + r.name + "?\n\nCoste: 150 de oro.\nVerás sus recursos, defensa y tropas si no te descubren (la muralla enemiga reduce el éxito).")) return;
    try{
      const res = await sbRpc("wow_spy", { p_token: this.me.token, p_target: r.id });
      modalClose();
      toast("🔍 Espía enviado. Llegará en " + tfmt(res.travel) + ".");
      await this.refresh();
    }catch(e){ toast(shortMsg(e), true); }
  },

  /* ----- ataques (flotas + informes) ----- */
  troopStr(t){
    if(!t) return "—";
    const parts = Object.keys(t).filter(k => Number(t[k]) > 0)
      .map(k => `${(TRP[k] || {}).e || "⚔️"}${un(t[k])}`);
    return parts.length ? parts.join(" ") : "—";
  },
  battleSummary(b){
    if(!b) return "";
    const nR = (b.rounds || []).length;
    const aL = this.troopStr(b.a_loss), dL = this.troopStr(b.d_loss);
    const aQ = this.troopStr(b.a_left), dQ = this.troopStr(b.d_left);
    const rout = b.rout ? (b.rout === "both" ? "rompieron filas ambos" : "huyó " + (b.rout === "attacker" ? "el atacante" : "el defensor"))
      : (nR >= 20 ? "se agotó el tiempo" : "sin desbandada");
    const rows = (b.rounds || []).map(x =>
      `<div class="rnd"><span>Ronda ${x.r}</span><span>⚔️ -${un(x.aLoss)} / 🛡️ -${un(x.dLoss)}</span>` +
      `<span>quedan ${un(x.aLeft)} / ${un(x.dLeft)}</span><span>moral ${x.aMor}/${x.dMor}</span></div>`).join("");
    return `<div class="btl">
      <div class="btlTop">🔄 ${nR} ronda${nR === 1 ? "" : "s"} · moral final <b>${un(b.a_morale)}</b> / <b>${un(b.d_morale)}</b> · ${rout}</div>
      <div class="btlSide">⚔️ Atacante — bajas: ${aL} · quedan: ${aQ}</div>
      <div class="btlSide">🛡️ Defensor — bajas: ${dL} · quedan: ${dQ}</div>
      ${rows ? `<details class="btlD"><summary>Ver ronda a ronda</summary>${rows}</details>` : ""}
    </div>`;
  },
  async loadMil(){
    if(!this.me) return;
    try{
      const d = await sbRpc("wow_fleets", { p_token: this.me.token });
      this.milData = d || { fleets: [], reports: [] };
      this.renderMil();
    }catch(e){ toast(shortMsg(e), true); }
  },
  updateMilTimers(){
    let due = false;
    document.querySelectorAll("#tabMil [data-arrive]").forEach(el => {
      const rem = (Number(el.dataset.arrive) - Date.now()) / 1000;
      el.textContent = rem > 0 ? tfmt(rem) : "…";
      if(rem <= 0) due = true;
    });
    return due;
  },
  renderMil(){
    const d = this.milData || { fleets: [], reports: [] };
    const fleets = d.fleets || [], reps = d.reports || [];
    let html = "";
    if(fleets.length){
      html += '<div class="secTitle" style="margin-top:0">🛰️ Tus flotas</div><div class="milBox">';
      fleets.forEach(f => {
        const inc = !f.mine;
        const isSpy = f.kind === "spy";
        const outbound = f.state === "outbound";
        const emoji = isSpy ? "🔍" : (outbound ? (inc ? "🛡️" : "⚔️") : "🏠");
        const lab = isSpy ? "espía en camino"
          : outbound
            ? (inc ? "en camino a atacarte" : "atacando a " + esc(f.who))
            : (inc ? "regresando tras atacarte" : "volviendo a casa");
        const troops = isSpy ? "Misión de espionaje"
          : ((inc && outbound) ? "Tropas enemigas en camino" : this.troopStr(f.troops));
        const loot = (f.loot && ((f.loot.gold||0)+(f.loot.wood||0)+(f.loot.ore||0) > 0))
          ? ` · botín 💰${un(f.loot.gold)} 🪵${un(f.loot.wood)} ⛏️${un(f.loot.ore)}` : "";
        html += `<div class="fleet${inc ? " in" : ""}">
          <span class="fi">${emoji}</span>
          <div class="fmain">
            <div class="ft">${esc(f.who)} <span style="color:var(--dim)">· ${lab}</span></div>
            <div class="fd">${troops}${loot}</div>
          </div>
          <span class="fcount" data-arrive="${f.arrive}">…</span>
        </div>`;
      });
      html += "</div>";
    }
    html += '<div class="secTitle">📜 Informes de batalla</div>';
    if(!reps.length){
      html += '<div class="empty">Todavía no hay batallas. Ataca o espía a otro reino desde el 🗺️ Mapa.</div>';
    }else{
      reps.forEach(r => {
        let title, cls, det = "";
        if(r.dir === "out"){
          cls = r.win ? "win" : "lose";
          title = `⚔️ Atacaste a <b>${esc(r.who)}</b> — <b style="color:var(--${r.win ? "green" : "bad"})">${r.win ? "¡Victoria!" : "Derrota"}</b>`;
        }else if(r.dir === "in"){
          cls = r.win ? "lose" : "win";
          title = `🛡️ <b>${esc(r.who)}</b> te atacó — <b style="color:var(--${r.win ? "bad" : "green"})">${r.win ? "Perdiste" : "¡Resististe!"}</b>`;
        }else if(r.dir === "spy"){
          cls = r.success ? "win" : "lose";
          title = r.success
            ? `🔍 Espiaste a <b>${esc(r.who)}</b>`
            : `🕵️ Espía capturado en <b>${esc(r.who)}</b>`;
          if(r.success){
            const b = {}; (r.buildings || []).forEach(x => b[x.key] = x.level);
            const tr = {}; (r.troops || []).forEach(x => tr[x.key] = x.qty);
            det = `Recursos: 💰${un(r.gold)} 🪵${un(r.wood)} ⛏️${un(r.ore)} · Tropas: ${this.troopStr(tr)} · Muralla Nv.${b.muralla || 0}, Cuartel Nv.${b.cuartel || 0} · ${un(r.points)} pts. `;
          }else det = "No conseguiste información: te descubrieron. ";
        }else if(r.dir === "spy_in"){
          cls = "win";
          title = `🕵️ Capturaste a un espía de <b>${esc(r.who)}</b>`;
          det = "Su misión fracasó. ";
        }else{
          cls = "win";
          title = "🏠 Tus tropas volvieron a casa";
        }
        if(r.battle){
          det += this.battleSummary(r.battle);
        }else if(r.a_loss != null) det += `Bajas: ${un(r.a_loss)} atacante / ${un(r.d_loss)} defensor. `;
        const l = r.loot || {};
        if((l.gold||0)+(l.wood||0)+(l.ore||0) > 0) det += `Botín: 💰${un(l.gold)} 🪵${un(l.wood)} ⛏️${un(l.ore)}.`;
        html += `<div class="rep ${cls}"><div>${title}</div><div class="rl">${det}<span style="color:var(--dim)">${hora(r.created)}</span></div></div>`;
      });
    }
    html += `<div style="margin-top:14px;display:flex;gap:8px;flex-wrap:wrap">
      <button class="btn sm" id="milRefresh">🔄 Actualizar</button>
      <button class="btn sm" id="milGo">🗺️ Ir al mapa a atacar</button></div>`;
    $("#tabMil").innerHTML = html;
    const rb = document.getElementById("milRefresh"); if(rb) rb.onclick = () => this.loadMil();
    const gb = document.getElementById("milGo");
    if(gb) gb.onclick = () => { const t = document.querySelector('.gameTabs [data-tab="map"]'); if(t) t.click(); };
    this.updateMilTimers();
  },
  openAttack(r){
    const troops = ((this.st && this.st.troops) || []).filter(t => t.qty > 0);
    if(!troops.length){
      modal(`<h2 style="margin-top:0;color:var(--gold)">⚔️ Atacar a ${esc(r.name)}</h2>
        <p style="color:var(--dim)">No tienes tropas. Entrena en el Cuartel (pestaña ⚔️ Tropas) antes de atacar.</p>`);
      return;
    }
    const my = (this.mapList || []).find(x => x.me);
    const travel = (my && typeof r.pos === "number") ? Math.max(20, 15 + 3 * Math.abs(my.pos - r.pos)) : null;
    const rows = troops.map(t => {
      const m = TRP[t.key] || { e: "⚔️", n: t.key };
      return `<div class="atkRow"><span class="an">${m.e || "⚔️"} ${m.n}</span><span class="amax">de ${un(t.qty)}</span>
        <input id="atkq_${t.key}" type="number" min="0" max="${t.qty}" value="0" inputmode="numeric"></div>`;
    }).join("");
    modal(`<h2 style="margin-top:0;color:var(--gold)">⚔️ Atacar a ${esc(r.name)}</h2>
      <p style="color:var(--dim);font-size:13px;margin:4px 0 8px">Elige cuántas tropas enviar. La batalla se resuelve al llegar; los supervivientes vuelven con el botín.</p>
      ${rows}
      <p style="color:var(--dim);font-size:11px;margin-top:10px;line-height:1.5">⚖️ Contadores: 🗡️ soldado ▸ 🐎 jinete · 🏹 arquero ▸ soldado, 🔮 mago y 🐉 dragón · 🐎 jinete ▸ arquero y 🛡️ paladín · 🔮 mago ▸ soldado y jinete · 🛡️ paladín ▸ mago y dragón · 🐉 dragón ▸ soldado, jinete y mago. El ejército con ventaja de tipo (y números) rompe antes la moral del rival.</p>
      ${travel != null ? `<p style="color:var(--dim);font-size:12px;margin-top:10px">⏱ Viaje de ida: ${tfmt(travel)} · vuelta: otro tanto.</p>` : ""}
      <div style="text-align:center;margin-top:14px"><button class="btn" id="atkGo">⚔️ Enviar ataque</button></div>`);
    const go = document.getElementById("atkGo");
    if(go) go.onclick = () => this.sendAttack(r);
  },
  async sendAttack(r){
    const payload = {};
    document.querySelectorAll('#modalBox input[id^="atkq_"]').forEach(inp => {
      const k = inp.id.slice(5);
      const v = Math.max(0, parseInt(inp.value, 10) || 0);
      if(v > 0) payload[k] = v;
    });
    if(!Object.keys(payload).length) return toast("Elige al menos una tropa.", true);
    try{
      const res = await sbRpc("wow_attack", { p_token: this.me.token, p_target: r.id, p_troops: payload });
      modalClose();
      toast("⚔️ Ataque enviado. Llegará en " + tfmt(res.travel) + ".");
      await this.refresh();
    }catch(e){ toast(shortMsg(e), true); }
  },

  /* ----- alianza ----- */
  async renderAlly(){
    if(!this.st) return;
    try{
      if(this.st.alliance) await this.renderAllyMine(this.st.alliance);
      else await this.renderAllyNone();
    }catch(e){ toast(shortMsg(e), true); }
  },
  async renderAllyNone(){
    this.stopChatPoll();
    const list = await sbRpc("wow_alliance_list", { p_token: this.me.token }) || [];
    let html = `<div class="allyBox">
      <div class="secTitle" style="margin-top:0">🤝 Crear una alianza</div>
      <div class="allyCreate">
        <input id="alName" placeholder="Nombre de la alianza" maxlength="30">
        <input id="alTag" placeholder="Etiqueta (2-5 letras, ej. CRV)" maxlength="5">
        <input id="alDesc" placeholder="Descripción (opcional)" maxlength="200">
        <button class="btn" id="alCreate">Crear alianza</button>
      </div>
      <div class="secTitle">⚔️ Alianzas existentes</div>
      <div class="allyList">`;
    if(!list.length) html += '<div class="empty" style="padding:16px">Todavía no hay alianzas. ¡Crea la primera!</div>';
    list.forEach(a => {
      html += `<div class="allyCard">
        <div class="info"><div class="t">[${esc(a.tag)}] ${esc(a.name)}</div>
        <div class="m">${a.members} miembro${a.members === 1 ? "" : "s"} · ${un(a.points)} pts</div></div>
        <button class="btn sm" data-join="${esc(a.id)}">Unirme</button>
      </div>`;
    });
    html += `</div></div>`;
    $("#tabAlly").innerHTML = html;
    $("#alCreate").onclick = () => this.createAlly();
    $("#tabAlly").querySelectorAll("[data-join]").forEach(b => { b.onclick = () => this.joinAlly(b.dataset.join); });
  },
  async renderAllyMine(id){
    const info = await sbRpc("wow_alliance_info", { p_token: this.me.token, p_id: id });
    let html = `<div class="allyBox">
      <div class="allyHead"><span class="allyTagBig">[${esc(info.tag)}]</span>${esc(info.name)}</div>
      <p class="allyDesc">${info.descr ? esc(info.descr) : "Sin descripción"}</p>
      <div class="secTitle" style="margin-top:0">👥 Miembros (${info.members.length})</div>
      <div class="members">`;
    info.members.forEach(m => {
      html += `<div class="mem${m.me ? " me" : ""}">${m.faction === "horda" ? "⚔️" : "🛡️"} ${esc(m.name)}${m.leader ? " 👑" : ""}<span class="memPts">${un(m.points)} pts</span></div>`;
    });
    html += `</div>
      <div class="secTitle">💬 Chat de la alianza</div>
      <div id="chatMsgs" class="chatBox"></div>
      <div class="chatRow"><input id="chatIn" placeholder="Escribe a tu alianza…" maxlength="300"><button class="btn sm" id="chatSend">Enviar</button></div>
      <div style="margin-top:14px"><button class="btn sm danger" id="allyLeave">🚪 Salir de la alianza</button></div>
    </div>`;
    $("#tabAlly").innerHTML = html;
    $("#chatSend").onclick = () => this.sendChat();
    $("#chatIn").onkeydown = e => { if(e.key === "Enter") this.sendChat(); };
    $("#allyLeave").onclick = () => this.leaveAlly(info.name);
    await this.loadChat();
    this.startChatPoll();
  },
  stopChatPoll(){ clearInterval(this.chatTimer); this.chatTimer = null; },
  startChatPoll(){ this.stopChatPoll(); this.chatTimer = setInterval(() => this.loadChat(), 4000); },
  async loadChat(){
    try{
      const msgs = await sbRpc("wow_chat", { p_token: this.me.token, p_since: 0 });
      const box = document.getElementById("chatMsgs"); if(!box) return;
      box.innerHTML = (msgs && msgs.length)
        ? msgs.map(m => `<div class="cmsg${m.me ? " me" : ""}"><span class="cwho">${esc(m.name)}:</span> ${esc(m.msg)} <span class="ctime">${hora(m.created)}</span></div>`).join("")
        : '<div class="empty" style="padding:14px">Sé el primero en escribir.</div>';
      box.scrollTop = box.scrollHeight;
    }catch(_){}
  },
  async sendChat(){
    const inp = document.getElementById("chatIn"); const msg = inp ? inp.value.trim() : "";
    if(!msg) return;
    try{ await sbRpc("wow_chat_send", { p_token: this.me.token, p_msg: msg }); if(inp) inp.value = ""; await this.loadChat(); }
    catch(e){ toast(shortMsg(e), true); }
  },
  async createAlly(){
    const name = ($("#alName").value || "").trim(), tag = ($("#alTag").value || "").trim(), descr = ($("#alDesc").value || "").trim();
    if(name.length < 3) return toast("El nombre debe tener al menos 3 letras.", true);
    if(tag.length < 2) return toast("La etiqueta debe tener al menos 2 letras.", true);
    try{ await sbRpc("wow_alliance_create", { p_token: this.me.token, p_name: name, p_tag: tag, p_descr: descr }); await this.refresh(); await this.renderAlly(); toast("¡Alianza creada!"); }
    catch(e){ toast(shortMsg(e), true); }
  },
  async joinAlly(id){
    try{ await sbRpc("wow_alliance_join", { p_token: this.me.token, p_id: id }); await this.refresh(); await this.renderAlly(); toast("¡Te uniste a la alianza!"); }
    catch(e){ toast(shortMsg(e), true); }
  },
  async leaveAlly(name){
    if(!confirm("¿Seguro que quieres salir de " + name + "?")) return;
    try{ await sbRpc("wow_alliance_leave", { p_token: this.me.token }); this.stopChatPoll(); await this.refresh(); await this.renderAlly(); toast("Has salido de la alianza."); }
    catch(e){ toast(shortMsg(e), true); }
  }
};

window.addEventListener("error", ev => {
  try{ toast("Error: " + (ev.message || "desconocido"), true); }catch(_){}
});
document.addEventListener("DOMContentLoaded", () => Auth.init());
