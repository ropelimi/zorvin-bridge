// UM SUPABASE DE MENTIRA, EM HTTP — para rodar a ponte DE VERDADE contra ele.
//
// A ponte não tinha teste nenhum. Testá-la trocando o cliente do Supabase por
// um objeto falso obrigaria a mexer no `index.js` só para poder testá-lo — e um
// código que só é testável depois de alterado não está sendo testado.
//
// Aqui o caminho é outro: sobe um servidor que FALA o mesmo protocolo do
// Supabase (PostgREST + GoTrue + Storage), e a ponte roda sem saber. Ela cria o
// cliente dela, faz as consultas dela, e o que responde é isto.
//
// Cobre o que a ponte usa: select com filtros e junções embutidas, insert,
// upsert com `on_conflict`, patch, delete, a API de admin do Auth e o Storage.
import http from "node:http";

const eq = (a, b) => String(a ?? "") === String(b ?? "");

/** Converte o valor de um filtro do PostgREST ("eq.5", "in.(1,2)") no teste. */
function testeDoFiltro(bruto) {
  const [op, ...resto] = String(bruto).split(".");
  const valor = resto.join(".");
  switch (op) {
    case "eq":  return (v) => eq(v, valor);
    case "neq": return (v) => !eq(v, valor);
    case "gt":  return (v) => Number(v) > Number(valor);
    case "gte": return (v) => Number(v) >= Number(valor);
    case "lt":  return (v) => (isNaN(Number(valor)) ? String(v) < valor : Number(v) < Number(valor));
    case "lte": return (v) => (isNaN(Number(valor)) ? String(v) <= valor : Number(v) <= Number(valor));
    case "is":  return (v) => (valor === "null" ? v == null : String(v) === valor);
    case "in": {
      const lista = valor.replace(/^\(|\)$/g, "").split(",").map((x) => x.replace(/^"|"$/g, ""));
      return (v) => lista.some((x) => eq(v, x));
    }
    case "like":
    case "ilike": {
      const re = new RegExp("^" + valor.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/%/g, ".*") + "$", "i");
      return (v) => re.test(String(v ?? ""));
    }
    default: return () => true;
  }
}

/** `select=id, contato:contato_id (numero)` → o que trazer e o que juntar. */
function lerSelect(sel, esquema) {
  const embutidos = [];
  // Tira os parênteses para achar as junções, uma a uma.
  const re = /(\w+):(\w+)\s*\(([^)]*)\)/g;
  let m;
  while ((m = re.exec(sel || "")) !== null) {
    embutidos.push({ apelido: m[1], coluna: m[2], campos: m[3].split(",").map((s) => s.trim()) });
  }
  return { embutidos };
}

export function subirFalsoSupabase({ tabelas, usuarios = [], porta = 0, aoGravar } = {}) {
  const dados = tabelas;                       // { nome: [linhas] }
  const contas = usuarios.slice();             // Auth
  const arquivos = new Map();                  // Storage
  const chamadas = [];                         // tudo o que a ponte pediu
  // De qual tabela cada coluna de junção aponta. Só o que a ponte usa.
  const esquema = { contato_id: "contatos", advogado_id: "advogados", conversa_id: "conversas" };
  let seq = 1000;

  const servidor = http.createServer(async (req, res) => {
    const url = new URL(req.url, "http://x");
    const caminho = url.pathname;
    let corpo = "";
    for await (const p of req) corpo += p;
    const json = corpo ? (() => { try { return JSON.parse(corpo); } catch (_) { return null; } })() : null;
    chamadas.push({ metodo: req.method, caminho, busca: url.search, corpo: json });

    // `.single()` e `.maybeSingle()` pedem UM OBJETO, e não uma lista: o
    // cliente manda `Accept: application/vnd.pgrst.object+json` e espera o
    // objeto cru. Devolvendo lista, `dado.advogado` vem indefinido e a ponte lê
    // "conversa não encontrada" — foi assim que a primeira versão deste falso
    // reprovou a fila de envio inteira, que estava certa.
    const umSo = String(req.headers.accept || "").includes("pgrst.object");
    const responder = (codigo, obj) => {
      const corpoFinal = umSo && Array.isArray(obj) ? (obj.length ? obj[0] : null) : obj;
      if (umSo && Array.isArray(obj) && obj.length === 0) {
        res.writeHead(406, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ code: "PGRST116", message: "0 rows" }));
      }
      res.writeHead(codigo, { "Content-Type": "application/json" });
      res.end(corpoFinal === undefined ? "" : JSON.stringify(corpoFinal));
    };

    // ---------------- Auth ----------------
    if (caminho === "/auth/v1/user") {
      const jwt = String(req.headers.authorization || "").replace(/^Bearer /i, "");
      const u = contas.find((x) => x.jwt === jwt);
      if (!u) return responder(401, { message: "invalid claim" });
      return responder(200, { id: u.id, email: u.email, user_metadata: u.user_metadata || {} });
    }
    if (caminho === "/auth/v1/admin/users" && req.method === "POST") {
      const existe = contas.find((x) => eq(x.email, json.email));
      if (existe) return responder(422, { message: "User already registered" });
      const nova = { id: `u-${seq++}`, email: json.email, user_metadata: json.user_metadata || {} };
      contas.push(nova);
      return responder(200, nova);
    }
    if (caminho === "/auth/v1/admin/users" && req.method === "GET") {
      return responder(200, { users: contas, aud: "authenticated" });
    }
    if (caminho.startsWith("/auth/v1/admin/users/")) {
      const id = caminho.split("/").pop();
      const u = contas.find((x) => eq(x.id, id));
      if (!u) return responder(404, { message: "not found" });
      if (req.method === "PUT") Object.assign(u, json, { user_metadata: { ...(u.user_metadata || {}), ...(json.user_metadata || {}) } });
      return responder(200, u);
    }
    if (caminho === "/auth/v1/admin/generate_link") {
      const u = contas.find((x) => eq(x.email, json.email));
      return responder(200, { properties: { hashed_token: "hash-" + (u ? u.id : "x") },
                              action_link: "http://x/verify?token=hash", user: u || null });
    }
    if (caminho === "/auth/v1/verify" || caminho === "/auth/v1/token") {
      return responder(200, { access_token: "jwt-de-mentira", refresh_token: "r", user: contas[0] || null });
    }

    // ---------------- Storage ----------------
    if (caminho.startsWith("/storage/v1/object/")) {
      const chave = caminho.replace("/storage/v1/object/", "").replace(/^authenticated\//, "");
      if (req.method === "POST" || req.method === "PUT") { arquivos.set(chave, corpo.length); return responder(200, { Key: chave }); }
      if (req.method === "GET") { res.writeHead(200); return res.end("bytes"); }
    }

    // ---------------- PostgREST ----------------
    if (caminho.startsWith("/rest/v1/")) {
      const tabela = caminho.replace("/rest/v1/", "");
      if (!dados[tabela]) dados[tabela] = [];
      const linhas = dados[tabela];

      const filtros = [];
      let ordem = null, limite = Infinity, deslocamento = 0, sel = "*";
      for (const [k, v] of url.searchParams.entries()) {
        if (k === "select") { sel = v; continue; }
        if (k === "order") { const [c, d] = v.split("."); ordem = { c, asc: d !== "desc" }; continue; }
        if (k === "limit") { limite = Number(v); continue; }
        if (k === "offset") { deslocamento = Number(v); continue; }
        if (k === "on_conflict") continue;
        if (k === "or") {
          const partes = v.replace(/^\(|\)$/g, "").split(",");
          filtros.push((l) => partes.some((p) => {
            const i = p.indexOf(".");
            return testeDoFiltro(p.slice(i + 1))(l[p.slice(0, i)]);
          }));
          continue;
        }
        const teste = testeDoFiltro(v);
        filtros.push((l) => teste(l[k]));
      }
      const casam = () => linhas.filter((l) => filtros.every((f) => f(l)));

      if (req.method === "GET") {
        let saida = casam();
        if (ordem) saida = saida.slice().sort((a, b) => {
          const x = a[ordem.c], y = b[ordem.c];
          const cmp = x === y ? 0 : (x > y ? 1 : -1);
          return ordem.asc ? cmp : -cmp;
        });
        saida = saida.slice(deslocamento, deslocamento + limite);
        const { embutidos } = lerSelect(sel, esquema);
        if (embutidos.length) {
          saida = saida.map((l) => {
            const copia = { ...l };
            for (const e of embutidos) {
              const alvo = (dados[esquema[e.coluna]] || []).find((x) => eq(x.id, l[e.coluna]));
              copia[e.apelido] = alvo ? Object.fromEntries(e.campos.map((c) => [c, alvo[c]])) : null;
            }
            return copia;
          });
        }
        return responder(200, saida);
      }

      if (req.method === "POST") {
        const novas = Array.isArray(json) ? json : [json];
        const conflito = url.searchParams.get("on_conflict");
        const merge = String(req.headers.prefer || "").includes("merge-duplicates");
        const ignora = String(req.headers.prefer || "").includes("ignore-duplicates");
        const gravadas = [];
        for (const n of novas) {
          let alvo = null;
          if (conflito) alvo = linhas.find((l) => conflito.split(",").every((c) => eq(l[c], n[c])));
          if (alvo) {
            if (merge) Object.assign(alvo, n);
            if (!ignora || merge) gravadas.push(alvo);
            continue;
          }
          const linha = { id: n.id != null ? n.id : seq++, ...n };
          linhas.push(linha);
          gravadas.push(linha);
        }
        if (aoGravar) aoGravar(tabela, gravadas);
        return responder(201, gravadas);
      }

      if (req.method === "PATCH") {
        const alvos = casam();
        alvos.forEach((l) => Object.assign(l, json));
        if (aoGravar) aoGravar(tabela, alvos);
        return responder(200, alvos);
      }

      if (req.method === "DELETE") {
        const alvos = casam();
        alvos.forEach((l) => { const i = linhas.indexOf(l); if (i >= 0) linhas.splice(i, 1); });
        return responder(200, alvos);
      }
    }

    responder(404, { message: "não implementado: " + req.method + " " + caminho });
  });

  return new Promise((resolve) => {
    servidor.listen(porta, "127.0.0.1", () => {
      resolve({
        url: `http://127.0.0.1:${servidor.address().port}`,
        dados, contas, arquivos, chamadas,
        parar: () => new Promise((r) => servidor.close(r)),
      });
    });
  });
}

/** Uma Uazapi de mentira: aceita tudo e anota o que recebeu. */
export function subirFalsaUazapi({ porta = 0 } = {}) {
  const recebidas = [];
  const servidor = http.createServer(async (req, res) => {
    let corpo = "";
    for await (const p of req) corpo += p;
    recebidas.push({ caminho: req.url, corpo: (() => { try { return JSON.parse(corpo); } catch (_) { return corpo; } })() });
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ id: "uazapi-" + recebidas.length, messageid: "uazapi-" + recebidas.length }));
  });
  return new Promise((resolve) => {
    servidor.listen(porta, "127.0.0.1", () => {
      resolve({
        url: `http://127.0.0.1:${servidor.address().port}`,
        recebidas,
        parar: () => new Promise((r) => servidor.close(r)),
      });
    });
  });
}
