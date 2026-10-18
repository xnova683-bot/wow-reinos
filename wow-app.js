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
const ALLY_MAX = 5;
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
  mina:       { e: "⛏️", n: "Mina de Mineral", d: "Extrae mineral del subsuelo",      p: "+{v} mineral/h", img: "img/mina.jpg" },
  aserradero: { e: "🪵", n: "Aserradero",      d: "Corta madera para tus obras",      p: "+{v} madera/h", img: "img/aserradero.jpg" },
  tesoreria:  { e: "🪙", n: "Mina de Oro",     d: "Extrae oro de las vetas del subsuelo", p: "+{v} oro/h", img: "img/oro.jpg" },
  almacen:    { e: "📦", n: "Almacén",         d: "Guarda más recursos",              p: "Capacidad: {v}", img: "img/almacen.jpg" },
  cuartel:    { e: "⚔️", n: "Cuartel",         d: "Entrena a tus tropas",             p: "Necesario para tropas" },
  herreria:   { e: "🛠️", n: "Herrería",        d: "Forja acero: sube el daño de tus tropas", p: "+{v}% daño de tus tropas" },
  fortaleza:  { e: "🏯", n: "Fortaleza",       d: "Muros reforzados: tus tropas aguantan más", p: "+{v}% aguante (menos bajas)" },
  mercado:    { e: "🏪", n: "Mercado",         d: "Rutas comerciales: más producción de recursos", p: "+{v}% producción de recursos" },
  muralla:    { e: "🛡️", n: "Muralla",         d: "Protege tu reino",                 p: "Defensa de tu reino" }
};
const TRP = {
  soldado: { n: "Soldado", d: "Infantería básica", img: "img/soldado.jpg", imgH: "img/horda/soldado.jpg" },
  arquero: { n: "Arquero", d: "Ataca a distancia", img: "img/arquero.jpeg", imgH: "img/horda/arquero.jpg" },
  jinete:  { n: "Jinete",  d: "Carga rápida", img: "img/jinete.jpg", imgH: "img/horda/jinete.jpg" },
  mago:    { n: "Mago",    d: "Daño mágico", img: "img/mago.jpg", imgH: "img/horda/mago.jpg" },
  paladin: { n: "Paladín", d: "Guerrero sagrado, brutal contra magos y dragones", img: "img/paladin.jpg", imgH: "img/horda/paladin.jpg" },
  dragon:  { n: "Dragón",  d: "Bestia legendaria, arrasa infantería y magos", img: "img/dragon.jpg", imgH: "img/horda/dragon.jpg?v=2" }
};
const CTR = {
  soldado: { up: "🐎 jinete",                  dn: "🏹 arquero y 🐉 dragón" },
  arquero: { up: "🗡️ soldado, 🔮 mago y 🐉 dragón", dn: "🐎 jinete" },
  jinete:  { up: "🏹 arquero y 🛡️ paladín",    dn: "🗡️ soldado, 🔮 mago y 🐉 dragón" },
  mago:    { up: "🗡️ soldado y 🐎 jinete",     dn: "🏹 arquero, 🛡️ paladín y 🐉 dragón" },
  paladin: { up: "🔮 mago y 🐉 dragón",        dn: "🐎 jinete" },
  dragon:  { up: "🗡️ soldado, 🐎 jinete y 🔮 mago", dn: "🏹 arquero y 🛡️ paladín" }
};

/* imagen de una tropa/edificio según tu facción: Horda usa imgH si existe; si no (o Alianza), usa img */
function facImg(m){
  if(m && m.imgH && Game.me && Game.me.faction === "horda") return m.imgH;
  return m ? m.img : null;
}

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

/* mapa: canvas 1200x2400 con DOS continentes (arriba/abajo) unidos por un puente.
   Red de caminos = MST de cada continente + puente entre las dos fortalezas.
   Nodos: 0=trono alto, 1..20=castillos alto, 21=trono bajo, 22..41=castillos bajo */
const MAPW = 1200, MAPH = 2400, MAPKX = 0.72, MAPKY = 0.60;
const MAP_CONT = [[600, 600], [600, 1800]];
const MAP_NODE = 42;
function mapNodeXY(idx){
  if(idx === 0) return MAP_CONT[0].slice();
  if(idx === 21) return MAP_CONT[1].slice();
  if(idx >= 1 && idx <= 20){ const s = SLOT_POS[idx - 1]; return [MAP_CONT[0][0] + s[0]*MAPKX, MAP_CONT[0][1] + s[1]*MAPKY]; }
  const s = SLOT_POS[idx - 22]; return [MAP_CONT[1][0] + s[0]*MAPKX, MAP_CONT[1][1] + s[1]*MAPKY];
}
const MAP_ROADS = (() => {
  const adj = Array.from({ length: MAP_NODE }, () => []);
  const link = (a, b) => { adj[a].push(b); adj[b].push(a); };
  const mst = (coords, off) => {
    const n = coords.length, inT = new Array(n).fill(false);
    inT[0] = true; let cnt = 1;
    while(cnt < n){
      let best = null;
      for(let i = 0; i < n; i++){
        if(!inT[i]) continue;
        for(let j = 0; j < n; j++){
          if(inT[j]) continue;
          const d = Math.hypot(coords[i][0]-coords[j][0], coords[i][1]-coords[j][1]);
          if(!best || d < best.d) best = { i, j, d };
        }
      }
      inT[best.j] = true; cnt++; link(off + best.i, off + best.j);
    }
  };
  MAP_CONT.forEach((c, ci) => {
    const coords = [[c[0], c[1]]].concat(SLOT_POS.map(s => [c[0] + s[0]*MAPKX, c[1] + s[1]*MAPKY]));
    mst(coords, ci === 0 ? 0 : 21);
  });
  link(0, 21); /* puente entre las dos fortalezas centrales */
  return adj;
})();
function mapPosNode(pos){
  const N = SLOT_POS.length, p = (((pos % (2*N)) + 2*N) % (2*N));
  const c = Math.floor(p / N), s = p % N;
  return c === 0 ? (s + 1) : (22 + s);
}
function mapNodePath(from, to){
  if(from === to) return [from];
  const prev = { [from]: -1 }, q = [from];
  while(q.length){
    const cur = q.shift();
    if(cur === to) break;
    for(const nx of MAP_ROADS[cur]) if(!(nx in prev)){ prev[nx] = cur; q.push(nx); }
  }
  const path = []; let c = to;
  while(c !== -1 && c !== undefined){ path.unshift(c); c = prev[c]; }
  if(path[0] !== from) return [from, to];
  return path;
}
function mapPathNodes(fromPos, toPos){
  return mapNodePath(mapPosNode(fromPos), mapPosNode(toPos));
}
function mapNodePct(idx){
  const xy = mapNodeXY(idx);
  return [xy[0] / MAPW * 100, xy[1] / MAPH * 100];
}
function mapPointAt(points, t){
  if(points.length < 2) return points[0] || [50, 50];
  const segs = []; let total = 0;
  for(let i = 0; i < points.length - 1; i++){
    const dx = (points[i + 1][0] - points[i][0]) / 100 * MAPW;
    const dy = (points[i + 1][1] - points[i][1]) / 100 * MAPH;
    const L = Math.hypot(dx, dy); segs.push(L); total += L;
  }
  let d = t * total;
  for(let i = 0; i < segs.length; i++){
    if(d <= segs[i] || i === segs.length - 1){
      const f = segs[i] ? Math.min(1, d / segs[i]) : 0;
      return [points[i][0] + (points[i + 1][0] - points[i][0]) * f,
              points[i][1] + (points[i + 1][1] - points[i][1]) * f];
    }
    d -= segs[i];
  }
  return points[points.length - 1];
}

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
        $("#tabChat").classList.toggle("hidden", Game.tab !== "chat");
        $("#tabRank").classList.toggle("hidden", Game.tab !== "rank");
        $("#tabMarket").classList.toggle("hidden", Game.tab !== "market");
        $("#tabAdmin").classList.toggle("hidden", Game.tab !== "admin");
        if(Game.tab === "rank") Game.loadRank();
        if(Game.tab === "bld") Game.renderBld();
        if(Game.tab === "troop") Game.renderTroop();
        if(Game.tab === "map") Game.loadMap(); else { Game.stopMarchLoop(); Game.stopMarchPoll(); }
        if(Game.tab === "mil") Game.loadMil();
        if(Game.tab === "ally") Game.renderAlly(); else Game.stopChatPoll();
        if(Game.tab === "chat") Game.renderGChat(); else Game.stopGChatPoll();
        if(Game.tab === "market") Game.loadMarket && Game.loadMarket();
        if(Game.tab === "admin") Game.loadAdmin();
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
  me: null, st: null, stNow: 0, tab: "bld", timer: null, syncing: false, rankLoaded: false, mapList: [], chatTimer: null, gchatTimer: null, mapRot: 0, mapTilt: 56,

  async start(me){
    this.me = me;
    showScreen("screenGame");
    $("#gName").textContent = me.name;
    const f = $("#gFac");
    f.textContent = me.faction === "horda" ? "⚔️ Horda" : "🛡️ Alianza";
    f.className = "facBadge " + (me.faction === "horda" ? "horda" : "alianza");
    const ab = $("#gAlly"); if(ab){ ab.textContent = ""; ab.style.display = "none"; }
    this.setAdminTab(!!me.is_admin);
    await this.refresh();
    if (this.me && this.me.id === "admin") this.setAdminTab(true);
    this.loop();
  },
  stop(){ clearInterval(this.timer); this.timer = null; this.st = null; this.rankLoaded = false; this.stopMarchLoop(); this.stopMarchPoll(); this.stopChatPoll(); this.stopGChatPoll(); },
  async refresh(){
    try{
      this.st = await sbRpc("wow_state", { p_token: this.me.token });
      this.stNow = Date.now();
      this.setAdminTab(!!this.st.is_admin || (this.me && this.me.id === "admin"));
      $("#gPts").textContent = un(this.st.points);
      const ab = $("#gAlly");
      if(ab){ ab.textContent = this.st.ally_tag ? "[" + this.st.ally_tag + "]" : ""; ab.style.display = this.st.ally_tag ? "" : "none"; }
      this.renderBld(); this.renderTroop(); this.tick();
      if(this.tab === "rank" && this.rankLoaded) this.loadRank();
      if(this.tab === "map") this.loadMap();
      if(this.tab === "mil") this.loadMil();
      if(this.tab === "market" && this.loadMarket) this.loadMarket();
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
    $("#rCup").textContent = fmt(s.cup||0);  $("#rCupH").textContent = "+" + un(s.rate.cup||0) + "/h";
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
      const img = facImg(m);
      const body = `<div class="cardTop">
          ${img ? "" : `<span class="emoji">${m.e}</span>`}
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
        </div>`;
      html += img
        ? `<div class="card hasPic"><div class="picBody">${body}</div><div class="picSide"><img class="troopImg" src="${img}" alt="${m.n}"${m.img && img !== m.img ? ` onerror="this.onerror=null;this.src='${m.img}';"` : ""}></div></div>`
        : `<div class="card">${body}</div>`;
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
      const img = facImg(m);
      const head = `<div class="cardTop">
          ${img ? "" : `<span class="emoji">${m.e}</span>`}
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
          <input id="qty_${t.key}" type="number" min="1" max="100000" value="" placeholder="Cantidad" ${(!unlocked || busy) ? "disabled" : ""}>
          <button class="btn sm" data-tr="${t.key}" ${(!unlocked || busy) ? "disabled" : ""}>⚔️ Entrenar</button>
        </div>`;
      html += img
        ? `<div class="card hasPic"><div class="picBody">${head}</div><div class="picSide"><img class="troopImg" src="${img}" alt="${m.n}"${m.img && img !== m.img ? ` onerror="this.onerror=null;this.src='${m.img}';"` : ""}></div></div>`
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
    const n = parseInt(inp && inp.value, 10);
    if(!n || n < 1){ toast("Escribe cuántas unidades quieres entrenar", true); if(inp) inp.focus(); return; }
    const qty = Math.min(100000, n);
    toast("⚔️ Entrenando " + qty + "…");
    try{ await sbRpc("wow_train", { p_token: this.me.token, p_key: k, p_qty: qty }); await this.refresh(); }
    catch(e){ toast(shortMsg(e), true); }
  },

  /* ----- ranking ----- */
  async loadRank(){
    try{
      const list = await sbRpc("wow_leaderboard", { p_token: this.me.token });
      this.rankLoaded = true;
      let html = '<table class="rank"><tr><th>#</th><th>Reino</th><th>Bando</th><th>Puntos</th><th>Nv.</th><th>Tropas</th><th>👑</th></tr>';
      (list || []).forEach((r, i) => {
        const cls = r.me ? ' class="me"' : "";
        const fac = r.faction === "horda"
          ? '<span class="rankFac" style="background:var(--red)">Horda</span>'
          : '<span class="rankFac" style="background:var(--blue)">Alianza</span>';
        html += `<tr${cls}><td>${i + 1}</td><td>${r.name}${r.me ? " (tú)" : ""}</td><td>${fac}</td>
          <td><b>${un(r.points)}</b></td><td>${un(r.level_sum)}</td><td>${un(r.troops)}</td><td>${r.thrones ? "👑 " + un(r.thrones) : "—"}</td></tr>`;
      });
      html += "</table>";
      $("#tabRank").innerHTML = html || '<div class="empty">Aún no hay reinos en el ranking.</div>';
    }catch(e){ toast(shortMsg(e), true); }
  },

  /* ----- mapa ----- */
  async loadMap(){
    try{
      this.mapList = await sbRpc("wow_map", { p_token: this.me.token }) || [];
      try{ const ti = await sbRpc("wow_throne_info", { p_token: this.me.token }); this._thrones = (ti && ti.thrones) || []; }
      catch(_){ this._thrones = this._thrones || []; }
      try{ this._events = await sbRpc("wow_events", { p_token: this.me.token }) || []; }
      catch(_){ this._events = this._events || []; }
      this.renderMap();
    }catch(e){ toast(shortMsg(e), true); }
  },
  renderMap(){
    const N = SLOT_POS.length;
    const list = this.mapList || [];
    const byKey = {};
    list.forEach(r => {
      const p = ((r.pos % (2*N)) + 2*N) % (2*N);
      const c = Math.floor(p / N), s = p % N, key = c*N + s;
      if(byKey[key] == null) byKey[key] = r;
    });
    let pins = "";
    for(let c = 0; c < 2; c++){
      for(let s = 0; s < N; s++){
        const node = (c === 0 ? (s + 1) : (22 + s));
        const pc = mapNodePct(node);
        const r = byKey[c*N + s];
        if(r){
          const fac = r.faction === "horda" ? "horda" : "alianza";
          pins += `<div class="mPin ${fac}${r.me ? " me" : ""}" data-pos="${r.pos}" style="left:${pc[0].toFixed(2)}%;top:${pc[1].toFixed(2)}%">
              <div class="mPinCastle">🏰</div>
              <div class="mPinName">${esc(r.name)}</div>
              ${r.alliance ? `<div class="mPinTag">[${esc(r.alliance)}]</div>` : ""}
            </div>`;
        }else{
          pins += `<div class="mPin empty" style="left:${pc[0].toFixed(2)}%;top:${pc[1].toFixed(2)}%"><div class="mPinCastle">🏰</div></div>`;
        }
      }
    }
    const thrones = (this._thrones && this._thrones.length) ? this._thrones : [
      { node: 0,  name: "TRONO DE AZEROTH" },
      { node: 21, name: "TRONO DE KALIMDOR" }
    ];
    let throneHtml = "";
    thrones.forEach(t => {
      const pc = mapNodePct(t.node);
      const owned = !!t.holder;
      const crown = owned ? "👑" : "🏯";
      const label = owned ? esc(t.holder_name || "?") : "Libre";
      throneHtml += `<div class="mPin throne${owned ? " taken" : ""}" data-thr="${t.node}" style="left:${pc[0].toFixed(2)}%;top:${pc[1].toFixed(2)}%">
          <div class="mPinCastle">${crown}</div>
          <div class="mPinName">${esc(t.name)}</div>
          <div class="mPinTag">${label}</div>
        </div>`;
    });
    $("#tabMap").innerHTML = `
      <div class="mapWrap"><div class="mapInner" id="m2root">
        <img class="mapImg" src="img/mapa.jpg" alt="Mapa de Azeroth">
        ${throneHtml}
        ${pins}
        <div class="armyLayer" id="armyLayer"></div>
      </div></div>
      ${this.cronicaHtml()}`;
    $("#m2root").querySelectorAll(".mPin[data-pos]").forEach(b => {
      b.onclick = () => this.openProfile(parseInt(b.dataset.pos, 10));
    });
    $("#m2root").querySelectorAll(".mPin.throne").forEach(b => {
      b.onclick = () => this.openThrone(parseInt(b.dataset.thr, 10));
    });
    this.keepFx();
    this.loadMarches();
    this.startMarchLoop();
    this.startMarchPoll();
  },
  cronicaHtml(){
    const evs = this._events || [];
    if(!evs.length) return '<div class="cronica"><div class="muted">📜 Aún no hay sucesos en la crónica.</div></div>';
    let body = '<div class="cronica"><div class="cronTitle">📜 Crónica de Azeroth</div>';
    evs.forEach(e => body += '<div class="cronEvent">' + esc(e.text||"") + ' <span style="opacity:.55">· ' + hora(e.created) + '</span></div>');
    return body + '</div>';
  },
  async loadMarches(){
    try{
      const r = await sbRpc("wow_marches", { p_token: this.me.token });
      this.marches = (r && r.marches) || [];
    }catch(e){ this.marches = this.marches || []; }
    this.renderMarches();
  },
  renderMarches(){
    const layer = document.getElementById("armyLayer"); if(!layer) return;
    layer.querySelectorAll(".mArmy:not(.fx)").forEach(e => e.remove());
    this._marchTokens = [];
    (this.marches || []).forEach((m, idx) => {
      if(m.from == null || m.to == null) return;
      const reach = mapPathNodes(m.from, m.to).map(mapNodePct);
      const el = document.createElement("div");
      el.className = "mArmy" + (m.mine ? " mine" : "") +
        (m.kind === "spy" ? " spy" : (m.state === "returning" ? " back" : ""));
      el.textContent = m.kind === "spy" ? "🕵️" : (m.state === "returning" ? "🚩" : "⚔️");
      layer.appendChild(el);
      this._marchTokens.push({ el, pts: reach, depart: m.depart, arrive: m.arrive, seed: idx * 1.7 });
    });
  },
  startMarchLoop(){
    this.stopMarchLoop();
    const step = () => {
      const now = Date.now();
      (this._marchTokens || []).forEach(tk => {
        const total = tk.arrive - tk.depart;
        let p = total > 0 ? (now - tk.depart) / total : 1;
        p = Math.max(0, Math.min(1, p));
        const pt = mapPointAt(tk.pts, p);
        tk.el.style.left = pt[0].toFixed(2) + "%";
        tk.el.style.top = pt[1].toFixed(2) + "%";
        const bob = (Math.sin(now / 170 + tk.seed) * 2.2).toFixed(1);
        tk.el.style.transform = "translate(-50%,-50%) translateY(" + bob + "px)";
      });
      const fx = this._fxTokens || [];
      for(let i = fx.length - 1; i >= 0; i--){
        const tk = fx[i];
        const total = tk.arrive - tk.depart;
        let p = total > 0 ? (now - tk.depart) / total : 1;
        p = Math.max(0, Math.min(1, p));
        const pt = mapPointAt(tk.pts, p);
        tk.el.style.left = pt[0].toFixed(2) + "%";
        tk.el.style.top = pt[1].toFixed(2) + "%";
        const bob = (Math.sin(now / 150 + tk.seed) * 2.4).toFixed(1);
        tk.el.style.transform = "translate(-50%,-50%) translateY(" + bob + "px)";
        if(p >= 1){ tk.el.remove(); fx.splice(i, 1); }
      }
      this._mapRAF = requestAnimationFrame(step);
    };
    step();
  },
  stopMarchLoop(){ if(this._mapRAF){ cancelAnimationFrame(this._mapRAF); this._mapRAF = null; } },
  startMarchPoll(){
    this.stopMarchPoll();
    this._marchTimer = setInterval(() => { if(this.tab === "map") this.loadMarches(); }, 5000);
  },
  stopMarchPoll(){ if(this._marchTimer){ clearInterval(this._marchTimer); this._marchTimer = null; } },
  _myNode(){
    const mine = (this.mapList || []).find(x => x.me);
    return mine ? mapPosNode(mine.pos) : null;
  },
  /* renderMap recrea el #armyLayer: re-adjunta los emojis de tropas en vuelo para no perderlos */
  keepFx(){
    const nl = document.getElementById("armyLayer"); if(!nl) return;
    (this._fxTokens || []).forEach(tk => { if(tk && tk.el && tk.el.parent !== nl) nl.appendChild(tk.el); });
  },
  _nodePos(node){
    if(node === 0) return 0;
    if(node === 21) return 20;
    return node >= 22 ? node - 2 : node - 1;
  },
  showMarchFx(fromNode, toNode, icon, cls){
    const layer = document.getElementById("armyLayer");
    if(!layer || fromNode == null || toNode == null) return;
    const reach = mapNodePath(fromNode, toNode).map(mapNodePct);
    const travel = Math.max(20, 15 + 3 * Math.abs(this._nodePos(fromNode) - this._nodePos(toNode)));
    const ms = travel * 1000;
    const el = document.createElement("div");
    el.className = "mArmy fx mine" + (cls ? " " + cls : "");
    el.textContent = icon || "⚔️";
    layer.appendChild(el);
    this._fxTokens = this._fxTokens || [];
    this._fxTokens.push({ el, pts: reach, depart: Date.now(), arrive: Date.now() + ms, seed: Math.random() * 3 });
    if(!this._mapRAF) this.startMarchLoop();
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
        <input id="atkq_${t.key}" type="number" min="0" max="${t.qty}" value="0" inputmode="numeric">
        <button class="btn sm" data-max="${t.key}">MAX</button></div>`;
    }).join("");
    modal(`<h2 style="margin-top:0;color:var(--gold)">⚔️ Atacar a ${esc(r.name)}</h2>
      <p style="color:var(--dim);font-size:13px;margin:4px 0 8px">Elige cuántas tropas enviar. La batalla se resuelve al llegar; los supervivientes vuelven con el botín.</p>
      ${rows}
      <p style="color:var(--dim);font-size:11px;margin-top:10px;line-height:1.5">⚖️ Contadores: 🗡️ soldado ▸ 🐎 jinete · 🏹 arquero ▸ soldado, 🔮 mago y 🐉 dragón · 🐎 jinete ▸ arquero y 🛡️ paladín · 🔮 mago ▸ soldado y jinete · 🛡️ paladín ▸ mago y dragón · 🐉 dragón ▸ soldado, jinete y mago. El ejército con ventaja de tipo (y números) rompe antes la moral del rival.</p>
      ${travel != null ? `<p style="color:var(--dim);font-size:12px;margin-top:10px">⏱ Viaje de ida: ${tfmt(travel)} · vuelta: otro tanto.</p>` : ""}
      <div style="text-align:center;margin-top:14px"><button class="btn" id="atkGo">⚔️ Enviar ataque</button></div>`);
    const go = document.getElementById("atkGo");
    if(go) go.onclick = () => this.sendAttack(r);
    document.querySelectorAll('#modalBox button[data-max]').forEach(b => {
      b.onclick = () => {
        const k = b.dataset.max;
        const inp = document.getElementById("atkq_" + k);
        if(inp) inp.value = Number(inp.max) || 0;
      };
    });
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
      const full = a.members >= ALLY_MAX;
      html += `<div class="allyCard">
        <div class="info"><div class="t">[${esc(a.tag)}] ${esc(a.name)}</div>
        <div class="m">${a.members}/${ALLY_MAX} miembros · ${un(a.points)} pts</div></div>
        ${full ? '<button class="btn sm" disabled>Llena</button>'
               : `<button class="btn sm" data-join="${esc(a.id)}">Unirme</button>`}
      </div>`;
    });
    html += `</div>
      <div class="secTitle">🏆 Ranking de alianzas</div>
      <div id="allyRank" class="allyRank"></div></div>`;
    $("#tabAlly").innerHTML = html;
    $("#alCreate").onclick = () => this.createAlly();
    $("#tabAlly").querySelectorAll("[data-join]").forEach(b => { b.onclick = () => this.joinAlly(b.dataset.join); });
    await this.loadRank("#allyRank");
  },
  async renderAllyMine(id){
    const info = await sbRpc("wow_alliance_info", { p_token: this.me.token, p_id: id });
    this._allyInfo = info;
    let html = `<div class="allyBox">
      <div class="allyHead"><span class="allyTagBig">[${esc(info.tag)}]</span>${esc(info.name)}</div>
      <p class="allyDesc">${info.descr ? esc(info.descr) : "Sin descripción"}</p>
      <div class="secTitle" style="margin-top:0">👥 Miembros (${info.members.length}/${ALLY_MAX})</div>
      <div class="members">`;
    info.members.forEach(m => {
      html += `<div class="mem${m.me ? " me" : ""}">${m.faction === "horda" ? "⚔️" : "🛡️"} ${esc(m.name)}${m.leader ? " 👑" : ""}<span class="memPts">${un(m.points)} pts</span></div>`;
    });
    html += `</div>
      <div class="secTitle">⚔️ Guerras</div>
      <div id="warsBox" class="warsBox"></div>
      <div class="secTitle">💬 Chat de la alianza</div>
      <div id="chatMsgs" class="chatBox"></div>
      <div class="chatRow"><input id="chatIn" placeholder="Escribe a tu alianza…" maxlength="300"><button class="btn sm" id="chatSend">Enviar</button></div>
      <div style="margin-top:14px"><button class="btn sm danger" id="allyLeave">🚪 Salir de la alianza</button></div>
      <div class="secTitle">🏆 Ranking de alianzas</div>
      <div id="allyRank" class="allyRank"></div>
    </div>`;
    $("#tabAlly").innerHTML = html;
    $("#chatSend").onclick = () => this.sendChat();
    $("#chatIn").onkeydown = e => { if(e.key === "Enter") this.sendChat(); };
    $("#allyLeave").onclick = () => this.leaveAlly(info.name);
    await this.loadWars();
    await this.loadChat();
    await this.loadRank("#allyRank");
    this.startChatPoll();
  },
  async loadRank(sel){
    try{
      const list = await sbRpc("wow_alliance_rank", { p_token: this.me.token }) || [];
      const box = document.querySelector(sel); if(!box) return;
      if(!list.length){ box.innerHTML = '<div class="empty" style="padding:12px">Sin alianzas todavía.</div>'; return; }
      box.innerHTML = list.map((a, i) => `<div class="rankRow${a.mine ? " mine" : ""}">
        <span class="rankPos">${i + 1}</span>
        <span class="rankTag">[${esc(a.tag)}]</span>
        <span class="rankName">${esc(a.name)}</span>
        <span class="rankStat">👥 ${a.members}</span>
        <span class="rankStat">⭐ ${un(a.points)}</span>
        <span class="rankStat">⚔️ ${un(a.troops)}</span>
        <span class="rankStat">🏯 ${a.thrones}</span>
        <span class="rankStat">🏆 ${a.wins}</span>
      </div>`).join("");
    }catch(e){ toast(shortMsg(e), true); }
  },
  async loadWars(){
    try{
      const data = await sbRpc("wow_ally_wars", { p_token: this.me.token });
      const box = document.getElementById("warsBox"); if(!box) return;
      const wars = (data && data.wars) || [];
      const isLeader = !!(this._allyInfo && this._allyInfo.leader === this.me.name);
      let html = "";
      if(!wars.length) html += '<div class="empty" style="padding:12px">No hay guerras activas. Reina la paz en Azeroth.</div>';
      wars.forEach(w => {
        const hrs = Math.max(0, Math.ceil((w.ends - Date.now()) / 3600000));
        html += `<div class="warCard${w.mine ? " mine" : ""}">
          <div class="warSide">[${esc(w.a_tag)}] ${esc(w.a_name)}</div>
          <div class="warScore">${w.a_score} : ${w.b_score}</div>
          <div class="warSide r">${esc(w.b_name)} [${esc(w.b_tag)}]</div>
          <div class="warFoot">⏳ ${hrs} h${w.mine ? ' · <button class="btn sm danger" data-surrender="${w.id}">Rendirse</button>' : ""}</div>
        </div>`;
      });
      if(isLeader){
        const list = await sbRpc("wow_alliance_list", { p_token: this.me.token }) || [];
        const atWar = wars.filter(w => w.mine).map(w => w.i_am_a ? w.b : w.a);
        const targets = list.filter(a => !a.mine && !atWars.includes(a.id));
        if(targets.length){
          html += `<div class="warDecl"><select id="warTarget">` +
            targets.map(a => `<option value="${esc(a.id)}">[${esc(a.tag)}] ${esc(a.name)}</option>`).join("") +
            `</select><button class="btn sm danger" id="warGo">⚔️ Declarar guerra</button></div>`;
        }
      }
      box.innerHTML = html;
      const go = document.getElementById("warGo"); if(go) go.onclick = () => this.declareWar();
    }catch(e){ toast(shortMsg(e), true); }
  },
  async declareWar(){
    const sel = document.getElementById("warTarget"); const tid = sel ? sel.value : "";
    if(!tid) return;
    if(!confirm("¿Declarar la guerra? Durará 48 horas y cada victoria en combate sumará puntos a tu alianza.")) return;
    try{ await sbRpc("wow_ally_war_declare", { p_token: this.me.token, p_target: tid }); await this.refresh(); await this.loadWars(); toast("¡Guerra declarada!"); }
    catch(e){ toast(shortMsg(e), true); }
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
  async renderGChat(){
    $("#tabChat").innerHTML =
      '<div class="secTitle">💬 Chat global</div>' +
      '<p class="hint" style="margin:-6px 0 10px">Habla con todos los reinos de Azeroth. Sé respetuoso.</p>' +
      '<div id="gchatMsgs" class="chatBox"></div>' +
      '<div class="chatRow"><input id="gchatIn" placeholder="Escribe al mundo…" maxlength="300"><button class="btn sm" id="gchatSend">Enviar</button></div>';
    $("#gchatSend").onclick = () => this.sendGChat();
    $("#gchatIn").onkeydown = e => { if(e.key === "Enter") this.sendGChat(); };
    await this.loadGChat();
    this.startGChatPoll();
  },
  stopGChatPoll(){ clearInterval(this.gchatTimer); this.gchatTimer = null; },
  startGChatPoll(){ this.stopGChatPoll(); this.gchatTimer = setInterval(() => this.loadGChat(), 4000); },
  async loadGChat(){
    try{
      const msgs = await sbRpc("wow_gchat", { p_token: this.me.token, p_since: 0 });
      const box = document.getElementById("gchatMsgs"); if(!box) return;
      box.innerHTML = (msgs && msgs.length)
        ? msgs.map(m => '<div class="cmsg' + (m.me ? " me" : "") + '"><span class="cwho">' + (m.faction === "horda" ? "⚔️" : "🛡️") + ' ' +
            esc(m.tag ? "[" + m.tag + "] " : "") + esc(m.name) + ':</span> ' + esc(m.msg) +
            ' <span class="ctime">' + hora(m.created) + '</span>' +
            (this.me.is_admin ? ' <button class="btn sm danger" data-gdel="' + m.id + '" title="Borrar mensaje">🗑️</button>' : "") + '</div>').join("")
        : '<div class="empty" style="padding:14px">Sé el primero en escribir.</div>';
      box.scrollTop = box.scrollHeight;
      box.querySelectorAll("[data-gdel]").forEach(b => b.onclick = () => this.delGChat(b.dataset.gdel));
    }catch(_){}
  },
  async sendGChat(){
    const inp = document.getElementById("gchatIn"); const msg = inp ? inp.value.trim() : "";
    if(!msg) return;
    try{ await sbRpc("wow_gchat_send", { p_token: this.me.token, p_msg: msg }); if(inp) inp.value = ""; await this.loadGChat(); }
    catch(e){ toast(shortMsg(e), true); }
  },
  async delGChat(id){
    if(!confirm("¿Borrar este mensaje del chat global?")) return;
    try{ await sbRpc("wow_gchat_delete", { p_token: this.me.token, p_id: Number(id) }); await this.loadGChat(); toast("Mensaje borrado."); }
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
  },

  /* ---------------- gestión (admin) ---------------- */
  setAdminTab(on){
    const btn = $("#tabBtnAdmin"); if(!btn) return;
    btn.classList.toggle("hidden", !on);
    if(!on && this.tab === "admin"){
      const t = document.querySelector('.gameTabs [data-tab="bld"]'); if(t) t.click();
    }
  },
  async loadAdmin(){
    const el = $("#tabAdmin"); if(!el) return;
    el.innerHTML = '<p class="empty">Cargando reinos…</p>';
    try{
      this.adm = await sbRpc("wow_admin_list", { p_token: this.me.token });
      try{ const f = await sbRpc("wow_market_fee", {}); this.mktFee = f && f.fee; }catch(_){ this.mktFee = this.mktFee; }
      try{ const g = await sbRpc("wow_throne_info", { p_token: this.me.token }); this.throneShare = g && g.share; this.throneRates = (g && g.rates) || this.throneRates; }catch(_){ this.throneShare = this.throneShare; }
    }
    catch(e){ this.adm = null; el.innerHTML = '<p class="empty">' + esc(shortMsg(e)) + '</p>'; return; }
    this.renderAdmin();
  },
  renderAdmin(){
    const el = $("#tabAdmin"), d = this.adm; if(!el) return;
    if(!d){ el.innerHTML = '<p class="empty">Sin datos.</p>'; return; }
    const users = d.users || [];
    const rows = users.map(u => {
      const self = u.id === d.me;
      return '<div class="admRow' + (u.active ? "" : " banned") + '">' +
        '<div class="admHead"><b>' + esc(u.name) + '</b> <span class="admId">(' + esc(u.id) + ')</span>' +
          (u.is_admin ? '<span class="admTag">ADMIN</span>' : '') +
          (u.active ? '' : '<span class="admTag ban">BANEADO</span>') +
          '<span class="admFac">' + (u.faction === "horda" ? "⚔️ Horda" : "🛡️ Alianza") + '</span></div>' +
        '<div class="admStats">🏆 ' + un(u.points) + ' · ⚔️ ' + un(u.troops) + ' tropas · 🪙 ' + un(u.gold) + ' · 🪵 ' + un(u.wood) + ' · ⛏️ ' + un(u.ore) + ' · 🧿 ' + un(u.cup||0) +
          (u.alliance ? ' · [' + esc(u.alliance) + ']' : '') + '</div>' +
        '<div class="admActs">' +
          '<button class="btn sm" data-a="res" data-id="' + esc(u.id) + '">💰 Recursos</button>' +
          '<button class="btn sm" data-a="trp" data-id="' + esc(u.id) + '">⚔️ Tropas</button>' +
          '<button class="btn sm" data-a="pw" data-id="' + esc(u.id) + '">🔑 Clave</button>' +
          (self ? '' :
            '<button class="btn sm" data-a="adm" data-id="' + esc(u.id) + '">' + (u.is_admin ? "✋ Quitar admin" : "🛡️ Dar admin") + '</button>' +
            '<button class="btn sm" data-a="ban" data-id="' + esc(u.id) + '" data-on="' + (u.active ? 1 : 0) + '">' + (u.active ? "🚫 Banear" : "✅ Reactivar") + '</button>' +
            '<button class="btn sm danger" data-a="del" data-id="' + esc(u.id) + '">🗑️ Borrar</button>') +
        '</div></div>';
    }).join("");
    el.innerHTML = '<h2 style="margin-top:0;color:var(--gold)">🛡️ Gestión</h2>' +
      '<div style="display:flex;align-items:center;gap:8px;margin-bottom:12px;flex-wrap:wrap"><span class="hint" style="flex:1">' + users.length +
      ' reinos · comisión mercado ' + un(this.mktFee != null ? this.mktFee : 20) + '% · tributo tronos ' + un(this.throneShare != null ? this.throneShare : 1) + '% · tronos +' + un((this.throneRates||{}).gold!=null?this.throneRates.gold:100) + '/' + un((this.throneRates||{}).wood!=null?this.throneRates.wood:100) + '/' + un((this.throneRates||{}).ore!=null?this.throneRates.ore:100) + ' /h · ' + hora(d.now) + '</span>' +
      '<button class="btn sm" id="admFee">⚙️ Comisión</button>' +
      '<button class="btn sm" id="admRefresh">↻ Actualizar</button></div>' +
      '<div class="admList">' + rows + '</div>';
    const rb = $("#admRefresh"); if(rb) rb.onclick = () => this.loadAdmin();
    const fb = $("#admFee"); if(fb) fb.onclick = () => this.admFee();
    el.querySelectorAll("button[data-a]").forEach(b => b.onclick = () => this.admAction(b.dataset.a, b.dataset.id, b.dataset.on));
  },
  admFee(){
    const f = (this.mktFee != null) ? this.mktFee : 20;
    const s = (this.throneShare != null) ? this.throneShare : 1;
    const rt = this.throneRates || { gold: 100, wood: 100, ore: 100 };
    modal('<h2 style="margin-top:0;color:var(--gold)">⚙️ Ajustes de economía</h2>' +
      '<p class="hint">La <b>comisión</b> se descuenta de lo que recibe el vendedor y se destruye. El <b>tributo</b> es el % del valor del trato que va al tesoro de cada trono con dueño (se descuenta de la comisión).</p>' +
      '<div class="admInputs"><label>Comisión mercado (%)<input id="admFeeIn" type="number" min="0" max="90" value="' + f + '"></label>' +
      '<label>Tributo tronos (%)<input id="admThrIn" type="number" min="0" max="90" value="' + s + '"></label></div>' +
      '<p class="hint" style="margin-top:12px">Producción de recursos de cada trono con dueño (por hora, se acumula en el tesoro).</p>' +
      '<div class="admInputs"><label>Oro /h<input id="admThrG" type="number" min="0" max="100000" value="' + un(rt.gold) + '"></label>' +
      '<label>Madera /h<input id="admThrW" type="number" min="0" max="100000" value="' + un(rt.wood) + '"></label>' +
      '<label>Mineral /h<input id="admThrO" type="number" min="0" max="100000" value="' + un(rt.ore) + '"></label></div>' +
      '<div style="text-align:center;margin-top:14px"><button class="btn" id="admGo">Guardar</button></div>' +
      '<div id="admMsg" class="notice" style="margin-top:8px"></div>');
    $("#admGo").onclick = async () => {
      const v = Number($("#admFeeIn").value);
      const sv = Number($("#admThrIn").value);
      const rg = Number($("#admThrG").value);
      const rw = Number($("#admThrW").value);
      const ro = Number($("#admThrO").value);
      if(!(v >= 0 && v <= 90)) return notice($("#admMsg"), "La comisión debe estar entre 0 y 90.", "danger");
      if(!(sv >= 0 && sv <= 90)) return notice($("#admMsg"), "El tributo debe estar entre 0 y 90.", "danger");
      if(!(rg >= 0 && rw >= 0 && ro >= 0)) return notice($("#admMsg"), "La producción debe ser 0 o mayor.", "danger");
      $("#admGo").disabled = true;
      try{
        await sbRpc("wow_admin_setfee", { p_token: this.me.token, p_fee: v });
        await sbRpc("wow_admin_setthrone", { p_token: this.me.token, p_pct: sv });
        await sbRpc("wow_admin_setthrones", { p_token: this.me.token, p_gold: rg, p_wood: rw, p_ore: ro });
        this.mktFee = v; this.throneShare = sv; this.throneRates = { gold: rg, wood: rw, ore: ro };
        modalClose(); toast("Ajustes guardados."); this.loadAdmin();
      }catch(e){ $("#admGo").disabled = false; notice($("#admMsg"), shortMsg(e), "danger"); }
    };
  },
  admUser(id){ return (this.adm && this.adm.users || []).find(x => x.id === id); },
  admAction(a, id, on){
    const u = this.admUser(id); if(!u) return;
    if(a === "res") return this.admRes(u);
    if(a === "trp") return this.admTrp(u);
    if(a === "pw") return this.admPw(u);
    if(a === "adm") return this.admSetAdmin(u);
    if(a === "ban") return this.admBan(u, on === "1");
    if(a === "del") return this.admDel(u);
  },
  admRes(u){
    modal('<h2 style="margin-top:0;color:var(--gold)">💰 Recursos · ' + esc(u.name) + '</h2>' +
      '<p class="hint">Valores negativos restan. Actual: 🪙 ' + un(u.gold) + ' · 🪵 ' + un(u.wood) + ' · ⛏️ ' + un(u.ore) + '</p>' +
      '<div class="admInputs">' +
        '<label>Oro<input id="admG" type="number" value="1000"></label>' +
        '<label>Madera<input id="admW" type="number" value="1000"></label>' +
        '<label>Mineral<input id="admO" type="number" value="1000"></label>' +
        '<label>CUP<input id="admC" type="number" value="0"></label>' +
      '</div>' +
      '<div style="text-align:center;margin-top:14px"><button class="btn" id="admGo">Aplicar</button></div>' +
      '<div id="admMsg" class="notice" style="margin-top:8px"></div>');
    $("#admGo").onclick = async () => {
      $("#admGo").disabled = true;
      try{
        await sbRpc("wow_admin_grant", { p_token: this.me.token, p_id: u.id,
          p_gold: Number($("#admG").value) || 0, p_wood: Number($("#admW").value) || 0, p_ore: Number($("#admO").value) || 0, p_cup: Number($("#admC").value) || 0 });
        modalClose(); toast("Recursos actualizados."); this.loadAdmin();
      }catch(e){ $("#admGo").disabled = false; notice($("#admMsg"), shortMsg(e), "danger"); }
    };
  },
  admTrp(u){
    const opts = Object.keys(TRP).map(k => '<option value="' + k + '">' + esc(TRP[k].n) + '</option>').join("");
    modal('<h2 style="margin-top:0;color:var(--gold)">⚔️ Tropas · ' + esc(u.name) + '</h2>' +
      '<p class="hint">Total actual: ' + un(u.troops) + '. Negativo quita tropas.</p>' +
      '<div class="admInputs">' +
        '<label>Tropa<select id="admT">' + opts + '</select></label>' +
        '<label>Cantidad<input id="admQ" type="number" value="100"></label>' +
      '</div>' +
      '<div style="text-align:center;margin-top:14px"><button class="btn" id="admGo">Aplicar</button></div>' +
      '<div id="admMsg" class="notice" style="margin-top:8px"></div>');
    $("#admGo").onclick = async () => {
      $("#admGo").disabled = true;
      try{
        await sbRpc("wow_admin_troops", { p_token: this.me.token, p_id: u.id,
          p_key: $("#admT").value, p_qty: Number($("#admQ").value) || 0 });
        modalClose(); toast("Tropas actualizadas."); this.loadAdmin();
      }catch(e){ $("#admGo").disabled = false; notice($("#admMsg"), shortMsg(e), "danger"); }
    };
  },
  admPw(u){
    modal('<h2 style="margin-top:0;color:var(--gold)">🔑 Resetear contraseña · ' + esc(u.name) + '</h2>' +
      '<p class="hint">Se cerrará su sesión y deberá entrar con la nueva contraseña.</p>' +
      '<div class="admInputs"><label>Nueva contraseña<input id="admP" type="text" value=""></label></div>' +
      '<div style="text-align:center;margin-top:14px"><button class="btn" id="admGo">Cambiar</button></div>' +
      '<div id="admMsg" class="notice" style="margin-top:8px"></div>');
    $("#admGo").onclick = async () => {
      const p = $("#admP").value;
      if(!p || p.length < 4){ return notice($("#admMsg"), "Mínimo 4 caracteres.", "danger"); }
      $("#admGo").disabled = true;
      try{
        const salt = newSalt();
        const hash = await pbkdf2Hex(p, salt, 100000);
        await sbRpc("wow_admin_setpw", { p_token: this.me.token, p_id: u.id, p_salt: salt, p_hash: hash });
        modalClose(); toast("Contraseña cambiada. Compártela con el jugador.");
      }catch(e){ $("#admGo").disabled = false; notice($("#admMsg"), shortMsg(e), "danger"); }
    };
  },
  admSetAdmin(u){
    const to = !u.is_admin;
    modal('<h2 style="margin-top:0;color:var(--gold)">' + (to ? "🛡️ Dar admin" : "✋ Quitar admin") + '</h2>' +
      '<p class="hint">¿' + (to ? "Dar" : "Quitar") + ' permisos de administrador a <b>' + esc(u.name) + '</b>?</p>' +
      '<div style="text-align:center;margin-top:14px"><button class="btn" id="admGo">Confirmar</button></div>' +
      '<div id="admMsg" class="notice" style="margin-top:8px"></div>');
    $("#admGo").onclick = async () => {
      $("#admGo").disabled = true;
      try{
        await sbRpc("wow_admin_setadmin", { p_token: this.me.token, p_id: u.id, p_admin: to });
        modalClose(); toast(to ? "Admin concedido." : "Admin retirado."); this.loadAdmin();
      }catch(e){ $("#admGo").disabled = false; notice($("#admMsg"), shortMsg(e), "danger"); }
    };
  },
  admBan(u, currentlyActive){
    const target = !currentlyActive;
    modal('<h2 style="margin-top:0;color:var(--gold)">' + (target ? "🚫 Banear" : "✅ Reactivar") + '</h2>' +
      '<p class="hint">¿' + (target ? "Banear" : "Reactivar") + ' a <b>' + esc(u.name) + '</b>?' +
      (target ? ' Su sesión se cerrará y no podrá entrar hasta que lo reactives.' : '') + '</p>' +
      '<div style="text-align:center;margin-top:14px"><button class="btn" id="admGo">Confirmar</button></div>' +
      '<div id="admMsg" class="notice" style="margin-top:8px"></div>');
    $("#admGo").onclick = async () => {
      $("#admGo").disabled = true;
      try{
        await sbRpc("wow_admin_ban", { p_token: this.me.token, p_id: u.id, p_active: !target });
        modalClose(); toast(target ? "Reino baneado." : "Reino reactivado."); this.loadAdmin();
      }catch(e){ $("#admGo").disabled = false; notice($("#admMsg"), shortMsg(e), "danger"); }
    };
  },
  admDel(u){
    modal('<h2 style="margin-top:0;color:var(--bad)">🗑️ Borrar reino</h2>' +
      '<p class="hint">Se borrará <b>' + esc(u.name) + '</b> (' + esc(u.id) + ') con TODOS sus edificios, tropas y datos. ' +
      'Esta acción NO se puede deshacer.</p>' +
      '<div style="text-align:center;margin-top:14px"><button class="btn" id="admGo" style="background:var(--bad);color:#1a0606">Borrar definitivamente</button></div>' +
      '<div id="admMsg" class="notice" style="margin-top:8px"></div>');
    $("#admGo").onclick = async () => {
      $("#admGo").disabled = true;
      try{
        await sbRpc("wow_admin_delete", { p_token: this.me.token, p_id: u.id });
        modalClose(); toast("Reino borrado."); this.loadAdmin();
      }catch(e){ $("#admGo").disabled = false; notice($("#admMsg"), shortMsg(e), "danger"); }
    };
  }
};

window.addEventListener("error", ev => {
  try{ toast("Error: " + (ev.message || "desconocido"), true); }catch(_){}
});
document.addEventListener("DOMContentLoaded", () => Auth.init());

/* ----- mercado (entre jugadores) ----- */
const MKT_ITEMS = ["cup","gold","wood","ore","soldado","arquero","jinete","mago","paladin","dragon"];
function mktName(k){
  if(k === "cup")  return "🧿 CUP";
  if(k === "gold") return "💰 Oro";
  if(k === "wood") return "🪵 Madera";
  if(k === "ore")  return "⛏️ Mineral";
  const t = TRP[k]; return t ? t.n : k;
}
Game.loadMarket = async function(){
  const el = $("#tabMarket"); if(!el) return;
  el.innerHTML = '<p class="empty">Cargando mercado…</p>';
  let d;
  try{ d = await sbRpc("wow_market_list", { p_token: this.me.token }); }
  catch(e){ el.innerHTML = '<p class="empty">' + esc(shortMsg(e)) + '</p>'; return; }
  this.mkt = d;
  const st = this.st || {};
  const inv = { cup: st.cup || 0, gold: st.gold || 0, wood: st.wood || 0, ore: st.ore || 0 };
  (st.troops || []).forEach(t => inv[t.key] = t.qty);
  const opts = MKT_ITEMS.map(k => '<option value="' + k + '">' + esc(mktName(k)) + '</option>').join("");
  let html = '<h2 style="margin-top:0;color:var(--gold)">🛒 Mercado</h2>' +
    '<p class="hint">Publica ofertas y toma las de otros reinos. Comisión actual: <b>' + un(d.fee) + '%</b> (la paga el vendedor). Las ofertas caducan en 1 día.</p>' +
    '<div class="secTitle">📢 Publicar oferta</div>' +
    '<div class="mktPub">' +
      '<label>Doy <select id="mkGive">' + opts + '</select>' +
        '<input id="mkGiveQty" type="number" min="0" value="0"><button class="btn sm" id="mkGiveMax">MAX</button></label>' +
      '<label>Pido <select id="mkWant">' + opts + '</select>' +
        '<input id="mkWantQty" type="number" min="0" value="0"></label>' +
      '<button class="btn" id="mkPubGo">📢 Publicar oferta</button>' +
    '</div>' +
    '<div id="mkMsg" class="notice"></div>';
  html += '<div class="secTitle">🌍 Ofertas del reino</div>';
  if(!(d.offers || []).length) html += '<div class="empty">No hay ofertas ahora mismo.</div>';
  else html += (d.offers || []).map(o =>
      '<div class="fleet"><span class="fi">🤝</span>' +
      '<div class="fmain"><div class="ft">' + esc(o.who) + '</div>' +
      '<div class="fd">da <b>' + un(o.give_left) + '</b> ' + esc(mktName(o.give)) + ' → pide <b>' + un(o.want_left) + '</b> ' + esc(mktName(o.want)) + '</div></div>' +
      '<div class="fcount"><input id="mkTk_' + o.id + '" type="number" min="0" value="' + o.give_left + '" style="width:78px"> ' +
      '<button class="btn sm" data-take="' + o.id + '">Tomar</button></div></div>'
    ).join("");
  html += '<div class="secTitle">📦 Mis ofertas</div>';
  if(!(d.mine || []).length) html += '<div class="empty">No tienes ofertas activas.</div>';
  else html += (d.mine || []).map(o =>
      '<div class="fleet"><span class="fi">📦</span>' +
      '<div class="fmain"><div class="ft">da <b>' + un(o.give_left) + '</b> ' + esc(mktName(o.give)) + '</div>' +
      '<div class="fd">pide <b>' + un(o.want_left) + '</b> ' + esc(mktName(o.want)) + '</div></div>' +
      '<div class="fcount"><button class="btn sm danger" data-cancel="' + o.id + '">Cancelar</button></div></div>'
    ).join("");
  el.innerHTML = html;
  const maxb = $("#mkGiveMax");
  if(maxb) maxb.onclick = () => { const k = $("#mkGive").value; $("#mkGiveQty").value = Math.floor(inv[k] || 0); };
  const gb = $("#mkPubGo");
  if(gb) gb.onclick = () => this.mktPublish();
  el.querySelectorAll("button[data-take]").forEach(b => b.onclick = () => this.mktTake(Number(b.dataset.take)));
  el.querySelectorAll("button[data-cancel]").forEach(b => b.onclick = () => this.mktCancel(Number(b.dataset.cancel)));
};
Game.mktPublish = async function(){
  const g = $("#mkGive").value, w = $("#mkWant").value;
  const gq = Number($("#mkGiveQty").value) || 0, wq = Number($("#mkWantQty").value) || 0;
  if(gq <= 0 || wq <= 0) return toast("Pon cantidades mayores que 0.", true);
  if(g === w) return toast("No puedes cambiar un objeto por sí mismo.", true);
  try{
    await sbRpc("wow_market_offer", { p_token: this.me.token, p_give: g, p_give_qty: gq, p_want: w, p_want_qty: wq });
    toast("📢 Oferta publicada."); await this.refresh();
  }catch(e){ toast(shortMsg(e), true); }
};
Game.mktTake = async function(id){
  const inp = $("#mkTk_" + id);
  const q = Number(inp && inp.value) || 0;
  if(q <= 0) return toast("Cantidad inválida.", true);
  try{
    const r = await sbRpc("wow_market_take", { p_token: this.me.token, p_id: id, p_qty: q });
    toast("🤝 Tomaste " + un(r.took) + " · pagaste " + un(r.paid) + ".");
    await this.refresh();
  }catch(e){ toast(shortMsg(e), true); }
};
Game.thrEvent = function(h){
  const who = esc(h.actor_name || "?");
  const t = hora(h.created);
  let txt = "";
  if(h.kind === "take") txt = "🏯 <b>" + who + "</b> ocupó el trono libre.";
  else if(h.kind === "conquest") txt = "⚔️ <b>" + who + "</b> conquistó el trono" + (h.detail && h.detail.from ? " (era de " + esc(h.detail.from) + ")" : "") + ".";
  else if(h.kind === "defended") txt = "🛡️ La defensa rechazó a <b>" + who + "</b>.";
  else if(h.kind === "reinforce") txt = "➕ <b>" + who + "</b> reforzó la guarnición.";
  else if(h.kind === "withdraw") txt = "➖ <b>" + who + "</b> retiró tropas de la guarnición.";
  else if(h.kind === "claim") txt = "💰 <b>" + who + "</b> reclamó el tesoro.";
  else txt = "• " + esc(h.kind);
  return txt + ' <span style="opacity:.6">· ' + t + '</span>';
};
Game.openThrone = async function(node){
  try{
    const r = await sbRpc("wow_throne_info", { p_token: this.me.token });
    this._thrones = r.thrones || [];
    const t = this._thrones.find(x => x.node === node);
    const me = this.me;
    const own = !!(t && t.holder === me.id);
    const troops = ((this.st && this.st.troops) || []).filter(x => x.qty > 0);
    let body = '<h2 style="margin-top:0;color:var(--gold)">🏯 ' + esc(t ? t.name : "Trono") + '</h2>';
    if(!t){
      body += '<div class="muted">Trono libre. Envía tropas para ocuparlo.</div>';
    }else{
      body += '<div class="row"><span>Dueño</span><span>' + esc(t.holder_name || 'Libre') + (t.faction? ' ['+esc(t.faction)+']' : '') + '</span></div>';
      body += '<div class="row"><span>Guarnición</span><span>' + un(t.garrison||0) + ' tropas</span></div>';
      if(t.treasure && Object.keys(t.treasure).length){
        body += '<div class="muted" style="margin-top:6px">Tesoro acumulado</div>';
        for(let k in t.treasure) body += '<div class="row"><span>' + mktName(k) + '</span><span>' + un(t.treasure[k]) + '</span></div>';
      }else body += '<div class="muted">Sin tesoro por ahora.</div>';
      body += '<div class="row"><span>Tributo</span><span>' + un(r.share||1) + '% del valor del trato</span></div>';
      if(r.rates) body += '<div class="muted" style="margin-top:4px">Genera +' + un(r.rates.gold||0) + ' 💰 oro · +' + un(r.rates.wood||0) + ' 🪵 madera · +' + un(r.rates.ore||0) + ' ⛏️ mineral por hora (se acumula en el tesoro).</div>';
    }
    if(!own){
      body += '<div class="muted" style="margin-top:10px">Enviar desde tu reino</div>';
      if(!troops.length){
        body += '<div class="muted">No tienes tropas. Entrena en el Cuartel (pestaña ⚔️ Tropas).</div>';
      }else{
        troops.forEach(x => {
          const m = TRP[x.key] || { e: "⚔️", n: x.key };
          body += '<div class="atkRow"><span class="an">' + (m.e || "⚔️") + ' ' + m.n + '</span><span class="amax">de ' + un(x.qty) + '</span>' +
            '<input id="thq_' + x.key + '" type="number" min="0" step="1" max="' + Math.floor(x.qty) + '" value="">' +
            '<button class="btn sm" data-thmax="' + x.key + '">MAX</button></div>';
        });
        body += '<div style="text-align:center;margin-top:10px">' +
          '<button class="btn" id="thrAtkBtn">⚔️ ' + (t && t.holder ? 'Atacar para conquistar' : 'Ocupar el trono') + '</button></div>';

      }
    }else{
      const gd = (t && t.gdetail) || {};
      const gkeys = Object.keys(gd).filter(k => Number(gd[k]) > 0);
      body += '<div class="muted" style="margin-top:10px">Enviar refuerzos desde tu reino</div>';
      if(!troops.length){
        body += '<div class="muted">No tienes tropas para reforzar.</div>';
      }else{
        troops.forEach(x => {
          const m = TRP[x.key] || { e: "⚔️", n: x.key };
          body += '<div class="atkRow"><span class="an">' + (m.e || "⚔️") + ' ' + m.n + '</span><span class="amax">de ' + un(x.qty) + '</span>' +
            '<input id="thq_' + x.key + '" type="number" min="0" step="1" max="' + Math.floor(x.qty) + '" value="">' +
            '<button class="btn sm" data-thmax="' + x.key + '">MAX</button></div>';
        });
      }
      if(gkeys.length){
        body += '<div class="muted" style="margin-top:12px">Retirar tropas de la guarnición</div>';
        gkeys.forEach(k => {
          const m = TRP[k] || { e: "⚔️", n: k };
          const gq = Math.floor(Number(gd[k]) || 0);
          body += '<div class="atkRow"><span class="an">' + (m.e || "⚔️") + ' ' + m.n + '</span><span class="amax">de ' + un(gq) + '</span>' +
            '<input id="thw_' + k + '" type="number" min="0" step="1" max="' + gq + '" value="">' +
            '<button class="btn sm" data-thwmax="' + k + '">MAX</button></div>';
        });
      }
      body += '<div style="text-align:center;margin-top:10px">' +
        (troops.length ? '<button class="btn" id="thrReinBtn">🛡️ Reforzar guarnición</button>' : '') +
        (gkeys.length ? '<button class="btn" id="thrWithBtn">➖ Retirar tropas</button>' : '') +
        (t.treasure && Object.keys(t.treasure).length ? '<button class="btn" id="thrClaimBtn">💰 Reclamar tesoro</button>' : '') +
        '</div>';
    }
    if(t && t.history && t.history.length){
      body += '<div class="muted" style="margin-top:12px">Historial</div><div class="thrHist">';
      t.history.forEach(h => body += '<div class="thrEvent">' + this.thrEvent(h) + '</div>');
      body += '</div>';
    }
    modal(body);
    document.querySelectorAll('#modalBox button[data-thmax]').forEach(b => {
      b.onclick = () => {
        const inp = document.getElementById('thq_' + b.dataset.thmax);
        if(inp) inp.value = Number(inp.max) || 0;
      };
    });
    document.querySelectorAll('#modalBox button[data-thwmax]').forEach(b => {
      b.onclick = () => {
        const inp = document.getElementById('thw_' + b.dataset.thwmax);
        if(inp) inp.value = Number(inp.max) || 0;
      };
    });
    const ab = document.getElementById("thrAtkBtn"); if(ab) ab.onclick = () => this.thrAtk(node);
    const rb = document.getElementById("thrReinBtn"); if(rb) rb.onclick = () => this.thrRein(node);
    const wb = document.getElementById("thrWithBtn"); if(wb) wb.onclick = () => this.thrWith(node);
    const cb = document.getElementById("thrClaimBtn"); if(cb) cb.onclick = () => this.thrClaim(node);
  }catch(e){ toast(shortMsg(e), true); }
};
Game._thrTroops = function(){
  const payload = {};
  document.querySelectorAll('#modalBox input[id^="thq_"]').forEach(inp => {
    const k = inp.id.slice(4);
    const v = Math.max(0, parseInt(inp.value, 10) || 0);
    if(v > 0) payload[k] = v;
  });
  return payload;
};
Game.thrAtk = async function(node){
  const payload = this._thrTroops();
  if(!Object.keys(payload).length) return toast("Elige al menos una tropa.", true);
  try{
    const r = await sbRpc("wow_throne_attack", { p_token: this.me.token, p_node: node, p_troops: payload });
    modalClose();
    toast(r.free ? "🏯 ¡Ocupaste el trono!" : (r.win ? "👑 ¡Conquistaste el trono!" : "❌ La guarnición resistió."));
    await this.refresh(); await this.loadMap();
    this.showMarchFx(this._myNode(), node, "⚔️", "atk");
  }catch(e){ toast(shortMsg(e), true); }
};
Game.thrRein = async function(node){
  const payload = this._thrTroops();
  if(!Object.keys(payload).length) return toast("Elige al menos una tropa.", true);
  try{
    await sbRpc("wow_throne_reinforce", { p_token: this.me.token, p_node: node, p_troops: payload });
    modalClose();
    toast("🛡️ Guarnición reforzada.");
    await this.refresh(); await this.loadMap();
    this.showMarchFx(this._myNode(), node, "🛡️", "rein");
  }catch(e){ toast(shortMsg(e), true); }
};
Game._thrWithTroops = function(){
  const payload = {};
  document.querySelectorAll('#modalBox input[id^="thw_"]').forEach(inp => {
    const k = inp.id.slice(4);
    const v = Math.max(0, parseInt(inp.value, 10) || 0);
    if(v > 0) payload[k] = v;
  });
  return payload;
};
Game.thrWith = async function(node){
  const payload = this._thrWithTroops();
  if(!Object.keys(payload).length) return toast("Elige al menos una tropa para retirar.", true);
  if(!confirm("¿Retirar estas tropas de la guarnición? Si la dejas vacía, otro reino podrá ocupar el trono.")) return;
  try{
    const r = await sbRpc("wow_throne_withdraw", { p_token: this.me.token, p_node: node, p_troops: payload });
    modalClose();
    toast(r.empty ? "➖ Tropas retiradas. ¡La guarnición quedó vacía!" : "➖ Tropas retiradas a tu reino.");
    await this.refresh(); await this.loadMap();
    this.showMarchFx(node, this._myNode(), "🚩", "back");
  }catch(e){ toast(shortMsg(e), true); }
};
Game.thrClaim = async function(node){
  try{
    const r = await sbRpc("wow_throne_claim", { p_token: this.me.token, p_node: node });
    const c = r.claimed || {};
    const parts = Object.keys(c).filter(k => Number(c[k]) > 0).map(k => mktName(k) + ": " + un(c[k]));
    modalClose();
    toast("💰 Reclamado: " + (parts.length ? parts.join(", ") : "nada"));
    await this.refresh(); await this.loadMap();
    this.showMarchFx(node, this._myNode(), "💰", "back");
  }catch(e){ toast(shortMsg(e), true); }
};

Game.mktCancel = async function(id){
  try{
    await sbRpc("wow_market_cancel", { p_token: this.me.token, p_id: id });
    toast("Oferta cancelada."); await this.refresh();
  }catch(e){ toast(shortMsg(e), true); }
};
