const fs = require("fs");
const dir = "/root/.config/openchamber/chats/2026-10-06/session-fab1e1a3-b35e-438b-a702-d1a2de364493/wow-reinos/";
const lines = fs.readFileSync(dir + "wow-schema.sql", "utf8").split("\n");
const idx = lines.findIndex(l => l.includes("APENDICE PvP v3"));
const base = lines.slice(0, idx - 2).join("\n");
const pvp = fs.readFileSync(dir + "wow-pvp.sql", "utf8");
const content = fs.readFileSync(dir + "wow-content.sql", "utf8");
const admin = fs.readFileSync(dir + "wow-admin.sql", "utf8");
const header = "\n-- ================================================================\n" +
  "-- APENDICE PvP v3: COMBATE POR RONDAS (contadores + moral) + ESPIONAJE\n" +
  "--   (generado desde wow-pvp.sql)\n" +
  "-- ================================================================\n";
const cheader = "\n-- ================================================================\n" +
  "-- APENDICE CONTENIDO v4: EDIFICIOS Y TROPAS NUEVAS (economia)\n" +
  "--   (generado desde wow-content.sql)\n" +
  "-- ================================================================\n";
const aheader = "\n-- ================================================================\n" +
  "-- APENDICE ADMIN: PANEL DE GESTION (generado desde wow-admin.sql)\n" +
  "-- ================================================================\n";
const market = fs.readFileSync(dir + "wow-market.sql", "utf8");
const mheader = "\n-- ================================================================\n" +
  "-- APENDICE MERCADO: COMPRA/VENTA DE RECURSOS Y TROPAS CON CUP\n" +
  "--   (generado desde wow-market.sql)\n";
const throne = fs.readFileSync(dir + "wow-throne.sql", "utf8");
const theader = "\n-- ================================================================\n" +
  "-- APENDICE TRONOS: FORTALEZAS CENTRALES CONQUISTABLES + TRIBUTO\n" +
  "--   (generado desde wow-throne.sql)\n" +
  "-- ================================================================\n";
const aldea = fs.readFileSync(dir + "wow-aldea.sql", "utf8");
const aldheader = "\n-- ================================================================\n" +
  "-- APENDICE ALDEAS: POBLADOS NEUTRALES CONQUISTABLES + TRIBUTO\n" +
  "--   (generado desde wow-aldea.sql)\n" +
  "-- ================================================================\n";
const alliance = fs.readFileSync(dir + "wow-alliance.sql", "utf8");
const alheader = "\n-- ================================================================\n" +
  "-- APENDICE ALIANZAS: RANKING Y GUERRAS ENTRE ALIANZAS\n" +
  "--   (generado desde wow-alliance.sql)\n" +
  "-- ================================================================\n";
const chat = fs.readFileSync(dir + "wow-chat.sql", "utf8");
const chatheader = "\n-- ================================================================\n" +
  "-- APENDICE CHAT GLOBAL: mensajes publicos de todos los jugadores\n" +
  "--   (generado desde wow-chat.sql)\n" +
  "-- ================================================================\n";
const online = fs.readFileSync(dir + "wow-online.sql", "utf8");
const onheader = "\n-- ================================================================\n" +
  "-- APENDICE ONLINE: contador de reinos en linea\n" +
  "--   (generado desde wow-online.sql)\n" +
  "-- ================================================================\n";
const cont4 = fs.readFileSync(dir + "wow-cont4.sql", "utf8");
const c4header = "\n-- ================================================================\n" +
  "-- APENDICE 4 CONTINENTES: mapa 2x2 + reparto de registros\n" +
  "--   (generado desde wow-cont4.sql)\n" +
  "-- ================================================================\n";
const bots = fs.readFileSync(dir + "wow-bots.sql", "utf8");
const botsheader = "\n-- ================================================================\n" +
  "-- APENDICE REINOS AUTOMATICOS: reinos que juegan solos (pg_cron)\n" +
  "--   (generado desde wow-bots.sql)\n" +
  "-- ================================================================\n";
const allynode = fs.readFileSync(dir + "wow-allynode.sql", "utf8");
const anheader = "\n-- ================================================================\n" +
  "-- APENDICE NODOS DE ALIANZA: tronos/aldeas a nombre de la alianza + arcon\n" +
  "--   (generado desde wow-allynode.sql)\n" +
  "-- ================================================================\n";
const emblems = fs.readFileSync(dir + "wow-emblems.sql", "utf8");
const emheader = "\n-- ================================================================\n" +
  "-- APENDICE EMBLEMA DE ALIANZA: el lider elige el icono del clan\n" +
  "--   (generado desde wow-emblems.sql)\n" +
  "-- ================================================================\n";
const botswitch = fs.readFileSync(dir + "wow-botswitch.sql", "utf8");
const bsheader = "\n-- ================================================================\n" +
  "-- APENDICE INTERRUPTOR DE REINOS AUTOMATICOS: un boton enciende/apaga todos\n" +
  "--   (generado desde wow-botswitch.sql)\n" +
  "-- ================================================================\n";
const diplo = fs.readFileSync(dir + "wow-diplo.sql", "utf8");
const diploheader = "\n-- ================================================================\n" +
  "-- APENDICE DIPLOMACIA: pactos de no agresion (treguas) entre alianzas\n" +
  "--   (generado desde wow-diplo.sql)\n" +
  "-- ================================================================\n";
const botmarket = fs.readFileSync(dir + "wow-botmarket.sql", "utf8");
const bmheader = "\n-- ================================================================\n" +
  "-- APENDICE MERCADO DE LOS REINOS AUTOMATICOS: venden recursos y tropas por CUP\n" +
  "--   (generado desde wow-botmarket.sql)\n" +
  "-- ================================================================\n";
const contrib = fs.readFileSync(dir + "wow-nodecontrib.sql", "utf8");
const ncheader = "\n-- ================================================================\n" +
  "-- APENDICE APORTES: cada jugador solo retira las tropas que aportó\n" +
  "--   (generado desde wow-nodecontrib.sql)\n" +
  "-- ================================================================\n";
const timetrust = fs.readFileSync(dir + "wow-timetrust.sql", "utf8");
const ttheader = "\n-- ================================================================\n" +
  "-- APENDICE CONFIANZA DE TIEMPO: el reino no puede ganar tiempo con el reloj del PC\n" +
  "--   (generado desde wow-timetrust.sql)\n" +
  "-- ================================================================\n";
const prod = fs.readFileSync(dir + "wow-prod.sql", "utf8");
const prodheader = "\n-- ================================================================\n" +
  "-- APENDICE CONTROL DE PRODUCCION: el admin regula lo que producen los reinos\n" +
  "--   (generado desde wow-prod.sql)\n" +
  "-- ================================================================\n";
const rank = fs.readFileSync(dir + "wow-rank.sql", "utf8");
const rankheader = "\n-- ================================================================\n" +
  "-- APENDICE RANKING DE TROPAS: los puntos cuentan las tropas esten donde esten\n" +
  "--   (generado desde wow-rank.sql)\n" +
  "-- ================================================================\n";
const gift = fs.readFileSync(dir + "wow-gift.sql", "utf8");
const giftheader = "\n-- ================================================================\n" +
  "-- APENDICE CARRUAJE DE RECURSOS: enviar oro/madera/mineral a un aliado\n" +
  "--   (generado desde wow-gift.sql)\n" +
  "-- ================================================================\n";
const madam = fs.readFileSync(dir + "wow-madam.sql", "utf8");
const madamheader = "\n-- ================================================================\n" +
  "-- APENDICE MADAM DE LA TABERNA: contrato de acompanantes (+1 ataque/tropa)\n" +
  "--   (generado desde wow-madam.sql)\n" +
  "-- ================================================================\n";
const miners = fs.readFileSync(dir + "wow-miners.sql", "utf8");
const minersheader = "\n-- ================================================================\n" +
  "-- APENDICE MINEROS Y LEÑADORES: segundo contrato de la taberna (duplica produccion)\n" +
  "--   (generado desde wow-miners.sql)\n" +
  "-- ================================================================\n";
const joint = fs.readFileSync(dir + "wow-joint.sql", "utf8");
const jointheader = "\n-- ================================================================\n" +
  "-- APENDICE ATAQUES CONJUNTOS: una batalla con el ejercito de toda la alianza\n" +
  "--   (generado desde wow-joint.sql)\n" +
  "-- ================================================================\n";
const botjoint = fs.readFileSync(dir + "wow-botjoint.sql", "utf8");
const botjointheader = "\n-- ================================================================\n" +
  "-- APENDICE ATAQUES CONJUNTOS CON LOS REINOS AUTOMATICOS: los bots aportan, convocan y lanzan\n" +
  "--   (generado desde wow-botjoint.sql)\n" +
  "-- ================================================================\n";
const out = base.replace(/\s*$/, "\n") + header + pvp + cheader + content + aheader + admin + mheader + market + theader + throne + aldheader + aldea + alheader + alliance + chatheader + chat + onheader + online + c4header + cont4 + botsheader + bots + anheader + allynode + diploheader + diplo + bsheader + botswitch + emheader + emblems + bmheader + botmarket + ncheader + contrib + ttheader + timetrust + prodheader + prod + rankheader + rank + giftheader + gift + madamheader + madam + minersheader + miners + jointheader + joint + botjointheader + botjoint;
fs.writeFileSync(dir + "wow-schema.sql", out);
console.log("wow-schema.sql ->", out.length, "bytes,", out.split("\n").length, "lines");
