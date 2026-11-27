// PROVA DA PONTE — o `index.js` de verdade, contra um Supabase e uma Uazapi
// de mentira que falam o mesmo protocolo.
import { spawn } from "node:child_process";
import http from "node:http";
import crypto from "node:crypto";
import fs from "node:fs";
import { subirFalsoSupabase, subirFalsaUazapi, subirFalsoVantoro } from "./falso-supabase.mjs";

let falhas = 0, feitas = 0;
const ok = (nome, cond, det = "") => {
  feitas++;
  if (cond) console.log(`  ok   ${nome}`);
  else { falhas++; console.log(`  FALHA ${nome}${det ? " — " + det : ""}`); }
};
const espera = (ms) => new Promise((r) => setTimeout(r, ms));

// UMA PORTA LIVRE DE VERDADE, pedida ao sistema.
//
// Antes isto era `3000 + Math.floor(Math.random() * 900)`, e sorteio não é
// escolha: duas provas podiam tirar a mesma porta, e aí a segunda ponte não
// subia — mas `subirTudo` devolvia a porta assim mesmo, e a prova falhava lá
// adiante, longe da causa.
//
// Pior: 3659 está na LISTA DE PORTAS BLOQUEADAS da especificação do `fetch`,
// que o Node aplica. Caindo nela, o `fetch` recusa com "bad port" antes de
// tentar conectar. Como o sorteio mudava a cada rodada, o estouro aparecia num
// bloco diferente a cada vez e passava por instabilidade da máquina.
//
// Pedir a porta ao sistema (`listen(0)`) resolve os dois: ele só oferece porta
// livre, e nunca uma da lista bloqueada.
async function portaLivre() {
  return new Promise((resolve, reject) => {
    const s = http.createServer();
    s.on("error", reject);
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

const TELEFONE = { id: "adv-1", nome: "Comercial", numero: "5567900000001",
                   token: "tok-uazapi", servidor: null, ativo: true, departamento_id: 1 };

async function subirTudo(env = {}, { tabelas = {}, vantoro = null, quebrar, semColunas, semTabelas, uazapi = {}, contas = null, bilhetesQueFalham = 0, authNoChao = false, jwksAssimetrico = false, rpcs = {}, deposito = {}, aoGravar } = {}) {
  const uaz = await subirFalsaUazapi(uazapi);
  TELEFONE.servidor = uaz.url;
  const van = vantoro ? await subirFalsoVantoro(vantoro) : null;
  const sb = await subirFalsoSupabase({
    quebrar, semColunas, semTabelas, bilhetesQueFalham, rpcs, deposito, aoGravar,
    tabelas: {
      advogados: [{ ...TELEFONE }],
      departamentos: [{ id: 1, nome: "Comercial", slug: "comercial", ordem: 1, ativo: true }],
      usuarios: [], contatos: [], conversas: [], mensagens: [], fila_envio: [],
      permissoes: [], conversa_tags: [], notas: [], eventos_recebidos: [],
      ...tabelas,
    },
    // As contas do Auth. Separadas da tabela `usuarios` de propósito: são duas
    // coisas diferentes no Supabase de verdade, e a entrada mexe nas duas.
    usuarios: contas || [{ id: "u1", email: "rodrigo@x", jwt: "jwt-bom", user_metadata: { nome: "Rodrigo" } }],
    authNoChao, jwksAssimetrico,
  });
  const porta = await portaLivre();
  // O caminho sai DESTE arquivo, e não do diretório de onde se chamou. Com
  // "../index.js" solto, `npm test` a partir da raiz procurava a ponte um nível
  // acima do projeto e nada subia — o teste só funcionava quando rodado de
  // dentro de `testes/`, o que ninguém adivinha.
  const PONTE = new URL("../index.js", import.meta.url).pathname;
  const filho = spawn("node", [PONTE], {
    env: { ...process.env, PORT: String(porta),
           SUPABASE_URL: sb.url, SUPABASE_SERVICE_KEY: "chave-de-mentira",
           VANTORO_API_URL: van ? van.url : "", VANTORO_API_TOKEN: van ? "tok-vantoro" : "",
           // O RESGATE DEPOIS DE SUBIR fica para daqui a uma hora, e não para
           // daqui a um minuto: uma prova longa veria, no meio dela, a ponte
           // indo atrás de um anexo vazio que a própria prova plantou — e a
           // conta de pedidos dela mudaria de assunto. A seção 72, que é a
           // dele, encurta.
           RESGATE_AO_SUBIR_MS: "3600000",
           // O RESGATE DO HISTÓRICO, pelo mesmo motivo: ele lê a caixa de
           // entrada e `zorvin_sementes` uma vez, e no meio de outra prova
           // essas leituras mudariam a conta de pedidos dela. A seção 77, que
           // é a dele, encurta.
           RESGATE_DO_HISTORICO_MS: "3600000",
           // A TRANSCRIÇÃO AUTOMÁTICA, pelo mesmo motivo: numa prova que liga a
           // chave do Groq para o CLIQUE (seção 56), a rodada pegaria sozinha
           // os áudios da cena e a conta de idas ao Groq mudaria de assunto. A
           // seção 84, que é a dela, encurta.
           TRANSCRICAO_PRIMEIRA_MS: "3600000",
           TRANSCRICAO_INTERVALO_MS: "3600000",
           // A IA QUE MOVE O FUNIL, pelo mesmo motivo: numa prova que liga a
           // chave da Anthropic para o copiloto, a rodada perguntaria ao banco
           // quem ler e mudaria a conta de pedidos dela. A seção 92, que é a
           // dela, encurta.
           FUNIL_IA_PRIMEIRA_MS: "3600000",
           FUNIL_IA_INTERVALO_MS: "3600000",
           // O ACOMPANHAMENTO POR ETAPA, pelo mesmo motivo: a rodada chama uma
           // função do banco, e no meio de outra prova esse pedido mudaria a
           // conta dela. A seção 94, que é a dela, encurta.
           ACOMPANHAMENTO_PRIMEIRA_MS: "3600000",
           ACOMPANHAMENTO_INTERVALO_MS: "3600000",
           // O COPILOTO QUE APRENDE, pelo mesmo motivo: numa prova que liga a
           // chave da Anthropic para o copiloto, a rodada perguntaria ao banco
           // quem tem o que aprender e mudaria a conta de pedidos dela. A
           // seção 102, que é a dela, encurta.
           COPILOTO_APRENDER_PRIMEIRA_MS: "3600000",
           COPILOTO_APRENDER_INTERVALO_MS: "3600000",
           // O QUAZAR À NOITE, pelo mesmo motivo: a rodada apaga as linhas
           // presas e pergunta ao banco quem espera, e isso mudaria a conta de
           // pedidos de outra prova. A seção 111, que é a dela, encurta.
           QUAZAR_NOITE_PRIMEIRA_MS: "3600000",
           QUAZAR_NOITE_INTERVALO_MS: "3600000",
           // O QUAZAR DE DIA, pelo mesmo motivo. A seção 123 encurta.
           QUAZAR_DIA_PRIMEIRA_MS: "3600000",
           QUAZAR_DIA_INTERVALO_MS: "3600000",
           // A FAXINA DO QUAZAR, pelo mesmo motivo: ela chama funções do banco
           // e grava "Já tratei". A seção 133 encurta.
           FAXINA_PRIMEIRA_MS: "3600000",
           FAXINA_INTERVALO_MS: "3600000",
           // QUEM PEDE ATENÇÃO (066), pelo mesmo motivo: a rodada pergunta ao
           // Vantoro e grava a lista no banco. A seção 136 encurta.
           ATENCAO_PRIMEIRA_MS: "3600000",
           ATENCAO_INTERVALO_MS: "3600000",
           // AS ETIQUETAS DO VANTORO (075), pelo mesmo motivo. A seção 156 encurta.
           ETIQUETAS_PRIMEIRA_MS: "3600000",
           ETIQUETAS_INTERVALO_MS: "3600000",
           // O AVISO À EQUIPE DE QUEM PEDE ATENÇÃO (068), pelo mesmo motivo: a
           // rodada chama uma função do banco. A seção 139 encurta.
           ATENCAO_AVISOS_PRIMEIRA_MS: "3600000",
           ATENCAO_AVISOS_INTERVALO_MS: "3600000",
           // O QUAZAR QUE RESPONDE QUEM ESPERA (069), pelo mesmo motivo: a rodada
           // chama duas funções do banco e põe mensagens na fila. A seção 141
           // encurta.
           QUAZAR_RESPONDE_PRIMEIRA_MS: "3600000",
           QUAZAR_RESPONDE_INTERVALO_MS: "3600000",
           // A IDENTIFICAÇÃO PELO CPF EM SEGUNDO PLANO (26/11): a rodada lê as
           // mensagens de cliente e pergunta ao Vantoro. A seção 154 encurta.
           IDENTIFICAR_PRIMEIRA_MS: "3600000",
           IDENTIFICAR_INTERVALO_MS: "3600000",
           ...env },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const registro = [];
  filho.stdout.on("data", (d) => registro.push(String(d)));
  filho.stderr.on("data", (d) => registro.push(String(d)));
  // Espera a porta responder — E RECLAMA SE NUNCA RESPONDER.
  //
  // Antes o laço desistia calado e `subirTudo` devolvia a porta assim mesmo. A
  // ponte que não subiu só era percebida na primeira conferência que a usasse,
  // com uma mensagem que não menciona a ponte — e o que ela mostrava era o
  // ASSUNTO daquela conferência, não a causa. Ficar sem subir é falha da
  // bancada, e falha de bancada tem de dizer o próprio nome.
  let subiu = false;
  for (let i = 0; i < 60; i++) {
    try { await fetch(`http://127.0.0.1:${porta}/ping`); subiu = true; break; }
    catch (_) { await espera(120); }
  }
  if (!subiu) {
    filho.kill(); await sb.parar(); await uaz.parar(); if (van) await van.parar();
    throw new Error(`a ponte não subiu na porta ${porta} em 7s. Log dela:\n`
                    + registro.join("").slice(-2000));
  }
  // `filho` VAI JUNTO, e não é detalhe de encanamento: o desligamento com calma
  // só se prova mandando o sinal de verdade (SIGTERM) e esperando o processo
  // sair. Sem o processo em mãos, a única forma seria chamar uma função
  // exportada só para o teste — que provaria a função, e não o sistema.
  return { sb, uaz, van, porta, registro, filho,
           /** Espera o processo sair e devolve o código. `null` se demorar. */
           esperarSair: (ms = 30000) => new Promise((resolve) => {
             if (filho.exitCode !== null) return resolve(filho.exitCode);
             const relogio = setTimeout(() => resolve(null), ms);
             filho.on('exit', (codigo) => { clearTimeout(relogio); resolve(codigo ?? 0); });
           }),
           parar: async () => {
             filho.kill(); await sb.parar(); await uaz.parar();
             if (van) await van.parar();
           } };
}

// A rodada de sincronização sai 20 segundos depois de a ponte subir, e daí em
// diante a cada 3 minutos. Esperar por ela é o preço de exercitar a rotina de
// verdade, pela porta por onde ela roda em produção — em vez de chamar uma
// função exportada só para o teste, que provaria a função e não o sistema.
async function esperarARodada(t) {
  for (let i = 0; i < 120; i++) {
    await espera(500);
    if (t.van && t.van.recebidas.some((c) => c.caminho === "/usuarios")) { await espera(1500); return true; }
  }
  return false;
}

/** Uma mensagem recebida, no formato que a Uazapi manda. */
const mensagemDaUazapi = (texto, id) => ({
  EventType: "messages",
  owner: TELEFONE.numero,
  message: {
    id, messageid: id, chatid: "5511999998888@s.whatsapp.net",
    sender: "5511999998888@s.whatsapp.net", fromMe: false, isGroup: false,
    messageType: "conversation", text: texto, content: texto,
    messageTimestamp: Date.now(), wasSentByApi: false,
    senderName: "Cliente Teste",
  },
});
// ============================================================
//  155. AS ETIQUETAS QUE VÊM DO VANTORO (075), num Postgres de verdade (27/11)
//
//  A blindagem e os tipos de subsídio de cada cliente viram etiquetas que o
//  Zorvin mantém sozinho. A seção guarda:
//    - num banco limpo, e sem o 066, nada, e diz;
//    - a instalação apaga as manuais "Blindagem" e "Blindagem Concluida", uma
//      vez, e deixa as outras;
//    - a troca: o contato ligado segue o cadastro dele, e só ele; sem vínculo,
//      o telefone (em outra forma), e só o que todos os cadastros dele têm;
//      grupo nunca;
//    - a etiqueta da equipe com o mesmo nome é aproveitada e renomeada, e as
//      conversas dela são trocadas pelas da lista;
//    - quem entrou não renomeia, não apaga, não cria, não põe e não tira a
//      automática, e mexe na sua como sempre;
//    - o tipo que some leva a etiqueta; a lista que encolhe é recusada;
//    - quem entrou não chama a troca; rodar de novo não apaga a manual nova.
// ============================================================
{
  console.log("\n155. As etiquetas que vêm do Vantoro (075), num Postgres de verdade");
  const BANCO_BASE = String(process.env.PROVA_DATABASE_URL || "").trim();
  if (!BANCO_BASE && process.env.CI) {
    ok("há um Postgres para provar o 075 (obrigatório na integração contínua)", false, "PROVA_DATABASE_URL não foi definida");
  } else if (!BANCO_BASE) {
    console.log("  (pulada: sem PROVA_DATABASE_URL. Na integração contínua isto seria FALHA.)");
  } else {
    const pg = await import("pg");
    const fs = await import("node:fs");
    const ler = (arq) => fs.readFileSync(new URL(`../sql/automaticos/${arq}`, import.meta.url), "utf8");
    const S075 = ler("075-as-etiquetas-do-vantoro.sql");
    const CHAVE = ler("066-quem-pede-atencao-nao-e-finalizado.sql")
      .match(/create or replace function public\.zorvin_chave_do_telefone[\s\S]*?\n\$f\$/)[0] + ";";
    const ESQUEMA = `
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
create schema if not exists auth;
create or replace function auth.uid() returns uuid language sql stable as $f$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $f$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
create table advogados (id uuid primary key default gen_random_uuid(), nome text);
create table contatos (id uuid primary key default gen_random_uuid(), numero text unique not null, nome text, vantoro_cliente_id bigint);
create table conversas (id uuid primary key default gen_random_uuid(), advogado_id uuid references advogados(id),
  contato_id uuid references contatos(id) on delete cascade);
create table tags (id uuid primary key default gen_random_uuid(), nome text not null, cor text default '#42a5f5', criado_em timestamptz default now());
create table conversa_tags (conversa_id uuid references conversas(id) on delete cascade, tag_id uuid references tags(id) on delete cascade,
  primary key (conversa_id, tag_id));
alter table tags enable row level security;
alter table conversa_tags enable row level security;
create policy tags_tudo on tags for all to authenticated using (true) with check (true);
create policy ct_tudo on conversa_tags for all to authenticated using (true) with check (true);
`;
    const raiz = new pg.Client({ connectionString: BANCO_BASE, ssl: false }); await raiz.connect();
    const bancos = [], clientes = [];
    async function bancoNovo() {
      const nome = `prova_${crypto.randomBytes(5).toString("hex")}`;
      await raiz.query(`create database ${nome}`); bancos.push(nome);
      const u = new URL(BANCO_BASE); u.pathname = `/${nome}`; u.searchParams.set("sslmode", "disable");
      const cl = new pg.Client({ connectionString: u.toString(), ssl: false }); await cl.connect(); clientes.push(cl);
      return cl;
    }
    const aplicar = async (cl, sql) => { const r = await cl.query(sql); return (Array.isArray(r) ? r[r.length - 1] : r).rows; };
    const guardado = async (fn) => { try { return await fn(); } catch (e) { return { erro: e.message, codigo: e.code }; } };
    const lista = (l) => (Array.isArray(l) ? l : []);
    const defeito = (l) => lista(l).some((x) => x.resposta === "false" || /^NÃO/.test(String(x.resposta)));
    const item = (l, re) => (lista(l).find((x) => re.test(x.item)) || {}).resposta;
    const ANA = "00000000-0000-0000-0000-00000000000a";
    const comoAna = async (c, fn) => {
      await c.query("select set_config('request.jwt.claim.sub', $1, false)", [ANA]);
      await c.query("set role authenticated");
      try { return await fn(); } finally { await c.query("reset role"); await c.query("select set_config('request.jwt.claim.sub', '', false)"); }
    };
    try {
      // ---- 155a. banco limpo, e sem o 066 ----
      {
        const c = await bancoNovo();
        const r = await guardado(() => aplicar(c, S075));
        ok("155a num banco limpo, o 075 não faz nada e diz", item(r, /sem as tabelas/) === "nada a fazer aqui", JSON.stringify(r));
        await c.query(ESQUEMA);
        const r2 = await guardado(() => aplicar(c, S075));
        ok("e sem o 066, diz que falta", lista(r2).some((x) => /falta o 066/.test(x.item)), JSON.stringify(r2));
      }

      const c = await bancoNovo();
      await c.query(ESQUEMA);
      await c.query(CHAVE);
      const tel = (await c.query("insert into advogados (nome) values ('SAC') returning id")).rows[0].id;
      const contato = async (numero, vinculo = null) => {
        const ct = (await c.query("insert into contatos (numero, nome, vantoro_cliente_id) values ($1, 'Cliente', $2) returning id", [numero, vinculo])).rows[0].id;
        return (await c.query("insert into conversas (advogado_id, contato_id) values ($1, $2) returning id", [tel, ct])).rows[0].id;
      };
      const tag = async (nome) => (await c.query("insert into tags (nome) values ($1) returning id", [nome])).rows[0].id;
      const por = async (conv) => (await c.query(
        "select t.nome from conversa_tags x join tags t on t.id = x.tag_id where x.conversa_id = $1 order by t.nome", [conv])).rows.map((x) => x.nome);
      const K1 = await contato("5571988881111", 101);   // ligado ao 101
      const K2 = await contato("557188882222");          // sem vínculo, a forma sem o 9 do 102
      const K3 = await contato("5571977773333");         // o telefone do 103 e do 104
      const K4 = await contato("5571966664444", 105);    // ligado a quem não está na lista, telefone do 102
      const K5 = await contato("5511955556666");         // tinha a manual "Subsidio Emenda", não está na lista
      const GR = await contato("grupo:5571988882222");    // grupo, com os dígitos do 102
      await c.query("update contatos set numero = '71 98888-2222 ' where id = (select contato_id from conversas where id = $1)", [K4]);
      const BLIND = await tag("Blindagem");
      const CONCL = await tag("Blindagem Concluida");
      const EMENDA = await tag("Subsidio Emenda");
      const CARAP = await tag("Subsidio CCR - Carapicuiba");
      const OUTRA = await tag("Urgente");
      await c.query("insert into conversa_tags values ($1, $2), ($1, $3), ($4, $5), ($4, $6)", [K1, BLIND, CONCL, K5, EMENDA, CARAP]);

      // ---- 155b. a instalação ----
      const inst = await guardado(() => aplicar(c, S075));
      ok("155b a instalação não acusa defeito", lista(inst).length > 0 && !defeito(inst), JSON.stringify(inst));
      ok("e apaga as manuais Blindagem e Blindagem Concluida (2)", item(inst, /apagadas agora/) === "2", JSON.stringify(inst));
      const nomes = (await c.query("select nome from tags order by nome")).rows.map((x) => x.nome);
      ok("e deixa as outras", JSON.stringify(nomes) === JSON.stringify(["Subsidio CCR - Carapicuiba", "Subsidio Emenda", "Urgente"]), JSON.stringify(nomes));
      ok("a conversa perde as duas apagadas", (await por(K1)).length === 0, JSON.stringify(await por(K1)));

      // ---- 155c. a troca ----
      const LISTA = [
        { id: 101, blindagem: "parcial", subsidios: ["SUBSÍDIO EMENDA", "SUBSÍDIO CCR"], telefones: ["71988881111"] },
        { id: 102, blindagem: "completa", subsidios: [], telefones: ["(71) 98888-2222"] },
        { id: 103, blindagem: "pendente", subsidios: ["SUBSÍDIO EMENDA"], telefones: ["71977773333"] },
        { id: 104, blindagem: "completa", subsidios: ["SUBSÍDIO EMENDA"], telefones: ["5571977773333"] },
      ];
      const r1 = (await c.query("select zorvin_etiquetas_do_vantoro($1::jsonb) r", [JSON.stringify(LISTA)])).rows[0].r;
      ok("155c a troca responde que trocou, com os 4 clientes", r1.trocada === true && r1.clientes === 4, JSON.stringify(r1));
      ok("o ligado segue o cadastro dele", JSON.stringify(await por(K1)) === JSON.stringify(["Blindagem parcial", "SUBSÍDIO CCR", "SUBSÍDIO EMENDA"]), JSON.stringify(await por(K1)));
      ok("sem vínculo, o telefone em outra forma vale", JSON.stringify(await por(K2)) === JSON.stringify(["Blindagem completa"]), JSON.stringify(await por(K2)));
      ok("o telefone de dois cadastros recebe só o que os dois têm", JSON.stringify(await por(K3)) === JSON.stringify(["SUBSÍDIO EMENDA"]), JSON.stringify(await por(K3)));
      ok("o ligado a quem não está na lista não recebe nada, mesmo com o telefone de outro", (await por(K4)).length === 0, JSON.stringify(await por(K4)));
      ok("o grupo nunca recebe", (await por(GR)).length === 0, JSON.stringify(await por(GR)));
      const em = (await c.query("select id, nome, automatica from tags where id = $1", [EMENDA])).rows[0];
      ok("a manual Subsidio Emenda é aproveitada: a mesma, com o nome do Vantoro", em && em.nome === "SUBSÍDIO EMENDA"
         && em.automatica === "subsidio:SUBSIDIO EMENDA", JSON.stringify(em));
      ok("e a conversa dela que não está na lista a perde; a manual ao lado fica", JSON.stringify(await por(K5)) === JSON.stringify(["Subsidio CCR - Carapicuiba"]), JSON.stringify(await por(K5)));
      const auto = (await c.query("select nome from tags where automatica is not null order by nome")).rows.map((x) => x.nome);
      ok("as três da blindagem e as dos subsídios existem", JSON.stringify(auto) === JSON.stringify(
        ["Blindagem completa", "Blindagem parcial", "Blindagem pendente", "SUBSÍDIO CCR", "SUBSÍDIO EMENDA"]), JSON.stringify(auto));
      ok("e a resposta conta por etiqueta", r1.por_etiqueta && r1.por_etiqueta["SUBSÍDIO EMENDA"] === 2, JSON.stringify(r1.por_etiqueta));
      const r1b = (await c.query("select zorvin_etiquetas_do_vantoro($1::jsonb) r", [JSON.stringify(LISTA)])).rows[0].r;
      ok("a mesma lista de novo não mexe em nada", r1b.postas === 0 && r1b.tiradas === 0 && r1b.etiquetas_criadas === 0, JSON.stringify(r1b));

      // ---- 155d. a trava ----
      const AUTO = (await c.query("select id from tags where automatica = 'blindagem:parcial'")).rows[0].id;
      const tenta = (sql, p) => guardado(() => comoAna(c, () => c.query(sql, p)));
      ok("155d quem entrou não renomeia a automática", (await tenta("update tags set nome = 'x' where id = $1", [AUTO])).codigo === "42501");
      ok("nem muda a cor", (await tenta("update tags set cor = '#000' where id = $1", [AUTO])).codigo === "42501");
      ok("nem a apaga", (await tenta("delete from tags where id = $1", [AUTO])).codigo === "42501");
      ok("nem cria uma automática", (await tenta("insert into tags (nome, automatica) values ('y', 'blindagem:z')")).codigo === "42501");
      ok("nem tira a sua marca", (await tenta("update tags set automatica = null where id = $1", [AUTO])).codigo === "42501");
      ok("nem a põe numa conversa", (await tenta("insert into conversa_tags values ($1, $2)", [K4, AUTO])).codigo === "42501");
      ok("nem a tira", (await tenta("delete from conversa_tags where conversa_id = $1 and tag_id = $2", [K1, AUTO])).codigo === "42501");
      const manual = await tenta("update tags set nome = 'Urgentíssimo' where id = $1 returning id", [OUTRA]);
      const pos = await tenta("insert into conversa_tags values ($1, $2) returning tag_id", [K1, OUTRA]);
      const tira = await tenta("delete from conversa_tags where conversa_id = $1 and tag_id = $2 returning tag_id", [K1, OUTRA]);
      ok("e mexe na manual como sempre", manual.rowCount === 1 && pos.rowCount === 1 && tira.rowCount === 1,
         JSON.stringify([manual.erro, pos.erro, tira.erro]));
      ok("e quem entrou não chama a troca", /permission denied/.test(String(
        (await tenta("select zorvin_etiquetas_do_vantoro('[]'::jsonb)")).erro)));
      const Kx = await contato("5531900001111", 101);
      await c.query("select zorvin_etiquetas_do_vantoro($1::jsonb)", [JSON.stringify(LISTA)]);
      ok("apagar a conversa leva as automáticas junto (a cascata passa)", !(await tenta("delete from conversas where id = $1", [Kx])).erro);

      // ---- 155e. a lista muda ----
      const LISTA2 = [
        { id: 101, blindagem: "parcial", subsidios: ["SUBSÍDIO EMENDA"], telefones: ["71988881111"] },
        { id: 102, blindagem: "parcial", subsidios: [], telefones: ["(71) 98888-2222"] },
        { id: 103, blindagem: "pendente", subsidios: ["SUBSÍDIO EMENDA"], telefones: ["71977773333"] },
        { id: 104, blindagem: "completa", subsidios: ["Subsidio  emenda"], telefones: ["5571977773333"] },
      ];
      const r2 = (await c.query("select zorvin_etiquetas_do_vantoro($1::jsonb) r", [JSON.stringify(LISTA2)])).rows[0].r;
      ok("155e o tipo que some leva a etiqueta", r2.etiquetas_que_sumiram === 1
         && !(await c.query("select 1 from tags where nome = 'SUBSÍDIO CCR'")).rowCount, JSON.stringify(r2));
      ok("a blindagem que muda troca a etiqueta", JSON.stringify(await por(K2)) === JSON.stringify(["Blindagem parcial"]), JSON.stringify(await por(K2)));
      ok("a outra escrita do mesmo tipo é a mesma etiqueta", JSON.stringify(await por(K3)) === JSON.stringify(["SUBSÍDIO EMENDA"]), JSON.stringify(await por(K3)));

      // ---- 155f. a lista que encolhe ----
      await c.query("update zorvin_etiquetas_marca set clientes = 40");
      const r3 = (await c.query("select zorvin_etiquetas_do_vantoro($1::jsonb) r", [JSON.stringify(LISTA2.slice(0, 3))])).rows[0].r;
      ok("155f a lista que encolhe pela metade é recusada", r3.trocada === false, JSON.stringify(r3));
      ok("e as etiquetas de antes ficam", JSON.stringify(await por(K2)) === JSON.stringify(["Blindagem parcial"]), JSON.stringify(await por(K2)));
      const r4 = (await guardado(() => c.query("select zorvin_etiquetas_do_vantoro('{}'::jsonb)")));
      ok("e o que não é lista é recusado", r4.codigo === "22023", JSON.stringify(r4));

      // ---- 155g. rodar de novo ----
      await tag("Blindagem");
      const de2 = await guardado(() => aplicar(c, S075));
      ok("155g rodar de novo não acusa defeito, e não apaga a manual nova", lista(de2).length > 0 && !defeito(de2)
         && item(de2, /apagadas agora/) === "0" && (await c.query("select 1 from tags where nome = 'Blindagem'")).rowCount === 1, JSON.stringify(de2));
      ok("e as automáticas continuam", (await c.query("select count(*)::int n from tags where automatica is not null")).rows[0].n === 4);
    } catch (e) {
      ok("a seção 155 rodou até o fim", false, e.stack || e.message);
    } finally {
      for (const cl of clientes) await cl.end().catch(() => {});
      for (const b of bancos) await raiz.query(`drop database if exists ${b} with (force)`).catch(() => {});
      await raiz.end().catch(() => {});
    }
  }
}

console.log(`\n${feitas - falhas}/${feitas} conferências passaram`);
process.exit(falhas ? 1 : 0);
