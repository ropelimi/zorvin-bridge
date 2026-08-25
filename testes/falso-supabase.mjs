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
  // `not.` INVERTE O QUE VEM DEPOIS. É como o PostgREST escreve `.not('col',
  // 'is', null)`: `col=not.is.null`.
  //
  // Sem isto, "not" caía no `default` e o filtro era IGNORADO — a bancada
  // devolvia tudo e a conferência passava por não haver filtro nenhum, e não
  // por o filtro estar certo. Um verde que fala de outro assunto.
  if (String(bruto).startsWith("not.")) {
    const dentro = testeDoFiltro(String(bruto).slice(4));
    return (v) => !dentro(v);
  }
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

// O TETO DE MIL LINHAS.
//
// O PostgREST devolve no máximo 1000 linhas por consulta e NÃO avisa: a
// resposta vem com 1000 linhas e cara de resposta inteira. Quem escreveu
// `select(...)` sem paginar acha que leu tudo, e o que passar de mil some em
// silêncio. É o defeito que mais se repetiu neste projeto — apareceu no Painel,
// na busca, na lista de conversas, nos selos de não lidas, na agenda.
//
// Um falso que devolve tudo esconde justamente esse defeito: o teste passa aqui
// e quebra em produção, no dia em que a tabela cresce. Então este falso também
// corta em mil.
const TETO_POSTGREST = 1000;

export function subirFalsoSupabase({ tabelas, usuarios = [], porta = 0, aoGravar, quebrar, bilhetesQueFalham = 0, authNoChao = false, jwksAssimetrico = false } = {}) {
  const dados = tabelas;                       // { nome: [linhas] }
  const contas = usuarios.slice();             // Auth
  const arquivos = new Map();                  // Storage
  // O CABEÇALHO importa tanto quanto os bytes: é ele que decide se cada
  // navegador vai rebaixar o arquivo de novo daqui a uma hora ou daqui a um ano.
  const cabecalhosDeUpload = new Map();         // caminho → cache-control enviado
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
    // O AUTH INTEIRO NO CHÃO, que foi o que aconteceu em 19/08: o banco
    // respondendo em 168ms e o `/auth/v1/*` devolvendo uma página do
    // Cloudflare com "Error 521 — o servidor de origem não está respondendo".
    // Sem poder imitar isso aqui, o caminho que existe justamente para esse
    // dia seria código que ninguém nunca viu funcionar. Repare que é só o
    // Auth: as rotas de banco continuam respondendo, como continuaram lá.
    if (authNoChao && caminho.startsWith("/auth/v1/")) {
      res.writeHead(521, { "Content-Type": "text/html" });
      return res.end("<html><title>xnhc… | 521: Web server is down</title></html>");
    }
    // A LISTA PÚBLICA DE CHAVES. Vazia quer dizer "este projeto assina com o
    // segredo compartilhado de sempre"; com uma chave de curva elíptica
    // dentro, quer dizer que ele migrou — e aí os bilhetes que a ponte assina
    // deixam de valer.
    if (caminho === "/auth/v1/.well-known/jwks.json") {
      return responder(200, { keys: jwksAssimetrico
        ? [{ kty: "EC", crv: "P-256", alg: "ES256", kid: "abc", x: "x", y: "y" }]
        : [] });
    }
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
      // O AUTH QUE FALHA NA PRIMEIRA E RESPONDE NA SEGUNDA. É o que aconteceu
      // em produção: 20 segundos sem responder numa tentativa, pronto na
      // seguinte. Sem poder imitar isso, a segunda chance seria código que
      // ninguém nunca viu funcionar.
      if (bilhetesQueFalham > 0) { bilhetesQueFalham -= 1; return responder(500, { message: "auth indisponível" }); }
      // A FORMA É PLANA, como o GoTrue de verdade responde: `hashed_token` e
      // companhia no primeiro nível, junto com os campos do usuário. Quem
      // agrupa isso em `properties` é o cliente do Supabase, depois de receber.
      //
      // Aqui estava agrupado já — e por isso o cliente devolvia `properties`
      // vazio, a entrada falhava em "não consegui abrir a sessão", e NENHUM
      // teste pegava, porque nenhum chegava a entrar de verdade. Um falso que
      // responde numa forma que o de verdade não usa não está provando nada.
      const u = contas.find((x) => eq(x.email, json.email));
      return responder(200, {
        ...(u || {}),
        action_link: "http://x/verify?token=hash",
        email_otp: "000000",
        hashed_token: "hash-" + (u ? u.id : "x"),
        verification_type: json.type || "magiclink",
        redirect_to: "http://x/",
      });
    }
    if (caminho === "/auth/v1/verify" || caminho === "/auth/v1/token") {
      return responder(200, { access_token: "jwt-de-mentira", refresh_token: "r", user: contas[0] || null });
    }

    // ---------------- Storage ----------------
    if (caminho.startsWith("/storage/v1/object/")) {
      const chave = caminho.replace("/storage/v1/object/", "").replace(/^authenticated\//, "");
      if (req.method === "POST" || req.method === "PUT") {
        arquivos.set(chave, corpo.length);
        cabecalhosDeUpload.set(chave, String(req.headers["cache-control"] || ""));
        return responder(200, { Key: chave });
      }
      if (req.method === "GET") { res.writeHead(200); return res.end("bytes"); }
    }

    // ---------------- PostgREST ----------------
    if (caminho.startsWith("/rest/v1/")) {
      const tabela = caminho.replace("/rest/v1/", "");
      if (!dados[tabela]) dados[tabela] = [];
      const linhas = dados[tabela];

      // Para provar o que acontece quando UMA escrita falha no meio de uma
      // rotina de várias. A rede cai, o banco recusa, o Supabase devolve 500 —
      // e o que importa é o estado em que a rotina deixa os dados.
      if (quebrar) {
        const motivo = quebrar(req.method, tabela, url.search);
        if (motivo) {
          res.writeHead(500, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ message: String(motivo), code: "XX000" }));
        }
      }

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

      // A CONTAGEM, que o PostgREST responde no cabeçalho `Content-Range`.
      //
      // `select('id', { count: 'exact', head: true })` quer dizer "não me mande
      // as linhas, me diga QUANTAS são" — e isso vira, na rede, um HTTP HEAD
      // com `Prefer: count=exact`. Foi MEDIDO, não suposto:
      //
      //     método : HEAD
      //     headers: [['prefer', 'count=exact']]
      //
      // Este falso não tratava HEAD: a consulta caía no fim do arquivo e o
      // cliente recebia contagem indefinida. Uma conferência sobre contagem
      // passaria medindo zero — verde falando de outro assunto.
      //
      // O NÚMERO É O TOTAL QUE CASA COM O FILTRO, e não o que caberia numa
      // página. É justamente essa diferença — "quantos existem" contra "quantos
      // vieram" — que faz alguém pedir a contagem em vez de contar a resposta.
      if (req.method === "HEAD") {
        const total = casam().length;
        res.writeHead(200, {
          "Content-Type": "application/json",
          "Content-Range": `0-${Math.max(total - 1, 0)}/${total}`,
        });
        return res.end();
      }

      if (req.method === "GET") {
        let saida = casam();
        if (ordem) saida = saida.slice().sort((a, b) => {
          const x = a[ordem.c], y = b[ordem.c];
          const cmp = x === y ? 0 : (x > y ? 1 : -1);
          return ordem.asc ? cmp : -cmp;
        });
        saida = saida.slice(deslocamento, deslocamento + Math.min(limite, TETO_POSTGREST));
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
        dados, contas, arquivos, cabecalhosDeUpload, chamadas,
        parar: () => new Promise((r) => servidor.close(r)),
      });
    });
  });
}

// UM VANTORO DE MENTIRA — o dono da permissão.
//
// Quem pode ver o quê é decidido no Vantoro; a ponte só copia a decisão para
// dentro do Zorvin. Para conferir essa cópia sem um Vantoro de verdade, basta
// alguém que responda `/usuarios` com a mesma forma que ele responde.
// `naoJson` faz este Vantoro responder o que uma HOSPEDAGEM responde quando o
// serviço não está lá: uma página, e não os dados. É o caso real de 21/08 — o
// workspace suspenso por consumo devolvendo HTML —, que a ponte resumia a
// "Resposta inválida do Vantoro" e emendava com "confira o token".
//   naoJson: { status: 503, corpo: "<html>…</html>" }
export function subirFalsoVantoro({ usuarios = [], porta = 0, demora = 0, naoJson = null,
                                    dormeAsPrimeiras = 0 } = {}) {
  // `dormeAsPrimeiras` imita a Render hibernando: as N primeiras chamadas
  // levam uma página de erro NA HORA, e a partir daí o serviço está de pé.
  let aindaDormindo = dormeAsPrimeiras;
  // Contador de atividades, para cada nota receber um id diferente — dois ids
  // iguais esconderiam uma nota gravada em cima da outra.
  let atividades = 0;
  const recebidas = [];
  const lista = usuarios.slice();
  const servidor = http.createServer(async (req, res) => {
    const url = new URL(req.url, "http://x");
    let corpo = "";
    for await (const p of req) corpo += p;
    const json = corpo ? (() => { try { return JSON.parse(corpo); } catch (_) { return corpo; } })() : null;
    recebidas.push({ metodo: req.method, caminho: url.pathname, corpo: json,
                     autorizacao: req.headers.authorization || null });
    if (demora) await new Promise((r) => setTimeout(r, demora));
    if (aindaDormindo > 0) {
      aindaDormindo -= 1;
      res.writeHead(502, { "Content-Type": "text/html" });
      return res.end("<html><body>Service is starting</body></html>");
    }
    if (naoJson) {
      res.writeHead(naoJson.status || 503, { "Content-Type": naoJson.tipo || "text/html" });
      return res.end(naoJson.corpo === undefined
        ? "<html><body>Service Suspended</body></html>" : naoJson.corpo);
    }
    res.writeHead(200, { "Content-Type": "application/json" });
    if (url.pathname === "/usuarios") return res.end(JSON.stringify({ ok: true, usuarios: lista }));

    // A CONFERÊNCIA DA SENHA. É o Vantoro quem responde se a pessoa é quem diz
    // ser — a ponte não guarda senha nenhuma. Sem esta rota aqui, a entrada
    // nunca chegava aos passos seguintes na bancada, e eles ficavam sem prova.
    if (url.pathname === "/auth/login") {
      const quem = lista.find((u) => String(u.login) === String(json && json.login));
      if (!quem) {
        res.writeHead(401, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ ok: false, erro: "Login ou senha incorretos." }));
      }
      return res.end(JSON.stringify({ ok: true, usuario: quem }));
    }

    // A NOTA, RESPONDIDA COMO O VANTORO DE VERDADE RESPONDE: com o id da
    // atividade que ela virou (`core/api.py`, rota `api_cliente_nota`).
    //
    // Isto não é enfeite. É por esse id que a ponte grava
    // `notas.vantoro_atividade_id`, e é essa marca que faz o retroativo rodado
    // duas vezes não subir tudo de novo. Enquanto este de mentira respondia
    // `{ok:true}` seco, a ponte certa parecia errada na bancada.
    if (/^\/clientes\/[^/]+\/nota$/.test(url.pathname)) {
      atividades += 1;
      return res.end(JSON.stringify({ ok: true, criada: true,
                                      atividade: { id: atividades, processo_id: null } }));
    }

    res.end(JSON.stringify({ ok: true }));
  });
  return new Promise((resolve) => {
    servidor.listen(porta, "127.0.0.1", () => {
      resolve({
        url: `http://127.0.0.1:${servidor.address().port}`,
        recebidas, usuarios: lista,
        parar: () => new Promise((r) => servidor.close(r)),
      });
    });
  });
}

// Uma Uazapi de mentira: aceita tudo e anota o que recebeu.
//
// `historico` é o que ela devolve em /message/find, paginado como a de verdade.
// `sufixo` é a terminação de chatid que ela reconhece — a Uazapi varia entre
// `@s.whatsapp.net` e `@c.us` conforme a versão, e a ponte descobre qual é
// tentando as duas.
//
// `rotaDeDownload` é a única rota de download que responde; as outras devolvem
// 404, como as que não existem naquela versão. É por isso que dá para MEDIR
// quantas tentativas perdidas a ponte faz por mídia.
export function subirFalsaUazapi({
  porta = 0, historico = [], sufixo = "@s.whatsapp.net",
  rotaDeDownload = "/message/downloadmedia", arquivo = null,
  // Como o envio falha, quando se quer que ele falhe: `{ status, corpo }`.
  // É o único jeito de exercitar a tradução do motivo do erro sem depender de
  // uma Uazapi de verdade recusando uma mensagem.
  falharEnvio = null,
  // A foto de perfil, e por qual rota ela é servida. Como no download de
  // mídia, a rota varia com a versão do servidor — as outras devolvem 404, e é
  // isso que faz a ponte ter de procurar (e faz o teste medir se ela procura).
  // `null` em `rotaDeFoto` é o servidor em que NENHUMA serve.
  rotaDeFoto = "/chat/details",
  foto = { imagePreview: "https://falsa/mini.jpg", imgUrl: "https://falsa/cheia.jpg" },
  // O que o endereço direto (`/files/…`) devolve. `null` é o endereço que já
  // não serve mais — que é o caso realista de um resgate tardio demais.
  arquivoPorEndereco = Buffer.from("%PDF-1.4 um documento de mentira"),
  // QUANTO O DOWNLOAD DEMORA A RESPONDER, em milissegundos.
  //
  // Na Uazapi de verdade isto não é zero nunca: ela vai buscar o arquivo nos
  // servidores do WhatsApp, e uma foto de celular são alguns megabytes. Com a
  // bancada respondendo instantaneamente, uma lentidão que existe em produção
  // não aparece em prova nenhuma — foi exatamente o que aconteceu, e o relato
  // veio de quem usa ("demora para aparecer o arquivo na conversa"), não daqui.
  //
  // Com o botão, dá para MEDIR: quanto tempo passa entre o webhook chegar e a
  // mensagem existir no banco, que é o instante em que a bolha nasce na tela.
  demoraDoDownload = 0,
} = {}) {
  const recebidas = [];
  const ROTAS_DE_DOWNLOAD = ["/message/downloadmedia", "/message/download", "/downloadmedia"];
  const servidor = http.createServer(async (req, res) => {
    const url = new URL(req.url, "http://x");
    let corpo = "";
    for await (const p of req) corpo += p;
    const json = (() => { try { return JSON.parse(corpo); } catch (_) { return corpo; } })();
    recebidas.push({ caminho: req.url, corpo: json });
    const responder = (codigo, obj) => {
      res.writeHead(codigo, { "Content-Type": "application/json" });
      res.end(JSON.stringify(obj));
    };

    if (falharEnvio && /^\/send\//.test(url.pathname)) {
      res.writeHead(falharEnvio.status || 400, { "Content-Type": "application/json" });
      return res.end(typeof falharEnvio.corpo === "string"
        ? falharEnvio.corpo : JSON.stringify(falharEnvio.corpo || {}));
    }

    if (url.pathname === "/message/find") {
      const pedido = json || {};
      if (!String(pedido.chatid || "").endsWith(sufixo)) return responder(200, { messages: [] });
      const de = Number(pedido.offset || 0);
      const quantas = Number(pedido.limit || 100);
      return responder(200, { messages: historico.slice(de, de + quantas) });
    }

    const ROTAS_DE_FOTO = ["/chat/details", "/chat/GetNameAndImageURL", "/contact/picture"];
    if (ROTAS_DE_FOTO.includes(url.pathname)) {
      if (url.pathname !== rotaDeFoto) return responder(404, { erro: "não existe nesta versão" });
      return responder(200, foto);
    }

    // O ARQUIVO SERVIDO POR ENDEREÇO DIRETO. É o que a Uazapi manda no
    // `FileURL` de um `messages_update`, e é por onde o resgate do anexo vazio
    // passa. Sem isto, a prova do resgate provaria só a intenção.
    if (url.pathname.startsWith("/files/")) {
      if (arquivoPorEndereco === null) { res.writeHead(404); return res.end("sumiu"); }
      res.writeHead(200, { "Content-Type": "application/pdf" });
      return res.end(arquivoPorEndereco);
    }

    if (ROTAS_DE_DOWNLOAD.includes(url.pathname)) {
      if (url.pathname !== rotaDeDownload) return responder(404, { erro: "não existe nesta versão" });
      if (demoraDoDownload > 0) {
        await new Promise((r) => setTimeout(r, demoraDoDownload));
      }
      return responder(200, {
        mimetype: "image/jpeg",
        file: (arquivo || Buffer.from("uma-foto-de-mentira".repeat(20))).toString("base64"),
      });
    }

    responder(200, { id: "uazapi-" + recebidas.length, messageid: "uazapi-" + recebidas.length });
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
