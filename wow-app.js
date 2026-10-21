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
const dec = n => Number(n || 0).toLocaleString("es", { maximumFractionDigits: 2 });
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
const _diagPre = [];
function logBook(){
  const parts = [];
  for(let i = 0; i < arguments.length; i++){
    const a = arguments[i];
    try{ parts.push(typeof a === "string" ? a : JSON.stringify(a)); }catch(_){ parts.push(String(a)); }
  }
  const line = new Date().toLocaleTimeString("es") + "  " + parts.join(" ");
  try{ console.log("[wow]", ...parts); }catch(_){}
  try{
    _diagPre.push(line); if(_diagPre.length > 24) _diagPre.shift();
    const box = document.getElementById("logBox"), pre = document.getElementById("logPre");
    if(box && pre){ pre.textContent = _diagPre.join("\n"); box.classList.remove("hidden"); }
  }catch(_){}
}
function logBind(){
  try{
    const h = document.getElementById("logHide"); if(h) h.onclick = () => document.getElementById("logBox").classList.add("hidden");
    const c = document.getElementById("logClear"); if(c) c.onclick = () => { _diagPre.length = 0; const p = document.getElementById("logPre"); if(p) p.textContent = ""; };
  }catch(_){}
  window.addEventListener("error", e => logBook("ERROR", (e && e.message) || "?"));
  window.addEventListener("unhandledrejection", e => logBook("PROMESA RECHAZADA", (e && e.reason && (e.reason.message || e.reason)) || "?"));
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
  muralla:    { e: "🛡️", n: "Muralla",         d: "Protege tu reino",                 p: "Defensa de tu reino", img: "img/muralla.jpg?v=1", imgH: "img/horda/muralla.jpg?v=1" }
};
const TRP = {
  soldado: { e: "🗡️", n: "Soldado", d: "Infantería básica", req: 1,  img: "img/soldado.jpg", imgH: "img/horda/soldado.jpg" },
  arquero: { e: "🏹", n: "Arquero", d: "Ataca a distancia", req: 3,  img: "img/arquero.jpeg", imgH: "img/horda/arquero.jpg" },
  jinete:  { e: "🐎", n: "Jinete",  d: "Carga rápida", req: 5,  img: "img/jinete.jpg", imgH: "img/horda/jinete.jpg" },
  mago:    { e: "🔮", n: "Mago",    d: "Daño mágico", req: 7,  img: "img/mago.jpg", imgH: "img/horda/mago.jpg" },
  paladin: { e: "🛡️", n: "Paladín", d: "Guerrero sagrado, brutal contra magos y dragones", req: 9,  img: "img/paladin.jpg", imgH: "img/horda/paladin.jpg" },
  dragon:  { e: "🐉", n: "Dragón",  d: "Bestia legendaria, arrasa infantería y magos", req: 11, img: "img/dragon.jpg", imgH: "img/horda/dragon.jpg?v=2" }
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

/* mapa: canvas 2400x2400 con CUATRO continentes (2x2) unidos por 4 puentes.
   Red de caminos = MST de cada continente + puentes entre los 4 tronos.
   Nodos: 0=trono alto-izq,  1..20=castillos alto-izq,
          21=trono bajo-izq, 22..41=castillos bajo-izq,
          50=trono alto-der, 51..70=castillos alto-der,
          75=trono bajo-der, 76..95=castillos bajo-der,
          aldeas: 42..45 alto-izq, 46..49 bajo-izq, 71..74 alto-der, 96..99 bajo-der */
const MAPW = 2400, MAPH = 2400, MAPKX = 0.72, MAPKY = 0.60;
const MAP_CONT = [[600, 600], [600, 1800], [1800, 600], [1800, 1800]];
const CONT_BASE = [0, 21, 50, 75];
const ALDEA_POS = [[-560, -560], [560, -560], [560, 560], [-560, 560]];
const ALDEA_NODES = [42, 43, 44, 45, 46, 47, 48, 49, 71, 72, 73, 74, 96, 97, 98, 99];
const MAP_NODE = 100;
function nodeCont(idx){
  if(idx >= 42 && idx <= 49) return idx <= 45 ? 0 : 1;
  if(idx >= 71 && idx <= 74) return 2;
  if(idx >= 96 && idx <= 99) return 3;
  for(let c = CONT_BASE.length - 1; c >= 0; c--) if(idx >= CONT_BASE[c]) return c;
  return 0;
}
function isAldeaNode(idx){ return ALDEA_NODES.indexOf(idx) >= 0; }
function mapNodeXY(idx){
  const c = nodeCont(idx), ctr = MAP_CONT[c], off = idx - CONT_BASE[c];
  if(off === 0) return ctr.slice();                     /* trono */
  const ai = ALDEA_NODES.indexOf(idx);
  if(ai >= 0){ const a = ALDEA_POS[ai % 4]; return [ctr[0] + a[0]*MAPKX, ctr[1] + a[1]*MAPKY]; }
  const s = SLOT_POS[off - 1];
  return [ctr[0] + s[0]*MAPKX, ctr[1] + s[1]*MAPKY];
}
/* segundos de viaje: distancia en px del mapa entre dos nodos/castillos */
function travelNodes(a, b){
  const p = mapNodeXY(a), q = mapNodeXY(b);
  return Math.max(20, Math.round(15 + Math.hypot(q[0]-p[0], q[1]-p[1]) / 20));
}
function travelSec(pa, pb){ return travelNodes(mapPosNode(pa), mapPosNode(pb)); }
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
    mst(coords, CONT_BASE[ci]);
  });
  /* 4 puentes entre los tronos: izq (0-1), arriba (0-2), abajo (1-3), der (2-3) */
  link(CONT_BASE[0], CONT_BASE[1]);
  link(CONT_BASE[0], CONT_BASE[2]);
  link(CONT_BASE[1], CONT_BASE[3]);
  link(CONT_BASE[2], CONT_BASE[3]);
  /* aldeas: cada una al castillo mas cercano de su continente (slots 0,3,6,9) */
  ALDEA_NODES.forEach((n, i) => link(n, CONT_BASE[Math.floor(i / 4)] + 1 + [0, 3, 6, 9][i % 4]));
  return adj;
})();
function mapPosNode(pos){
  const N = SLOT_POS.length, T = N * MAP_CONT.length;
  const p = (((pos % T) + T) % T);
  const c = Math.floor(p / N), s = p % N;
  return CONT_BASE[c] + s + 1;
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
        $("#tabTavern").classList.toggle("hidden", Game.tab !== "tavern");
        $("#tabAdmin").classList.toggle("hidden", Game.tab !== "admin");
        if(Game.tab === "rank") Game.loadRank();
        if(Game.tab === "bld") Game.renderBld();
        if(Game.tab === "troop") Game.renderTroop();
        if(Game.tab === "map") Game.loadMap(); else { Game.stopMarchLoop(); Game.stopMarchPoll(); }
        if(Game.tab === "mil") Game.loadMil();
        if(Game.tab === "ally") Game.renderAlly(); else Game.stopChatPoll();
        if(Game.tab === "chat") Game.renderGChat(); else Game.stopGChatPoll();
        if(Game.tab === "market") Game.loadMarket && Game.loadMarket();
        if(Game.tab === "tavern") Game.loadTavern && Game.loadTavern();
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
      await sbRpc("wow_register", { p_name: name, p_realm: realm, p_faction: this.fac, p_salt: salt, p_hash: hash });
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
    const ht = document.querySelector(".hudTop");
    if (ht) ht.classList.toggle("fac-horda", me.faction === "horda");
    const ab = $("#gAlly"); if(ab){ ab.textContent = ""; ab.style.display = "none"; }
    this.setAdminTab(!!me.is_admin);
    try{ const p = await sbRpc("wow_protect_info", {}); this.protect = p && p.points; }catch(_){}
    await this.refresh();
    if (this.me && this.me.id === "admin") this.setAdminTab(true);
    this.loop();
  },
  stop(){ clearInterval(this.timer); this.timer = null; this.st = null; this.rankLoaded = false; this._mktSig = null; this.mkt = null; this._mapScroll = null; this.stopMarchLoop(); this.stopMarchPoll(); this.stopChatPoll(); this.stopGChatPoll(); },
  async refresh(){
    try{
      this.st = await sbRpc("wow_state", { p_token: this.me.token });
      this.stNow = Date.now();
      this.setAdminTab(!!this.st.is_admin || (this.me && this.me.id === "admin"));
      $("#gPts").textContent = un(this.st.points);
      const onEl = $("#gOnline"); if(onEl) onEl.textContent = "🟢 " + un(this.st.online || 0) + " en línea";
      const ab = $("#gAlly");
      if(ab){ ab.textContent = this.st.ally_tag ? (this.st.ally_emblem || "") + "[" + this.st.ally_tag + "]" : ""; ab.style.display = this.st.ally_tag ? "" : "none"; }
      if(this.st.ally_tag && (!this._diploTs || Date.now() - this._diploTs > 60000)) this.loadDiplo(true);
      this.renderBld(); this.renderTroop(); this.tick();
      if(this.tab === "rank" && this.rankLoaded) this.loadRank();
      if(this.tab === "map") this.loadMap();
      if(this.tab === "mil") this.loadMil();
      if(this.tab === "market" && this.loadMarket) this.loadMarket();
      if(this.tab === "tavern" && this.loadTavern) this.loadTavern();
      if(this.tab === "admin") this.loadAdmin(true);
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
    const pm = Number(s.prod_mult != null ? s.prod_mult : 1);
    const pn = $("#prodNote");
    if(pn) pn.innerHTML = (pm !== 1)
      ? '<span class="prodBadge" title="La producción de recursos de tu reino está ajustada por el administrador">⚙️ Producción ×' + dec(pm) + '</span>'
      : '';
    const box = $("#queueBox");
    const qs = (s.queues && s.queues.length) ? s.queues : (s.queue ? [s.queue] : []);
    const active = qs.filter(q => q && q.finish);
    if(active.length){
      box.classList.remove("hidden");
      box.innerHTML = active.map(q => {
        const label = q.kind === "build"
          ? "🔨 Construyendo: " + (BLD[q.ref] ? BLD[q.ref].n : q.ref)
          : "⚔️ Entrenando: " + (TRP[q.ref] ? q.qty + " " + TRP[q.ref].n + (q.qty === 1 ? "" : "s") : q.ref);
        const total = Math.max(1, q.finish - q.start), done = Math.max(0, now - q.start);
        const rem = (q.finish - now) / 1000;
        return '<div class="qRow"><div class="qLabel">' + label + '</div>' +
          '<div class="qBar"><div class="qFill" style="width:' + Math.min(100, done / total * 100) + '%"></div></div>' +
          '<div class="qTime">' + (rem > 0 ? "⏳ " + tfmt(rem) + " restantes" : "¡Listo! sincronizando…") + '</div></div>';
      }).join("");
      if(active.some(q => (q.finish - now) <= 0) && !this.syncing){ this.syncing = true; this.refresh().finally(() => { this.syncing = false; }); }
    }else{
      box.classList.add("hidden");
    }
    if(this.tab === "mil"){
      const due = this.updateMilTimers();
      if(due && !this.milSyncing){ this.milSyncing = true; this.loadMil().finally(() => { this.milSyncing = false; }); }
    }
  },

  /* ----- edificios ----- */
  hasQueue(kind){
    const s = this.st; if(!s) return false;
    const qs = (s.queues && s.queues.length) ? s.queues : (s.queue ? [s.queue] : []);
    return qs.some(q => q && q.kind === kind && q.finish);
  },
  renderBld(){
    const s = this.st; if(!s) return;
    const busy = this.hasQueue("build");
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
    const busy = this.hasQueue("train");
    const barr = (s.buildings || []).find(b => b.key === "cuartel");
    const lvl = barr ? barr.level : 0;
    const unlocked = lvl >= 1;
    let html = "";
    if(!unlocked){
      html += `<div class="empty">⚔️ Necesitas al menos un <b>Cuartel</b> (nivel 1) para entrenar tropas.<br><br>Sube el Cuartel en la pestaña 🏰 Edificios.</div>`;
    }
    const abon = Number(s.atk_bonus || 0);
    html += '<div class="hint" style="margin:6px 0 10px">🔒 El <b>Cuartel</b> desbloquea tropas: 🗡️ Soldado 1 · 🏹 Arquero 3 · 🐎 Jinete 5 · 🔮 Mago 7 · 🛡️ Paladín 9 · 🐉 Dragón 11.</div>';
    if(abon > 0) html += `<div class="hint" style="margin:0 0 10px;color:var(--gold)">💃 La Madam y sus chicas cabalgan con tus tropas: <b>+${abon} de ataque</b> a cada unidad mientras el contrato esté activo.</div>`;
    html += '<div class="grid">';
    (s.troops || []).forEach(t => {
      const m = TRP[t.key] || { e: "⚔️", n: t.key, d: "" };
      const c = CTR[t.key] || { up: "—", dn: "—" };
      const req = (t.req != null) ? t.req : (m.req || 1);
      const locked = unlocked && lvl < req;
      const canTr = unlocked && !locked && !busy;
      const noG = s.gold < t.cost.gold, noW = s.wood < t.cost.wood, noO = s.ore < t.cost.ore;
      const img = facImg(m);
      const head = `<div class="cardTop">
          ${img ? "" : `<span class="emoji">${m.e}</span>`}
          <div style="flex:1"><div class="bName">${m.n} <span class="troopQty">× ${un(t.qty)}</span>${locked ? `<span class="lockTag">🔒 Cuartel ${req}</span>` : ""}</div>
          <div class="bDesc">${m.d}</div>
          <div class="bDesc" style="color:var(--gold)">⚔️ ATK ${un(Number(t.atk) + abon)}${abon > 0 ? ` <span style="color:var(--green)">(+${abon} 💃)</span>` : ""} · ❤️ HP ${un(t.hp)}</div>
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
          ${locked ? `<div class="bDesc" style="color:var(--bad);flex:1">🔒 Requiere Cuartel nivel ${req}</div>` : ""}
          <input id="qty_${t.key}" type="number" min="1" max="100000" value="" placeholder="Cantidad" ${canTr ? "" : "disabled"}>
          <button class="btn sm" data-tr="${t.key}" ${canTr ? "" : "disabled"}>⚔️ Entrenar</button>
        </div>`;
      html += img
        ? `<div class="card hasPic${locked ? " locked" : ""}"><div class="picBody">${head}</div><div class="picSide"><img class="troopImg" src="${img}" alt="${m.n}"${m.img && img !== m.img ? ` onerror="this.onerror=null;this.src='${m.img}';"` : ""}></div></div>`
        : `<div class="card${locked ? " locked" : ""}">${head}</div>`;
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
      let html = '<table class="rank"><tr><th>#</th><th>Reino</th><th>Bando</th><th>Puntos</th><th>Nv.</th><th>Tropas</th><th>👑</th><th>🏘️</th></tr>';
      (list || []).forEach((r, i) => {
        const cls = r.me ? ' class="me"' : "";
        const fac = r.faction === "horda"
          ? '<span class="rankFac" style="background:var(--red)">Horda</span>'
          : '<span class="rankFac" style="background:var(--blue)">Alianza</span>';
        html += `<tr${cls}><td>${i + 1}</td><td>${esc(r.name)}${r.me ? " (tú)" : ""}</td><td>${fac}</td>
          <td><b>${un(r.points)}</b></td><td>${un(r.level_sum)}</td><td>${un(r.troops)}</td><td>${r.thrones ? "👑 " + un(r.thrones) : "—"}</td><td>${r.aldeas ? "🏘️ " + un(r.aldeas) : "—"}</td></tr>`;
      });
      html += "</table>";
      $("#tabRank").innerHTML = html || '<div class="empty">Aún no hay reinos en el ranking.</div>';
    }catch(e){ toast(shortMsg(e), true); }
  },

  /* ----- mapa ----- */
  async loadMap(){
    try{
      this.mapList = await sbRpc("wow_map", { p_token: this.me.token }) || [];
      try{ const p = await sbRpc("wow_protect_info", {}); this.protect = p && p.points; }catch(_){}
      try{ const ti = await sbRpc("wow_throne_info", { p_token: this.me.token }); this._thrones = (ti && ti.thrones) || []; }
      catch(_){ this._thrones = this._thrones || []; }
      try{ const ai = await sbRpc("wow_aldea_info", { p_token: this.me.token }); this._aldeas = (ai && ai.aldeas) || []; }
      catch(_){ this._aldeas = this._aldeas || []; }
      try{ this._events = await sbRpc("wow_events", { p_token: this.me.token }) || []; }
      catch(_){ this._events = this._events || []; }
      this.renderMap();
    }catch(e){ toast(shortMsg(e), true); }
  },
  renderMap(){
    const N = SLOT_POS.length, T = N * MAP_CONT.length;
    const list = this.mapList || [];
    const byKey = {};
    list.forEach(r => {
      const p = ((r.pos % T) + T) % T;
      const c = Math.floor(p / N), s = p % N, key = c*N + s;
      if(byKey[key] == null) byKey[key] = r;
    });
    let pins = "";
    for(let c = 0; c < MAP_CONT.length; c++){
      for(let s = 0; s < N; s++){
        const node = CONT_BASE[c] + s + 1;
        const pc = mapNodePct(node);
        const r = byKey[c*N + s];
        if(r){
          const fac = r.faction === "horda" ? "horda" : "alianza";
          const prot = this.protect;
          const shield = (prot != null && prot > 0 && !r.me && r.points < prot) ? "🔰 " : "";
          pins += `<div class="mPin ${fac}${r.me ? " me" : ""}" data-pos="${r.pos}" style="left:${pc[0].toFixed(2)}%;top:${pc[1].toFixed(2)}%">
              <div class="mPinCastle">🏰</div>
              <div class="mPinName">${shield}${esc(r.name)}</div>
              ${r.alliance ? `<div class="mPinTag">[${esc(r.alliance)}]</div>` : ""}
            </div>`;
        }else{
          pins += `<div class="mPin empty" style="left:${pc[0].toFixed(2)}%;top:${pc[1].toFixed(2)}%"><div class="mPinCastle">🏰</div></div>`;
        }
      }
    }
    const thrones = (this._thrones && this._thrones.length) ? this._thrones : [
      { node: 0,  name: "TRONO DE AZEROTH" },
      { node: 21, name: "TRONO DE KALIMDOR" },
      { node: 50, name: "TRONO DE NORTHREND" },
      { node: 75, name: "TRONO DE PANDARIA" }
    ];
    let throneHtml = "";
    thrones.forEach(t => {
      const pc = mapNodePct(t.node);
      const owned = !!t.holder;
      const crown = t.ally_icon || (t.holder_ally ? "🏛️" : owned ? "👑" : "🏯");
      const label = owned ? esc(t.ally || t.holder_name || "?") : "Libre";
      throneHtml += `<div class="mPin throne${owned ? " taken" : ""}" data-thr="${t.node}" style="left:${pc[0].toFixed(2)}%;top:${pc[1].toFixed(2)}%">
          <div class="mPinCastle">${crown}</div>
          <div class="mPinName">${esc(t.name)}</div>
          <div class="mPinTag">${label}</div>
        </div>`;
    });
    const aldeas = (this._aldeas && this._aldeas.length) ? this._aldeas : [
      { node: 42, name: "Aldea del Alba" }, { node: 43, name: "Aldea del Bosque" },
      { node: 44, name: "Aldea de la Colina" }, { node: 45, name: "Aldea del Río" },
      { node: 46, name: "Aldea de la Costa" }, { node: 47, name: "Aldea del Valle" },
      { node: 48, name: "Aldea del Desierto" }, { node: 49, name: "Aldea de la Niebla" },
      { node: 71, name: "Aldea del Amanecer" }, { node: 72, name: "Aldea del Roble" },
      { node: 73, name: "Aldea del Pico" }, { node: 74, name: "Aldea del Raudal" },
      { node: 96, name: "Aldea del Puerto" }, { node: 97, name: "Aldea de la Pradera" },
      { node: 98, name: "Aldea de la Arena" }, { node: 99, name: "Aldea de la Nieve" }
    ];
    let aldeaHtml = "";
    aldeas.forEach(a => {
      const pc = mapNodePct(a.node);
      const owned = !!a.holder;
      aldeaHtml += `<div class="mPin aldea${owned ? " taken" : ""}" data-ald="${a.node}" style="left:${pc[0].toFixed(2)}%;top:${pc[1].toFixed(2)}%">
          <div class="mPinCastle">${a.ally_icon || (a.holder_ally ? "🏛️" : owned ? "🏘️" : "🛖")}</div>
          <div class="mPinName">${esc(a.name)}</div>
          <div class="mPinTag">${owned ? esc(a.ally || a.holder_name || "?") : "Libre"}</div>
        </div>`;
    });
    const prevWrap = document.querySelector(".mapWrap");
    if(prevWrap) this._mapScroll = { l: prevWrap.scrollLeft, t: prevWrap.scrollTop };
    $("#tabMap").innerHTML = `
      <div class="mapBar">
        <button class="btn sm" id="mapCenterBtn">🎯 Mi castillo</button>
        <span class="mapHint">Arrastra para moverte por el mundo</span>
      </div>
      <div class="mapWrap"><div class="mapInner" id="m2root">
        <img class="mapImg" src="img/mapa.jpg?v=20261018p" alt="Mapa de Azeroth">
        ${throneHtml}
        ${aldeaHtml}
        ${pins}
        <div class="armyLayer" id="armyLayer"></div>
      </div></div>
      ${this.cronicaHtml()}`;
    const centerBtn = $("#mapCenterBtn"); if(centerBtn) centerBtn.onclick = () => this.mapCenterMe();
    $("#m2root").querySelectorAll(".mPin[data-pos]").forEach(b => {
      b.onclick = () => this.openProfile(parseInt(b.dataset.pos, 10));
    });
    $("#m2root").querySelectorAll(".mPin.throne").forEach(b => {
      b.onclick = () => this.openThrone(parseInt(b.dataset.thr, 10));
    });
    $("#m2root").querySelectorAll(".mPin.aldea").forEach(b => {
      b.onclick = () => this.openFort(parseInt(b.dataset.ald, 10), "aldea");
    });
    const wrap = document.querySelector(".mapWrap");
    if(wrap && this._mapScroll){
      wrap.scrollLeft = this._mapScroll.l; wrap.scrollTop = this._mapScroll.t;
      this._mapScroll = { l: wrap.scrollLeft, t: wrap.scrollTop };
    }else this.mapCenterMe();
    this.keepFx();
    this.loadMarches();
    this.startMarchLoop();
    this.startMarchPoll();
  },
  /* centra la vista en tu castillo (el mapa es mas ancho que la pantalla) */
  mapCenterMe(){
    const wrap = document.querySelector(".mapWrap"), inner = document.getElementById("m2root");
    if(!wrap || !inner) return;
    const me = (this.mapList || []).find(x => x.me);
    const pc = mapNodePct(me ? mapPosNode(me.pos) : 0);
    const l = Math.max(0, pc[0] / 100 * inner.offsetWidth - wrap.clientWidth / 2);
    const t = Math.max(0, pc[1] / 100 * inner.offsetHeight - wrap.clientHeight / 2);
    wrap.scrollLeft = l; wrap.scrollTop = t;
    this._mapScroll = { l: wrap.scrollLeft, t: wrap.scrollTop };
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
      const fn = m.from_node != null ? m.from_node : (m.from != null ? mapPosNode(m.from) : null);
      const tn = m.to_node != null ? m.to_node : (m.to != null ? mapPosNode(m.to) : null);
      if(fn == null || tn == null) return;
      const reach = mapNodePath(fn, tn).map(mapNodePct);
      const back = m.state === "returning";
      const icon = m.kind === "spy" ? "🕵️"
        : m.kind === "throne_rein" ? "🛡️"
        : m.kind === "throne_claim" ? "💰"
        : m.kind === "gift" ? "🛒"
        : back ? "🚩" : "⚔️";
      const el = document.createElement("div");
      el.className = "mArmy" + (m.mine ? " mine" : "") +
        (m.kind === "spy" ? " spy" : (m.kind === "gift" ? (" gift" + (back ? " back" : "")) : (back ? " back" : "")));
      el.textContent = m.kind === "gift" ? "" : icon;
      el.title = m.kind === "gift"
        ? "Carruaje de recursos: " + (m.attacker || "?") + " → " + (m.target || "?")
        : (m.attacker || "?") + " → " + (m.target || (m.kind === "spy" ? "espionaje" : "?"));
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
  showMarchFx(fromNode, toNode, icon, cls){
    const layer = document.getElementById("armyLayer");
    if(!layer || fromNode == null || toNode == null) return;
    const reach = mapNodePath(fromNode, toNode).map(mapNodePct);
    const travel = travelNodes(fromNode, toNode);
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
    const peace = !!r.alliance && ((this._diplo && this._diplo.pacts) || []).some(p => r.alliance === (p.i_am_a ? p.b_tag : p.a_tag));
    const prot = this.protect;
    const myPts = (this.st && this.st.points) || 0;
    const isNovice = (prot != null && prot > 0 && !r.me && r.points < prot);
    const tooWeak = (prot != null && prot > 0 && !r.me && !isNovice && (myPts - r.points) >= prot);
    const canAtk = !r.me && !sameAlly && !peace && !isNovice && !tooWeak;
    const blockMsg = isNovice
      ? '🔰 Reino protegido por ser novato (menos de ' + un(prot) + ' puntos): no puedes atacarlo.'
      : (tooWeak ? '⚖️ Hay demasiada diferencia de puntos (' + un(prot) + '): busca un rival más parejo.' : '');
    modal(`<h2 style="margin-top:0;color:var(--gold)">🏰 ${esc(r.name)}</h2>
      ${r.me ? '<p style="color:var(--green);margin:0 0 8px">Este es tu reino</p>' : ""}
      <div class="profRow"><span class="k">Bando</span><span class="v">${fac}</span></div>
      <div class="profRow"><span class="k">Puntos</span><span class="v">${un(r.points)}${isNovice ? " 🔰" : ""}</span></div>
      <div class="profRow"><span class="k">Alianza</span><span class="v">${r.alliance ? "[" + esc(r.alliance) + "]" : "Sin alianza"}</span></div>
      ${canAtk ? `<div style="text-align:center;margin-top:14px;display:flex;gap:8px;justify-content:center;flex-wrap:wrap">
        <button class="btn" id="profAtk">⚔️ Atacar</button>
        <button class="btn sm" id="profSpy" style="align-self:center">🔍 Espiar (150 💰)</button></div>` : ""}
      ${blockMsg && !r.me ? '<p style="text-align:center;color:var(--dim);font-size:12px;margin-top:10px">' + blockMsg + '</p>' : ""}
      ${sameAlly ? '<p style="text-align:center;color:var(--dim);font-size:12px;margin-top:10px">Es de tu alianza: no puedes atacarlo ni espiarlo.</p>' : ""}
      ${(sameAlly && !r.me) ? `<div style="text-align:center;margin-top:10px"><button class="btn" id="profGift">📦 Enviar recursos</button></div>` : ""}
      ${peace && !r.me ? '<p style="text-align:center;color:var(--green);font-size:12px;margin-top:10px">🤝 Hay paz con [' + esc(r.alliance) + ']: no puedes atacarlo ni espiarlo.</p>' : ""}`);
    const ab = document.getElementById("profAtk");
    if(ab) ab.onclick = () => this.openAttack(r);
    const sb = document.getElementById("profSpy");
    if(sb) sb.onclick = () => this.openSpy(r);
    const gb = document.getElementById("profGift");
    if(gb) gb.onclick = () => this.openGift(r);
  },
  openGift(r){
    const s = this.st || {};
    modal(`<h2 style="margin-top:0;color:var(--gold)">📦 Enviar recursos a ${esc(r.name)}</h2>
      <p class="hint">Envía oro, madera y mineral a tu aliado. Los recursos se descuentan al enviar y viajan en un carruaje que tarda lo mismo que una tropa.</p>
      <div class="admInputs">
        <label>💰 Oro <input id="giftGold" type="number" min="0" step="1" value="0"></label>
        <label>🪵 Madera <input id="giftWood" type="number" min="0" step="1" value="0"></label>
        <label>⛏️ Mineral <input id="giftOre" type="number" min="0" step="1" value="0"></label>
      </div>
      <p class="hint" style="margin-top:8px">Tienes: 💰 ${un(s.gold||0)} · 🪵 ${un(s.wood||0)} · ⛏️ ${un(s.ore||0)}</p>
      <div style="text-align:center;margin-top:14px"><button class="btn" id="giftGo">Enviar</button></div>
      <div id="giftMsg" class="notice" style="margin-top:8px"></div>`);
    $("#giftGo").onclick = async () => {
      const g = Math.floor(Number($("#giftGold").value) || 0);
      const w = Math.floor(Number($("#giftWood").value) || 0);
      const o = Math.floor(Number($("#giftOre").value) || 0);
      if(g < 0 || w < 0 || o < 0) return notice($("#giftMsg"), "Las cantidades no pueden ser negativas.", "danger");
      if(g + w + o <= 0) return notice($("#giftMsg"), "Elige cuánto quieres enviar.", "danger");
      if(g > (s.gold||0) || w > (s.wood||0) || o > (s.ore||0)) return notice($("#giftMsg"), "No tienes tantos recursos.", "danger");
      $("#giftGo").disabled = true;
      try{
        const res = await sbRpc("wow_ally_gift", { p_token: this.me.token, p_target: r.id, p_gold: g, p_wood: w, p_ore: o });
        modalClose();
        toast("📦 Carruaje enviado a " + r.name + ". Llegará en " + tfmt(res.travel) + ".");
        await this.refresh(); if(this.tab === "map") this.loadMap();
      }catch(e){ $("#giftGo").disabled = false; notice($("#giftMsg"), shortMsg(e), "danger"); }
    };
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
    const K = ["soldado","arquero","jinete","mago","paladin","dragon"];
    const em = k => (TRP[k] || {}).e || "⚔️";
    const nm = k => (TRP[k] || {}).n || k;
    const num = (o, k) => Number(o && o[k]) || 0;
    const nR = (b.rounds || []).length;
    const has = o => o && Object.keys(o).length;
    const merge = (x, y) => { const o = {}; K.forEach(k => { const v = num(x, k) + num(y, k); if (v) o[k] = v; }); return o; };
    const as = has(b.a_start) ? b.a_start : merge(b.a_left, b.a_loss);
    const ds = has(b.d_start) ? b.d_start : merge(b.d_left, b.d_loss);
    const al = b.a_left || {}, dl = b.d_left || {}, ax = b.a_loss || {}, dx = b.d_loss || {};
    const sum = o => K.reduce((s, k) => s + (Number(o[k]) || 0), 0);
    const totA = sum(as), totD = sum(ds);
    const win = b.winner === "attacker";
    const rout = b.rout ? (b.rout === "both" ? "rompieron filas ambos" : "huyó " + (b.rout === "attacker" ? "el atacante" : "el defensor"))
      : (nR >= 20 ? "se agotó el tiempo" : "sin desbandada");
    const cell = (q0, q1, qL) => `<b>${un(q0)}</b> → <span class="btlQ">${un(q1)}</span>` +
      (qL > 0 ? ` <span class="btlL">-${un(qL)}</span>` : "");
    const rows = K.filter(k => (num(as, k) + num(ds, k)) > 0).map(k =>
      `<tr><td class="btlT">${em(k)} ${nm(k)}</td>` +
      `<td>${cell(num(as, k), num(al, k), num(ax, k))}</td>` +
      `<td>${cell(num(ds, k), num(dl, k), num(dx, k))}</td></tr>`).join("");
    const rrows = (b.rounds || []).map(x =>
      `<div class="rnd"><span class="rndR">Ronda ${x.r}</span>` +
      `<span>⚔️ -${un(x.aLoss)} · 🛡️ -${un(x.dLoss)}</span>` +
      `<span>quedan ⚔️ ${un(x.aLeft)} / 🛡️ ${un(x.dLeft)}</span>` +
      `<span>moral ${x.aMor} / ${x.dMor}</span></div>`).join("");
    return `<div class="btl ${win ? "btlWin" : "btlLose"}">
      <div class="btlHead">${win ? "🏆 Victoria del atacante" : "🛡️ El defensor resiste"} · ${nR} ronda${nR === 1 ? "" : "s"} · ${rout}</div>
      <div class="btlVs">
        <div class="btlS atk"><span class="btlLbl">⚔️ Atacante</span><span class="btlN">${un(totA)}</span><span class="btlD2">tropas iniciales</span></div>
        <div class="btlVor">VS</div>
        <div class="btlS def"><span class="btlLbl">🛡️ Defensor</span><span class="btlN">${un(totD)}</span><span class="btlD2">tropas iniciales</span></div>
      </div>
      <table class="btlTbl">
        <tr><th>Tropa</th><th>⚔️ Atacante</th><th>🛡️ Defensor</th></tr>
        ${rows || '<tr><td colspan="3">Sin tropas</td></tr>'}
        <tr class="btlTot"><td class="btlT">Total</td><td><b>${un(totA)}</b> → ${un(sum(al))}</td><td><b>${un(totD)}</b> → ${un(sum(dl))}</td></tr>
      </table>
      <div class="btlFoot">Moral final · ⚔️ <b>${un(b.a_morale)}</b> / 🛡️ <b>${un(b.d_morale)}</b></div>
      ${rrows ? `<details class="btlD"><summary>Ver rondas (${nR})</summary>${rrows}</details>` : ""}
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
        const isRein = f.kind === "throne_rein";
        const isClaim = f.kind === "throne_claim";
        const outbound = f.state === "outbound";
        const emoji = isSpy ? "🔍" : isRein ? "🛡️" : isClaim ? "💰" : (outbound ? (inc ? "🛡️" : "⚔️") : "🏠");
        const lab = isSpy ? "espía en camino"
          : isRein ? (outbound ? "reforzando " + esc(f.who) : "volviendo a casa")
          : isClaim ? (outbound ? "a por el tesoro de " + esc(f.who) : "con el tesoro a casa")
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
        }else if(r.dir === "throne"){
          cls = r.win ? "win" : "lose";
          title = r.win
            ? `🏯 ¡Has conquistado <b>${esc(r.who)}</b>!` + (r.ally ? ` — en nombre de <b>${esc(r.ally)}</b>` : "")
            : `🏯 Ataque a <b>${esc(r.who)}</b> repelido`;
        }else if(r.dir === "throne_in"){
          cls = r.win ? "lose" : "win";
          title = r.win
            ? `🏯 Has perdido <b>${esc(r.who)}</b>` + (r.from ? ` — atacado por <b>${esc(r.from)}</b>` : "") + (r.ally ? ` — pasa a <b>${esc(r.ally)}</b>` : "")
            : `🏯 Has defendido <b>${esc(r.who)}</b>` + (r.from ? ` de <b>${esc(r.from)}</b>` : "");
        }else if(r.dir === "vault"){
          cls = "win";
          title = `🏛️ Llevaste el tesoro de <b>${esc(r.who)}</b> al arcón de tu alianza`;
        }else if(r.dir === "throne_rein"){
          cls = "win";
          title = `🛡️ Tus refuerzos llegaron a <b>${esc(r.who)}</b>`;
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
    const peace = ((this._diplo && this._diplo.pacts) || []).find(p => r.alliance && r.alliance === (p.i_am_a ? p.b_tag : p.a_tag));
    if(peace){
      modal(`<h2 style="margin-top:0;color:var(--gold)">🤝 Paz con [${esc(r.alliance)}]</h2>
        <p style="color:var(--dim)">Tenéis un pacto de no agresión: no se puede atacar ni espiar a esa alianza hasta que uno de los dos líderes lo cancele.</p>`);
      return;
    }
    const troops = ((this.st && this.st.troops) || []).filter(t => t.qty > 0);
    if(!troops.length){
      modal(`<h2 style="margin-top:0;color:var(--gold)">⚔️ Atacar a ${esc(r.name)}</h2>
        <p style="color:var(--dim)">No tienes tropas. Entrena en el Cuartel (pestaña ⚔️ Tropas) antes de atacar.</p>`);
      return;
    }
    const my = (this.mapList || []).find(x => x.me);
    const travel = (my && typeof r.pos === "number") ? travelSec(my.pos, r.pos) : null;
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
    await this.loadAllyRank("#allyRank");
  },
  async renderAllyMine(id){
    const info = await sbRpc("wow_alliance_info", { p_token: this.me.token, p_id: id });
    this._allyInfo = info;
    const isLeader = info.leader === this.me.name;
    let v = { vault: {}, members: [], is_leader: false, sum: 0 };
    try{ v = await sbRpc("wow_alliance_vault", { p_token: this.me.token }) || v; }catch(_){}
    this._vault = v;
    let html = `<div class="allyBox">
      <div class="allyHead"><span class="allyTagBig">${esc(info.emblem || "")}[${esc(info.tag)}]</span>${esc(info.name)}</div>
      <p class="allyDesc">${info.descr ? esc(info.descr) : "Sin descripción"}</p>
      <div class="secTitle" style="margin-top:0">🎨 Emblema del clan</div>
      <div id="embBox" class="embBox"></div>
      <div class="secTitle" style="margin-top:0">👥 Miembros (${info.members.length}/${ALLY_MAX})</div>
      ${isLeader && info.members.length > 1 ? '<p class="hint" style="margin:0 0 6px">Eres el líder: puedes expulsar a quien no cumpla.</p>' : ''}
      <div class="members">`;
    info.members.forEach(m => {
      html += `<div class="mem${m.me ? " me" : ""}">${m.faction === "horda" ? "⚔️" : "🛡️"} ${esc(m.name)}${m.leader ? " 👑" : ""}` +
        `<span class="memPts">${un(m.points)} pts</span>` +
        (isLeader && !m.leader && !m.me ? `<button class="btn sm danger" data-kick="${esc(m.id)}" title="Expulsar de la alianza">🚫</button>` : "") +
        `</div>`;
    });
    html += `</div>
      <div class="secTitle">🏛️ Arcón de la alianza</div>
      ${this.vaultHtml(v)}
      <div class="secTitle">🤝 Diplomacia</div>
      <div id="diploBox" class="warsBox"></div>
      <div class="secTitle">💬 Chat de la alianza</div>
      <div id="chatMsgs" class="chatBox"></div>
      <div class="chatRow"><input id="chatIn" placeholder="Escribe a tu alianza…" maxlength="300"><button class="btn sm" id="chatSend">Enviar</button></div>
      <div style="margin-top:14px"><button class="btn sm danger" id="allyLeave">🚪 Salir de la alianza</button></div>
      <div class="secTitle">🏆 Ranking de alianzas</div>
      <div id="allyRank" class="allyRank"></div>
    </div>`;
    $("#tabAlly").innerHTML = html;
    this.renderEmblem(info);
    $("#tabAlly").querySelectorAll("[data-kick]").forEach(b => { b.onclick = () => this.kickMember(b.dataset.kick); });
    $("#tabAlly").querySelectorAll("[data-vsh]").forEach(inp => { inp.onchange = () => this.setShare(inp.dataset.vsh, inp.value); });
    const vg = document.getElementById("vaultGo"); if(vg) vg.onclick = () => this.distributeVault();
    const vp = document.getElementById("vpayGo"); if(vp) vp.onclick = () => this.payVault();
    $("#chatSend").onclick = () => this.sendChat();
    $("#chatIn").onkeydown = e => { if(e.key === "Enter") this.sendChat(); };
    $("#allyLeave").onclick = () => this.leaveAlly(info.name);
    await this.loadDiplo();
    await this.loadChat();
    await this.loadAllyRank("#allyRank");
    this.startChatPoll();
  },
  renderEmblem(info){
    const box = document.getElementById("embBox"); if(!box) return;
    const cur = info.emblem || "";
    const list = info.emblems || [];
    const leader = !!info.is_leader;
    let h = '<p class="hint" style="margin:0 0 6px">' + (leader
      ? 'Elige el icono que verán todos sobre las aldeas y fortalezas conquistadas por tu alianza.'
      : 'Es el icono que sale sobre las aldeas y fortalezas conquistadas por tu alianza (lo elige ' + esc(info.leader || "el líder") + ').') + '</p>';
    h += '<div class="embGrid">' + list.map(ic =>
      '<button class="embBtn' + (ic === cur ? ' on' : '') + '"' + (leader ? '' : ' disabled') + ' data-emb="' + esc(ic) + '">' + ic + '</button>').join("") + '</div>';
    h += '<div style="margin-top:6px;display:flex;align-items:center;gap:8px;flex-wrap:wrap">' +
      '<span class="muted">' + (cur ? 'Ahora: <b>' + cur + '</b>' : 'Ahora: 🏛️ (por defecto)') + '</span>' +
      (leader ? '<button class="btn sm' + (cur ? ' danger' : '') + '" id="embClear"' + (cur ? '' : ' disabled') + '>🧹 Quitar</button>' : '') + '</div>';
    box.innerHTML = h;
    box.querySelectorAll("[data-emb]").forEach(b => { b.onclick = () => this.setEmblem(b.dataset.emb); });
    const cl = document.getElementById("embClear");
    if(cl) cl.onclick = () => this.setEmblem("");
  },
  async setEmblem(ic){
    try{
      const r = await sbRpc("wow_alliance_emblem", { p_token: this.me.token, p_icon: ic });
      if(this._allyInfo) this._allyInfo.emblem = r.emblem;
      toast(r.emblem ? "🎨 Emblema del clan: " + r.emblem : "🧹 Emblema quitado.");
      this.renderEmblem(this._allyInfo || {});
      if(this.tab === "map") this.loadMap();
    }catch(e){ toast(shortMsg(e), true); }
  },
  vaultHtml(v){
    const vl = (v && v.vault) || {};
    const keys = Object.keys(vl).filter(k => Number(vl[k]) > 0);
    const mem = ((v && v.members) || []);
    let h = "";
    if(!keys.length){
      h += '<div class="empty" style="padding:10px">Vacío. Los tesoros de los tronos y aldeas de la alianza entran aquí cuando algún miembro los reclama.</div>';
    }else{
      h += '<div style="background:rgba(0,0,0,.18);border:1px solid var(--line);border-radius:8px;padding:8px 10px">' +
        keys.map(k => `<div style="display:flex;justify-content:space-between;padding:2px 0"><span>${esc(mktName(k))}</span><b>${un(vl[k])}</b></div>`).join("") + '</div>';
    }
    if(v && v.is_leader){
      h += '<p class="hint" style="margin:8px 0 4px">Como líder decides qué % del arcón recibe cada miembro. Al repartir, cada uno cobra su parte y lo que sobre se queda en la alianza.</p>';
      h += '<div style="display:flex;flex-direction:column;gap:4px">' + mem.map(m =>
        `<div style="display:flex;align-items:center;gap:8px"><span style="flex:1">${m.leader ? "👑 " : ""}${esc(m.name)}</span>` +
        `<input type="number" min="0" max="100" step="5" value="${Number(m.pct) || 0}" data-vsh="${esc(m.id)}" style="width:70px"> %</div>`).join("") + '</div>';
      h += `<div class="muted" style="margin-top:6px">Suman <b>${un(v.sum || 0)}%</b> (no pueden pasar de 100%).</div>`;
      h += '<div style="margin-top:8px"><button class="btn sm" id="vaultGo">💰 Repartir ahora</button></div>';
      h += `<div style="margin-top:10px;display:flex;gap:6px;flex-wrap:wrap;align-items:center">
        <span class="muted">Pagar a</span>
        <select id="vpayWho">${mem.map(m => `<option value="${esc(m.id)}">${esc(m.name)}</option>`).join("")}</select>
        <select id="vpayKey">${(keys.length ? keys : ["gold"]).map(k => `<option value="${esc(k)}">${esc(mktName(k))}</option>`).join("")}</select>
        <input id="vpayQty" type="number" min="0" step="1" placeholder="Cantidad" style="width:100px">
        <button class="btn sm" id="vpayGo">Pagar</button></div>`;
    }else{
      const mine = mem.filter(m => Number(m.pct) > 0);
      if(mine.length) h += '<div class="muted" style="margin-top:6px">Reparto que decide el líder: ' + mine.map(m => `${esc(m.name)} <b>${un(m.pct)}%</b>`).join(" · ") + '.</div>';
    }
    return h;
  },
  async setShare(id, pct){
    try{
      await sbRpc("wow_alliance_setshare", { p_token: this.me.token, p_id: id, p_pct: Math.max(0, Math.min(100, Number(pct) || 0)) });
      await this.renderAllyMine(this._allyInfo.id);
    }catch(e){ toast(shortMsg(e), true); }
  },
  async distributeVault(){
    if(!confirm("¿Repartir el arcón de la alianza según los porcentajes?")) return;
    try{
      const r = await sbRpc("wow_alliance_distribute", { p_token: this.me.token });
      toast("Arcón repartido entre " + un(r.members_paid || 0) + " miembro(s).");
      await this.renderAllyMine(this._allyInfo.id);
    }catch(e){ toast(shortMsg(e), true); }
  },
  async payVault(){
    const who = (document.getElementById("vpayWho") || {}).value;
    const key = (document.getElementById("vpayKey") || {}).value;
    const qty = Number((document.getElementById("vpayQty") || {}).value || 0);
    if(!who || !key || qty <= 0) return toast("Elige miembro, recurso y cantidad.", true);
    try{
      const r = await sbRpc("wow_alliance_pay", { p_token: this.me.token, p_id: who, p_key: key, p_qty: qty });
      toast("Pagado: " + un(r.qty) + " de " + mktName(r.key) + ".");
      await this.renderAllyMine(this._allyInfo.id);
    }catch(e){ toast(shortMsg(e), true); }
  },
  async loadAllyRank(sel){
    try{
      const list = await sbRpc("wow_alliance_rank", { p_token: this.me.token }) || [];
      const box = document.querySelector(sel); if(!box) return;
      if(!list.length){ box.innerHTML = '<div class="empty" style="padding:12px">Sin alianzas todavía.</div>'; return; }
      box.innerHTML = list.map((a, i) => `<div class="rankRow${a.mine ? " mine" : ""}">
        <span class="rankPos">${i + 1}</span>
        <span class="rankTag">${esc(a.emblem || "")}[${esc(a.tag)}]</span>
        <span class="rankName">${esc(a.name)}</span>
        <span class="rankStat">👥 ${a.members}</span>
        <span class="rankStat">⭐ ${un(a.points)}</span>
        <span class="rankStat">⚔️ ${un(a.troops)}</span>
        <span class="rankStat">🏯 ${a.thrones}</span>
        <span class="rankStat">🏆 ${a.wins}</span>
      </div>`).join("");
    }catch(e){ toast(shortMsg(e), true); }
  },
  async loadDiplo(silent){
    try{
      this._diplo = await sbRpc("wow_ally_diplo", { p_token: this.me.token }) || {};
      this._diploTs = Date.now();
    }catch(e){ if(!silent) toast(shortMsg(e), true); return; }
    const box = document.getElementById("diploBox");
    if(box) await this.renderDiplo(box);
  },
  async renderDiplo(box){
    let wars = [];
    try{ const w = await sbRpc("wow_ally_wars", { p_token: this.me.token }); wars = (w && w.wars) || []; }catch(_){}
    const d = this._diplo || {};
    const pacts = d.pacts || [], oin = d.offers_in || [], oout = d.offers_out || [];
    const isLeader = !!d.is_leader;
    const now = Date.now();
    const dur = h => !h ? "sin caducidad" : (h + " h");
    const rtag = p => (p.i_am_a ? p.b_tag : p.a_tag);
    const rname = p => (p.i_am_a ? p.b_name : p.a_name);
    const ricon = p => (p.i_am_a ? (p.b_icon || "") : (p.a_icon || ""));
    let html = '<div class="secSub">⚔️ Guerras activas</div>';
    if(!wars.length) html += '<div class="empty" style="padding:10px">No hay guerras activas. Reina la paz en Azeroth.</div>';
    wars.forEach(w => {
      const hrs = Math.max(0, Math.ceil((w.ends - now) / 3600000));
      html += `<div class="warCard${w.mine ? " mine" : ""}">
        <div class="warSide">${esc(w.a_icon || "")}[${esc(w.a_tag)}] ${esc(w.a_name)}</div>
        <div class="warScore">${w.a_score} : ${w.b_score}</div>
        <div class="warSide r">${esc(w.b_name)} ${esc(w.b_icon || "")}[${esc(w.b_tag)}]</div>
        <div class="warFoot">⏳ ${hrs} h${w.mine && isLeader ? ' · <button class="btn sm danger" data-surrender="' + w.id + '">Rendirse</button>' : ""}</div>
      </div>`;
    });
    html += '<div class="secSub">🤝 Pactos de no agresión</div>';
    if(!pacts.length) html += '<div class="empty" style="padding:10px">Sin pactos. Con un pacto vigente no se puede atacar ni espiar a esa alianza.</div>';
    pacts.forEach(p => {
      const left = p.ends > 0 ? (Math.max(0, Math.ceil((p.ends - now) / 3600000)) + " h restantes") : "sin caducidad";
      html += `<div class="pactCard"><div class="pactWho">${esc(ricon(p))}[${esc(rtag(p))}] ${esc(rname(p))}</div>
        <div class="pactMeta">⏳ ${left} · duración ${dur(p.hours)}</div>
        ${isLeader ? '<button class="btn sm danger" data-pactcancel="' + p.id + '">Cancelar pacto</button>' : ""}</div>`;
    });
    if(oin.length || oout.length) html += '<div class="secSub">📨 Ofertas de pacto</div>';
    oin.forEach(p => {
      html += `<div class="pactCard"><div class="pactWho">${esc(ricon(p))}[${esc(rtag(p))}] ${esc(rname(p))} propone ${dur(p.hours)}</div>
        <div class="pactMeta">Caduca en ${Math.max(1, Math.ceil((p.offer_ends - now) / 3600000))} h</div>
        ${isLeader ? '<button class="btn sm" data-pactok="' + p.id + '">✅ Aceptar</button><button class="btn sm danger" data-pactno="' + p.id + '">❌ Rechazar</button>' : '<span class="pactMeta">Solo tu líder puede responder.</span>'}</div>`;
    });
    oout.forEach(p => {
      html += `<div class="pactCard"><div class="pactWho">Propuesta enviada a ${esc(ricon(p))}[${esc(rtag(p))}] ${esc(rname(p))}</div>
        <div class="pactMeta">${dur(p.hours)} · esperando respuesta del líder rival</div>
        ${isLeader ? '<button class="btn sm danger" data-pactcancel="' + p.id + '">Retirar oferta</button>' : ""}</div>`;
    });
    if(isLeader){
      try{ this._allyList = await sbRpc("wow_alliance_list", { p_token: this.me.token }) || []; }catch(_){ this._allyList = this._allyList || []; }
      const busy = pacts.map(rtag).concat(oin.map(rtag), oout.map(rtag));
      const atWar = wars.filter(w => w.mine).map(w => w.i_am_a ? w.b_tag : w.a_tag);
      const list = (this._allyList || []).filter(a => !a.mine);
      if(list.length){
        html += `<div class="warDecl"><span class="pactMeta" style="align-self:center">Pactar</span><select id="pactTarget">` +
          list.map(a => `<option value="${esc(a.id)}">${esc(a.emblem || "")}[${esc(a.tag)}] ${esc(a.name)}${busy.indexOf(a.tag) >= 0 ? " (en curso)" : ""}</option>`).join("") +
          `</select><select id="pactHours"><option value="24">24 h</option><option value="48">48 h</option><option value="72">72 h</option><option value="0">sin caducidad</option></select>` +
          `<button class="btn sm" id="pactGo">🤝 Proponer</button></div>`;
        const warTargets = list.filter(a => atWar.indexOf(a.tag) < 0);
        if(warTargets.length){
          html += `<div class="warDecl"><span class="pactMeta" style="align-self:center">Guerra</span><select id="warTarget">` +
            warTargets.map(a => `<option value="${esc(a.id)}">${esc(a.emblem || "")}[${esc(a.tag)}] ${esc(a.name)}</option>`).join("") +
            `</select><button class="btn sm danger" id="warGo">⚔️ Declarar guerra</button></div>`;
        }
      }
    }
    box.innerHTML = html;
    box.querySelectorAll("[data-surrender]").forEach(b => { b.onclick = () => this.surrenderWar(b.dataset.surrender); });
    box.querySelectorAll("[data-pactok]").forEach(b => { b.onclick = () => this.answerPact(b.dataset.pactok, true); });
    box.querySelectorAll("[data-pactno]").forEach(b => { b.onclick = () => this.answerPact(b.dataset.pactno, false); });
    box.querySelectorAll("[data-pactcancel]").forEach(b => { b.onclick = () => this.cancelPact(b.dataset.pactcancel); });
    const pg = document.getElementById("pactGo"); if(pg) pg.onclick = () => this.offerPact();
    const wg = document.getElementById("warGo"); if(wg) wg.onclick = () => this.declareWar();
  },
  async surrenderWar(id){
    if(!confirm("¿Rendirte? La guerra termina y cuenta como derrota para tu alianza.")) return;
    try{
      await sbRpc("wow_ally_war_surrender", { p_token: this.me.token, p_id: Number(id) });
      toast("🏳️ Te has rendido.");
      await this.loadDiplo();
      if(this._allyInfo) await this.loadAllyRank("#allyRank");
    }catch(e){ toast(shortMsg(e), true); }
  },
  async offerPact(){
    const t = document.getElementById("pactTarget"), h = document.getElementById("pactHours");
    if(!t || !t.value) return;
    try{
      await sbRpc("wow_ally_pact_offer", { p_token: this.me.token, p_target: t.value, p_hours: Number(h ? h.value : 24) });
      toast("📨 Propuesta de pacto enviada.");
      await this.loadDiplo();
    }catch(e){ toast(shortMsg(e), true); }
  },
  async answerPact(id, ok){
    try{
      await sbRpc("wow_ally_pact_answer", { p_token: this.me.token, p_id: Number(id), p_accept: !!ok });
      toast(ok ? "🤝 Pacto firmado." : "Oferta rechazada.");
      await this.loadDiplo();
    }catch(e){ toast(shortMsg(e), true); }
  },
  async cancelPact(id){
    if(!confirm("¿Cancelar? El pacto deja de proteger de inmediato y ya podréis atacaros.")) return;
    try{
      await sbRpc("wow_ally_pact_cancel", { p_token: this.me.token, p_id: Number(id) });
      toast("Pacto cancelado.");
      await this.loadDiplo();
    }catch(e){ toast(shortMsg(e), true); }
  },
  async declareWar(){
    const sel = document.getElementById("warTarget"); const tid = sel ? sel.value : "";
    if(!tid) return;
    const tagSel = sel && sel.options[sel.selectedIndex] ? sel.options[sel.selectedIndex].text : "";
    const pact = ((this._diplo && this._diplo.pacts) || []).some(p => tagSel.indexOf("[" + (p.i_am_a ? p.b_tag : p.a_tag) + "]") === 0);
    if(!confirm(pact
      ? "¿Declarar la guerra? Romperás el pacto de no agresión: las treguas cuentan como canceladas y la guerra durará 48 horas."
      : "¿Declarar la guerra? Durará 48 horas y cada victoria en combate sumará puntos a tu alianza.")) return;
    try{ await sbRpc("wow_ally_war_declare", { p_token: this.me.token, p_target: tid }); toast("⚔️ ¡Guerra declarada!"); await this.loadDiplo(); }
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
            esc((m.tag ? (m.emblem || "") + "[" + m.tag + "] " : "")) + esc(m.name) + ':</span> ' + esc(m.msg) +
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
  async kickMember(id){
    const m = ((this._allyInfo && this._allyInfo.members) || []).find(x => x.id === id);
    if(!confirm("¿Expulsar a " + (m ? m.name : "este reino") + " de la alianza?")) return;
    try{
      const r = await sbRpc("wow_alliance_kick", { p_token: this.me.token, p_id: id });
      toast((r.name || "El reino") + " ya no está en la alianza.");
      await this.renderAllyMine(this._allyInfo.id);
    }catch(e){ toast(shortMsg(e), true); }
  },

  /* ---------------- gestión (admin) ---------------- */
  setAdminTab(on){
    const btn = $("#tabBtnAdmin"); if(!btn) return;
    btn.classList.toggle("hidden", !on);
    if(!on && this.tab === "admin"){
      const t = document.querySelector('.gameTabs [data-tab="bld"]'); if(t) t.click();
    }
  },
  async loadAdmin(quiet){
    const el = $("#tabAdmin"); if(!el) return;
    if(!quiet) el.innerHTML = '<p class="empty">Cargando reinos…</p>';
    try{
      this.adm = await sbRpc("wow_admin_list", { p_token: this.me.token });
      try{ const f = await sbRpc("wow_market_fee", {}); this.mktFee = f && f.fee; }catch(_){ this.mktFee = this.mktFee; }
      try{ const g = await sbRpc("wow_throne_info", { p_token: this.me.token }); this.throneShare = g && g.share; this.throneRates = (g && g.rates) || this.throneRates; }catch(_){ this.throneShare = this.throneShare; }
      try{ const a = await sbRpc("wow_aldea_info", { p_token: this.me.token }); this.aldeaShare = a && a.share; this.aldeaRates = (a && a.rates) || this.aldeaRates; }catch(_){ this.aldeaShare = this.aldeaShare; }
      try{ const pr = await sbRpc("wow_protect_info", {}); this.protect = pr && pr.points; }catch(_){ this.protect = this.protect; }
      try{ const o = await sbRpc("wow_online_info", {}); this.onlineMin = o && o.min; }catch(_){ this.onlineMin = this.onlineMin; }
      try{ const pp = await sbRpc("wow_prod_info", {}); this.prodMult = pp && pp.mult; }catch(_){ this.prodMult = this.prodMult; }
      this.prodMult = (this.adm && this.adm.prod_mult != null) ? this.adm.prod_mult : this.prodMult;
      this.madam = (this.adm && this.adm.madam) || this.madam;
      try{ const bl = await sbRpc("wow_admin_bot_list", { p_token: this.me.token }); this.bots = (bl && bl.bots) || []; this.botAuto = !!(bl && bl.auto); this.botNow = bl && bl.now; this.botProtect = bl && bl.protect; }catch(_){ this.bots = this.bots || []; }
    }
    catch(e){ this.adm = null; if(!quiet) el.innerHTML = '<p class="empty">' + esc(shortMsg(e)) + '</p>'; return; }
    this.renderAdmin();
  },
  renderAdmin(){
    const el = $("#tabAdmin"), d = this.adm; if(!el) return;
    const prot = (this.protect != null) ? this.protect : 1000;
    if(!d){ el.innerHTML = '<p class="empty">Sin datos.</p>'; return; }
    const users = d.users || [];
    const autos = this.bots || [];
    const om = Number(this.onlineMin != null ? this.onlineMin : 5) * 60000;
    const nowMs = Number(d.now) || Date.now();
    const onl = u => (nowMs - Number(u.last || 0)) < om;
    const allRows = users.map(u => ({ u: u, on: onl(u) }));
    const cntOn = allRows.filter(x => x.on).length;
    const flt = this.admFlt || "all";
    const q = (this.admQ || "").trim().toLowerCase();
    const view = allRows.filter(x => flt === "all" ? true : (flt === "on" ? x.on : !x.on))
      .filter(x => !q || (x.u.name || "").toLowerCase().indexOf(q) >= 0);
    const rows = view.map(x => {
      const u = x.u;
      const self = u.id === d.me;
      const isAuto = autos.some(b => b.id === u.id);
      return '<div class="admRow' + (u.active ? "" : " banned") + '">' +
        '<div class="admHead"><span class="' + (x.on ? "dotOn" : "dotOff") + '" title="' + (x.on ? "en línea" : "ausente") + '"></span><b>' + esc(u.name) + '</b> <span class="admId">(' + esc(u.id) + ')</span>' +
          (u.is_admin ? '<span class="admTag">ADMIN</span>' : '') +
          (u.active ? '' : '<span class="admTag ban">BANEADO</span>') +
          (isAuto ? '<span class="admTag" title="reino que juega solo">🤖 auto</span>' : '') +
          '<span class="admFac">' + (u.faction === "horda" ? "⚔️ Horda" : "🛡️ Alianza") + '</span></div>' +
        '<div class="admStats"><span class="' + (x.on ? "admOn" : "admOff") + '">' + (x.on ? "🟢 En línea" : "⚫ No en línea") + '</span> · 🏆 ' + un(u.points) + ' · ⚔️ ' + un(u.troops) + ' tropas · 🪙 ' + un(u.gold) + ' · 🪵 ' + un(u.wood) + ' · ⛏️ ' + un(u.ore) + ' · 🧿 ' + un(u.cup||0) +
           (u.alliance ? ' · [' + esc(u.alliance) + ']' : '') + (u.points < prot ? ' · 🔰 protegido' : '') +
           (Number(u.prod_mult) !== 1 ? ' · <span class="admTag ban" title="producción alterada">⚙️ producción ×' + dec(u.prod_mult) + '</span>' : '') + '</div>' +
         '<div class="admActs">' +
           '<button class="btn sm" data-a="res" data-id="' + esc(u.id) + '">💰 Recursos</button>' +
           '<button class="btn sm" data-a="bld" data-id="' + esc(u.id) + '">🏗️ Edificios</button>' +
           '<button class="btn sm" data-a="trp" data-id="' + esc(u.id) + '">⚔️ Tropas</button>' +
           '<button class="btn sm" data-a="prod" data-id="' + esc(u.id) + '">⚙️ Producción</button>' +
          '<button class="btn sm" data-a="pw" data-id="' + esc(u.id) + '">🔑 Clave</button>' +
          (self ? '' :
            '<button class="btn sm" data-a="adm" data-id="' + esc(u.id) + '">' + (u.is_admin ? "✋ Quitar admin" : "🛡️ Dar admin") + '</button>' +
            '<button class="btn sm" data-a="ban" data-id="' + esc(u.id) + '" data-on="' + (u.active ? 1 : 0) + '">' + (u.active ? "🚫 Banear" : "✅ Reactivar") + '</button>' +
            '<button class="btn sm danger" data-a="del" data-id="' + esc(u.id) + '">🗑️ Borrar</button>') +
        '</div></div>';
    }).join("");
    el.innerHTML = '<h2 style="margin-top:0;color:var(--gold)">🛡️ Gestión</h2>' +
      '<div style="display:flex;align-items:center;gap:8px;margin-bottom:12px;flex-wrap:wrap"><span class="hint" style="flex:1">' + users.length +
      ' reinos · 🟢 ' + un(cntOn) + ' en línea · ⚫ ' + un(users.length - cntOn) + ' ausentes (≤ ' + un(this.onlineMin != null ? this.onlineMin : 5) + ' min) · comisión mercado ' + un(this.mktFee != null ? this.mktFee : 20) + '% · tributo tronos ' + un(this.throneShare != null ? this.throneShare : 1) + '% · tronos +' + un((this.throneRates||{}).gold!=null?this.throneRates.gold:100) + '/' + un((this.throneRates||{}).wood!=null?this.throneRates.wood:100) + '/' + un((this.throneRates||{}).ore!=null?this.throneRates.ore:100) + ' /h · tributo aldeas ' + un(this.aldeaShare != null ? this.aldeaShare : 1) + '% · aldeas +' + un((this.aldeaRates||{}).gold!=null?this.aldeaRates.gold:100) + '/' + un((this.aldeaRates||{}).wood!=null?this.aldeaRates.wood:100) + '/' + un((this.aldeaRates||{}).ore!=null?this.aldeaRates.ore:100) +        ' /h · 🔰 protección ' + un(prot) + ' pts · 💃 Madam ' + un((this.madam && this.madam.cost) != null ? this.madam.cost : 50) + ' CUP / ' + un((this.madam && this.madam.days) != null ? this.madam.days : 30) + 'd (recaudado ' + un((this.madam && this.madam.earned) || 0) + ' CUP) · ' + hora(d.now) + '</span>' +
      '<button class="btn sm" id="admFee">⚙️ Comisión</button>' +
       '<button class="btn sm" id="admProd">⚙️ Producción ×' + dec(this.prodMult != null ? this.prodMult : 1) + '</button>' +
       '<button class="btn sm" id="admTavern">🍺 Taberna</button>' +
      '<button class="btn sm" id="admBots">🤖 Reinos automáticos' + (autos.length ? ' (' + autos.length + ')' : '') + '</button>' +
      '<button class="btn sm" id="admClock">🕒 Relojes raros</button>' +
      '<button class="btn sm" id="admRefresh">↻ Actualizar</button></div>' +
      '<div style="display:flex;align-items:center;gap:8px;margin-bottom:10px;flex-wrap:wrap">' +
        '<input id="admFind" type="text" placeholder="Buscar reino…" value="' + esc(this.admQ || "") + '" style="flex:1;min-width:140px">' +
        '<button class="btn sm' + (flt === "all" ? " on" : "") + '" data-flt="all">Todos (' + users.length + ')</button>' +
        '<button class="btn sm' + (flt === "on" ? " on" : "") + '" data-flt="on">🟢 En línea (' + cntOn + ')</button>' +
        '<button class="btn sm' + (flt === "off" ? " on" : "") + '" data-flt="off">⚫ Ausentes (' + (users.length - cntOn) + ')</button>' +
      '</div>' +
      '<div class="admList">' + (rows || '<p class="empty">Ningún reino coincide.</p>') + '</div>';
    const rb = $("#admRefresh"); if(rb) rb.onclick = () => this.loadAdmin();
    const fb = $("#admFee"); if(fb) fb.onclick = () => this.admFee();
    const pb = $("#admProd"); if(pb) pb.onclick = () => this.admProd();
    const tb = $("#admTavern"); if(tb) tb.onclick = () => this.admTavern();
    const ab = $("#admBots"); if(ab) ab.onclick = () => this.admBotsPanel();
    const cb = $("#admClock"); if(cb) cb.onclick = () => this.admClock();
    const fi = $("#admFind"); if(fi){
      fi.oninput = () => { this.admQ = fi.value; const p = fi.value.length; this.renderAdmin(); const n2 = $("#admFind"); if(n2){ n2.focus(); try{ n2.setSelectionRange(p, p); }catch(_){} } };
    }
    el.querySelectorAll("button[data-flt]").forEach(b => b.onclick = () => { this.admFlt = b.dataset.flt; this.renderAdmin(); });
    el.querySelectorAll("button[data-a]").forEach(b => b.onclick = () => this.admAction(b.dataset.a, b.dataset.id, b.dataset.on));
  },
  async botToggle(on, btn){
    if(btn) btn.disabled = true;
    try{
      logBook("Interruptor pulsado: " + (on ? "encender" : "apagar"));
      const r = await sbRpc("wow_admin_bot_auto", { p_token: this.me.token, p_on: !!on });
      logBook("Respuesta del servidor:", r);
      toast(on ? "🌞 " + un((r && r.bots) || 0) + " reinos automáticos jugando y en línea." : "🌙 Reinos automáticos apagados: ya no juegan ni atacan.");
      await this.admBotsPanel();
      logBook("Panel actualizado: ahora " + (this.botAuto ? "encendidos" : "apagados"));
    }
    catch(e){ if(btn) btn.disabled = false; logBook("FALLO al cambiar:", (e && e.message) || e); toast(shortMsg(e), true); }
  },
  async admClock(){
    modal('<h2 style="margin-top:0;color:var(--gold)">🕒 Relojes raros</h2>' +
      '<p class="hint">Reinos cuyo reloj de creación o última conexión no cuadra (en el futuro, o muy antiguo). El juego no usa la hora de tu ordenador: solo sirve para revisar quién lo intentó.</p>' +
      '<div id="admClockBox"><p class="empty">Comprobando…</p></div>' +
      '<div style="text-align:center;margin-top:14px"><button class="btn" id="admClockClose">Cerrar</button></div>');
    $("#admClockClose").onclick = () => modalClose();
    const box = $("#admClockBox");
    try{
      const r = await sbRpc("wow_admin_timeaudit", { p_token: this.me.token });
      const rows = (r && r.rows) || [];
      if(!rows.length){ box.innerHTML = '<p class="empty">Todo correcto: ningún reino con la hora rara.</p>'; return; }
      box.innerHTML = '<p class="hint">Tope de producción por refresco: <b>' + un(r.top) + ' h</b>.</p>' +
        '<div class="admList">' + rows.map(x => {
          const fut = Number(x.created_off_min) > 5 || Number(x.last_off_min) > 5;
          return '<div class="admRow"><div class="admHead"><b>' + esc(x.name) + '</b> <span class="admId">(' + esc(x.id) + ')</span>' +
            (fut ? '<span class="admTag ban">FUTURO</span>' : '<span class="admTag">REVISAR</span>') + '</div>' +
            '<div class="admStats">creado hace ' + un(x.created_off_min) + ' min · última conexión hace ' + un(x.last_off_min) + ' min</div></div>';
        }).join('') + '</div>';
    }catch(e){ box.innerHTML = '<p class="empty">' + esc(shortMsg(e)) + '</p>'; }
  },
  admFee(){
    const f = (this.mktFee != null) ? this.mktFee : 20;
    const s = (this.throneShare != null) ? this.throneShare : 1;
    const rt = this.throneRates || { gold: 100, wood: 100, ore: 100 };
    const al0 = (this.aldeaShare != null) ? Number(this.aldeaShare) : 1;
    const al = al0 > 20 ? 20 : al0;
    const alt = this.aldeaRates || { gold: 100, wood: 100, ore: 100 };
    modal('<h2 style="margin-top:0;color:var(--gold)">⚙️ Ajustes de economía</h2>' +
      '<p class="hint">La <b>comisión</b> se descuenta de lo que recibe el vendedor y se destruye. El <b>tributo</b> es el % del valor del trato que va al tesoro de cada trono con dueño (se descuenta de la comisión).</p>' +
      '<div class="admInputs"><label>Comisión mercado (%)<input id="admFeeIn" type="number" min="0" max="90" value="' + f + '"></label>' +
      '<label>Tributo tronos (%)<input id="admThrIn" type="number" min="0" max="90" value="' + s + '"></label></div>' +
      '<p class="hint" style="margin-top:12px">Producción de recursos de cada trono con dueño (por hora, se acumula en el tesoro).</p>' +
      '<div class="admInputs"><label>Oro /h<input id="admThrG" type="number" min="0" max="100000" value="' + un(rt.gold) + '"></label>' +
      '<label>Madera /h<input id="admThrW" type="number" min="0" max="100000" value="' + un(rt.wood) + '"></label>' +
      '<label>Mineral /h<input id="admThrO" type="number" min="0" max="100000" value="' + un(rt.ore) + '"></label></div>' +
      '<p class="hint" style="margin-top:12px">Las <b>aldeas</b> son poblados neutrales conquistables que se pintan en el mapa. Su tributo y producción son independientes de los tronos.</p>' +
      '<div class="admInputs"><label>Tributo aldeas (%)<input id="admAldIn" type="number" min="0.01" max="20" step="0.01" value="' + al + '"></label></div>' +
      '<p class="hint" style="margin-top:4px">Admite decimales: mínimo <b>0,01 %</b>, máximo <b>20 %</b>. Se cobra <b>min(tributo, comisión)</b>: con la comisión actual (<b>' + dec(f) + ' %</b>) el tributo efectivo es como mucho <b>' + dec(Math.min(Number(al), Number(f))) + ' %</b>.' + (al0 > 20 ? ' <b style="color:var(--bad)">Había guardado ' + dec(al0) + ' %: se recorta a 20 %.</b>' : '') + '</p>' +
      '<p class="hint" style="margin-top:8px">Producción de recursos de cada aldea con dueño (por hora, se acumula en el tesoro).</p>' +
      '<div class="admInputs"><label>Oro /h<input id="admAldG" type="number" min="0" max="100000" value="' + un(alt.gold) + '"></label>' +
      '<label>Madera /h<input id="admAldW" type="number" min="0" max="100000" value="' + un(alt.wood) + '"></label>' +
      '<label>Mineral /h<input id="admAldO" type="number" min="0" max="100000" value="' + un(alt.ore) + '"></label></div>' +
      '<p class="hint" style="margin-top:12px">Protección de novatos: (1) los reinos con <b>menos</b> de estos puntos no pueden atacar ni ser atacados; (2) nadie puede atacar a un reino que esté <b>estos puntos o más</b> por debajo suyo (evita que los fuertes machaquen a los débiles). Pon 0 para desactivarla.</p>' +
      '<div class="admInputs"><label>Protección de novatos (puntos)<input id="admProtIn" type="number" min="0" max="1000000" value="' + un(this.protect != null ? this.protect : 1000) + '"></label></div>' +
      '<p class="hint" style="margin-top:12px">Reinos <b>en línea</b>: cuentan los reinos activos vistos en los últimos minutos indicados (el juego avisa cada 20 s mientras la pestaña está abierta).</p>' +
      '<div class="admInputs"><label>En línea (minutos)<input id="admOnIn" type="number" min="1" max="60" value="' + un(this.onlineMin != null ? this.onlineMin : 5) + '"></label></div>' +
      '<div style="text-align:center;margin-top:14px"><button class="btn" id="admGo">Guardar</button></div>' +
      '<div id="admMsg" class="notice" style="margin-top:8px"></div>');
    $("#admGo").onclick = async () => {
      const v = Number($("#admFeeIn").value);
      const sv = Number($("#admThrIn").value);
      const rg = Number($("#admThrG").value);
      const rw = Number($("#admThrW").value);
      const ro = Number($("#admThrO").value);
      const av = Number($("#admAldIn").value);
      const ag = Number($("#admAldG").value);
      const aw = Number($("#admAldW").value);
      const ao = Number($("#admAldO").value);
      const pr = Number($("#admProtIn").value);
      const onm = Number($("#admOnIn").value);
      if(!(v >= 0 && v <= 90)) return notice($("#admMsg"), "La comisión debe estar entre 0 y 90.", "danger");
      if(!(sv >= 0 && sv <= 90)) return notice($("#admMsg"), "El tributo de tronos debe estar entre 0 y 90.", "danger");
      if(!(rg >= 0 && rw >= 0 && ro >= 0)) return notice($("#admMsg"), "La producción de tronos debe ser 0 o mayor.", "danger");
      if(!(av >= 0.01 && av <= 20)) return notice($("#admMsg"), "El tributo de aldeas debe estar entre 0,01 y 20.", "danger");
      if(!(ag >= 0 && aw >= 0 && ao >= 0)) return notice($("#admMsg"), "La producción de aldeas debe ser 0 o mayor.", "danger");
      if(!(pr >= 0 && pr <= 1000000)) return notice($("#admMsg"), "La protección debe estar entre 0 y 1.000.000 puntos.", "danger");
      if(!(onm >= 1 && onm <= 60)) return notice($("#admMsg"), "El tiempo en línea debe estar entre 1 y 60 minutos.", "danger");
      $("#admGo").disabled = true;
      try{
        await sbRpc("wow_admin_setfee", { p_token: this.me.token, p_fee: v });
        await sbRpc("wow_admin_setthrone", { p_token: this.me.token, p_pct: sv });
        await sbRpc("wow_admin_setthrones", { p_token: this.me.token, p_gold: rg, p_wood: rw, p_ore: ro });
        await sbRpc("wow_admin_setaldeashare", { p_token: this.me.token, p_pct: av });
        await sbRpc("wow_admin_setaldeas", { p_token: this.me.token, p_gold: ag, p_wood: aw, p_ore: ao });
        await sbRpc("wow_admin_setprotect", { p_token: this.me.token, p_pts: pr });
        await sbRpc("wow_admin_setonline", { p_token: this.me.token, p_min: onm });
        this.mktFee = v; this.throneShare = sv; this.throneRates = { gold: rg, wood: rw, ore: ro };
        this.aldeaShare = av; this.aldeaRates = { gold: ag, wood: aw, ore: ao }; this.protect = pr;
        this.onlineMin = onm;
        modalClose(); toast("Ajustes guardados."); this.loadAdmin();
      }catch(e){ $("#admGo").disabled = false; notice($("#admMsg"), shortMsg(e), "danger"); }
    };
  },
  admProd(){
    const g = (this.prodMult != null) ? Number(this.prodMult) : 1;
    modal('<h2 style="margin-top:0;color:var(--gold)">⚙️ Producción de recursos</h2>' +
      '<p class="hint">Cuánto producen los reinos respecto a lo normal. <b>1</b> = normal, <b>0,5</b> = la mitad, <b>2</b> = el doble, <b>0</b> = nada. Afecta a todos los reinos (jugadores y bots). No cambia almacenes, costes ni tiempos.</p>' +
      '<div class="admInputs"><label>Multiplicador global (0 a 10)<input id="admProdIn" type="number" min="0" max="10" step="0.05" value="' + dec(g) + '"></label></div>' +
      '<p class="hint" style="margin-top:8px">Cada reino puede tener además su propio ajuste desde su fila (botón ⚙️ Producción). El ritmo final es <b>global × reino</b>.</p>' +
      '<div style="text-align:center;margin-top:14px"><button class="btn" id="admProdGo">Guardar</button></div>' +
      '<div id="admMsg" class="notice" style="margin-top:8px"></div>');
    $("#admProdGo").onclick = async () => {
      const v = Number($("#admProdIn").value);
      if(!(v >= 0 && v <= 10)) return notice($("#admMsg"), "El multiplicador debe estar entre 0 y 10.", "danger");
      $("#admProdGo").disabled = true;
      try{
        const r = await sbRpc("wow_admin_setprod", { p_token: this.me.token, p_mult: v });
        this.prodMult = (r && r.prod_mult != null) ? r.prod_mult : v;
        modalClose(); toast("Producción global ×" + dec(this.prodMult) + "."); this.loadAdmin();
      }catch(e){ $("#admProdGo").disabled = false; notice($("#admMsg"), shortMsg(e), "danger"); }
    };
  },
  admTavern(){
    const m = this.madam || { cost: 50, days: 30, bonus: 1 };
    modal('<h2 style="margin-top:0;color:var(--gold)">🍺 Taberna · precios</h2>' +
      '<p class="hint">Ajusta lo que cuesta y lo que dan las atracciones de la taberna. Ahora mismo solo la <b>💃 Madam</b> tiene contrato; 🗡️ Mercenarios y 🍺 Beber llegarán después y también se regularán desde aquí.</p>' +
      '<h3 style="margin:14px 0 6px;color:var(--gold)">💃 La Madam</h3>' +
      '<div class="admInputs">' +
        '<label>Precio del contrato (CUP)<input id="adMdmCost" type="number" min="0" max="100000" value="' + un(m.cost != null ? m.cost : 50) + '"></label>' +
        '<label>Duración (días)<input id="adMdmDays" type="number" min="1" max="365" value="' + un(m.days != null ? m.days : 30) + '"></label>' +
        '<label>Bonus de ataque por tropa<input id="adMdmBonus" type="number" min="0" max="100" value="' + un(m.bonus != null ? m.bonus : 1) + '"></label>' +
      '</div>' +
      '<p class="hint" style="margin-top:8px">Mientras el contrato esté activo, todas las tropas del reino reciben el bonus de ataque (atacando y defendiendo). · Contratos activos ahora: <b>' + un((this.madam && this.madam.active_n) || 0) + '</b> · Total recaudado: <b>' + un((this.madam && this.madam.earned) || 0) + ' CUP</b>.</p>' +
      '<div style="text-align:center;margin-top:14px"><button class="btn" id="adMdmGo">Guardar</button></div>' +
      '<div id="admMsg" class="notice" style="margin-top:8px"></div>');
    $("#adMdmGo").onclick = async () => {
      const cost = Number($("#adMdmCost").value);
      const days = Number($("#adMdmDays").value);
      const bonus = Number($("#adMdmBonus").value);
      if(!(cost >= 0 && cost <= 100000)) return notice($("#admMsg"), "El precio debe estar entre 0 y 100.000 CUP.", "danger");
      if(!(days >= 1 && days <= 365)) return notice($("#admMsg"), "La duración debe estar entre 1 y 365 días.", "danger");
      if(!(bonus >= 0 && bonus <= 100)) return notice($("#admMsg"), "El bonus debe estar entre 0 y 100.", "danger");
      $("#adMdmGo").disabled = true;
      try{
        const r = await sbRpc("wow_admin_setmadam", { p_token: this.me.token, p_cost: cost, p_days: days, p_bonus: bonus });
        this.madam = { cost: r.cost, days: r.days, bonus: r.bonus, active_n: (this.madam && this.madam.active_n) || 0 };
        modalClose(); toast("🍺 Precios de la taberna guardados."); this.loadAdmin();
      }catch(e){ $("#adMdmGo").disabled = false; notice($("#admMsg"), shortMsg(e), "danger"); }
    };
  },
  admProdUser(u){
    const g = (this.prodMult != null) ? Number(this.prodMult) : 1;
    modal('<h2 style="margin-top:0;color:var(--gold)">⚙️ Producción · ' + esc(u.name) + '</h2>' +
      '<p class="hint">Ajuste solo para este reino. <b>1</b> = normal, <b>0,5</b> = la mitad, <b>2</b> = el doble, <b>0</b> = nada.</p>' +
      '<div class="admInputs"><label>Multiplicador del reino (0 a 10)<input id="admProdUIn" type="number" min="0" max="10" step="0.05" value="' + dec(Number(u.prod_mult)||1) + '"></label></div>' +
      '<p class="hint" style="margin-top:8px">Su producción real será <b>global ×' + dec(g) + '</b> × este valor = <b>×' + dec(g * (Number(u.prod_mult)||1)) + '</b> ahora mismo.</p>' +
      '<div style="text-align:center;margin-top:14px"><button class="btn" id="admProdUGo">Guardar</button></div>' +
      '<div id="admMsg" class="notice" style="margin-top:8px"></div>');
    $("#admProdUGo").onclick = async () => {
      const v = Number($("#admProdUIn").value);
      if(!(v >= 0 && v <= 10)) return notice($("#admMsg"), "El multiplicador debe estar entre 0 y 10.", "danger");
      $("#admProdUGo").disabled = true;
      try{
        await sbRpc("wow_admin_setproduser", { p_token: this.me.token, p_id: u.id, p_mult: v });
        modalClose(); toast("Producción de " + u.name + " ×" + dec(v) + "."); this.loadAdmin();
      }catch(e){ $("#admProdUGo").disabled = false; notice($("#admMsg"), shortMsg(e), "danger"); }
    };
  },
  /* ----- reinos automáticos: juegan solos, como cualquier otro reino ----- */
  botLevelName(l){ return ({ 1:"Muy tranquilo", 2:"Tranquilo", 3:"Normal", 4:"Agresivo", 5:"Muy agresivo" })[Number(l)] || "Normal"; },
  botLevelOpts(sel){
    return [1,2,3,4,5].map(n => '<option value="' + n + '"' + (n === Number(sel) ? ' selected' : '') + '>' + n + ' · ' + this.botLevelName(n) + '</option>').join("");
  },
  botAgo(ms, now){
    if(!ms) return "nunca";
    const m = Math.max(0, Math.round((now - Number(ms)) / 60000));
    if(m < 1) return "hace un momento";
    if(m < 60) return "hace " + m + " min";
    const h = Math.round(m / 60);
    return h < 24 ? "hace " + h + " h" : "hace " + Math.round(h / 24) + " d";
  },
  allianceOpts(sel){
    return (this.alliances || []).map(a => '<option value="' + esc(a.id) + '"' + (a.id === sel ? ' selected' : '') + '>[' + esc(a.tag) + '] ' + esc(a.name) + ' · ' + a.members + '/5</option>').join("");
  },
  async admBotsPanel(){
    try{
      const r = await sbRpc("wow_admin_bot_list", { p_token: this.me.token });
      this.bots = r.bots || []; this.botAuto = !!r.auto; this.botNow = r.now; this.botProtect = r.protect;
      try{ this.alliances = await sbRpc("wow_alliance_list", { p_token: this.me.token }) || []; }catch(_){ this.alliances = this.alliances || []; }
      try{ this.botMkt = await sbRpc("wow_admin_bot_prices", { p_token: this.me.token }); }catch(_){ this.botMkt = this.botMkt || null; }
    }catch(e){ return toast(shortMsg(e), true); }
    this.renderBotsPanel();
  },
  renderBotsPanel(){
    const list = this.bots || [], auto = !!this.botAuto, now = Number(this.botNow || Date.now());
    const prot = (this.botProtect != null ? this.botProtect : 1000);
    const rows = list.map(b => {
      const lv = Number(b.level) || 3, seed = b.seed || {};
      const when = b.online ? '🟢 en línea ahora' : '⚫ visto ' + this.botAgo(b.last, now);
      return '<div class="admRow' + (b.active ? '' : ' banned') + '">' +
        '<div class="admHead"><b>🤖 ' + esc(b.name) + '</b> <span class="admId">(usuario: ' + esc(b.id) + ')</span>' +
          (b.active ? '' : '<span class="admTag ban">PAUSADO</span>') +
          (b.atag ? '<span class="admTag">[' + esc(b.atag) + ']</span>' : '') +
          '<span class="admFac">' + (b.faction === 'horda' ? '⚔️ Horda' : '🛡️ Alianza') + '</span></div>' +
        '<div class="admStats">🏆 ' + un(b.points) + ' · ⚔️ ' + un(b.troops) + ' tropas · 🏰 ' + un(b.nodes) + ' plazas · ' +
          'nivel ' + lv + ' (' + this.botLevelName(lv) + ') · nace con edificios ' + un(seed.bld || 0) + ' y ' + un(seed.trp || 0) + ' tropas · ' + when + '</div>' +
        '<div class="admActs">' +
          '<label style="font-size:12px;color:var(--dim);display:flex;align-items:center;gap:4px">🎚 <select data-b="lvl" data-id="' + esc(b.id) + '">' + this.botLevelOpts(lv) + '</select></label>' +
          '<label style="font-size:12px;color:var(--dim);display:flex;align-items:center;gap:4px">🤝 <select data-b="ally" data-id="' + esc(b.id) + '"><option value="">— sin alianza —</option>' + this.allianceOpts(b.alliance || "") + '</select></label>' +
          '<button class="btn sm" data-b="ren" data-id="' + esc(b.id) + '">✏️ Nombre del reino</button>' +
          '<button class="btn sm" data-b="on" data-id="' + esc(b.id) + '" data-on="' + (b.active ? 1 : 0) + '">' + (b.active ? '⏸ Pausar' : '▶️ Reanudar') + '</button>' +
          '<button class="btn sm danger" data-b="del" data-id="' + esc(b.id) + '">🗑 Quitar</button>' +
        '</div></div>';
    }).join('') || '<p class="empty">Todavía no hay ninguno. Crea el primero aquí abajo.</p>';
    modal('<h2 style="margin-top:0;color:var(--gold)">🤖 Reinos automáticos</h2>' +
      '<p class="hint">Son reinos normales que juegan solos: producen, construyen, entrenan y atacan a otros reinos. ' +
      'Sirven para que el mundo siga con movimiento cuando hay poca gente conectada. Ocupan su casilla en el mapa y salen en el ranking y en el contador en línea como cualquier otro. ' +
      'Cada uno tiene su <b>nombre de reino</b> (el que se ve) y su <b>nombre de usuario</b> (con el que entra), y puedes reunirlos en una <b>alianza</b>: así luchan juntos, van a por el enemigo de la alianza y cada victoria suma para ella.</p>' +
      '<div class="pactCard" style="margin:10px 0 4px' + (auto ? ';border-color:var(--green)' : '') + '">' +
        '<div class="pactWho">' + (auto ? '🟢 Jugando y en línea' : '⚫ Apagados') + '</div>' +
        '<div class="pactMeta">' + (auto
          ? 'Los ' + un(list.length) + ' reinos automáticos juegan sin parar (cada uno a su ritmo) y se ven siempre en línea, como un jugador más.'
          : 'Están de vacaciones: no juegan, no construyen ni atacan, y no aparecen en el contador en línea.') + '</div>' +
        '<button type="button" class="btn' + (auto ? ' danger' : '') + '" id="botAuto" onclick="Game.botToggle(!Game.botAuto, this)">' + (auto ? '🌙 Apagar todos' : '🌞 Encender todos') + '</button>' +
      '</div>' +
      '<div class="secTitle" style="margin:16px 0 0">🏪 Lo que venden en el mercado</div>' +
      '<p class="hint" style="margin:6px 0">Precio en 🧿 CUP por unidad. Ponlo de <b>desde</b> a <b>hasta</b>; si pones <b>hasta 0</b>, no venden ese objeto. Nunca compran: solo ponen en venta lo que les sobra (oro, madera, mineral y tropas).</p>' +
      '<div id="botMktBox"><p class="empty">Cargando…</p></div>' +
      (list.length ? '<div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-top:8px"><span class="hint" style="margin:0">A todos:</span>' +
        '<select id="botAllAll" style="flex:1;min-width:140px"><option value="">— sacarlos de su alianza —</option>' + this.allianceOpts("") + '</select>' +
        '<button class="btn sm" id="botAllGo">Meterlos en la alianza</button></div>' : '') +
      '<div class="admList" style="max-height:38vh;overflow:auto;margin-top:10px">' + rows + '</div>' +
      '<h3 style="margin:14px 0 0;color:var(--gold);font-size:15px">Crear uno</h3>' +
      '<p class="hint">Respetan la protección de novatos: no atacan ni son atacados por debajo de ' + un(prot) + ' puntos. El nivel fija con cuánto nacen (edificios y tropas) y con cuánta frecuencia actúan.</p>' +
      '<div class="admInputs">' +
        '<label>Nombre del reino<input id="botName" type="text" maxlength="20" placeholder="P. ej. Falkreath"></label>' +
        '<label>Nombre de usuario (rey)<input id="botKing" type="text" maxlength="20" placeholder="igual que el del reino"></label>' +
        '<label>Bando<select id="botFac"><option value="alianza">🛡️ Alianza</option><option value="horda">⚔️ Horda</option></select></label>' +
        '<label>Dificultad<select id="botLvl">' + this.botLevelOpts(3) + '</select></label>' +
        '<label>Alianza<select id="botAll"><option value="">— sin alianza —</option>' + this.allianceOpts("") + '</select></label>' +
      '</div>' +
      '<div style="display:flex;gap:8px;justify-content:center;flex-wrap:wrap;margin-top:12px">' +
        '<button class="btn" id="botAdd">➕ Crear reino</button>' +
        '<button class="btn sm" id="botRun">⏭️ Jugar ahora</button>' +
        (list.length ? '<button class="btn sm danger" id="botPurge">🗑 Quitarlos todos</button>' : '') +
      '</div>' +
      '<div id="admMsg" class="notice" style="margin-top:8px"></div>');
    document.getElementById("modalBox").addEventListener("click", el => {
      const b = el.target.closest ? el.target.closest("#botAuto") : null; if(!b) return;
      this.botToggle(!this.botAuto, b);
    });
    const aa = document.getElementById("botAuto"); if(aa){ aa.disabled = false; aa.onclick = e => { e.preventDefault(); if(e.stopPropagation) e.stopPropagation(); this.botToggle(!this.botAuto, aa); }; }
    const ab = $("#botAdd"); if(ab) ab.onclick = async () => {
      const nm = ($("#botName").value || "").trim();
      const king = ($("#botKing").value || "").trim();
      if(nm.length < 2) return notice($("#admMsg"), "Escribe el nombre del reino.", "danger");
      if(king && (king.length < 2 || king.length > 20)) return notice($("#admMsg"), "El nombre de usuario debe tener entre 2 y 20 letras.", "danger");
      ab.disabled = true;
      try{
        const r = await sbRpc("wow_admin_bot_create", { p_token: this.me.token, p_name: nm, p_faction: $("#botFac").value,
          p_level: Number($("#botLvl").value), p_king: king || null, p_alliance: $("#botAll").value || null });
        toast('"' + r.name + '" nace en la casilla ' + r.pos + ' con ' + un(r.points) + ' puntos.');
        await this.admBotsPanel();
      }catch(e){ ab.disabled = false; notice($("#admMsg"), shortMsg(e), "danger"); }
    };
    const ag = $("#botAllGo"); if(ag) ag.onclick = async () => {
      const al = $("#botAllAll").value;
      ag.disabled = true;
      try{
        const r = await sbRpc("wow_admin_bot_ally", { p_token: this.me.token, p_id: "", p_alliance: al });
        toast(al ? ("Se unen " + un(r.n || 0) + " reinos." + (r.llenos ? " " + r.llenos + " no caben (máximo 5 por alianza)." : ""))
                 : ("Salen de la alianza " + un(r.n || 0) + " reinos."));
        await this.admBotsPanel();
      }catch(e){ ag.disabled = false; notice($("#admMsg"), shortMsg(e), "danger"); }
    };
    const ar = $("#botRun"); if(ar) ar.onclick = async () => {
      ar.disabled = true;
      try{ logBook("Jugar ahora pulsado");
        const r = await sbRpc("wow_admin_bot_run", { p_token: this.me.token }); toast("Han jugado " + un(r.acted || 0) + " reinos."); await this.admBotsPanel(); }
      catch(e){ ar.disabled = false; logBook("FALLO jugar ahora:", (e && e.message) || e); notice($("#admMsg"), shortMsg(e), "danger"); }
    };
    const ap = $("#botPurge"); if(ap) ap.onclick = async () => {
      if(!confirm("¿Quitar TODOS los reinos automáticos? Desaparecerán del mapa y del ranking.")) return;
      ap.disabled = true;
      try{ const r = await sbRpc("wow_admin_bot_purge", { p_token: this.me.token }); toast("Quitados " + un(r.deleted || 0) + " reinos."); await this.admBotsPanel(); }
      catch(e){ ap.disabled = false; notice($("#admMsg"), shortMsg(e), "danger"); }
    };
    document.querySelectorAll("#modalBox [data-b]").forEach(el => {
      if(el.dataset.b === "lvl") el.onchange = async () => {
        try{ await sbRpc("wow_admin_bot_set", { p_token: this.me.token, p_id: el.dataset.id, p_level: Number(el.value) });
          toast("Dificultad: " + this.botLevelName(el.value) + "."); await this.admBotsPanel(); }
        catch(e){ toast(shortMsg(e), true); }
      };
      if(el.dataset.b === "ally") el.onchange = async () => {
        try{
          await sbRpc("wow_admin_bot_ally", { p_token: this.me.token, p_id: el.dataset.id, p_alliance: el.value });
          toast(el.value ? "Se une a la alianza." : "Sale de la alianza.");
          await this.admBotsPanel();
        }catch(e){ toast(shortMsg(e), true); await this.admBotsPanel(); }
      };
      if(el.dataset.b === "ren") el.onclick = () => this.admRenameBot(el.dataset.id);
      if(el.dataset.b === "on") el.onclick = async () => {
        const on = el.dataset.on !== "1";
        try{ logBook("Pausar/Reanudar " + el.dataset.id + " -> " + (on ? "activo" : "pausado"));
          await sbRpc("wow_admin_bot_stop", { p_token: this.me.token, p_id: el.dataset.id, p_on: on });
          toast(on ? "Vuelve a jugar." : "Pausado."); await this.admBotsPanel(); }
        catch(e){ logBook("FALLO pausar/reanudar:", (e && e.message) || e); toast(shortMsg(e), true); }
      };
      if(el.dataset.b === "del") el.onclick = async () => {
        if(!confirm("¿Quitar este reino? Se borrará con todo lo suyo (edificios, tropas y plazas).")) return;
        try{ await sbRpc("wow_admin_bot_del", { p_token: this.me.token, p_id: el.dataset.id }); toast("Reino quitado."); await this.admBotsPanel(); }
        catch(e){ toast(shortMsg(e), true); }
      };
    });
    this.renderBotMarket();
  },
  renderBotMarket(){
    const box = document.getElementById("botMktBox"); if(!box) return;
    const d = this.botMkt || {}, list = d.prices || [];
    if(!list.length){ box.innerHTML = '<p class="empty">No se pudieron cargar los precios.</p>'; return; }
    let h = '<div style="margin:0 0 8px;font-size:12px;color:var(--dim)">🧿 CUP ganado por los reinos automáticos: <b style="color:var(--gold)">' + un(d.earned || 0) + '</b>' +
      ' · ahora en Administración: <b style="color:var(--gold)">' + un(d.admin_cup || 0) + '</b>' +
      ' · ofertas suyas activas: <b>' + un(d.offers || 0) + '</b></div>';
    h += '<div class="mktGrid">' + list.map(p => {
      const on = Number(p.hi) > 0;
      return '<div class="mktPrice' + (on ? '' : ' off') + '">' +
        '<span class="mpName">' + esc(mktName(p.item)) + '</span>' +
        '<input type="number" min="0" step="0.05" value="' + Number(p.lo) + '" data-blo="' + esc(p.item) + '" title="Desde (CUP por unidad)">' +
        '<span class="mpDash">–</span>' +
        '<input type="number" min="0" step="0.05" value="' + Number(p.hi) + '" data-bhi="' + esc(p.item) + '" title="Hasta (CUP por unidad)">' +
        '<button class="btn sm" data-bsave="' + esc(p.item) + '">Guardar</button>' +
        '<span class="mpState">' + (on ? 'vende' : 'no vende') + '</span></div>';
    }).join('') + '</div>';
    box.innerHTML = h;
    box.querySelectorAll("[data-bsave]").forEach(b => { b.onclick = () => this.saveBotPrice(b.dataset.bsave); });
  },
  async loadBotMarket(){
    try{ this.botMkt = await sbRpc("wow_admin_bot_prices", { p_token: this.me.token }); }catch(_){}
    this.renderBotMarket();
  },
  async saveBotPrice(item){
    const box = document.getElementById("botMktBox");
    const lo = box && box.querySelector('[data-blo="' + item + '"]'), hi = box && box.querySelector('[data-bhi="' + item + '"]');
    if(!lo || !hi) return;
    try{
      const r = await sbRpc("wow_admin_bot_price", { p_token: this.me.token, p_item: item, p_lo: Number(lo.value) || 0, p_hi: Number(hi.value) || 0 });
      toast(r.on ? ("🏪 " + mktName(item) + ": " + un(r.lo) + " a " + un(r.hi) + " CUP por unidad.") : ("🏪 " + mktName(item) + ": ya no lo venden."));
      await this.loadBotMarket();
    }catch(e){ toast(shortMsg(e), true); }
  },
  admRenameBot(id){
    const b = (this.bots || []).find(x => x.id === id); if(!b) return;
    modal('<h2 style="margin-top:0;color:var(--gold)">✏️ Nombre del reino</h2>' +
      '<p class="hint">Cambia el nombre que se ve en el mapa, el ranking y el chat. Su nombre de usuario (<b>' + esc(b.id) + '</b>) no cambia: es con el que entra.</p>' +
      '<div class="admInputs"><label>Nombre del reino<input id="botNew" type="text" maxlength="20" value="' + esc(b.name) + '"></label></div>' +
      '<div style="display:flex;gap:8px;justify-content:center;margin-top:12px">' +
        '<button class="btn" id="botNewGo">Guardar</button><button class="btn sm" id="botNewBack">Volver</button></div>' +
      '<div id="admMsg" class="notice" style="margin-top:8px"></div>');
    const back = $("#botNewBack"); if(back) back.onclick = () => this.renderBotsPanel();
    const go = $("#botNewGo"); if(go) go.onclick = async () => {
      const nn = ($("#botNew").value || "").trim();
      if(nn.length < 2) return notice($("#admMsg"), "Escribe el nombre del reino.", "danger");
      go.disabled = true;
      try{ await sbRpc("wow_admin_bot_rename", { p_token: this.me.token, p_id: b.id, p_name: nn }); toast("Nombre cambiado."); await this.admBotsPanel(); }
      catch(e){ go.disabled = false; notice($("#admMsg"), shortMsg(e), "danger"); }
    };
  },
  admUser(id){ return (this.adm && this.adm.users || []).find(x => x.id === id); },
  bldName(k){ const b = BLD[k]; return (b && (b.e + " " + b.n)) || k; },
  admAction(a, id, on){
    const u = this.admUser(id); if(!u) return;
    if(a === "res") return this.admRes(u);
    if(a === "bld") return this.admBlds(u);
    if(a === "trp") return this.admTrp(u);
    if(a === "prod") return this.admProdUser(u);
    if(a === "pw") return this.admPw(u);
    if(a === "adm") return this.admSetAdmin(u);
    if(a === "ban") return this.admBan(u, on === "1");
    if(a === "del") return this.admDel(u);
  },
  admBlds(u){
    modal('<h2 style="margin-top:0;color:var(--gold)">🏗️ Edificios · ' + esc(u.name) + '</h2>' +
      '<p class="hint">Sube o baja el nivel de cada edificio (0 a 20). A 0 se quita; al subirlo desde 0 se crea. Las tropas no cambian.</p>' +
      '<div id="admBldList" class="admList"><p class="empty">Cargando…</p></div>' +
      '<div id="admMsg" class="notice" style="margin-top:8px"></div>' +
      '<div style="text-align:center;margin-top:12px"><button class="btn" id="admBldClose">Cerrar</button></div>');
    $("#admBldClose").onclick = () => modalClose();
    this.admBldsRender(u);
  },
  admBldsRender(u){
    const box = $("#admBldList"); if(!box) return;
    box.innerHTML = '<p class="empty">Cargando…</p>';
    sbRpc("wow_admin_blds", { p_token: this.me.token, p_id: u.id }).then(r => {
      const list = (r && r.blds) || [];
      const b = $("#admBldList"); if(!b) return;
      b.innerHTML = list.map(x => {
        const lv = un(x.level), busy = Number(x.finish||0) > Number((r && r.now) || Date.now());
        return '<div class="admRow"><div class="admHead"><b>' + esc(this.bldName(x.key)) + '</b>' +
          (busy ? ' <span class="admTag">⏳ en obra → ' + lv + '</span>' : ' <span class="admId">nivel ' + lv + '</span>') + '</div>' +
          '<div class="admActs">' +
            '<button class="btn sm" data-b="minus" data-k="' + esc(x.key) + '">−1</button>' +
            '<button class="btn sm" data-b="plus" data-k="' + esc(x.key) + '">+1</button>' +
            '<button class="btn sm" data-b="zero" data-k="' + esc(x.key) + '">A 0</button>' +
            '<button class="btn sm" data-b="max" data-k="' + esc(x.key) + '">A 20</button>' +
          '</div></div>';
      }).join("");
      b.querySelectorAll("button[data-b]").forEach(bt => bt.onclick = () => this.admBldSet(u, bt.dataset.k, bt.dataset.b));
    }).catch(e => { const b = $("#admBldList"); if(b) b.innerHTML = '<p class="empty">' + esc(shortMsg(e)) + '</p>'; });
  },
  async admBldSet(u, key, act){
    const box = $("#admBldList"), msg = $("#admMsg");
    let lv;
    try{ const r = await sbRpc("wow_admin_blds", { p_token: this.me.token, p_id: u.id });
      lv = (((r && r.blds) || []).find(x => x.key === key) || {}).level || 0; }
    catch(e){ notice(msg, shortMsg(e), "danger"); return; }
    if(act === "minus") lv = Number(lv) - 1;
    else if(act === "plus") lv = Number(lv) + 1;
    else if(act === "zero") lv = 0;
    else if(act === "max") lv = 20;
    lv = Math.max(0, Math.min(20, Number(lv) || 0));
    if(!confirm(this.bldName(key) + " de " + u.name + " → nivel " + lv + "?")) return;
    if(box) box.querySelectorAll("button").forEach(b => b.disabled = true);
    try{
      const r = await sbRpc("wow_admin_setbld", { p_token: this.me.token, p_id: u.id, p_key: key, p_level: lv });
      notice(msg, this.bldName(key) + " → nivel " + un(r && r.level) + ".", "ok");
      this.admBldsRender(u); this.loadAdmin(true);
    }catch(e){ if(box) box.querySelectorAll("button").forEach(b => b.disabled = false); notice(msg, shortMsg(e), "danger"); }
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
document.addEventListener("DOMContentLoaded", () => { logBind(); Auth.init(); });

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
  const first = !this._mktSig;
  if(first) el.innerHTML = '<p class="empty">Cargando mercado…</p>';
  let d;
  try{ d = await sbRpc("wow_market_list", { p_token: this.me.token }); }
  catch(e){ if(first) el.innerHTML = '<p class="empty">' + esc(shortMsg(e)) + '</p>'; return; }
  this.mkt = d;
  const sig = JSON.stringify(d);
  if(sig === this._mktSig) return;  // nada cambió: no redibujar (evita parpadeo)
  const ae = document.activeElement;
  if(!first && ae && el.contains(ae) && (ae.tagName === "INPUT" || ae.tagName === "SELECT" || ae.tagName === "TEXTAREA")) return;
  this._mktSig = sig;
  const st = this.st || {};
  const inv = { cup: st.cup || 0, gold: st.gold || 0, wood: st.wood || 0, ore: st.ore || 0 };
  (st.troops || []).forEach(t => inv[t.key] = t.qty);
  const optsGive = MKT_ITEMS.map(k => '<option value="' + k + '">' + esc(mktName(k)) + '</option>').join("");
  const optsWant = ['cup'].map(k => '<option value="' + k + '">' + esc(mktName(k)) + '</option>').join("");
  let html = '<h2 style="margin-top:0;color:var(--gold)">🛒 Mercado</h2>' +
    '<p class="hint">Publica ofertas y toma las de otros reinos. Comisión actual: <b>' + un(d.fee) + '%</b> (la paga el vendedor). Las ofertas caducan en 1 día. En <b>Pido</b> solo puedes pedir 🧿 CUP.</p>' +
    '<div class="secTitle">📢 Publicar oferta</div>' +
    '<div class="mktPub">' +
      '<label>Doy <select id="mkGive">' + optsGive + '</select>' +
        '<input id="mkGiveQty" type="number" min="0" value="0"><button class="btn sm" id="mkGiveMax">MAX</button></label>' +
      '<label>Pido <select id="mkWant" disabled>' + optsWant + '</select>' +
        '<input id="mkWantQty" type="number" min="0" value="0"></label>' +
      '<button class="btn" id="mkPubGo">📢 Publicar oferta</button>' +
    '</div>' +
    '<div id="mkMsg" class="notice"></div>';
  html += '<div class="secTitle">🌍 Ofertas del reino</div>';
  if(!(d.offers || []).length) html += '<div class="empty">No hay ofertas ahora mismo.</div>';
  else html += (d.offers || []).map(o =>
      '<div class="fleet mkRow"><span class="fi">🤝</span>' +
      '<div class="fmain"><div class="ft">' + esc(o.who) + '</div>' +
      '<div class="fd">da <b>' + dec(o.give_left) + '</b> ' + esc(mktName(o.give)) + ' · pide <b>' + dec(o.want_left) + '</b> ' + esc(mktName(o.want)) + '</div></div>' +
      '<div class="fcount"><input id="mkTk_' + o.id + '" type="number" min="0" value="' + o.give_left + '" style="width:70px"> ' +
      '<button class="btn sm" data-take="' + o.id + '">Tomar</button></div></div>'
    ).join("");
  html += '<div class="secTitle">📦 Mis ofertas</div>';
  if(!(d.mine || []).length) html += '<div class="empty">No tienes ofertas activas.</div>';
  else html += (d.mine || []).map(o =>
      '<div class="fleet mkRow"><span class="fi">📦</span>' +
      '<div class="fmain"><div class="ft">da <b>' + dec(o.give_left) + '</b> ' + esc(mktName(o.give)) + '</div>' +
      '<div class="fd">pide <b>' + dec(o.want_left) + '</b> ' + esc(mktName(o.want)) + '</div></div>' +
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
    toast("🤝 Tomaste " + dec(r.took) + " · pagaste " + dec(r.paid) + ".");
    await this.refresh();
  }catch(e){ toast(shortMsg(e), true); }
};
Game.loadTavern = async function(){
  const el = $("#tabTavern"); if(!el) return;
  el.innerHTML = '<div class="tvBanner">' +
      '<img src="img/taberna.jpg?v=1" alt="Taberna de Azeroth">' +
      '<div class="tvOverlay">' +
        '<div class="tvBtns">' +
          '<button id="tvMadam">💃 Madam</button>' +
          '<button disabled title="Próximamente">🗡️ Mercenarios</button>' +
          '<button disabled title="Próximamente">🍺 Beber</button>' +
        '</div>' +
        '<div class="tvSoon" id="tvSoon"></div>' +
      '</div>' +
    '</div>';
  const mb = $("#tvMadam");
  if(mb) mb.onclick = () => Game.openMadam();
};

Game.madamStories = [
  { t: "El anillo de Sombraverde", s: "La Madam te recibe entre cortinas de terciopelo. Deja sobre la mesa un anillo de plata con una esmeralda oscura. «Lo gané apostando contra un noble de Ventormenta… pero él lo quiere de vuelta y manda matones cada noche. Si tus tropas me protegen, mis chicas marcharán contigo.»", a: "Aceptar el contrato", b: "Solo protegerla esta noche", c: "Guardar el anillo tú" },
  { t: "El druida desterrado", s: "«Conocí a un druida que podía hablar con los lobos», murmura la Madam mientras sirve hidromiel. «Me enseñó un secreto: el miedo vuelve torpes a los soldados. El mío, en cambio, los vuelve letales. Cuarenta monedas y mis chicas susurrarán en tus campamentos.»", a: "Aceptar el contrato", b: "Pedirle solo el secreto", c: "Marcharte sin más" },
  { t: "La promesa de Sylvanas", s: "Una carta sellada con cera negra reposa en la barra. «La Dama Oscura me debe un favor», dice la Madam. «Un contrato conmigo es un contrato con ella. Tus enemigos lo pensarán dos veces antes de alzar la espada.»", a: "Aceptar el contrato", b: "Leer la carta a escondidas", c: "Devolver la carta" },
  { t: "El baile de las cuchillas", s: "En el piso de arriba, una docena de mujeres entrenan con dagas al ritmo de un laúd. La Madam sonríe: «No son solo hermosas; son mortales. Ponlas a tu lado y cada golpe de tus tropas tendrá un filo extra.»", a: "Aceptar el contrato", b: "Apostar una pelea de exhibición", c: "Marcharte" },
  { t: "El general sin ejército", s: "«Un general lo perdió todo en una sola batalla», cuenta la Madam, «pero me enseñó que la moral importa más que el acero. Mis chicas levantan la moral allá donde van. Tu tropa peleará como si fueran diez y no una.»", a: "Aceptar el contrato", b: "Escuchar solo la historia", c: "Rechazar" },
  { t: "El mapa de Kalimdor", s: "La Madam desenrolla un mapa manchado de vino. «Hay rutas que nadie vigila, pozos donde el agua sabe a hierro. Conmigo, tus marchas nunca serán emboscadas… y tus ataques, siempre certeros.»", a: "Aceptar el contrato", b: "Copiar el mapa", c: "Ignorarlo" },
  { t: "El hijo del barón", s: "«El hijo de un barón viene cada noche a llorar por una cantante», dice la Madam con desdén. «Su padre guarda rencor. Si me contratas, él te dará información valiosa sobre tus rivales. Los reyes escuchan; las cortesanas, más.»", a: "Aceptar el contrato", b: "Chantajear al barón", c: "Marcharte" },
  { t: "El collar de rubíes", s: "La Madam abre un cofre: un collar de rubíes que gotea luz. «Fue de una reina que traicionó a su reino. Yo lo guardo como recuerdo de que la lealtad se compra… y se vende. ¿Cuánto vale la tuya?»", a: "Aceptar el contrato", b: "Intentar robarlo", c: "Cerrar el cofre" },
  { t: "La apuesta del capitán", s: "Un capitán borracho reta a la Madam a los dados. Ella gana sin mirar. «La suerte me sigue», dice. «Y mientras estés conmigo, seguirá tu estandarte. Mis chicas y yo… traemos buena fortuna al combate.»", a: "Aceptar el contrato", b: "Apostar tú también", c: "Retirarte" },
  { t: "El juramento de la taberna", s: "Cuando el último cliente se marcha, la Madam apaga las velas y habla en serio. «He visto caer imperios desde esta barra. Lo único que nunca muere es la lealtad de quien paga bien. Cuarenta monedas, treinta días, mis chicas a tu lado.»", a: "Aceptar el contrato", b: "Negociar el precio", c: "Apagar las velas tú" }
];

Game.openMadam = async function(){
  let r;
  try{ r = await sbRpc("wow_madam_info", { p_token: this.me.token }); }
  catch(e){ toast(e.message, true); return; }
  const cost = Number(r.cost), days = Number(r.days);
  const active = r.active === true;
  const remain = Number(r.remain_ms || 0);
  const dias = Math.floor(remain / 86400000), horas = Math.floor((remain % 86400000) / 3600000);
  if(!this._madamSeen){ this._madamSeen = []; }
  let pool = Game.madamStories.map((_, i) => i).filter(i => this._madamSeen.indexOf(i) < 0);
  if(!pool.length){ this._madamSeen = []; pool = Game.madamStories.map((_, i) => i); }
  const pick = pool[Math.floor(Math.random() * pool.length)];
  this._madamSeen.push(pick);
  const st = Game.madamStories[pick];
  const estados = active
    ? '<div class="mLin">Contrato <b>activo</b> · <b>+' + r.bonus + '</b> de ataque por tropa · quedan <b>' + dias + 'd ' + horas + 'h</b></div>'
    : '<div class="mLin">Contrato <b>inactivo</b> · coste <b>' + cost + ' CUP</b> / ' + days + ' días</div>';
  const btn = 'Contratar mis chicas +1 ATK <span style="opacity:.7">· ' + cost + ' CUP</span>';
  modal(
    '<h3 style="margin:0 0 8px">💃 La Madam</h3>' +
    estados +
    '<div style="margin:12px 0;line-height:1.5"><b>' + esc(st.t) + '</b><br><span style="opacity:.9">' + esc(st.s) + '</span></div>' +
    '<div style="text-align:center;margin-top:6px">' +
      '<button class="btn" id="mdHire">' + btn + '</button>' +
    '</div>'
  );
  const hb = $("#mdHire");
  if(hb) hb.onclick = async () => {
    hb.disabled = true;
    try{
      const hr = await sbRpc("wow_madam_hire", { p_token: Game.me.token });
      toast("💃 La Madam acepta. +" + hr.bonus + " de ataque durante " + days + " días.");
      if(Game.me) Game.me.cup = hr.cup;
      modalClose();
      Game.loadTavern && Game.loadTavern();
    }catch(e){ toast(e.message, true); hb.disabled = false; }
  };
};
Game.thrEvent = function(h, kind){
  const who = esc(h.actor_name || "?");
  const t = hora(h.created);
  const noun = kind === "aldea" ? "la aldea" : "el trono";
  let txt = "";
  if(h.kind === "take") txt = "🏯 <b>" + who + "</b> ocupó " + noun + " libre.";
  else if(h.kind === "conquest") txt = "⚔️ <b>" + who + "</b> conquistó " + noun + (h.detail && h.detail.from ? " (era de " + esc(h.detail.from) + ")" : "") + ".";
  else if(h.kind === "defended") txt = "🛡️ La defensa rechazó a <b>" + who + "</b>.";
  else if(h.kind === "reinforce") txt = "➕ <b>" + who + "</b> reforzó la guarnición.";
  else if(h.kind === "withdraw") txt = "➖ <b>" + who + "</b> retiró tropas de la guarnición.";
  else if(h.kind === "claim") txt = "💰 <b>" + who + "</b> reclamó el tesoro.";
  else txt = "• " + esc(h.kind);
  return txt + ' <span style="opacity:.6">· ' + t + '</span>';
};
Game.openThrone = function(node){ return this.openFort(node, "trono"); };
Game.openFort = async function(node, kind){
  kind = kind === "aldea" ? "aldea" : "trono";
  const noun = kind === "aldea" ? "aldea" : "trono";
  const icon = kind === "aldea" ? "🏘️" : "🏯";
  try{
    let r;
    if(kind === "aldea"){ r = await sbRpc("wow_aldea_info", { p_token: this.me.token }); this._aldeas = r.aldeas || []; }
    else { r = await sbRpc("wow_throne_info", { p_token: this.me.token }); this._thrones = r.thrones || []; }
    const list = (kind === "aldea") ? this._aldeas : this._thrones;
    const t = list.find(x => x.node === node);
    const me = this.me;
    const own = !!(t && t.mine);
    const troops = ((this.st && this.st.troops) || []).filter(x => x.qty > 0);
    let body = '<h2 style="margin-top:0;color:var(--gold)">' + icon + ' ' + esc(t ? t.name : (kind === "aldea" ? "Aldea" : "Trono")) + '</h2>';
    if(!t){
      body += '<div class="muted">' + (kind === "aldea" ? "Aldea libre. Envía tropas para ocuparla." : "Trono libre. Envía tropas para ocuparlo.") + '</div>';
    }else{
      body += '<div class="row"><span>Dueño</span><span>' + (t.holder_ally ? (t.ally_icon || '🏛️') + ' ' + esc(t.ally || 'Alianza') : esc(t.holder_name || 'Libre')) + (t.faction? ' ['+esc(t.faction)+']' : '') + '</span></div>';
      if(t.holder_ally && t.mine) body += '<div class="muted" style="margin-top:4px">' + (t.ally_icon || '🏛️') + ' Este lugar es de tu alianza: los recursos que reclames van al arcón común.</div>';
      body += '<div class="row"><span>Guarnición</span><span>' + un(t.garrison||0) + ' tropas</span></div>';
      if(t.treasure && Object.keys(t.treasure).length){
        body += '<div class="muted" style="margin-top:6px">Tesoro acumulado</div>';
        ["gold","wood","ore","cup"].forEach(function(k){
          var q = Number((t.treasure || {})[k] || 0);
          body += '<div class="row"><span>' + mktName(k) + '</span><span>' + dec(q) + (k === "cup" ? ' <span class="muted">(tributo del mercado)</span>' : '') + '</span></div>';
        });
      }else body += '<div class="muted">Sin tesoro por ahora.</div>';
      body += '<div class="row"><span>Tributo</span><span>' + dec(r.share||1) + '% del valor de cada venta del mercado</span></div>';
      if(r.rates) body += '<div class="muted" style="margin-top:4px">Genera +' + un(r.rates.gold||0) + ' 💰 oro · +' + un(r.rates.wood||0) + ' 🪵 madera · +' + un(r.rates.ore||0) + ' ⛏️ mineral por hora (se acumula en el tesoro).</div>';
    }
    if(this.st && this.st.pos != null && this.st.pos >= 0){
      body += '<div class="muted" style="margin-top:8px">⏱ Tus tropas tardan ~' + travelNodes(mapPosNode(this.st.pos), node) + ' s en llegar.</div>';
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
          '<button class="btn" id="thrAtkBtn">⚔️ ' + (t && t.holder ? 'Atacar para conquistar' : (kind === "aldea" ? 'Ocupar la aldea' : 'Ocupar el trono')) + '</button></div>';

      }
    }else{
      const mc = (t && t.mycontrib) || {};
      const gkeys = Object.keys(mc).filter(k => Number(mc[k]) > 0);
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
        body += '<div class="muted" style="margin-top:12px">Retirar tus tropas de la guarnición</div>';
        gkeys.forEach(k => {
          const m = TRP[k] || { e: "⚔️", n: k };
          const gq = Math.floor(Number(mc[k]) || 0);
          body += '<div class="atkRow"><span class="an">' + (m.e || "⚔️") + ' ' + m.n + '</span><span class="amax">tu aporte: ' + un(gq) + '</span>' +
            '<input id="thw_' + k + '" type="number" min="0" step="1" max="' + gq + '" value="">' +
            '<button class="btn sm" data-thwmax="' + k + '">MAX</button></div>';
        });
      }else{
        body += '<div class="muted" style="margin-top:12px">Solo puedes retirar las tropas que aportaste.</div>';
      }
      body += '<div style="text-align:center;margin-top:10px">' +
        (troops.length ? '<button class="btn" id="thrReinBtn">🛡️ Reforzar guarnición</button>' : '') +
        (gkeys.length ? '<button class="btn" id="thrWithBtn">➖ Retirar tropas</button>' : '') +
        (t.treasure && Object.keys(t.treasure).length ? '<button class="btn" id="thrClaimBtn">💰 ' + (t.holder_ally ? 'Reclamar al arcón' : 'Reclamar tesoro') + '</button>' : '') +
        '</div>';
    }
    if(t && t.history && t.history.length){
      body += '<div class="muted" style="margin-top:12px">Historial</div><div class="thrHist">';
      t.history.forEach(h => body += '<div class="thrEvent">' + this.thrEvent(h, kind) + '</div>');
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
Game._fortKind = function(node){ return isAldeaNode(node) ? "aldea" : "trono"; };
Game._thrTroops = function(){
  const payload = {};
  document.querySelectorAll('#modalBox input[id^="thq_"]').forEach(inp => {
    const k = inp.id.slice(4);
    const v = Math.max(0, parseInt(inp.value, 10) || 0);
    if(v > 0) payload[k] = v;
  });
  return payload;
};
Game._marchEta = function(r){ return Math.max(1, Math.round(Number((r && r.travel) || 0))); };
Game._marchSent = async function(){
  await this.refresh(); await this.loadMap(); this.loadMarches();
};
Game.thrAtk = async function(node){
  const payload = this._thrTroops();
  if(!Object.keys(payload).length) return toast("Elige al menos una tropa.", true);
  try{
    const r = await sbRpc("wow_throne_attack", { p_token: this.me.token, p_node: node, p_troops: payload });
    modalClose();
    const al = this._fortKind(node) === "aldea";
    toast((al ? "🛖" : "🏯") + " Tu ejército marcha contra " + (r.target || (al ? "la aldea" : "el trono")) + ". ⏱ Llega en ~" + this._marchEta(r) + " s.");
    await this._marchSent();
  }catch(e){ toast(shortMsg(e), true); }
};
Game.thrRein = async function(node){
  const payload = this._thrTroops();
  if(!Object.keys(payload).length) return toast("Elige al menos una tropa.", true);
  try{
    const r = await sbRpc("wow_throne_reinforce", { p_token: this.me.token, p_node: node, p_troops: payload });
    modalClose();
    toast("🛡️ Refuerzo en camino a " + (r.target || "la guarnición") + ". ⏱ Llega en ~" + this._marchEta(r) + " s.");
    await this._marchSent();
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
  if(!confirm("¿Retirar estas tropas de la guarnición? Si la dejas vacía, otro reino podrá ocupar " + (this._fortKind(node) === "aldea" ? "la aldea." : "el trono."))) return;
  try{
    const r = await sbRpc("wow_throne_withdraw", { p_token: this.me.token, p_node: node, p_troops: payload });
    modalClose();
    toast((r.empty ? "➖ Tropas retiradas. ¡La guarnición quedó vacía! " : "➖ Tropas retiradas. ") +
      "Vuelven a casa ⏱ ~" + this._marchEta(r) + " s.");
    await this._marchSent();
  }catch(e){ toast(shortMsg(e), true); }
};
Game.thrClaim = async function(node){
  try{
    const r = await sbRpc("wow_throne_claim", { p_token: this.me.token, p_node: node });
    modalClose();
    toast("💰 Una partida va a reclamar el tesoro de " + (r.target || "la aldea") + ". ⏱ Llega en ~" + this._marchEta(r) + " s.");
    await this._marchSent();
  }catch(e){ toast(shortMsg(e), true); }
};

Game.mktCancel = async function(id){
  try{
    await sbRpc("wow_market_cancel", { p_token: this.me.token, p_id: id });
    toast("Oferta cancelada."); await this.refresh();
  }catch(e){ toast(shortMsg(e), true); }
};
