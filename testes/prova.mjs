// PROVA DA PONTE — o `index.js` de verdade, contra um Supabase e uma Uazapi
// de mentira que falam o mesmo protocolo.
import { spawn } from "node:child_process";
import http from "node:http";
import crypto from "node:crypto";
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

async function subirTudo(env = {}, { tabelas = {}, vantoro = null, quebrar, semColunas, semTabelas, uazapi = {}, contas = null, bilhetesQueFalham = 0, authNoChao = false, jwksAssimetrico = false } = {}) {
  const uaz = await subirFalsaUazapi(uazapi);
  TELEFONE.servidor = uaz.url;
  const van = vantoro ? await subirFalsoVantoro(vantoro) : null;
  const sb = await subirFalsoSupabase({
    quebrar, semColunas, semTabelas, bilhetesQueFalham,
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

// ==================================================================
//  1. O WEBHOOK
// ==================================================================
{
  console.log("\n1. O webhook");
  const t = await subirTudo();
  const r = await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(mensagemDaUazapi("Bom dia, preciso de ajuda", "msg-1")),
  });
  await espera(700);
  ok("responde 200 rápido (a Uazapi não reenvia)", r.status === 200);
  ok("cria o contato", t.sb.dados.contatos.length === 1,
     JSON.stringify(t.sb.dados.contatos));
  ok("cria a conversa", t.sb.dados.conversas.length === 1);
  ok("grava a mensagem", t.sb.dados.mensagens.length === 1,
     JSON.stringify(t.sb.dados.mensagens.map((m) => m.texto)));
  ok("a mensagem entra como recebida",
     t.sb.dados.mensagens[0]?.origem === "contato", t.sb.dados.mensagens[0]?.origem);

  // A MESMA MENSAGEM DE NOVO não pode virar duas: a Uazapi reenvia quando
  // desconfia que não entregou.
  await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(mensagemDaUazapi("Bom dia, preciso de ajuda", "msg-1")),
  });
  await espera(600);
  ok("a mesma mensagem reenviada não duplica", t.sb.dados.mensagens.length === 1,
     `ficaram ${t.sb.dados.mensagens.length}`);

  await t.parar();
}

// ==================================================================
//  2. QUEM PODE MANDAR MENSAGEM PARA DENTRO DO ESCRITÓRIO?
// ==================================================================
//
// O endereço do webhook não pedia nada. Qualquer um que descobrisse a URL podia
// mandar um POST e a mensagem entrava no banco como se tivesse vindo do
// cliente — aparecia na conversa, contava no Painel, ficava no histórico.
//
// A trava é um segredo, e ela liga em duas etapas de propósito: enquanto
// `WEBHOOK_TOKEN` não existir, tudo passa. Ligar a exigência antes de o
// endereço na Uazapi ter o segredo faria as mensagens dos clientes pararem de
// chegar, em silêncio.
{
  console.log("\n2. Quem pode escrever no webhook");

  // ---- 2a. sem o segredo configurado: nada muda (é a rede de segurança) ----
  {
    const t = await subirTudo();
    await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(mensagemDaUazapi("Antes de configurar", "a-1")),
    });
    await espera(700);
    ok("sem WEBHOOK_TOKEN, as mensagens continuam entrando",
       t.sb.dados.mensagens.length === 1, `entraram ${t.sb.dados.mensagens.length}`);
    ok("mas a ponte avisa no log que está sem segredo",
       t.registro.join("").includes("SEM segredo"),
       t.registro.join("").slice(-200));
    await t.parar();
  }

  // ---- 2b. com o segredo: forjada de fora não entra ----
  {
    const t = await subirTudo({ WEBHOOK_TOKEN: "segredo-do-escritorio" });
    const r = await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(mensagemDaUazapi("Mensagem forjada por um estranho", "forjada-1")),
    });
    await espera(700);
    ok("sem o segredo, o webhook recusa", r.status === 403, `veio ${r.status}`);
    ok("e nada entra no banco", t.sb.dados.mensagens.length === 0,
       JSON.stringify(t.sb.dados.mensagens.map((m) => m.texto)));

    const errado = await fetch(`http://127.0.0.1:${t.porta}/webhook?token=chute`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(mensagemDaUazapi("Chute", "forjada-2")),
    });
    ok("com o segredo errado, recusa também", errado.status === 403, `veio ${errado.status}`);

    // ---- 2c. com o segredo certo, na URL e no cabeçalho ----
    const naUrl = await fetch(`http://127.0.0.1:${t.porta}/webhook?token=segredo-do-escritorio`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(mensagemDaUazapi("Mensagem de verdade", "boa-1")),
    });
    await espera(700);
    ok("com o segredo na URL, entra", naUrl.status === 200 && t.sb.dados.mensagens.length === 1,
       `status ${naUrl.status}, ${t.sb.dados.mensagens.length} mensagens`);

    const noCabecalho = await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-webhook-token": "segredo-do-escritorio" },
      body: JSON.stringify(mensagemDaUazapi("Pelo cabeçalho", "boa-2")),
    });
    await espera(700);
    ok("com o segredo no cabeçalho, também entra",
       noCabecalho.status === 200 && t.sb.dados.mensagens.length === 2,
       `status ${noCabecalho.status}, ${t.sb.dados.mensagens.length} mensagens`);
    await t.parar();
  }
}

// ==================================================================
//  3. A FILA DE ENVIO
// ==================================================================
{
  console.log("\n3. A fila de envio");
  const t = await subirTudo();
  t.sb.dados.contatos.push({ id: 1, numero: "5511999998888", nome: "Cliente Teste" });
  t.sb.dados.conversas.push({ id: 1, advogado_id: TELEFONE.id, contato_id: 1 });
  t.sb.dados.fila_envio.push({
    id: 1, conversa_id: 1, tipo: "texto", texto: "Olá!", status: "pendente",
    tentativas: 0, criado_em: new Date().toISOString(),
  });
  await fetch(`http://127.0.0.1:${t.porta}/ping`);
  await espera(1200);
  ok("manda a mensagem para a Uazapi", t.uaz.recebidas.length === 1,
     JSON.stringify(t.uaz.recebidas));
  ok("marca o item da fila como enviada",
     t.sb.dados.fila_envio[0]?.status === "enviada", t.sb.dados.fila_envio[0]?.status);

  // O ITEM VELHO QUE ESTÁ SENDO ENVIADO AGORA.
  //
  // A recuperação de itens travados olhava `criado_em` — quando o item foi
  // CRIADO —, e não quando ele foi reivindicado. Um item que ficou 6 minutos na
  // fila e acabou de ser pego para envio se encaixa nessa regra: ele volta para
  // "pendente" no meio do envio, e o cliente recebe a mesma mensagem duas vezes.
  t.uaz.recebidas.length = 0;
  t.sb.dados.fila_envio.push({
    id: 2, conversa_id: 1, tipo: "texto", texto: "Segunda", status: "enviando",
    tentativas: 1, criado_em: new Date(Date.now() - 10 * 60 * 1000).toISOString(),
    enviando_em: new Date().toISOString(),   // reivindicado AGORA
  });
  await fetch(`http://127.0.0.1:${t.porta}/ping`);
  await espera(1200);
  ok("item reivindicado agora NÃO é reenviado, mesmo sendo antigo",
     t.uaz.recebidas.length === 0,
     `a Uazapi recebeu ${t.uaz.recebidas.length} — o cliente veria a mesma mensagem duas vezes`);

  // O item DE VERDADE travado (reivindicado há muito) tem de voltar.
  t.sb.dados.fila_envio.push({
    id: 3, conversa_id: 1, tipo: "texto", texto: "Terceira", status: "enviando",
    tentativas: 1, criado_em: new Date(Date.now() - 30 * 60 * 1000).toISOString(),
    enviando_em: new Date(Date.now() - 30 * 60 * 1000).toISOString(),
  });
  await fetch(`http://127.0.0.1:${t.porta}/ping`);
  await espera(1400);
  ok("item preso de verdade volta para a fila e sai",
     t.uaz.recebidas.some((x) => JSON.stringify(x.corpo).includes("Terceira")),
     JSON.stringify(t.uaz.recebidas));

  // A FILA SAI NA ORDEM EM QUE ENTROU.
  //
  // Conversa de WhatsApp é sequência, não conjunto. Quem escreve "vou te mandar
  // o documento" e em seguida "segue em anexo" está contando uma coisa em duas
  // partes; trocadas, viram outra coisa. E o cliente não tem como desconfiar —
  // ele lê o que está na tela, na ordem da tela.
  //
  // O código JÁ FAZ ISTO: lê com `order('criado_em')` e envia num laço que
  // espera cada envio terminar. O que faltava era a PROVA. Sem ela, trocar o
  // laço por um `Promise.all` — que parece só deixar mais rápido — embaralharia
  // a conversa de todo mundo sem uma conferência sequer ficar vermelha.
  //
  // Isto foi MEDIDO, e não suposto: invertendo a leitura para
  // `ascending: false`, a bancada inteira passava.
  t.uaz.recebidas.length = 0;
  const instante = Date.now();
  // EMPURRADAS FORA DE ORDEM de propósito. Plantadas na ordem certa, a prova
  // passaria também com uma fila que ignora `criado_em` e devolve as linhas na
  // ordem em que estão no banco — mediria o acaso, e não a regra.
  t.sb.dados.fila_envio.push(
    { id: 11, conversa_id: 1, tipo: "texto", texto: "TERCEIRA parte", status: "pendente",
      tentativas: 0, criado_em: new Date(instante - 10000).toISOString() },
    { id: 12, conversa_id: 1, tipo: "texto", texto: "PRIMEIRA parte", status: "pendente",
      tentativas: 0, criado_em: new Date(instante - 30000).toISOString() },
    { id: 13, conversa_id: 1, tipo: "texto", texto: "SEGUNDA parte", status: "pendente",
      tentativas: 0, criado_em: new Date(instante - 20000).toISOString() },
  );
  await fetch(`http://127.0.0.1:${t.porta}/ping`);
  await espera(2000);

  const ordem = t.uaz.recebidas
    .map((x) => (JSON.stringify(x.corpo).match(/(PRIMEIRA|SEGUNDA|TERCEIRA)/) || [])[1])
    .filter(Boolean);
  ok("as três partes saíram", ordem.length === 3,
     JSON.stringify(t.uaz.recebidas.map((x) => x.corpo)));
  ok("da mais antiga para a mais nova, e não na ordem do banco",
     ordem.join(",") === "PRIMEIRA,SEGUNDA,TERCEIRA",
     `saiu ${JSON.stringify(ordem)} — o cliente leria a conversa embaralhada`);

  await t.parar();
}

// ==================================================================
//  4. AS ROTAS PROTEGIDAS
// ==================================================================
{
  console.log("\n4. As rotas protegidas");
  const t = await subirTudo();
  const semLogin = await fetch(`http://127.0.0.1:${t.porta}/permissoes/atendentes`);
  ok("sem login, /permissoes/atendentes recusa", semLogin.status === 401, `veio ${semLogin.status}`);
  const jwtRuim = await fetch(`http://127.0.0.1:${t.porta}/permissoes/atendentes`,
    { headers: { Authorization: "Bearer jwt-inventado" } });
  ok("com sessão inválida, recusa", jwtRuim.status === 401, `veio ${jwtRuim.status}`);
  const semToken = await fetch(`http://127.0.0.1:${t.porta}/importar-historico?advogado=1&contato=2`);
  ok("importar histórico sem senha recusa", semToken.status === 403, `veio ${semToken.status}`);
  await t.parar();

  // ------------------------------------------------------------
  //  A RECUSA DIZ QUAL DOS DOIS PROBLEMAS É
  //
  //  Era uma frase só para duas situações opostas — a variável não existe no
  //  servidor, ou existe e o token não confere. Quem a recebe não tem como
  //  saber qual é, e os consertos são diferentes: criar uma variável, ou
  //  reconferir o que se colou.
  //
  //  Aconteceu em 02/09, no resgate do histórico do grupo: a resposta mandou
  //  procurar erro de digitação num token que estava certo, porque a variável
  //  nunca tinha sido criada — ela nem constava da lista do CLAUDE.md.
  // ------------------------------------------------------------
  {
    const semVariavel = await subirTudo();   // sem IMPORT_TOKEN no ambiente
    const r1 = await fetch(`http://127.0.0.1:${semVariavel.porta}`
      + `/importar-historico?token=qualquer&advogado=1&contato=2`);
    const f1 = await r1.text();
    ok("sem a variável no servidor, a recusa DIZ que ela não existe",
       r1.status === 403 && /IMPORT_TOKEN não existe/.test(f1), `disse: "${f1.slice(0, 160)}"`);
    ok("e ensina onde criá-la, em vez de mandar procurar erro de digitação",
       /Environment/.test(f1), `disse: "${f1.slice(0, 200)}"`);
    await semVariavel.parar();

    const comVariavel = await subirTudo({ IMPORT_TOKEN: "a-senha-certa" });
    const r2 = await fetch(`http://127.0.0.1:${comVariavel.porta}`
      + `/importar-historico?token=a-senha-errada&advogado=1&contato=2`);
    const f2 = await r2.text();
    ok("com a variável posta, o token errado dá OUTRA frase",
       r2.status === 403 && /não confere/.test(f2), `disse: "${f2.slice(0, 160)}"`);
    // O VALOR NUNCA APARECE. Uma frase que ajuda demais devolve a senha a quem
    // não a tem — e aí a porta deixou de ser porta.
    ok("e a frase NÃO devolve a senha para quem não a tem",
       !f2.includes("a-senha-certa"), `disse: "${f2}"`);
    await comVariavel.parar();
  }
}

// ==================================================================
//  5. A SESSÃO NÃO É CONFERIDA A CADA CHAMADA
// ==================================================================
// `auth.getUser` é uma ida à API do Supabase, e ela acontecia em TODA chamada
// do painel — abrir a ficha do cliente são duas, digitar na busca é mais uma a
// cada pausa. A mesma sessão, conferida cinco vezes em dez segundos, dá cinco
// vezes a mesma resposta.
{
  console.log("\n5. A sessão conferida uma vez");
  const t = await subirTudo();
  const conta = () => t.sb.chamadas.filter((c) => c.caminho === "/auth/v1/user").length;
  const antes = conta();
  for (let i = 0; i < 6; i++) {
    await fetch(`http://127.0.0.1:${t.porta}/permissoes/atendentes`,
      { headers: { Authorization: "Bearer jwt-bom" } });
  }
  const idas = conta() - antes;
  console.log(`     6 chamadas do painel → ${idas} ida(s) à autenticação`);
  ok("seis chamadas seguidas conferem a sessão uma vez só", idas === 1, `foram ${idas}`);

  // Sessão ruim não pode ser lembrada: quem entra de novo tem de passar na hora.
  const ruim = await fetch(`http://127.0.0.1:${t.porta}/permissoes/atendentes`,
    { headers: { Authorization: "Bearer jwt-podre" } });
  t.sb.contas.push({ id: "u9", email: "novo@x", jwt: "jwt-podre", user_metadata: {} });
  const agoraVale = await fetch(`http://127.0.0.1:${t.porta}/permissoes/atendentes`,
    { headers: { Authorization: "Bearer jwt-podre" } });
  ok("sessão recusada não fica lembrada como recusada",
     ruim.status === 401 && agoraVale.status !== 401,
     `antes ${ruim.status}, depois ${agoraVale.status}`);
  await t.parar();
}

// ==================================================================
//  6. A CÓPIA DA PERMISSÃO DO VANTORO
// ==================================================================
//
// Quem pode ver o quê é decidido no Vantoro. A ponte copia essa decisão para
// dentro do Zorvin de três em três minutos, para quem já está com o painel
// aberto passar a enxergar sem sair e entrar de novo.
//
// Esta é a rotina mais delicada do arquivo: ela APAGA a permissão de alguém e
// grava de novo. Tudo o que acontecer entre uma coisa e outra, a pessoa passa
// sem ver conversa nenhuma.
{
  console.log("\n6. A cópia da permissão do Vantoro");

  // 1103 pessoas espelhadas: as três primeiras logo no começo, e a quarta lá
  // atrás, depois da milésima linha. O PostgREST corta em mil e não avisa.
  const espelhados = [
    { id: "ana",   login: "ana",   email: "ana@x",   nome: "Ana",   ativo: true },
    { id: "bruno", login: "bruno", email: "bruno@x", nome: "Bruno", ativo: true },
    { id: "carla", login: "carla", email: "carla@x", nome: "Carla", ativo: true },
  ];
  // Mais quarenta pessoas de verdade, para a rodada ter tamanho: é com elas que
  // dá para ver se o custo cresce por pessoa ou não.
  const turma = [];
  for (let i = 0; i < 40; i++) turma.push(`turma${i}`);
  for (const t of turma) espelhados.push({ id: t, login: t, email: `${t}@x`, ativo: true });
  for (let i = 0; i < 1100; i++) {
    espelhados.push({ id: `enche-${i}`, login: `enche${i}`, email: `enche${i}@x`, ativo: true });
  }
  espelhados.push({ id: "davi", login: "davi", email: "davi@x", nome: "Davi", ativo: true });

  const doVantoro = [
    // Departamento — o corte normal.
    { login: "ana", email: "ana@x", nome: "Ana", admin: false,
      zorvin_definido: true, zorvin: ["comercial"] },
    // Só um telefone, escrito como gente escreve: com parênteses e traço.
    { login: "bruno", email: "bruno@x", nome: "Bruno", admin: false,
      zorvin_definido: true, zorvin_so_telefones: true,
      zorvin_telefones: ["(67) 90000-0001"] },
    // Ninguém definiu ainda: não pode virar "não vê nada".
    { login: "carla", email: "carla@x", nome: "Carla", admin: false,
      zorvin_definido: false },
    // Igual à Ana — mas espelhada depois da milésima linha.
    { login: "davi", email: "davi@x", nome: "Davi", admin: false,
      zorvin_definido: true, zorvin: ["comercial"] },
    ...turma.map((t) => ({ login: t, email: `${t}@x`, nome: t, admin: false,
                           zorvin_definido: true, zorvin: ["comercial"] })),
  ];

  // ---- 6a. a rodada normal ----
  {
    const t = await subirTudo({}, {
      vantoro: { usuarios: doVantoro },
      tabelas: {
        usuarios: espelhados.map((u) => ({ ...u })),
        // A Ana JÁ TEM a permissão certa. A rodada não deveria mexer em nada.
        // A Carla também já tem — e ninguém definiu nada para ela no Vantoro,
        // então a rodada não pode tirar o que ela tem.
        permissoes: [
          { id: 1, usuario_id: "ana", departamento_id: 1 },
          { id: 2, usuario_id: "carla", departamento_id: 1 },
        ],
      },
    });
    const chegou = await esperarARodada(t);
    ok("a rodada de permissões acontece sozinha", chegou);

    const de = (quem) => t.sb.dados.permissoes.filter((p) => p.usuario_id === quem);

    ok("quem tem departamento marcado recebe o departamento",
       de("ana").length === 1 && de("ana")[0].departamento_id === 1,
       JSON.stringify(de("ana")));

    ok("telefone escrito com parênteses e traço encontra o número",
       de("bruno").length === 1 && de("bruno")[0].telefone_id === TELEFONE.id,
       JSON.stringify(de("bruno")) + " — log: "
         + (t.registro.join("").match(/não tem os telefones.*/) || [""])[0]);

    ok("quem ninguém definiu no Vantoro não perde o que já tinha",
       de("carla").length === 1,
       `a Carla ficou com ${de("carla").length} — o Vantoro não diz nada sobre ela, `
       + "e 'ninguém definiu' não é a mesma coisa que 'não pode ver nada'");

    // O TETO DE MIL LINHAS.
    ok("a pessoa espelhada depois da milésima linha também recebe permissão",
       de("davi").length === 1 && de("davi")[0].departamento_id === 1,
       `o Davi ficou com ${de("davi").length} linha(s) — se ficou com zero, `
       + "a leitura de `usuarios` parou em mil e ele nunca é encontrado");

    // A JANELA CEGA.
    //
    // A permissão da Ana já estava certa antes da rodada. Apagá-la e gravar a
    // mesma coisa de volta não muda nada no fim — mas entre o apagar e o
    // gravar ela fica sem permissão nenhuma, e quem estiver carregando as
    // conversas nesse instante não vê nada. Três em três minutos, para cada
    // pessoa do escritório.
    const escritas = t.sb.chamadas.filter(
      (c) => c.caminho === "/rest/v1/permissoes" && c.metodo !== "GET"
             && (String(c.busca || "") + JSON.stringify(c.corpo || "")).includes("ana"));
    ok("permissão que não mudou não é reescrita",
       escritas.length === 0,
       `houve ${escritas.length} escrita(s) na permissão da Ana sem nada ter mudado: `
       + escritas.map((c) => c.metodo).join(", "));

    // O CUSTO DA RODADA NÃO PODE CRESCER POR PESSOA.
    //
    // A lista de telefones e a de departamentos são as MESMAS para todo mundo,
    // e a rotina relia as duas para cada pessoa: quarenta e três pessoas, mais
    // de quarenta consultas idênticas, de três em três minutos, para sempre.
    const releituras = t.sb.chamadas.filter(
      (c) => c.metodo === "GET"
             && (c.caminho === "/rest/v1/advogados" || c.caminho === "/rest/v1/departamentos")).length;
    console.log(`     43 pessoas na rodada → ${releituras} leitura(s) de telefones/departamentos`);
    ok("a rodada não relê telefones e departamentos uma vez por pessoa",
       releituras <= 10,
       `foram ${releituras} para 43 pessoas — deveria ser um punhado, não uma por pessoa`);

    // ---- O QUE O LOG CONTA DA RODADA ----
    //
    // Ele dizia `Permissões: reaplicadas para 44 usuário(s).` — e o número
    // contava quem a rotina VISITOU, não quem teve permissão mexida. Como ela
    // foi consertada justamente para não escrever quando nada mudou, a frase
    // anunciava um trabalho que na maioria das rodadas não acontecia.
    const registro = t.registro.join("");
    ok("o log não fala mais em 'reaplicadas'",
       !/reaplicad/i.test(registro),
       (registro.match(/.*reaplicad.*/) || [""])[0]);

    const linha = (registro.match(/Permissões: mudei.*/) || [""])[0];
    ok("mas conta que mudou alguma coisa, porque aqui mudou mesmo", !!linha,
       "não saiu linha nenhuma");
    // NOMEAR É O PONTO. "mudei 42" não responde à pergunta que quem administra
    // faz depois: "a fulana parou de ver o departamento, quando foi isso?".
    ok("dizendo de QUEM", /\bbruno\b/.test(linha), `dizia: "${linha}"`);
    ok("e quanto entrou e quanto saiu", /bruno \(\+1\)/.test(linha), `dizia: "${linha}"`);
    // A Ana já estava certa. Nomeá-la seria dizer que houve escrita onde não
    // houve — o mesmo defeito da frase velha, só que com nome próprio.
    // O `!!linha` não é redundância: sem ele, esta conferência passa de graça
    // quando não sai linha nenhuma — uma frase vazia de fato não nomeia a Ana.
    // Foi o que aconteceu ao rodar contra o código velho: a única das novas que
    // ficou verde, e pelo motivo errado.
    ok("e sem nomear quem não mudou", !!linha && !/\bana\b/.test(linha),
       `dizia: "${linha}"`);
    // Quarenta e duas pessoas mudaram de uma vez, que é o que acontece na
    // primeira rodada depois de uma implantação. A linha não pode virar um
    // parágrafo.
    ok("com teto de nomes, para a linha não virar parágrafo",
       /e mais \d+/.test(linha) && linha.length < 300,
       `tinha ${linha.length} caracteres: "${linha}"`);
    ok("e ainda dizendo quantas foram conferidas", /de \d+ conferido/.test(linha),
       `dizia: "${linha}"`);

    await t.parar();
  }

  // ---- 6c. a rodada em que nada mudou ----
  //
  // ESTE É O CASO DE QUASE TODA RODADA, e o motivo de a mudança existir. Ela
  // sai de três em três minutos: quase quinhentas vezes por dia. Uma linha
  // dizendo "reaplicadas" em cada uma delas enterra o que de fato aconteceu —
  // uma linha caída, um webhook recusado — debaixo de centenas de linhas
  // iguais que não noticiam nada.
  {
    const t = await subirTudo({}, {
      vantoro: { usuarios: [
        { login: "ana", email: "ana@x", nome: "Ana", admin: false,
          zorvin_definido: true, zorvin: ["comercial"] },
      ] },
      tabelas: {
        usuarios: [{ id: "ana", login: "ana", email: "ana@x", ativo: true }],
        // Já está exatamente como o Vantoro manda. Não há o que escrever.
        permissoes: [{ id: 1, usuario_id: "ana", departamento_id: 1 }],
      },
    });
    ok("a rodada aconteceu", await esperarARodada(t));

    // A conferência de que ela REALMENTE rodou e não escreveu. Sem isto, o
    // silêncio de baixo passaria de graça numa rodada que nem chegou a começar
    // — um teste verde provando nada, que é pior do que teste nenhum.
    const escritas = t.sb.chamadas.filter(
      (c) => c.caminho === "/rest/v1/permissoes" && c.metodo !== "GET");
    ok("e não escreveu nada, porque não havia o que escrever",
       escritas.length === 0, `houve ${escritas.length} escrita(s)`);

    const registro = t.registro.join("");
    ok("então o log fica calado sobre permissões",
       !/Permissões: (mudei|reaplicad)/i.test(registro),
       (registro.match(/.*Permissões: (mudei|reaplicad).*/) || [""])[0]);

    await t.parar();
  }

  // ---- 6b. quando a gravação falha no meio ----
  //
  // A rotina apaga e depois grava. Se a gravação falhar — a rede caiu, o banco
  // recusou —, o apagar já aconteceu: a pessoa fica cega até a próxima rodada
  // dar certo. E se o defeito for permanente (uma constraint, uma coluna que
  // sumiu), ela fica cega para sempre, com a tela do Vantoro mostrando a
  // permissão marcada, certinha.
  {
    const t = await subirTudo({}, {
      vantoro: { usuarios: [
        { login: "elias", email: "elias@x", nome: "Elias", admin: false,
          zorvin_definido: true, zorvin: ["comercial", "financeiro"] },
      ] },
      tabelas: {
        usuarios: [{ id: "elias", login: "elias", email: "elias@x", ativo: true }],
        departamentos: [
          { id: 1, nome: "Comercial", slug: "comercial", ordem: 1, ativo: true },
          { id: 2, nome: "Financeiro", slug: "financeiro", ordem: 2, ativo: true },
        ],
        permissoes: [{ id: 1, usuario_id: "elias", departamento_id: 1 }],
      },
      quebrar: (metodo, tabela) =>
        (metodo === "POST" && tabela === "permissoes") ? "a rede caiu na hora de gravar" : null,
    });
    await esperarARodada(t);

    const dele = t.sb.dados.permissoes.filter((p) => p.usuario_id === "elias");
    ok("gravação que falha não deixa a pessoa sem ver nada",
       dele.length >= 1,
       `o Elias ficou com ${dele.length} permissão(ões) — ele TINHA o comercial antes, `
       + "e a única coisa que falhou foi acrescentar o financeiro");
    ok("e o que ele já tinha continua valendo",
       dele.some((p) => p.departamento_id === 1),
       JSON.stringify(dele));

    await t.parar();
  }
}

// ==================================================================
//  7. A IMPORTAÇÃO DE HISTÓRICO
// ==================================================================
//
// Quando um número entra no Zorvin, a conversa começa vazia: tudo o que o
// cliente e o escritório trocaram antes fica só no celular. A importação puxa
// esse passado da Uazapi. É uso manual e administrativo, e a única resposta que
// ela dá é uma frase com um número — então o número precisa ser verdade.
{
  console.log("\n7. A importação de histórico");

  const ONTEM = Date.now() - 24 * 60 * 60 * 1000;
  const historico = [
    { messageid: "h-1", fromMe: false, text: "Bom dia, doutor",
      messageTimestamp: Math.floor(ONTEM / 1000), messageType: "conversation" },
    { messageid: "h-2", fromMe: true, text: "Bom dia! Pode falar",
      messageTimestamp: Math.floor((ONTEM + 60000) / 1000), messageType: "conversation" },
    { messageid: "h-3", fromMe: false, caption: "Segue o documento",
      messageTimestamp: Math.floor((ONTEM + 120000) / 1000), messageType: "image",
      fileURL: "https://mmg.whatsapp.net/expira-em-pouco-tempo.enc" },
  ];

  const comHistorico = (extra = {}) => ({
    uazapi: { historico },
    tabelas: {
      contatos: [], conversas: [], mensagens: [],
      // Uma conversa que já existe, com mensagem nova por ler.
      ...(extra.tabelas || {}),
    },
    ...(extra.quebrar ? { quebrar: extra.quebrar } : {}),
  });

  const importar = (porta, extra = "") =>
    fetch(`http://127.0.0.1:${porta}/importar-historico?token=senha-do-escritorio`
          + `&advogado=${TELEFONE.numero}&contato=5511999998888${extra}`);

  // ---- 7a. traz o passado, com a data do passado ----
  {
    const t = await subirTudo({ IMPORT_TOKEN: "senha-do-escritorio" }, comHistorico());
    const r = await importar(t.porta);
    const frase = await r.text();
    ok("a importação responde 200", r.status === 200, `veio ${r.status}: ${frase.slice(0, 200)}`);
    ok("traz as três mensagens do histórico", t.sb.dados.mensagens.length === 3,
       `vieram ${t.sb.dados.mensagens.length}`);

    const primeira = t.sb.dados.mensagens.find((m) => m.id_uazapi === "h-1");
    ok("com o horário original, e não a hora da importação",
       primeira && new Date(primeira.criado_em).getTime() < Date.now() - 20 * 60 * 60 * 1000,
       primeira && primeira.criado_em);
    ok("quem mandou cada uma é preservado",
       t.sb.dados.mensagens.find((m) => m.id_uazapi === "h-2")?.origem === "advogado");

    // A FOTO DO HISTÓRICO.
    //
    // O endereço que a Uazapi devolve aponta para o servidor do WhatsApp, é
    // temporário e vem cifrado. Guardá-lo na mensagem faz a foto aparecer hoje
    // — se aparecer — e virar bolha quebrada depois, sem nada explicando.
    // O caminho do webhook já baixa o arquivo e guarda no Storage; a
    // importação precisa fazer o mesmo, senão importa fotos que não abrem.
    const foto = t.sb.dados.mensagens.find((m) => m.id_uazapi === "h-3");
    ok("a foto do histórico é guardada no Storage, não deixada no link que expira",
       foto && String(foto.midia_url || "").includes("/storage/"),
       `ficou apontando para: ${foto && foto.midia_url}`);

    // ---- 7b. rodar de novo não duplica — e não mente no número ----
    const r2 = await importar(t.porta);
    const frase2 = await r2.text();
    ok("rodar de novo não duplica nada", t.sb.dados.mensagens.length === 3,
       `ficaram ${t.sb.dados.mensagens.length}`);
    ok("e a frase final não diz que importou o que já estava lá",
       /Importei 0 /.test(frase2) || /nenhuma mensagem nova/i.test(frase2),
       `disse: "${frase2.trim()}"`);

    await t.parar();
  }

  // ---- 7c. quando o banco recusa, a resposta precisa ser compreensível ----
  //
  // Quem roda isto é uma pessoa, num navegador, e o que ela recebe é uma frase.
  // "Cannot read properties of null (reading 'id')" não é uma frase — é o
  // sintoma de um erro que não foi conferido, mostrado a quem não pode fazer
  // nada com ele.
  {
    const t = await subirTudo({ IMPORT_TOKEN: "senha-do-escritorio" }, comHistorico({
      quebrar: (metodo, tabela) =>
        (metodo === "POST" && tabela === "contatos") ? "o banco recusou" : null,
    }));
    const r = await importar(t.porta);
    const frase = await r.text();
    ok("banco recusando dá uma frase em português, não o erro cru",
       !/Cannot read|undefined|null \(reading/.test(frase),
       `respondeu: "${frase.trim().slice(0, 160)}"`);
    await t.parar();
  }

  // ---- 7d. importar o passado não apaga o aviso de mensagem nova ----
  {
    const t = await subirTudo({ IMPORT_TOKEN: "senha-do-escritorio" }, {
      uazapi: { historico },
      tabelas: {
        contatos: [{ id: 1, numero: "5511999998888", nome: "Cliente" }],
        conversas: [{ id: 1, advogado_id: TELEFONE.id, contato_id: 1, nao_lidas: 3,
                      ultima_atividade: new Date().toISOString() }],
        mensagens: [{ id: 90, conversa_id: 1, origem: "contato", tipo: "texto",
                      texto: "Chegou agora, ninguém leu", id_uazapi: "nova-1",
                      criado_em: new Date().toISOString() }],
      },
    });
    await importar(t.porta);
    const conversa = t.sb.dados.conversas.find((c) => c.id === 1);
    ok("importar o passado não zera as mensagens por ler",
       conversa && conversa.nao_lidas === 3,
       `o selo foi para ${conversa && conversa.nao_lidas} — havia 3 mensagens novas por ler, `
       + "e nenhuma delas foi lida por causa de uma importação de histórico");
    await t.parar();
  }
}

// ==================================================================
//  8. A MÍDIA QUE CHEGA
// ==================================================================
{
  console.log("\n8. A mídia que chega");

  const fotoDaUazapi = (id) => ({
    EventType: "messages",
    owner: TELEFONE.numero,
    message: {
      id, messageid: id, chatid: "5511999998888@s.whatsapp.net",
      sender: "5511999998888@s.whatsapp.net", fromMe: false, isGroup: false,
      messageType: "image", type: "media", mediaType: "image",
      caption: "olha só", messageTimestamp: Date.now(), senderName: "Cliente Teste",
      content: { mimetype: "image/jpeg", JPEGThumbnail: "bWluaWF0dXJh" },
    },
  });

  // A rota que funciona nesta "versão" da Uazapi é a TERCEIRA da lista que a
  // ponte tenta. É o pior caso, e é o caso que revela o desperdício.
  const t = await subirTudo({}, { uazapi: { rotaDeDownload: "/downloadmedia" } });

  for (const id of ["f-1", "f-2", "f-3"]) {
    await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(fotoDaUazapi(id)),
    });
    await espera(900);
  }

  ok("a foto vira mensagem", t.sb.dados.mensagens.length === 3,
     `vieram ${t.sb.dados.mensagens.length}`);
  ok("e o arquivo é guardado no Storage", t.sb.arquivos.size === 3,
     `foram ${t.sb.arquivos.size} arquivo(s)`);
  ok("a mensagem aponta para o Storage, e não para a miniatura",
     t.sb.dados.mensagens.every((m) => String(m.midia_url || "").includes("/storage/")),
     JSON.stringify(t.sb.dados.mensagens.map((m) => String(m.midia_url || "").slice(0, 40))));

  // O DESPERDÍCIO.
  //
  // A ponte tenta três rotas de download, sempre na mesma ordem, e nunca
  // guarda qual funcionou. Se a que serve é a terceira, cada foto que chega
  // custa duas tentativas jogadas fora — e uma delas pode esperar 20 segundos
  // se o servidor não responder, com a mensagem parada até lá.
  const perdidas = t.uaz.recebidas.filter(
    (c) => c.caminho === "/message/downloadmedia" || c.caminho === "/message/download").length;
  console.log(`     3 fotos → ${perdidas} tentativa(s) de rota jogada(s) fora`);
  ok("a ponte lembra qual rota de download funciona",
     perdidas <= 2,
     `foram ${perdidas} para 3 fotos — a rota certa é descoberta na primeira e `
     + "não deveria ser procurada de novo a cada mídia");

  // O SIGILO NO LOG.
  //
  // Havia uma linha de diagnóstico que despejava o conteúdo de toda mídia
  // recebida no log — legenda, nome de arquivo, miniatura. Num escritório de
  // advocacia, log é lugar onde muita gente entra e nada se apaga.
  ok("o conteúdo da mídia não é despejado no log quando dá tudo certo",
     !t.registro.join("").includes("Mídia recebida (content)"),
     "o log traz o conteúdo da mensagem do cliente");

  await t.parar();
}

// ---- 8b. download impossível não pode perder a mensagem ----
{
  const t = await subirTudo({}, { uazapi: { rotaDeDownload: "/nenhuma" } });
  await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      EventType: "messages", owner: TELEFONE.numero,
      message: {
        id: "sem-download", messageid: "sem-download",
        chatid: "5511999998888@s.whatsapp.net", sender: "5511999998888@s.whatsapp.net",
        fromMe: false, messageType: "image", mediaType: "image", caption: "tenta essa",
        messageTimestamp: Date.now(), senderName: "Cliente",
        content: { mimetype: "image/jpeg", JPEGThumbnail: "bWluaWF0dXJh" },
      },
    }),
  });
  await espera(1200);
  const m = t.sb.dados.mensagens[0];
  ok("download que falha não faz a mensagem sumir", t.sb.dados.mensagens.length === 1,
     `ficaram ${t.sb.dados.mensagens.length}`);
  ok("e sobra a miniatura para a bolha não nascer vazia",
     m && String(m.midia_url || "").startsWith("data:image/jpeg"),
     m && String(m.midia_url || "").slice(0, 40));
  await t.parar();
}

// ==================================================================
//  9. POR QUE A MENSAGEM NÃO SAIU
// ==================================================================
//
// A bolha vermelha na tela dizia só "não enviado". Quem atende ficava sem saber
// se o número está errado, se o cliente não tem WhatsApp, se a linha do
// escritório caiu ou se foi coisa de um minuto — e cada um desses casos pede
// uma ação diferente. Sem o motivo, a única ação possível era clicar em
// reenviar e torcer.
{
  console.log("\n9. Por que a mensagem não saiu");

  /** Põe uma mensagem na fila, deixa a Uazapi recusar, e devolve a linha.
   *
   *  `extra` serve para o caso em que a Uazapi não RECUSA: ela demora, e quem
   *  desiste somos nós. Esse caminho precisa de um tempo limite curto, senão a
   *  prova esperaria os 15 segundos de produção. */
  async function tentarEnviar(falharEnvio, extra = {}) {
    const t = await subirTudo(extra.env || {},
                              { uazapi: { falharEnvio, ...(extra.uazapi || {}) } });
    t.sb.dados.contatos.push({ id: 1, numero: "5511999998888", nome: "Cliente" });
    t.sb.dados.conversas.push({ id: 1, advogado_id: TELEFONE.id, contato_id: 1 });
    t.sb.dados.fila_envio.push({
      id: 1, conversa_id: 1, tipo: "texto", texto: "Bom dia", status: "pendente",
      tentativas: 0, criado_em: new Date().toISOString(),
    });
    await fetch(`http://127.0.0.1:${t.porta}/ping`);
    await espera(1600);
    const linha = t.sb.dados.fila_envio.find((f) => f.id === 1);
    const registro = t.registro.join("");
    await t.parar();
    return { linha, registro };
  }

  // ---- 9a. número que não tem WhatsApp ----
  {
    const { linha } = await tentarEnviar({ status: 400, corpo: { error: "number not exists" } });
    ok("a falha vira erro na fila", linha?.status === "erro", `ficou ${linha?.status}`);
    ok("o motivo é dito em português, e diz o que fazer",
       /WhatsApp|escrito errado|Confira o número/i.test(linha?.erro_motivo || ""),
       `veio: ${JSON.stringify(linha?.erro_motivo)}`);
    ok("e o texto técnico continua guardado à parte",
       /number not exists/.test(linha?.erro_detalhe || ""),
       `veio: ${JSON.stringify(linha?.erro_detalhe)}`);
  }

  // ---- 9b. a linha do escritório desconectada ----
  //
  // Aqui há DUAS pessoas para avisar, e elas precisam de coisas diferentes: a
  // atendente lê a frase na bolha vermelha; quem administra precisa saber POR
  // QUAL TELEFONE nada mais sai. Em 19/08 o log trazia só o código do item —
  // "Falha ao enviar (7dbc4b7e-3fdc-…)" — e para descobrir qual linha tinha
  // caído era preciso ir ao banco.
  {
    const { linha, registro } = await tentarEnviar({
      status: 503, corpo: { error: true, message: "WhatsApp disconnected: session is not reconnectable" } });
    ok("linha desconectada diz que é preciso reconectar",
       /desconectada|reconectar/i.test(linha?.erro_motivo || ""),
       `veio: ${JSON.stringify(linha?.erro_motivo)}`);
    ok("e o log diz qual telefone do escritório caiu",
       new RegExp(TELEFONE.numero).test(registro), registro.slice(-400));
    ok("com o nome dele, para quem não decora número",
       new RegExp(TELEFONE.nome).test(registro), registro.slice(-400));
    ok("e para quem a mensagem ia",
       /5511999998888/.test(registro), registro.slice(-400));
    // O AVISO ALTO, separado da falha da mensagem: não é uma mensagem que deu
    // errado, é um telefone fora do ar.
    ok("e grita que NADA MAIS SAI por aquela linha",
       /LINHA DESCONECTADA/.test(registro) && /NADA MAIS SAI/.test(registro),
       registro.slice(-500));
    ok("dizendo o conserto — reconectar o aparelho",
       /reconectar o aparelho na Uazapi/.test(registro), registro.slice(-500));
  }

  // ---- 9b-bis. um erro comum NÃO vira aviso de linha caída ----
  //
  // Gritar "LINHA DESCONECTADA" por um número errado faria quem administra ir
  // reconectar um aparelho que está de pé. Aviso que grita à toa é aviso que
  // se aprende a ignorar.
  {
    const { registro } = await tentarEnviar({ status: 400, corpo: { error: "number not exists" } });
    ok("número inexistente não grita linha caída",
       !/LINHA DESCONECTADA/.test(registro), registro.slice(-300));
  }

  // ---- 9c. a Uazapi fora do ar ----
  {
    const { linha } = await tentarEnviar({ status: 502, corpo: { error: "bad gateway" } });
    ok("servidor fora do ar manda tentar de novo daqui a pouco",
       /daqui a pouco|reenviar/i.test(linha?.erro_motivo || ""),
       `veio: ${JSON.stringify(linha?.erro_motivo)}`);
  }

  // ---- 9d. um erro que a ponte NÃO conhece ----
  //
  // É o caso que mais importa. Frase genérica no lugar de um motivo
  // desconhecido seria pior do que nada: pareceria resposta, e quem lesse
  // pararia de procurar. Então `erro_motivo` fica vazio de propósito, a tela
  // mostra o texto cru, e o log grita — é assim que a lista de motivos cresce a
  // partir de casos reais em vez de adivinhação.
  {
    const { linha, registro } = await tentarEnviar({
      status: 418, corpo: { error: "sou um bule de cha" } });
    ok("erro desconhecido NÃO vira frase genérica",
       !linha?.erro_motivo,
       `inventou: ${JSON.stringify(linha?.erro_motivo)}`);
    ok("o texto cru é preservado para a tela mostrar",
       /bule de cha/.test(linha?.erro_detalhe || ""),
       `veio: ${JSON.stringify(linha?.erro_detalhe)}`);
    ok("e o log avisa que apareceu um motivo novo",
       /MOTIVO DE ERRO NÃO RECONHECIDO/.test(registro),
       "sem esse aviso, a lista de motivos nunca aprende com o uso");
  }

  // ---- 9e. AS FORMAS QUE APARECERAM DE VERDADE NO BANCO DO ESCRITÓRIO ----
  //
  // Não são exemplos inventados: saíram de uma varredura dos 238 erros
  // guardados no banco, agrupados pela forma do texto cru. Eram estas as seis
  // que chegavam à tela SEM tradução — 193 bolhas vermelhas mostrando JSON em
  // inglês para quem atende.
  //
  // Cinco o Zorvin já entendia: os registros eram antigos, de antes de a lista
  // ter aprendido essas frases (a última de cada grupo é de 12 a 18 de agosto,
  // e a varredura é de 28). Sobra uma, e ela estava VIVA — a mais recente de
  // todas, de ontem.
  //
  // Ficam aqui as seis, e não só a que faltava. Uma lista de motivos cresce
  // quando alguém acrescenta uma linha, e é fácil acrescentar uma linha que
  // apaga outra: `/abort/` no lugar de `/aborterror/` é exatamente o tipo de
  // alargamento que poderia engolir um caso vizinho. Estas são as formas que o
  // escritório vive, e agora elas se defendem sozinhas.
  {
    const DO_BANCO = [
      { quantas: 125, nome: "número não tem WhatsApp",
        falha: { status: 500, corpo: { error: "the number 5511991777483@s.whatsapp.net is not on WhatsApp" } },
        espera: /conta no WhatsApp|escrito errado/i },
      { quantas: 49, nome: "linha caída, sessão não reconectável",
        falha: { status: 503, corpo: { error: true, message: "WhatsApp disconnected: session is not reconnectable" } },
        espera: /desconectada|reconectar/i },
      { quantas: 16, nome: "linha caída, sem detalhe",
        falha: { status: 503, corpo: { error: true, message: "WhatsApp disconnected" } },
        espera: /desconectada|reconectar/i },
      { quantas: 1, nome: "whatsmeow não inicializado",
        falha: { status: 500, corpo: { error: "error sending message after 2 attempts: whatsmeow client not initialized" } },
        espera: /daqui a pouco|reenviar/i },
      { quantas: 1, nome: "cliente do WhatsApp desconectado",
        falha: { status: 500, corpo: { error: "WhatsApp client is not connected" } },
        espera: /desconectada|reconectar/i },
    ];
    for (const caso of DO_BANCO) {
      const { linha } = await tentarEnviar(caso.falha);
      ok(`traduz o que apareceu ${String(caso.quantas).padStart(3)}x — ${caso.nome}`,
         caso.espera.test(linha?.erro_motivo || ""),
         `veio: ${JSON.stringify(linha?.erro_motivo)} (cru: ${JSON.stringify(linha?.erro_detalhe)})`);
    }

    // A SEXTA, E A ÚNICA QUE AINDA ESTAVA VIVA: o nosso próprio tempo limite.
    //
    // Aqui a Uazapi não recusa nada — ela DEMORA, e quem desiste somos nós. O
    // Node anuncia isso como "This operation was aborted", sem o "error"
    // colado; o filtro procurava `aborterror`, que é o NOME DA CLASSE e não o
    // texto da mensagem. Resultado na tela da advogada: "This operation was
    // aborted", em inglês, sem nada a fazer com aquilo.
    //
    // Este caminho nunca tinha sido provado, e não por descuido: com o tempo
    // limite fixo em 15 segundos, prová-lo custava 15 segundos de espera. Ele
    // passou a vir de `UAZAPI_TIMEOUT_MS`, e a bancada o baixa para 300 ms.
    {
      const { linha } = await tentarEnviar(null, {
        env: { UAZAPI_TIMEOUT_MS: "300" },
        uazapi: { demoraDoEnvio: 1500 },
      });
      ok("a Uazapi que demora demais vira erro, e não fica pendurada",
         linha?.status === "erro", `ficou ${linha?.status}`);
      ok("traduz o nosso próprio tempo limite — era a única forma ainda viva",
         /não respondeu a tempo|nao respondeu a tempo/i.test(linha?.erro_motivo || ""),
         `veio: ${JSON.stringify(linha?.erro_motivo)} (cru: ${JSON.stringify(linha?.erro_detalhe)})`);
      ok("e o texto técnico continua guardado à parte",
         /abort/i.test(linha?.erro_detalhe || ""),
         `veio: ${JSON.stringify(linha?.erro_detalhe)}`);
    }
  }
}

// ============================================================
//  10. A FOTO DO CONTATO EM TAMANHO CHEIO
//
//  A foto guardada era a MINIATURA, porque `imagePreview` vinha na frente da
//  lista de campos do webhook. Corrigida a ordem, as novas chegam cheias; as
//  já guardadas só melhorariam quando o contato voltasse a escrever — um
//  cliente calado há um mês ficaria com a miniatura para sempre.
//
//  Esta rota vai buscar de novo, sob demanda. E, como no download de mídia, a
//  rota da Uazapi varia com a versão: o que se prova aqui é que ela PROCURA,
//  que LEMBRA a que serviu, e que quando nenhuma serve ela diz isso em vez de
//  falhar calada.
// ============================================================
console.log("\n10. A foto do contato em tamanho cheio");
{
  const CONTATO = { id: "ct-1", numero: "5567988887777", nome: "MARIA", foto_url: "https://falsa/mini.jpg" };
  const CONVERSA = { id: "cv-1", advogado_id: "adv-1", contato_id: "ct-1", nao_lidas: 0 };

  const pedirFoto = async (t, corpo = { conversa_id: "cv-1" }) => {
    const r = await fetch(`http://127.0.0.1:${t.porta}/contato/foto`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer jwt-bom" },
      body: JSON.stringify(corpo),
    });
    return { status: r.status, corpo: await r.json().catch(() => ({})) };
  };

  // ---- 10a. acha a cheia, e não a miniatura ----
  {
    const t = await subirTudo({}, {
      tabelas: { contatos: [{ ...CONTATO }], conversas: [{ ...CONVERSA }] },
      uazapi: { rotaDeFoto: "/chat/details" },
    });
    const { corpo } = await pedirFoto(t);
    ok("traz a foto cheia, e não a miniatura",
       corpo.ok && /cheia/.test(corpo.foto_url || ""),
       `veio: ${JSON.stringify(corpo)}`);
    ok("e grava no contato, para valer da próxima vez também",
       /cheia/.test((t.sb.dados.contatos[0] || {}).foto_url || ""),
       `ficou: ${JSON.stringify((t.sb.dados.contatos[0] || {}).foto_url)}`);
    await t.parar();
  }

  // ---- 10b. a rota que serve é lembrada ----
  //
  // Sem lembrar, cada pedido recomeça pelas 404 — e o preço não é só tempo: é
  // uma sequência de erros no log do servidor da Uazapi a cada foto.
  {
    const t = await subirTudo({}, {
      tabelas: { contatos: [{ ...CONTATO }], conversas: [{ ...CONVERSA }] },
      uazapi: { rotaDeFoto: "/contact/picture" },   // a ÚLTIMA da lista
    });
    await pedirFoto(t);
    const antes = t.uaz.recebidas.filter((c) => /chat|contact/.test(c.caminho)).length;
    await pedirFoto(t);
    const depois = t.uaz.recebidas.filter((c) => /chat|contact/.test(c.caminho)).length;
    ok("o segundo pedido vai direto na rota que serviu",
       depois - antes === 1,
       `o primeiro tentou ${antes}, o segundo tentou ${depois - antes}`);
    await t.parar();
  }

  // ---- 10c. nenhuma rota serve ----
  //
  // O caso que mais importa: o servidor pode não ter NENHUMA dessas rotas.
  // Falhar calada deixaria o botão girando para sempre; o log tem de dizer o
  // que foi tentado, para uma linha na lista resolver quando se souber a certa.
  {
    const t = await subirTudo({}, {
      tabelas: { contatos: [{ ...CONTATO }], conversas: [{ ...CONVERSA }] },
      uazapi: { rotaDeFoto: null },
    });
    const { status, corpo } = await pedirFoto(t);
    ok("sem rota que sirva, responde em português", status >= 400 && /não consegui/i.test(corpo.erro || ""),
       `veio: ${status} ${JSON.stringify(corpo)}`);
    ok("e a foto que já existia NÃO é apagada",
       (t.sb.dados.contatos[0] || {}).foto_url === "https://falsa/mini.jpg",
       "meia foto é melhor do que nenhuma");
    await espera(300);
    ok("e o log diz o que foi tentado",
       /nenhuma rota serviu/.test(t.registro.join("")),
       "sem isso, descobrir a rota certa exige adivinhação");
    await t.parar();
  }

  // ---- 10d. grupo não tem foto de perfil ----
  {
    const t = await subirTudo({}, {
      tabelas: {
        contatos: [{ id: "ct-g", numero: "grupo:12036@g.us", nome: "GRUPO", foto_url: null }],
        conversas: [{ id: "cv-g", advogado_id: "adv-1", contato_id: "ct-g", nao_lidas: 0 }],
      },
    });
    const { status } = await pedirFoto(t, { conversa_id: "cv-g" });
    ok("grupo recusa antes de sair perguntando", status === 400);
    await t.parar();
  }

  // ---- 10e. sem login ----
  {
    const t = await subirTudo({}, {
      tabelas: { contatos: [{ ...CONTATO }], conversas: [{ ...CONVERSA }] },
    });
    const r = await fetch(`http://127.0.0.1:${t.porta}/contato/foto`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ conversa_id: "cv-1" }),
    });
    ok("sem login, não passa", r.status === 401, `veio ${r.status}`);
    await t.parar();
  }
}

// ============================================================
//  11. UMA VARIÁVEL MAL COLADA NÃO PODE DERRUBAR A ENTRADA
//
//  Aconteceu numa manhã de expediente: `PAINEL_ORIGEM` foi preenchida com uma
//  quebra de linha invisível no fim. O Node recusa pôr "\n" num cabeçalho e
//  lança `ERR_INVALID_CHAR` — DENTRO da rota, que morre antes de responder. O
//  navegador vê a conexão falhar e escreve "Load failed"; o log mostra uma
//  pilha de erro que não menciona a variável. Ninguém do escritório entrou.
//
//  O que se prova aqui é que a entrada RESPONDE mesmo com a variável torta.
// ============================================================
console.log("\n11. PAINEL_ORIGEM torta não derruba a entrada");
{
  const pedirPermissao = async (t) => {
    const r = await fetch(`http://127.0.0.1:${t.porta}/auth/login`, {
      method: "OPTIONS",
      headers: { Origin: "https://zorvin.exemplo.com.br" },
    });
    return { status: r.status, origem: r.headers.get("access-control-allow-origin") };
  };

  // ---- 11a. com quebra de linha no fim — o caso real ----
  {
    const t = await subirTudo({ PAINEL_ORIGEM: "https://zorvin.exemplo.com.br\n" });
    const { status, origem } = await pedirPermissao(t);
    ok("com quebra de linha, o pedido de permissão ainda responde", status === 204,
       `veio ${status} — antes a rota estourava e o navegador dizia "Load failed"`);
    ok("e o cabeçalho sai limpo", origem === "https://zorvin.exemplo.com.br",
       `veio: ${JSON.stringify(origem)}`);
    await espera(200);
    ok("e o log conta o que arrumou", /PAINEL_ORIGEM tinha espaço/.test(t.registro.join("")),
       "consertar calado esconde a configuração errada");
    await t.parar();
  }

  // ---- 11b. com barra no fim — o engano mais comum ----
  //
  // A barra não estoura, mas não CASA: o navegador compara letra por letra e
  // descarta a resposta. Falha silenciosa, do tipo que ninguém acha.
  {
    const t = await subirTudo({ PAINEL_ORIGEM: "https://zorvin.exemplo.com.br/" });
    const { origem } = await pedirPermissao(t);
    ok("a barra no fim é tirada", origem === "https://zorvin.exemplo.com.br",
       `veio: ${JSON.stringify(origem)}`);
    await t.parar();
  }

  // ---- 11c. valor que não é endereço nenhum ----
  {
    const t = await subirTudo({ PAINEL_ORIGEM: "sim" });
    const { status, origem } = await pedirPermissao(t);
    ok("valor sem sentido não derruba nada", status === 204);
    ok("e cai no padrão de aceitar qualquer origem", origem === "*",
       `veio: ${JSON.stringify(origem)} — degradar avisando é melhor do que parar`);
    await espera(200);
    ok("dizendo no log o que a variável deveria ser",
       /PAINEL_ORIGEM não parece um endereço/.test(t.registro.join("")));
    await t.parar();
  }

  // ---- 11d. e a entrada de verdade continua respondendo ----
  {
    const t = await subirTudo({ PAINEL_ORIGEM: "https://zorvin.exemplo.com.br\n" });
    const r = await fetch(`http://127.0.0.1:${t.porta}/auth/login`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Origin: "https://zorvin.exemplo.com.br" },
      body: JSON.stringify({ login: "alguem", senha: "x" }),
    });
    ok("a entrada responde em vez de estourar", r.status < 500 || r.status === 503,
       `veio ${r.status}`);
    ok("com o cabeçalho de origem no lugar",
       r.headers.get("access-control-allow-origin") === "https://zorvin.exemplo.com.br");
    await t.parar();
  }
}

// ============================================================
//  12. UM PASSO DA ENTRADA QUE TRAVA NÃO TRAVA A ENTRADA
//
//  O caso real: o log dizia "tentativa de rodrigo.sousa" e depois SILÊNCIO. A
//  entrada é uma fila de cinco idas à rede e só a primeira tinha prazo; as
//  outras, travando, penduravam tudo. A tela esperou 75 segundos e desistiu,
//  sem que ninguém pudesse dizer qual passo estava parado.
//
//  Aqui o Vantoro de mentira simplesmente não responde. Antes, a entrada ficava
//  pendurada junto; agora ela desiste, diz QUAL passo e devolve o botão.
// ============================================================
console.log("\n12. Um passo travado não pendura a entrada");
{
  // Um Vantoro que aceita a conexão e nunca responde — o pior tipo de falha,
  // porque não dá erro: só não volta.
  const mudo = http.createServer(() => { /* nunca responde */ });
  await new Promise((r) => mudo.listen(0, "127.0.0.1", r));
  const urlMudo = `http://127.0.0.1:${mudo.address().port}`;

  const t = await subirTudo({ VANTORO_API_URL: urlMudo, VANTORO_API_TOKEN: "tok" });
  const comecou = Date.now();
  const r = await fetch(`http://127.0.0.1:${t.porta}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ login: "rodrigo.sousa", senha: "x" }),
  });
  const levou = Date.now() - comecou;
  const corpo = await r.json().catch(() => ({}));

  ok("a entrada responde em vez de ficar pendurada", r.status >= 400 && r.status < 600,
     `veio ${r.status} depois de ${levou}ms`);
  ok("e responde antes dos 75 segundos que a tela espera", levou < 40000,
     `levou ${levou}ms`);
  ok("dizendo qual passo não respondeu", /não respondeu/.test(corpo.erro || ""),
     `veio: ${JSON.stringify(corpo.erro)}`);
  await espera(300);
  ok("e o log marca o passo e o tempo",
     /entrada · perguntar ao Vantoro: FALHOU/.test(t.registro.join("")),
     "sem isso, 'não entrou' continua sendo tudo o que se sabe");

  await t.parar();
  await new Promise((r) => mudo.close(r));
}

// ============================================================
//  13. QUEM JÁ ENTROU UMA VEZ NÃO PASSA MAIS PELO AUTH
//
//  A entrada chamava `createUser` A CADA LOGIN, contando com o erro "já
//  registrado" para descobrir que a conta existe. Uma ESCRITA na API de
//  administração do Auth por login de cada pessoa, para responder o que o
//  banco responde num piscar.
//
//  No dia em que essa API ficou lenta: entrada de 6 minutos e meio, e depois
//  nem isso. O escritório inteiro na porta, e o passo que travava era a
//  criação de contas que existiam há meses.
// ============================================================
console.log("\n13. Quem já entrou não passa mais pelo Auth");
{
  const VANTORO = { usuarios: [{ login: "rodrigo.sousa", nome: "Rodrigo Sousa",
                                 email: "rodrigo.sousa@x", admin: true }] };
  const entrar = (t) => fetch(`http://127.0.0.1:${t.porta}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ login: "rodrigo.sousa", senha: "certa" }),
  });

  // ---- 13a. já está em `usuarios`: nem toca no Auth ----
  {
    const t = await subirTudo({}, {
      vantoro: VANTORO,
      tabelas: { usuarios: [{ id: "11111111-1111-1111-1111-111111111111", login: "rodrigo.sousa",
                              nome: "Rodrigo Sousa", email: "rodrigo.sousa@x", admin: true }] },
      // A conta no Auth existe, como existe em produção para quem já entrou.
      contas: [{ id: "11111111-1111-1111-1111-111111111111", email: "rodrigo.sousa@x", jwt: "jwt-bom",
                 user_metadata: { nome: "Rodrigo Sousa" } }],
    });
    const r = await entrar(t);
    const corpo = await r.json().catch(() => ({}));
    ok("entra", r.status === 200 && corpo.ok, `veio ${r.status} ${JSON.stringify(corpo.erro)}`);

    const criacoes = t.sb.chamadas.filter(
      (c) => c.caminho === "/auth/v1/admin/users" && c.metodo === "POST").length;
    ok("sem criar conta nenhuma no Auth", criacoes === 0,
       `bateu ${criacoes}× na criação de contas — era uma escrita por login de cada pessoa`);
    await t.parar();
  }

  // ---- 13b. primeira entrada da vida: o caminho antigo continua ----
  //
  // Quem nunca entrou não está em `usuarios`, e a conta precisa nascer. Se
  // esta parte quebrasse, ninguém novo entraria nunca — e isso só apareceria
  // no dia da contratação.
  {
    const t = await subirTudo({}, { vantoro: VANTORO, tabelas: { usuarios: [] } });
    const r = await entrar(t);
    const corpo = await r.json().catch(() => ({}));
    ok("quem nunca entrou continua entrando", r.status === 200 && corpo.ok,
       `veio ${r.status} ${JSON.stringify(corpo.erro)}`);
    ok("e fica gravado para a próxima ser barata",
       (t.sb.dados.usuarios || []).some((u) => u.email === "rodrigo.sousa@x"),
       JSON.stringify(t.sb.dados.usuarios));
    await t.parar();
  }
}

// ============================================================
//  14. QUANDO O AUTH NÃO DÁ O BILHETE, A PONTE ASSINA
//
//  Medido em produção em 19/08: "gerar o bilhete: FALHOU depois de 20002ms",
//  três vezes seguidas, e o log com uma página do Cloudflare dizendo
//  "Error 521". O banco respondia em 168ms na MESMA chamada. Metade do
//  projeto de pé, metade no chão — e a metade no chão era a porta de entrada.
//
//  Havia uma segunda tentativa aqui, e ela saiu: ela existia porque desistir
//  era não entrar. Hoje desistir é entrar pelo outro caminho.
// ============================================================
console.log("\n14. Sem o Auth, a ponte assina a sessão");
{
  const SEGREDO = "um-segredo-de-teste-com-tamanho-suficiente";
  const PESSOA = { id: "11111111-1111-1111-1111-111111111111", login: "rodrigo.sousa",
                   nome: "Rodrigo Sousa", email: "rodrigo.sousa@x", admin: true };
  const base = {
    vantoro: { usuarios: [{ login: "rodrigo.sousa", nome: "Rodrigo Sousa",
                            email: "rodrigo.sousa@x", admin: true }] },
    tabelas: { usuarios: [PESSOA] },
    contas: [{ id: PESSOA.id, email: "rodrigo.sousa@x", jwt: "jwt-bom",
               user_metadata: { nome: "Rodrigo Sousa" } }],
  };
  const entrar = (t) => fetch(`http://127.0.0.1:${t.porta}/auth/login`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ login: "rodrigo.sousa", senha: "x" }),
  });

  /** Lê o miolo de um bilhete sem conferir nada — é o teste olhando. */
  const miolo = (jwt) => JSON.parse(
    Buffer.from(String(jwt).split(".")[1], "base64url").toString("utf8"));

  // ---- 14a. com o Auth de pé: os DOIS caminhos vêm na resposta ----
  //
  // O de sempre continua primeiro, porque a sessão que sai dele se renova
  // sozinha. O assinado vem junto, no bolso, para o caso de o `verifyOtp` do
  // painel falhar depois de o `generateLink` daqui ter dado certo — são duas
  // chamadas ao mesmo serviço doente, e elas falham separadas.
  {
    const t = await subirTudo({ SUPABASE_JWT_SECRET: SEGREDO }, base);
    const corpo = await (await entrar(t)).json().catch(() => ({}));
    ok("entra", corpo.ok === true, JSON.stringify(corpo.erro));
    ok("com o bilhete do Auth", !!corpo.token_hash);
    ok("e com a sessão assinada aqui, junto", !!(corpo.sessao && corpo.sessao.access_token));
    await t.parar();
  }

  // ---- 14b. com o Auth no chão: entra do mesmo jeito ----
  {
    const t = await subirTudo({ SUPABASE_JWT_SECRET: SEGREDO }, { ...base, authNoChao: true });
    const r = await entrar(t);
    const corpo = await r.json().catch(() => ({}));
    ok("com o Auth fora do ar, a pessoa AINDA ENTRA", r.status === 200 && corpo.ok === true,
       `veio ${r.status} ${JSON.stringify(corpo.erro)} — era esta a manhã de 19/08`);
    ok("sem bilhete do Auth, porque ele não respondeu", !corpo.token_hash);
    ok("e com a sessão assinada pela ponte", !!(corpo.sessao && corpo.sessao.access_token));

    const c = corpo.sessao ? miolo(corpo.sessao.access_token) : {};
    // `sub` é de onde sai `auth.uid()`, e é `auth.uid()` que decide quais
    // conversas a pessoa abre. Errar isto seria dar a sessão de outra pessoa.
    ok("o bilhete diz QUEM é a pessoa", c.sub === PESSOA.id, `dizia sub=${c.sub}`);
    ok("com o papel que o banco espera", c.role === "authenticated" && c.aud === "authenticated");
    ok("e o e-mail dela", c.email === "rodrigo.sousa@x", `dizia ${c.email}`);
    // Doze horas: mais do que um expediente, porque não há como renovar.
    const horas = (c.exp - c.iat) / 3600;
    ok("valendo por um expediente inteiro", horas >= 8 && horas <= 24, `valia ${horas}h`);

    ok("e o log conta que foi por aí",
       /assinando a sessão aqui mesmo/.test(t.registro.join("")));
    await t.parar();
  }

  // ---- 14c. o bilhete assinado ABRE AS PORTAS, sem perguntar ao Auth ----
  //
  // Era o segundo lugar em que a entrada dependia do Auth, e o menos óbvio:
  // `exigirLogin` chamava `auth.getUser` a cada pedido do painel. Com o Auth
  // fora, quem já estava logado ia perdendo a Ficha e o Histórico à medida
  // que a lembrança de 60 segundos vencia — e as mensagens continuavam
  // chegando, o que fazia a coisa parecer defeito da tela.
  {
    const t = await subirTudo({ SUPABASE_JWT_SECRET: SEGREDO }, { ...base, authNoChao: true });
    const corpo = await (await entrar(t)).json().catch(() => ({}));
    const bilhete = corpo.sessao && corpo.sessao.access_token;
    ok("tem bilhete para usar", !!bilhete);

    const antes = t.sb.chamadas.filter((c) => c.caminho === "/auth/v1/user").length;
    const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/buscar?q=ab`, {
      headers: { Authorization: `Bearer ${bilhete}` },
    });
    ok("o painel passa pela porta com ele", r.status !== 401,
       `veio ${r.status} — 401 é a ponte dizendo "faça login"`);
    const depois = t.sb.chamadas.filter((c) => c.caminho === "/auth/v1/user").length;
    ok("e a ponte não foi perguntar ao Auth", depois === antes,
       `foi ${depois - antes}× — com o Auth no chão, perguntar é não entrar`);
    await t.parar();
  }

  // ---- 14d. bilhete mexido não passa ----
  //
  // O que separa "assinar a própria sessão" de "qualquer um assinar a sessão
  // de qualquer um" é exatamente esta conferência.
  {
    const t = await subirTudo({ SUPABASE_JWT_SECRET: SEGREDO }, base);
    const corpo = await (await entrar(t)).json().catch(() => ({}));
    const bom = corpo.sessao.access_token;
    const [cab, mio, ass] = bom.split(".");

    // (1) trocar a pessoa mantendo a assinatura
    const outroMiolo = Buffer.from(JSON.stringify({ ...miolo(bom), sub: "99999999-9999-9999-9999-999999999999" }))
      .toString("base64url");
    const trocado = `${cab}.${outroMiolo}.${ass}`;
    // (2) mexer só na assinatura
    const rabiscado = `${cab}.${mio}.${ass.slice(0, -3)}xyz`;
    // (3) assinar com OUTRO segredo — é o caso de quem tem o formato mas não
    //     tem a chave, que é o atacante realista
    const outro = crypto.createHmac("sha256", "um-segredo-completamente-diferente-aqui")
      .update(`${cab}.${mio}`).digest("base64url");
    const forjado = `${cab}.${mio}.${outro}`;
    // (4) vencido: assinado com o segredo CERTO, mas com o prazo no passado
    const passado = Math.floor(Date.now() / 1000) - 60;
    const velhoMiolo = Buffer.from(JSON.stringify({ ...miolo(bom), exp: passado }))
      .toString("base64url");
    const velhoAss = crypto.createHmac("sha256", SEGREDO)
      .update(`${cab}.${velhoMiolo}`).digest("base64url");
    const vencido = `${cab}.${velhoMiolo}.${velhoAss}`;

    for (const [nome, jwt] of [["com outra pessoa dentro", trocado],
                               ["com a assinatura rabiscada", rabiscado],
                               ["assinado com outro segredo", forjado],
                               ["com o prazo vencido", vencido]]) {
      const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/buscar?q=ab`, {
        headers: { Authorization: `Bearer ${jwt}` },
      });
      ok(`bilhete ${nome}: recusado`, r.status === 401, `veio ${r.status}`);
    }
    await t.parar();
  }

  // ---- 14e. sem o segredo configurado, nada muda ----
  //
  // É o que torna esta mudança segura de soltar: onde a variável não estiver
  // posta, a entrada é exatamente a de antes. Ela não pode quebrar nada por
  // si só — só entra em cena onde foi ligada.
  {
    const t = await subirTudo({}, base);
    const corpo = await (await entrar(t)).json().catch(() => ({}));
    ok("sem segredo, entra pelo caminho de sempre", corpo.ok === true);
    ok("com o bilhete do Auth", !!corpo.token_hash);
    ok("e sem sessão assinada nenhuma", !corpo.sessao);

    // E a conferência de sessão volta a ser a ida ao Supabase.
    const antes = t.sb.chamadas.filter((c) => c.caminho === "/auth/v1/user").length;
    await fetch(`http://127.0.0.1:${t.porta}/vantoro/buscar?q=ab`, {
      headers: { Authorization: "Bearer jwt-bom" },
    });
    const depois = t.sb.chamadas.filter((c) => c.caminho === "/auth/v1/user").length;
    ok("e a sessão continua sendo conferida com o Supabase", depois > antes);
    await t.parar();
  }

  // ---- 14f. sem segredo E com o Auth no chão: a mensagem é honesta ----
  {
    const t = await subirTudo({}, { ...base, authNoChao: true });
    const r = await entrar(t);
    const corpo = await r.json().catch(() => ({}));
    ok("não entra, que é a verdade", r.status >= 400 && !corpo.ok, `veio ${r.status}`);
    ok("e o log diz o que falta configurar",
       /SUPABASE_JWT_SECRET/.test(t.registro.join("")),
       "quem administra precisa saber que existe conserto");
    await t.parar();
  }
}

// ============================================================
//  15. AO SUBIR, A PONTE DIZ COMO ESTÁ A ENTRADA
//
//  A saída para o Auth fora do ar só aparece no dia em que o Auth cair. Até
//  lá, ligada ou desligada, a ponte se comporta igual — e quem configurou a
//  variável não teria como saber se acertou. Descobrir no dia seria descobrir
//  do pior jeito possível.
// ============================================================
console.log("\n15. O log conta se a ponte sabe assinar");
{
  const SEGREDO = "um-segredo-de-teste-com-tamanho-suficiente";

  {
    const t = await subirTudo({ SUPABASE_JWT_SECRET: SEGREDO }, {});
    await espera(800);
    const log = t.registro.join("");
    ok("com a variável posta, o log diz que sabe", /sei assinar a sessão/.test(log), log.slice(-300));
    await t.parar();
  }

  {
    const t = await subirTudo({}, {});
    await espera(800);
    const log = t.registro.join("");
    ok("sem ela, o log diz o que falta", /SUPABASE_JWT_SECRET não está configurada/.test(log),
       log.slice(-300));
    ok("e onde achar o valor", /JWT Keys/.test(log), log.slice(-300));
    await t.parar();
  }

  // O PROJETO QUE MIGROU PARA CHAVE ASSIMÉTRICA. O Supabase oferece isso num
  // botão; depois dele, o banco recusa os bilhetes HS256 que a ponte assina, e
  // a saída deixaria de funcionar EM SILÊNCIO até o dia em que fosse precisa.
  {
    const t = await subirTudo({ SUPABASE_JWT_SECRET: SEGREDO }, { jwksAssimetrico: true });
    await espera(1200);
    const log = t.registro.join("");
    ok("migrando para chave assimétrica, o log avisa em letras grandes",
       /passou a assinar com chave assimétrica/.test(log), log.slice(-400));
    await t.parar();
  }
}

// ============================================================
//  16. O LOG DIZ DE QUEM ERA O WEBHOOK RECUSADO
//
//  Em 19/08 apareceram vinte "Webhook recusado: segredo ausente ou errado."
//  em vinte minutos, e a linha não dizia de quem. Dois casos opostos se
//  escreviam igual: um telefone do escritório cadastrado sem o `?token=` na
//  Uazapi — e aí são mensagens de cliente sendo jogadas fora, sem ninguém
//  perceber — ou alguém varrendo a internet, e aí recusar é o certo.
// ============================================================
console.log("\n16. Um webhook recusado diz de quem era");
{
  const t = await subirTudo({ WEBHOOK_TOKEN: "segredo-certo" }, {});
  const bater = (busca, corpo) => fetch(`http://127.0.0.1:${t.porta}/webhook${busca}`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(corpo),
  });

  // (1) sem segredo nenhum: o caso do telefone mal cadastrado
  const r1 = await bater("", { EventType: "messages", owner: "5511976378160" });
  ok("recusa quem não traz segredo", r1.status === 403);
  await espera(200);
  let log = t.registro.join("");
  ok("dizendo qual telefone era", /5511976378160/.test(log), log.slice(-300));
  ok("e que veio sem segredo nenhum", /sem segredo nenhum/.test(log), log.slice(-300));
  ok("e apontando o conserto, com o risco escrito",
     /\?token=/.test(log) && /PERDIDAS/.test(log), log.slice(-400));

  // (2) segredo errado: outra coisa, e a linha tem de separar
  const r2 = await bater("?token=chute", { EventType: "messages", owner: "5511900000000" });
  ok("recusa quem traz o segredo errado", r2.status === 403);
  await espera(200);
  log = t.registro.join("");
  ok("chamando isso de segredo ERRADO, e não de ausente", /segredo ERRADO/.test(log),
     log.slice(-300));

  // (3) O SEGREDO NUNCA VAI PARA O LOG. Nem o certo, nem o que tentaram.
  ok("e o segredo não aparece em lugar nenhum do log",
     !/segredo-certo/.test(log) && !/token=chute/.test(log),
     "log de escritório de advocacia é lugar onde muita gente entra e nada se apaga");

  // (4) VINTE IGUAIS NÃO VIRAM VINTE LINHAS. Senão o próprio volume empurra
  //     para fora do log o que a gente foi ali procurar.
  const antes = t.registro.join("").split("Webhook recusado").length - 1;
  for (let i = 0; i < 12; i += 1) await bater("", { EventType: "messages", owner: "5511976378160" });
  await espera(300);
  const depois = t.registro.join("").split("Webhook recusado").length - 1;
  ok("doze recusas iguais não viram doze linhas", depois - antes <= 1,
     `viraram ${depois - antes}`);

  await t.parar();
}

// ============================================================
//  17. O ENDEREÇO DE ARQUIVO APARECE NO LOG — E SEM A PARTE ASSINADA
//
//  Esta seção nasceu quando o endereço era JOGADO FORA e a pergunta era se
//  daria para aproveitá-lo. Deu (ver a seção 18), e o que sobra aqui continua
//  valendo: quem lê o log precisa ver o id da mensagem inteiro, para cruzar
//  com um download que falhou — e não precisa ver a assinatura do endereço,
//  que dá acesso ao arquivo e não ajuda em nada.
// ============================================================
console.log("\n17. O endereço de arquivo aparece no log, sem a parte assinada");
{
  const t = await subirTudo({}, {});
  await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      EventType: "messages_update",
      event: {
        Chat: "558199043770@s.whatsapp.net",
        FileURL: "https://novaera.uazapi.com/files/abc123.pdf?assinatura=xyz",
        MessageIDs: ["A55DC78559D9CE9881F208"],
        Type: "Delivered",
      },
    }),
  });
  await espera(500);
  const log = t.registro.join("");
  ok("o log conta que veio um endereço de arquivo",
     /Endereço de arquivo recebido/.test(log), log.slice(-400));
  ok("com o id da mensagem inteiro, para cruzar com o download que falhou",
     /A55DC78559D9CE9881F208/.test(log), log.slice(-400));
  ok("e sem a parte assinada do endereço, que dá acesso e não ajuda",
     /abc123\.pdf/.test(log) && !/assinatura=xyz/.test(log), log.slice(-400));
  await t.parar();
}

// ============================================================
//  18. O ANEXO QUE FICARIA VAZIO
//
//  Do log de 19/08, com um segundo de diferença:
//
//    Anexo (documento) sem arquivo: o download falhou.
//    Mensagem A5F59D4D… fica sem mídia.
//    Evento não tratado: messages_update {…"FileURL":"https://…jpg"…
//
//  Alguém abriu essa conversa e viu um anexo em branco — um documento que o
//  cliente mandou e o escritório não tem. E o endereço do arquivo chegou um
//  segundo depois, indo direto para o balde dos eventos ignorados.
//
//  O casamento é pelo id EXATO da mensagem, e a prova mais importante desta
//  seção é a que confere que ele NÃO acontece quando o id não bate.
// ============================================================
console.log("\n18. O anexo não fica vazio");
{
  const CHAT = "5511999998888@s.whatsapp.net";
  const midiaDaUazapi = (id) => ({
    EventType: "messages",
    owner: TELEFONE.numero,
    message: {
      id, messageid: id, chatid: CHAT, sender: CHAT, fromMe: false, isGroup: false,
      messageType: "documentMessage", mimetype: "application/pdf",
      content: { mimetype: "application/pdf", fileName: "peticao.pdf" },
      messageTimestamp: Date.now(), wasSentByApi: false, senderName: "Cliente",
    },
  });
  const enderecoDoArquivo = (t, ids) => ({
    BaseUrl: t.uaz.url,
    EventType: "messages_update",
    event: { Chat: CHAT, FileURL: `${t.uaz.url}/files/abc.pdf?assinatura=xyz`,
             MessageIDs: ids, Type: "Delivered" },
  });
  const mandar = (t, corpo) => fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(corpo),
  });
  const mensagemDe = (t, id) => (t.sb.dados.mensagens || []).find((m) => m.id_uazapi === id);

  // ---- 18a. o endereço chega DEPOIS — o caso exato do log ----
  {
    // `rotaDeDownload: null` é o servidor em que NENHUMA rota de download
    // serve: é assim que se reproduz o "o download falhou" sem depender de
    // uma Uazapi de verdade tendo um dia ruim.
    const t = await subirTudo({}, { uazapi: { rotaDeDownload: null } });
    await mandar(t, midiaDaUazapi("MSG-VAZIA"));
    await espera(900);

    const antes = mensagemDe(t, "MSG-VAZIA");
    ok("a mensagem entra mesmo sem o arquivo", !!antes,
       "perder a bolha inteira seria pior: ninguém saberia que veio algo");
    ok("e entra vazia, como entrou em 19/08", antes && !antes.midia_url,
       `veio ${antes && antes.midia_url}`);

    await mandar(t, enderecoDoArquivo(t, ["MSG-VAZIA"]));
    await espera(1200);

    const depois = mensagemDe(t, "MSG-VAZIA");
    ok("o endereço que chega depois preenche o anexo", !!(depois && depois.midia_url),
       "era o documento do cliente que ficava faltando");
    ok("e o log conta o resgate",
       /Anexo resgatado/.test(t.registro.join("")), t.registro.join("").slice(-300));
    await t.parar();
  }

  // ---- 18b. o endereço chega ANTES ----
  //
  // Acontece sempre que o evento do arquivo vem na frente da mensagem — foi o
  // que o log mostrou nas duas vezes seguintes. Aí não há o que resgatar: o
  // endereço guardado é usado na hora em que o download falha.
  {
    const t = await subirTudo({}, { uazapi: { rotaDeDownload: null } });
    await mandar(t, enderecoDoArquivo(t, ["MSG-ANTES"]));
    await espera(400);
    await mandar(t, midiaDaUazapi("MSG-ANTES"));
    await espera(1200);

    const m = mensagemDe(t, "MSG-ANTES");
    ok("a mensagem já nasce com o arquivo", !!(m && m.midia_url), `veio ${m && m.midia_url}`);
    ok("e o log diz por onde veio",
       /endereço que a Uazapi mandou à parte/.test(t.registro.join("")),
       t.registro.join("").slice(-300));
    await t.parar();
  }

  // ---- 18c. UM ANEXO QUE JÁ CHEGOU NUNCA É SOBRESCRITO ----
  //
  // Esta é a que separa um resgate de um estrago. Se o endereço que chega
  // pudesse passar por cima do arquivo que já está lá, um evento repetido
  // trocaria o documento de um cliente pelo de outro.
  {
    const t = await subirTudo({}, {});   // aqui o download FUNCIONA
    await mandar(t, midiaDaUazapi("MSG-CHEIA"));
    await espera(900);
    const original = mensagemDe(t, "MSG-CHEIA");
    ok("a mensagem chegou com arquivo", !!(original && original.midia_url));

    await mandar(t, enderecoDoArquivo(t, ["MSG-CHEIA"]));
    await espera(1000);
    const agora = mensagemDe(t, "MSG-CHEIA");
    ok("o endereço que chega depois NÃO troca o arquivo que já existe",
       agora && agora.midia_url === original.midia_url,
       `era ${original && original.midia_url}, virou ${agora && agora.midia_url}`);
    await t.parar();
  }

  // ---- 18d. id que não existe não escreve em ninguém ----
  {
    const t = await subirTudo({}, {});
    await mandar(t, midiaDaUazapi("MSG-OUTRA"));
    await espera(900);
    const antes = mensagemDe(t, "MSG-OUTRA");

    await mandar(t, enderecoDoArquivo(t, ["ID-QUE-NAO-EXISTE"]));
    await espera(900);
    const depois = mensagemDe(t, "MSG-OUTRA");
    ok("um endereço de id desconhecido não encosta em mensagem nenhuma",
       depois && depois.midia_url === antes.midia_url,
       "casar por id exato é o que separa um resgate de um estrago");
    ok("e nada estoura por causa disso",
       !/uncaughtException|unhandledRejection/.test(t.registro.join("")));
    await t.parar();
  }

  // ---- 18e. o endereço que já não serve mais ----
  {
    // Um resgate tardio: a Uazapi apagou o arquivo. Tem de falhar quieto, sem
    // derrubar nada e sem gravar um endereço quebrado na mensagem.
    const t = await subirTudo({}, { uazapi: { rotaDeDownload: null, arquivoPorEndereco: null } });
    await mandar(t, midiaDaUazapi("MSG-TARDE"));
    await espera(900);
    await mandar(t, enderecoDoArquivo(t, ["MSG-TARDE"]));
    await espera(1200);

    const m = mensagemDe(t, "MSG-TARDE");
    ok("a mensagem continua sem arquivo, e não com um endereço quebrado",
       m && !m.midia_url, `veio ${m && m.midia_url}`);
    ok("e o log diz que não deu",
       /não consegui resgatar|também não serviu/i.test(t.registro.join("")),
       t.registro.join("").slice(-300));
    await t.parar();
  }
}


// ==================================================================
//  19. A BOLHA NÃO ESPERA O ARQUIVO
//
//  Relato de quem usa: "ao enviar ou receber algum arquivo, está demorando
//  para aparecer o arquivo na conversa".
//
//  O caminho de recebimento fazia tudo em fila indiana, e só no fim gravava:
//
//     webhook chega
//       → /message/downloadmedia na Uazapi   (até 20s, e até 3 rotas)
//       → baixa o arquivo                     (uma foto de celular são MBs)
//       → sobe para o Storage do Supabase
//       → SÓ ENTÃO insere a mensagem no banco
//       → só então o tempo real acende a bolha na tela
//
//  Enquanto isso a conversa fica VAZIA. Não é o arquivo que demora a aparecer:
//  é a mensagem inteira que não existe ainda. Quem está do outro lado vê o
//  cliente dizer "te mandei a foto" e não vê foto nenhuma.
//
//  E o mais irônico: a miniatura que vem embutida no próprio webhook — que o
//  código já lia, e cujo comentário dizia "prévia imediata" — era calculada e
//  depois jogada fora, porque a gravação esperava o arquivo grande de todo
//  jeito. A prévia imediata nunca foi imediata.
//
//  ESTA PROVA MEDE. Ela põe a Uazapi para demorar 1,2s no download (o que é
//  otimista para uma foto de verdade) e cronometra quanto tempo passa entre o
//  webhook chegar e a mensagem existir no banco.
// ==================================================================
{
  console.log("\n19. A bolha não espera o arquivo");

  const DEMORA = 1200;

  const fotoDaUazapi = (id) => ({
    EventType: "messages",
    owner: TELEFONE.numero,
    message: {
      id, messageid: id, chatid: "5511977776666@s.whatsapp.net",
      sender: "5511977776666@s.whatsapp.net", fromMe: false, isGroup: false,
      messageType: "image", type: "media", mediaType: "image",
      caption: "segue o documento", messageTimestamp: Date.now(), senderName: "Cliente Lento",
      content: { mimetype: "image/jpeg", JPEGThumbnail: "bWluaWF0dXJhLWRlLW1lbnRpcmE=" },
    },
  });

  const t = await subirTudo({}, { uazapi: { demoraDoDownload: DEMORA } });

  /** Espera a mensagem existir no banco e devolve quanto tempo levou. */
  async function quandoNasceABolha(id, limite = 15000) {
    const comeco = Date.now();
    for (;;) {
      const linha = t.sb.dados.mensagens.find((m) => m.id_uazapi === id);
      if (linha) return { ms: Date.now() - comeco, linha };
      if (Date.now() - comeco > limite) return { ms: Infinity, linha: null };
      await espera(25);
    }
  }

  // Dispara o webhook SEM esperar: a medição começa agora.
  fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(fotoDaUazapi("lento-1")),
  }).catch(() => {});

  const nascimento = await quandoNasceABolha("lento-1");
  console.log(`     download demorando ${DEMORA}ms → bolha nasceu em ${nascimento.ms}ms`);

  ok("a mensagem chega a existir", !!nascimento.linha);

  // O CORAÇÃO DA PROVA. A bolha tem de nascer ANTES do download terminar, e
  // não depois. A margem é generosa de propósito: subir a ponte e falar com o
  // falso Supabase custa alguma coisa, e não é isso que está sendo medido.
  ok("a bolha nasce sem esperar o download",
     nascimento.ms < DEMORA,
     `levou ${nascimento.ms}ms com o download demorando ${DEMORA}ms — `
     + "a conversa fica vazia esse tempo todo, e é isso que quem usa relata");

  // E ela não nasce vazia: a miniatura do próprio webhook é o que a pessoa vê
  // enquanto o arquivo grande não chega.
  ok("e já nasce com a miniatura, para não ser uma bolha em branco",
     String(nascimento.linha && nascimento.linha.midia_url || "").startsWith("data:image/"),
     `midia_url nasceu como "${String(nascimento.linha && nascimento.linha.midia_url || "").slice(0, 40)}"`);

  ok("com a legenda que o cliente escreveu",
     nascimento.linha && nascimento.linha.texto === "segue o documento",
     `texto: ${JSON.stringify(nascimento.linha && nascimento.linha.texto)}`);

  // E DEPOIS o arquivo de verdade substitui a miniatura, sem bolha nova.
  let trocou = null;
  for (let i = 0; i < 80; i++) {
    const linha = t.sb.dados.mensagens.find((m) => m.id_uazapi === "lento-1");
    if (linha && String(linha.midia_url || "").includes("/storage/")) { trocou = linha; break; }
    await espera(100);
  }
  ok("e o arquivo de verdade entra no lugar da miniatura", !!trocou,
     `midia_url ficou "${String((t.sb.dados.mensagens.find((m) => m.id_uazapi === "lento-1") || {}).midia_url || "").slice(0, 50)}"`);

  ok("sem criar uma segunda bolha",
     t.sb.dados.mensagens.filter((m) => m.id_uazapi === "lento-1").length === 1,
     `ficaram ${t.sb.dados.mensagens.filter((m) => m.id_uazapi === "lento-1").length} mensagens com o mesmo id`);

  ok("e o arquivo foi mesmo parar no Storage", t.sb.arquivos.size >= 1,
     `foram ${t.sb.arquivos.size} arquivo(s)`);

  await t.parar();
}

// ==================================================================
//  20. AO SUBIR, A PONTE DIZ QUAL VERSÃO ELA É
//
//  Em 20/08 uma correção ficou pronta, mesclada, e NÃO estava rodando. A
//  Render não publicou, e o repositório dizia uma coisa enquanto o serviço
//  fazia outra — sem nenhuma diferença visível.
//
//  Só descobrimos por ACIDENTE: uma frase de log tinha mudado, e a antiga
//  continuava aparecendo em produção. Sem essa coincidência, a correção da
//  lentidão do anexo teria ficado parada com todo mundo achando que estava no
//  ar. Esta seção existe para que a próxima vez não dependa de sorte.
// ==================================================================
{
  console.log("\n20. A versão no ar aparece no log");

  {
    const t = await subirTudo({ RENDER_GIT_COMMIT: "abc1234def5678", RENDER_GIT_BRANCH: "main" });
    await espera(600);
    const log = t.registro.join("");
    const linha = (log.split("\n").find((l) => l.includes("versão no ar")) || "").trim();

    ok("a ponte anuncia a versão ao subir", !!linha, `o log não tem a linha`);
    // O COMMIT ENCURTADO, e não inteiro: oito letras bastam para comparar com
    // o que está no GitHub, e a linha continua legível de relance no meio de
    // um log corrido.
    ok("dizendo o commit", /abc1234d/.test(linha), `dizia: "${linha}"`);
    ok("e o ramo", /main/.test(linha), `dizia: "${linha}"`);
    // A DATA DO ARQUIVO VAI JUNTO. É ela que denuncia um deploy velho mesmo
    // onde o commit não vier — e é o caso de qualquer lugar que não seja a
    // Render.
    ok("e a data em que o arquivo foi escrito",
       /\d{4}-\d{2}-\d{2} \d{2}:\d{2}/.test(linha), `dizia: "${linha}"`);
    await t.parar();
  }

  {
    // SEM AS VARIÁVEIS DA RENDER a linha não pode sumir: ela ainda responde
    // "de quando é este arquivo?", que já separa um deploy de hoje de um de
    // três meses atrás. Uma linha que só aparece na Render deixaria de
    // funcionar exatamente onde se costuma investigar — na máquina de quem
    // está procurando o defeito.
    const t = await subirTudo({ RENDER_GIT_COMMIT: "", RENDER_GIT_BRANCH: "" });
    await espera(600);
    const linha = (t.registro.join("").split("\n")
      .find((l) => l.includes("versão no ar")) || "").trim();
    ok("sem as variáveis da Render, a linha continua saindo", !!linha);
    ok("e ainda diz de quando é o arquivo",
       /\d{4}-\d{2}-\d{2} \d{2}:\d{2}/.test(linha), `dizia: "${linha}"`);
    ok("sem inventar um commit que não sabe", !/commit /.test(linha),
       `dizia: "${linha}"`);
    await t.parar();
  }
}

// ==================================================================
//  O TELEFONE QUE MANDA E NÃO ESTÁ CADASTRADO
// ==================================================================
//
//  Relatado em 21/08: "acreditamos que o telefone 3857 esteja com uma
//  interferência, pois as mensagens que enviamos são recebidas pelos clientes,
//  porém eles não nos retornam. Pelo 1932 eles respondem em seguida."
//
//  Não era interferência. O telefone não estava na tabela `advogados`, e a
//  ponte descartava tudo o que chegava por ele — com um `console.log` de duas
//  palavras no meio de milhares de linhas. O ENVIO continua funcionando (sai
//  por outro caminho), e é isso que faz o sintoma parecer do cliente.
//
//  O descarte está certo: sem advogado não há conversa em que pôr a mensagem.
//  O que estava errado era o silêncio.
{
  console.log("\nO telefone que manda e não está cadastrado");
  const t = await subirTudo();

  const deOutroTelefone = { ...mensagemDaUazapi("Oi, respondendo", "m-x"),
                            owner: "5567900003857" };
  await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(deOutroTelefone),
  });
  await espera(700);

  ok("a mensagem de telefone não cadastrado não é gravada",
     t.sb.dados.mensagens.length === 0, `ficaram ${t.sb.dados.mensagens.length}`);

  const log = t.registro.join("");
  ok("mas o aviso DIZ que é mensagem de cliente sendo perdida",
     /MENSAGEM DE CLIENTE PERDIDA/.test(log));
  ok("e diz QUAL telefone", /5567900003857/.test(log));
  ok("e diz o que fazer (cadastrar em advogados)",
     /não está na tabela "advogados"/.test(log) && /Cadastre o número/.test(log));
  ok("e avisa que o envio continua funcionando — que é o que confunde",
     /envio POR este telefone continua funcionando/i.test(log));

  // SEM PRECISAR CAÇAR NO LOG. Quem atende não entra na Render.
  const d = await (await fetch(`http://127.0.0.1:${t.porta}/webhook/desconhecidos`)).json();
  ok("o /webhook/desconhecidos lista o telefone",
     d.telefones.some((x) => x.numero === "5567900003857"), JSON.stringify(d));
  ok("com a contagem do que foi descartado",
     d.telefones[0]?.eventos_descartados === 1, JSON.stringify(d.telefones));

  // O TELEFONE CADASTRADO CONTINUA ENTRANDO — a correção não pode fechar a porta boa.
  await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(mensagemDaUazapi("Do telefone certo", "m-ok")),
  });
  await espera(700);
  ok("o telefone cadastrado continua entrando normalmente",
     t.sb.dados.mensagens.length === 1, `ficaram ${t.sb.dados.mensagens.length}`);

  // NÃO PODE VIRAR ENXURRADA: um telefone movimentado empurraria para fora do
  // log tudo o que interessa, inclusive isto.
  for (let i = 0; i < 5; i++) {
    await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ...deOutroTelefone,
        message: { ...deOutroTelefone.message, id: `m-y${i}`, messageid: `m-y${i}` } }),
    });
  }
  await espera(800);
  const quantosAvisos = (t.registro.join("").match(/MENSAGEM DE CLIENTE PERDIDA/g) || []).length;
  ok("seis eventos do mesmo telefone não viram seis avisos", quantosAvisos === 1,
     `saíram ${quantosAvisos}`);

  const d2 = await (await fetch(`http://127.0.0.1:${t.porta}/webhook/desconhecidos`)).json();
  ok("mas a contagem soma todos os descartados",
     d2.telefones.find((x) => x.numero === "5567900003857")?.eventos_descartados === 6,
     JSON.stringify(d2.telefones));

  await t.parar();
}

// ==================================================================
//  QUANDO O VANTORO NÃO RESPONDE JSON
// ==================================================================
//
//  Relatado em 21/08, com a tela mostrando "Resposta inválida do Vantoro" e,
//  logo abaixo, "verifique se a ponte está configurada com VANTORO_API_URL e
//  VANTORO_API_TOKEN".
//
//  A dica estava errada, e errada de um jeito específico: se aquelas duas
//  variáveis faltassem, a ponte teria parado antes, com outra mensagem. Chegar
//  ali PROVA que as duas existem. A causa real era o serviço do Vantoro fora do
//  ar — workspace suspenso por consumo —, devolvendo a página de suspensão em
//  HTML no lugar dos dados.
{
  console.log("\nQuando o Vantoro não responde JSON");

  // Serviço suspenso/fora do ar: HTML com 503.
  {
    const t = await subirTudo({}, { vantoro: { naoJson: { status: 503 } } });
    const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente?telefone=5511999998888`,
                          { headers: { Authorization: "Bearer jwt-bom" } });
    const c = await r.json();
    ok("diz o código que veio (503)", /503/.test(c.erro || ""), c.erro);
    ok("diz que veio uma página em vez dos dados", /página HTML/i.test(c.erro || ""), c.erro);
    ok("e diz na cara que NÃO é a configuração da ponte",
       /não é a configuração da ponte/i.test(c.erro || ""), c.erro);
    ok("não some com a evidência numa frase genérica",
       !/^Resposta inválida do Vantoro\.$/.test(c.erro || ""), c.erro);
    await t.parar();
  }

  // Endereço apontando para um caminho que não existe.
  {
    const t = await subirTudo({}, { vantoro: { naoJson: { status: 404 } } });
    const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente?telefone=5511999998888`,
                          { headers: { Authorization: "Bearer jwt-bom" } });
    const c = await r.json();
    ok("404 aponta para o ENDEREÇO, não para o token",
       /VANTORO_API_URL/.test(c.erro || "") && !/TOKEN/.test(c.erro || ""), c.erro);
    await t.parar();
  }

  // Recusa sem JSON: aí sim é token.
  {
    const t = await subirTudo({}, { vantoro: { naoJson: { status: 401 } } });
    const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente?telefone=5511999998888`,
                          { headers: { Authorization: "Bearer jwt-bom" } });
    const c = await r.json();
    ok("401 sem JSON aponta para o TOKEN", /VANTORO_API_TOKEN/.test(c.erro || ""), c.erro);
    await t.parar();
  }

  // Texto solto do servidor: mostrar o texto resolve mais que qualquer frase minha.
  {
    const t = await subirTudo({}, { vantoro: {
      naoJson: { status: 500, tipo: "text/plain", corpo: "upstream connect error" } } });
    const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente?telefone=5511999998888`,
                          { headers: { Authorization: "Bearer jwt-bom" } });
    const c = await r.json();
    ok("mostra o texto que o servidor mandou",
       /upstream connect error/.test(c.erro || ""), c.erro);
    await t.parar();
  }

  // E o caminho bom continua bom.
  {
    const t = await subirTudo({}, { vantoro: {} });
    const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente?telefone=5511999998888`,
                          { headers: { Authorization: "Bearer jwt-bom" } });
    ok("com o Vantoro no ar, a ficha responde normalmente", r.status === 200, `veio ${r.status}`);
    await t.parar();
  }
}

// ==================================================================
//  O VANTORO HIBERNANDO NÃO PODE VIRAR ERRO NA CARA DE QUEM ATENDE
// ==================================================================
//
//  No plano gratuito da Render o serviço hiberna. A primeira chamada depois
//  disso NÃO ESPERA: a Render responde na hora, com uma página de erro, e só
//  então acorda o Django por baixo.
//
//  Do lado de quem atende isso aparecia como a ficha do cliente falhando sem
//  motivo e voltando sozinha minutos depois. É o relato de 21/08.
{
  console.log("\nO Vantoro hibernando não vira erro na cara de quem atende");

  // Dorme na PRIMEIRA chamada, acorda na segunda — exatamente como a Render.
  {
    // JANELA FECHADA de propósito: com ela aberta, o ping de manutenção
    // absorve a primeira resposta "dormindo" e o reenvio nunca é exercitado.
    // (Foi o que aconteceu na primeira rodada — o que prova que os dois
    // mecanismos se cobrem, mas cada um precisa da sua própria conferência.)
    const t = await subirTudo({ VANTORO_ACORDADO_ATE: "0" },
                              { vantoro: { dormeAsPrimeiras: 1 } });
    const comeco = Date.now();
    const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente?telefone=5511999998888`,
                          { headers: { Authorization: "Bearer jwt-bom" } });
    const levou = Date.now() - comeco;
    console.log(`     serviço dormindo → a ficha respondeu ${r.status} em ${levou}ms`);

    ok("a ficha responde certo mesmo com o serviço dormindo", r.status === 200,
       `veio ${r.status} — quem atende veria a ficha falhar sem motivo`);
    ok("e esperou o serviço acordar antes de responder", levou >= 6000,
       `respondeu em ${levou}ms; a espera de 6s não aconteceu`);
    ok("e o log diz que foi sono, não defeito",
       /parece serviço hibernando/.test(t.registro.join("")));
    await t.parar();
  }

  // DORMINDO DE VERDADE (não acorda nunca): tem de desistir com a mensagem que
  // explica, e não ficar tentando para sempre.
  {
    const t = await subirTudo({ VANTORO_ACORDADO_ATE: "0" },
                              { vantoro: { dormeAsPrimeiras: 99 } });
    const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente?telefone=5511999998888`,
                          { headers: { Authorization: "Bearer jwt-bom" } });
    const c = await r.json();
    ok("serviço que não acorda desiste, com o motivo",
       /502|fora do ar|dormindo|suspenso/i.test(c.erro || ""), c.erro);
    await t.parar();
  }

  // O ENVIO NÃO É REPETIDO. Se o Vantoro chegou a receber o cadastro antes de a
  // Render cortar, repetir criaria DOIS clientes — e um cadastro duplicado é
  // pior do que um erro na tela, porque ninguém percebe na hora.
  {
    const t = await subirTudo({ VANTORO_ACORDADO_ATE: "0" },
                              { vantoro: { dormeAsPrimeiras: 1 } });
    await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente`, {
      method: "POST",
      headers: { Authorization: "Bearer jwt-bom", "Content-Type": "application/json" },
      body: JSON.stringify({ nome: "Fulano", telefone: "5511999998888" }),
    });
    // TODOS os POSTs que o Vantoro recebeu, e não os de um caminho escolhido a
    // dedo: a ponte chama "/clientes" lá dentro, não "/vantoro/cliente" (esse é
    // o endereço DELA). Filtrando pelo caminho errado, a conta dava zero e a
    // conferência passava sem olhar nada — foi assim na primeira rodada, e só
    // apareceu porque a sabotagem correspondente NÃO derrubou nada.
    const posts = t.van.recebidas.filter((x) => x.metodo === "POST");
    ok("um cadastro que falhou NÃO é reenviado", posts.length <= 1,
       `o Vantoro recebeu ${posts.length} POSTs — cria cliente duplicado`);
    await t.parar();
  }

  // RESPOSTA LENTA NÃO É SONO. Serviço no ar e sobrecarregado responde devagar;
  // insistir nesse caso só piora, e ainda dobra a espera de quem está olhando.
  {
    const t = await subirTudo({ VANTORO_ACORDADO_ATE: "0" },
                              { vantoro: { naoJson: { status: 503 }, demora: 5500 } });
    const comeco = Date.now();
    await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente?telefone=5511999998888`,
                { headers: { Authorization: "Bearer jwt-bom" } });
    const levou = Date.now() - comeco;
    ok("resposta lenta não é tratada como sono (não tenta de novo)",
       levou < 11000, `levou ${levou}ms — dobrou a espera de quem está olhando`);
    await t.parar();
  }
}

// ==================================================================
//  A JANELA EM QUE O VANTORO É MANTIDO ACORDADO
// ==================================================================
//
//  Acordado 24 horas, cada serviço consome ~730 h/mês. São DOIS serviços, e o
//  plano gratuito dá 750 h para o workspace inteiro — manter os dois de pé o
//  tempo todo estoura a franquia e troca o problema do sono pelo da conta.
//
//  Por isso a batida que mantém o Vantoro acordado tem hora para começar e
//  para acabar. Estas conferências olham o que o Vantoro RECEBE, que é a única
//  coisa que decide se a franquia vai ser gasta ou não.
{
  console.log("\nA janela em que o Vantoro é mantido acordado");

  // Janela escancarada: o ping tem de sair assim que a ponte sobe.
  {
    const t = await subirTudo({ VANTORO_ACORDADO_DE: "0", VANTORO_ACORDADO_ATE: "24",
                                VANTORO_ACORDADO_SABADO: "1" }, { vantoro: {} });
    await espera(900);
    const pings = t.van.recebidas.filter((x) => x.caminho === "/ping");
    ok("dentro da janela, a ponte bate no /ping do Vantoro", pings.length >= 1,
       `bateu ${pings.length} vez(es)`);
    await t.parar();
  }

  // Janela fechada: NADA pode sair. É esta linha que protege a franquia de
  // horas — sem ela, o Vantoro ficaria de pé 24h e a conta estouraria no fim
  // do mês, sem nada apontando para a causa.
  {
    const t = await subirTudo({ VANTORO_ACORDADO_DE: "0", VANTORO_ACORDADO_ATE: "0" },
                              { vantoro: {} });
    await espera(900);
    const pings = t.van.recebidas.filter((x) => x.caminho === "/ping");
    ok("fora da janela, NÃO bate", pings.length === 0,
       `bateu ${pings.length} vez(es) — o serviço ficaria de pé 24h`);
    await t.parar();
  }

  // O PING NÃO LEVA O TOKEN. Ele não precisa — do outro lado é 200 vazio, sem
  // banco e sem sessão. Mandar o token numa chamada que não pede é espalhá-lo
  // por mais um lugar sem ganhar nada.
  {
    const t = await subirTudo({ VANTORO_ACORDADO_DE: "0", VANTORO_ACORDADO_ATE: "24" },
                              { vantoro: {} });
    await espera(900);
    const ping = t.van.recebidas.find((x) => x.caminho === "/ping");
    ok("e o ping não leva o token junto", !!ping && !ping.autorizacao,
       JSON.stringify(ping || null));
    await t.parar();
  }
}


// ==================================================================
//  O ARQUIVO SOBE COM CACHE LONGO
// ==================================================================
//
//  A biblioteca do Supabase manda `max-age=3600` quando ninguém diz nada — uma
//  hora. De hora em hora, cada atendente que abre uma conversa BAIXA DE NOVO
//  todas as fotos, áudios e vídeos dela.
//
//  Com oito pessoas rolando conversas o dia inteiro e mais de 1 GB de mídia
//  guardada, é assim que a franquia de banda vira zero. Em 21/08 o workspace
//  foi suspenso por consumo e o atendimento parou — a ficha do cliente deixou
//  de responder, porque serviço suspenso devolve página, não dados.
//
//  Este é o único ponto do código que decide isso, e ele não estava dizendo
//  nada.
{
  console.log("\nO arquivo sobe com cache longo");

  const fotoDaUazapi = (id) => ({
    EventType: "messages",
    owner: TELEFONE.numero,
    message: {
      id, messageid: id, chatid: "5511977776666@s.whatsapp.net",
      sender: "5511977776666@s.whatsapp.net", fromMe: false, isGroup: false,
      messageType: "image", type: "media", mediaType: "image",
      caption: "uma foto", messageTimestamp: Date.now(), senderName: "Cliente",
      content: { mimetype: "image/jpeg", JPEGThumbnail: "bWluaWF0dXJh" },
    },
  });

  const t = await subirTudo();
  await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(fotoDaUazapi("foto-cache-1")),
  });

  // Espera o arquivo chegar ao Storage (o download é assíncrono de propósito —
  // a bolha nasce antes dele, e isso já tem conferência própria).
  for (let i = 0; i < 80 && t.sb.cabecalhosDeUpload.size === 0; i++) await espera(50);

  const enviados = [...t.sb.cabecalhosDeUpload.entries()];
  ok("o arquivo chega ao Storage", enviados.length === 1,
     JSON.stringify(enviados));

  const cache = (enviados[0] || [])[1] || "";
  ok("e sobe com cache-control", !!cache, `veio "${cache}"`);

  // O CORAÇÃO DA PROVA. Uma hora é o padrão da biblioteca e é o que quebrou o
  // escritório. Qualquer coisa acima de um mês já muda a natureza do problema.
  const segundos = Number((cache.match(/max-age=(\d+)/) || [])[1] || 0);
  ok("com prazo longo, e não a hora que a biblioteca usa por padrão",
     segundos >= 2592000,
     `veio max-age=${segundos} (${Math.round(segundos / 3600)}h) — `
     + "com isso cada atendente rebaixa a conversa inteira nesse intervalo");

  // `immutable` é o que faz o navegador nem PERGUNTAR se mudou. Sem ele ainda
  // sai uma ida à rede por arquivo para receber "304, continua igual" — pouco
  // tráfego, mas uma chamada por imagem por atendente, e é o que deixa a
  // conversa lenta ao abrir.
  ok("e marcado como imutável, para o navegador nem perguntar",
     /immutable/.test(cache), `veio "${cache}"`);

  // O CAMINHO É QUE AUTORIZA O CACHE LONGO. Guardar por um ano só é seguro
  // porque aquele endereço nunca vai apontar para outro conteúdo. Se o caminho
  // passasse a ser reaproveitado, o cache longo viraria defeito — e esta linha
  // é o que avisa.
  const caminho = (enviados[0] || [])[0] || "";
  ok("e o caminho carrega o id da mensagem, que não se repete",
     caminho.includes("foto-cache-1"), `caminho "${caminho}"`);

  await t.parar();
}

// ==================================================================
//  O TELEFONE CADASTRADO DUAS VEZES
// ==================================================================
//
//  O SEGUNDO caminho silencioso, e o pior dos dois.
//
//  A busca usava `maybeSingle()`, que devolve ERRO quando acha mais de uma
//  linha. Um telefone cadastrado duas vezes em `advogados` — coisa que
//  acontece, alguém cadastra de novo achando que faltava — fazia TODA mensagem
//  daquele número ser descartada, com um `console.error` que não dizia que
//  eram mensagens de cliente.
//
//  É pior do que o "não cadastrado" porque o telefone ESTÁ lá: quem for
//  conferir vai achar tudo certo. Foi assim que este defeito escapou uma vez —
//  a explicação "não está cadastrado" batia com o sintoma e estava errada.
{
  console.log("\nO telefone cadastrado duas vezes");

  const DOIS = [
    { id: "adv-1", nome: "Comercial", numero: "5567900000001", token: "tok-a",
      servidor: null, ativo: true, departamento_id: 1 },
    { id: "adv-2", nome: "Comercial (repetido)", numero: "5567900000001", token: "tok-b",
      servidor: null, ativo: true, departamento_id: 1 },
  ];
  const t = await subirTudo({}, { tabelas: { advogados: DOIS } });

  await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(mensagemDaUazapi("Oi, respondendo", "dup-1")),
  });
  await espera(900);

  // O CORAÇÃO DA PROVA. Cadastro repetido é problema de cadastro, e não pode
  // custar as mensagens dos clientes enquanto ninguém arruma.
  ok("a mensagem ENTRA mesmo com o telefone cadastrado duas vezes",
     t.sb.dados.mensagens.length === 1,
     `ficaram ${t.sb.dados.mensagens.length} — o cliente respondeu e sumiu`);

  ok("e a duplicidade é avisada",
     /CADASTRO REPETIDO/.test(t.registro.join("")));
  ok("dizendo qual telefone", /5567900000001/.test(t.registro.join("")));

  const d = await (await fetch(`http://127.0.0.1:${t.porta}/webhook/desconhecidos`)).json();
  ok("e o /webhook/desconhecidos lista o cadastro repetido",
     (d.cadastros_repetidos || []).includes("5567900000001"), JSON.stringify(d));

  await t.parar();
}

// ==================================================================
//  A BUSCA DO ADVOGADO FALHANDO
// ==================================================================
//
//  Banco fora do ar, coluna que não existe, o que for. Antes era um
//  `console.error` genérico e a mensagem ia embora sem nada dizer que era
//  mensagem de cliente — e sem aparecer em lugar nenhum que alguém consultasse.
{
  console.log("\nA busca do advogado falhando");
  const t = await subirTudo({}, {
    quebrar: (metodo, tabela) => (metodo === "GET" && tabela.startsWith("advogados"))
      ? "banco fora do ar" : null,
  });

  await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(mensagemDaUazapi("Oi", "falha-1")),
  });
  await espera(900);

  const log = t.registro.join("");
  ok("o aviso diz que é mensagem de cliente sendo perdida",
     /MENSAGEM DE CLIENTE PERDIDA/.test(log));
  ok("e aponta o cadastro repetido como causa mais comum",
     /DUAS VEZES/.test(log), log.slice(-400));

  const d = await (await fetch(`http://127.0.0.1:${t.porta}/webhook/desconhecidos`)).json();
  const linha = (d.telefones || [])[0];
  ok("e o /webhook/desconhecidos separa este motivo do 'não cadastrado'",
     linha && linha.motivo === "busca", JSON.stringify(d.telefones));
  ok("e diz o que fazer", !!(linha && /DUAS VEZES/.test(linha.o_que_fazer || "")),
     JSON.stringify(linha || null));

  await t.parar();
}

// ==================================================================
//  QUAL TELEFONE ESTÁ MUDO
// ==================================================================
//
//  A causa que sobrou depois de as outras duas serem descartadas com dado na
//  mão: a URL do webhook é configurada POR TELEFONE, dentro da Uazapi. Se a de
//  um deles estiver vazia ou errada, NADA chega à ponte — nenhum log, nenhum
//  descarte, nenhuma recusa. E o envio continua funcionando.
//
//  Nenhuma lista de erro responde isso, porque não há erro: há AUSÊNCIA. A
//  única forma de enxergar ausência é comparar com quem está presente.
{
  console.log("\nQual telefone está mudo");

  const DOIS = [
    { id: "adv-1", nome: "Comercial 1932", numero: "5567900001932", token: "t1",
      servidor: null, ativo: true, departamento_id: 1 },
    { id: "adv-2", nome: "Comercial 3857", numero: "5567900003857", token: "t2",
      servidor: null, ativo: true, departamento_id: 1 },
  ];
  const t = await subirTudo({}, { tabelas: { advogados: DOIS } });

  // Só o 1932 manda evento. O 3857 fica calado — é o cenário relatado.
  await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...mensagemDaUazapi("oi", "mudo-1"), owner: "5567900001932" }),
  });
  await espera(700);

  const d = await (await fetch(`http://127.0.0.1:${t.porta}/webhook/telefones`)).json();
  const por = Object.fromEntries((d.telefones || []).map((l) => [l.numero, l]));

  ok("lista TODOS os telefones cadastrados, não só os com problema",
     (d.telefones || []).length === 2, JSON.stringify(d.telefones));
  ok("quem mandou evento aparece como falante", por["5567900001932"]?.mudo === false,
     JSON.stringify(por["5567900001932"]));
  ok("e quem não mandou aparece como MUDO", por["5567900003857"]?.mudo === true,
     JSON.stringify(por["5567900003857"]));
  ok("o mudo vem primeiro na lista", d.telefones[0].numero === "5567900003857",
     JSON.stringify(d.telefones.map((l) => l.numero)));

  // A HONESTIDADE DA TABELA. A contagem vive na memória e zera a cada
  // publicação. Uma ponte que subiu agora mostra todo mundo mudo, e isso não
  // quer dizer nada — sem esta ressalva, a tabela seria lida como diagnóstico
  // quando ainda é um cronômetro começando, e alguém iria mexer no webhook de
  // um telefone que estava certo.
  ok("diz há quanto tempo a ponte está no ar", typeof d.ponte_no_ar_ha_minutos === "number");
  ok("e AVISA que é cedo demais para concluir", /cedo|Espere/i.test(d.recado || ""),
     d.recado);

  // O outro lado da mesma pergunta: quem manda evento e não está cadastrado.
  await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...mensagemDaUazapi("oi", "mudo-2"), owner: "5567911112222" }),
  });
  await espera(700);
  const d2 = await (await fetch(`http://127.0.0.1:${t.porta}/webhook/telefones`)).json();
  ok("e mostra quem mandou evento sem estar cadastrado",
     (d2.mandaram_evento_e_nao_estao_cadastrados || []).includes("5567911112222"),
     JSON.stringify(d2.mandaram_evento_e_nao_estao_cadastrados));

  // O EVENTO É ANOTADO MESMO QUANDO A MENSAGEM É DESCARTADA. É o que separa
  // "não chega" de "chega e cai" — as duas parecem iguais de fora e pedem
  // coisas completamente diferentes de quem for arrumar.
  ok("anota o evento mesmo do telefone não cadastrado (chegou, mas caiu)",
     (d2.mandaram_evento_e_nao_estao_cadastrados || []).length >= 1);

  await t.parar();
}

// ==================================================================
//  A NOTA INTERNA SOBE PARA O VANTORO
// ==================================================================
//
//  A equipe escreve a nota dentro da conversa, que é onde ela está quando
//  descobre o que precisa anotar. Mas quem for procurar aquilo meses depois vai
//  à ficha do cliente, ou ao histórico do processo.
//
//  O VÍNCULO É SEMPRE COM O CLIENTE; o processo é opcional, e serve para achar
//  a informação depois.
{
  console.log("\nA nota interna sobe para o Vantoro");

  const t = await subirTudo({}, { vantoro: {
    usuarios: [{ id: 1, login: "ana", nome: "Ana Aguiar" }] } });

  async function mandarNota(corpo) {
    return fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente/7/nota`, {
      method: "POST",
      headers: { Authorization: "Bearer jwt-bom", "Content-Type": "application/json" },
      body: JSON.stringify(corpo),
    });
  }

  const r = await mandarNota({ id: "n-1", texto: "Cliente vai mandar o RG" });
  ok("a ponte aceita e responde", r.status === 200, `veio ${r.status}`);

  const recebida = t.van.recebidas.find((x) => x.caminho === "/clientes/7/nota");
  ok("e chama o endereço certo do Vantoro", !!recebida,
     JSON.stringify(t.van.recebidas.map((x) => x.caminho)));
  ok("levando o texto", recebida?.corpo?.texto === "Cliente vai mandar o RG");
  ok("e o id da nota, que é o elo entre os dois", recebida?.corpo?.id === "n-1",
     "sem ele, editar cria uma segunda em vez de reescrever");

  // O PROCESSO É OPCIONAL — a "nota geral" do cliente é o caso comum.
  ok("sem processo, manda null e não inventa um",
     recebida?.corpo?.processo_id === null, JSON.stringify(recebida?.corpo));

  await t.parar();
}

console.log("\nCom processo, ele vai junto");
{
  const t = await subirTudo({}, { vantoro: {} });
  await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente/7/nota`, {
    method: "POST",
    headers: { Authorization: "Bearer jwt-bom", "Content-Type": "application/json" },
    body: JSON.stringify({ id: "n-2", texto: "sobre a ação", processo_id: 42 }),
  });
  const recebida = t.van.recebidas.find((x) => x.caminho === "/clientes/7/nota");
  ok("o processo escolhido chega ao Vantoro", recebida?.corpo?.processo_id === 42,
     JSON.stringify(recebida?.corpo));
  await t.parar();
}

console.log("\nO AUTOR É DECIDIDO NA PONTE, e não recebido do navegador");
{
  // É a mesma regra do histórico de alterações: a ponte confere o login antes
  // de deixar passar, então é aqui que se sabe QUEM é quem. Um histórico em que
  // o autor é o que o navegador disse ser não responde "quem escreveu isto?" —
  // e num escritório de advocacia essa é a pergunta que se faz.
  const t = await subirTudo({}, {
    vantoro: {},
    contas: [{ id: "u1", email: "rodrigo@x", jwt: "jwt-bom",
               user_metadata: { nome: "Rodrigo Alves" } }],
  });
  await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente/7/nota`, {
    method: "POST",
    headers: { Authorization: "Bearer jwt-bom", "Content-Type": "application/json" },
    body: JSON.stringify({ id: "n-3", texto: "oi", autor: "Eu Sou Outro" }),
  });
  const recebida = t.van.recebidas.find((x) => x.caminho === "/clientes/7/nota");
  ok("o autor é quem está logado", recebida?.corpo?.autor === "Rodrigo Alves",
     `foi como "${recebida?.corpo?.autor}"`);
  ok("e NÃO o que o navegador mandou", recebida?.corpo?.autor !== "Eu Sou Outro",
     "qualquer um assinaria com o nome de qualquer um");
  await t.parar();
}

console.log("\nSem login, a nota não passa");
{
  const t = await subirTudo({}, { vantoro: {} });
  const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente/7/nota`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ id: "n-4", texto: "oi" }),
  });
  ok("recusa sem sessão", r.status === 401, `veio ${r.status}`);
  ok("e nada chega ao Vantoro",
     !t.van.recebidas.some((x) => x.caminho === "/clientes/7/nota"));
  await t.parar();
}

// ==================================================================
//  AS NOTAS QUE JÁ EXISTEM SOBEM PARA O VANTORO
// ==================================================================
//
//  Dois casos, uma máquina só:
//    • o contato VIRA cliente, e o que a equipe já anotou passa a ter lugar;
//    • o retroativo, uma vez, para tudo o que foi escrito antes.
//
//  SOBEM COMO NOTA GERAL, sem processo: é tudo passado, e adivinhar de qual
//  ação era cada uma poria nota no histórico do processo errado.
{
  console.log("\nAs notas que já existem sobem para o Vantoro");

  const TABELAS = {
    contatos: [
      { id: "ct-1", numero: "5511900001111", vantoro_cliente_id: "v-1" },
      { id: "ct-2", numero: "5511900002222", vantoro_cliente_id: null },
      // UM SEGUNDO CLIENTE, e não por simetria. O retroativo lê as notas de
      // muitos contatos numa consulta só e DEPOIS separa de quem é cada uma.
      // Com um cliente só na amostra, uma separação errada passaria batida — e
      // o que ela esconderia é a nota de um cliente entrando na ficha de outro,
      // que numa banca não é defeito de software, é incidente com o cliente.
      { id: "ct-3", numero: "5511900003333", vantoro_cliente_id: "v-3" },
    ],
    conversas: [
      { id: "cv-1", contato_id: "ct-1", advogado_id: "adv-1" },
      { id: "cv-2", contato_id: "ct-2", advogado_id: "adv-1" },
      { id: "cv-3", contato_id: "ct-3", advogado_id: "adv-1" },
    ],
    notas: [
      { id: "nt-1", conversa_id: "cv-1", texto: "primeira", autor: "Isabela",
        criado_em: "2026-01-01T10:00:00Z", vantoro_atividade_id: null, apagada_em: null },
      { id: "nt-2", conversa_id: "cv-1", texto: "segunda", autor: "Davi",
        criado_em: "2026-02-01T10:00:00Z", vantoro_atividade_id: null, apagada_em: null },
      { id: "nt-3", conversa_id: "cv-1", texto: "ja subiu", autor: "Ana",
        criado_em: "2026-03-01T10:00:00Z", vantoro_atividade_id: 999, apagada_em: null },
      // Do contato SEM cadastro: não tem para onde subir.
      { id: "nt-4", conversa_id: "cv-2", texto: "de quem nao e cliente", autor: "Ana",
        criado_em: "2026-01-05T10:00:00Z", vantoro_atividade_id: null, apagada_em: null },
      // Do OUTRO cliente. A data cai NO MEIO das do primeiro de propósito: a
      // leitura em lote vem ordenada por data, misturando os dois donos, que é
      // exatamente a situação em que uma separação frouxa erra.
      { id: "nt-5", conversa_id: "cv-3", texto: "do outro cliente", autor: "Ana",
        criado_em: "2026-01-15T10:00:00Z", vantoro_atividade_id: null, apagada_em: null },
    ],
    usuarios: [{ id: "u1", nome: "Rodrigo", admin: true }],
  };

  const t = await subirTudo({}, { tabelas: TABELAS, vantoro: {} });

  // SIMULAÇÃO PRIMEIRO — nada sai, nada é gravado.
  const sim = await (await fetch(
    `http://127.0.0.1:${t.porta}/vantoro/notas/subir-tudo?simular=1`,
    { method: "POST", headers: { Authorization: "Bearer jwt-bom" } })).json();
  ok("a simulação diz quantas subiriam", sim.subiram === 3,
     JSON.stringify(sim));
  ok("e não manda nada ao Vantoro",
     !t.van.recebidas.some((x) => /\/nota$/.test(x.caminho)),
     JSON.stringify(t.van.recebidas.map((x) => x.caminho)));

  // AGORA DE VERDADE.
  const r = await (await fetch(
    `http://127.0.0.1:${t.porta}/vantoro/notas/subir-tudo`,
    { method: "POST", headers: { Authorization: "Bearer jwt-bom" } })).json();
  ok("sobem as que faltavam", r.subiram === 3, JSON.stringify(r));
  ok("a que já tinha subido é reconhecida e não repete", r.jaEstavam === 1,
     JSON.stringify(r));

  const notas = t.van.recebidas.filter((x) => /\/nota$/.test(x.caminho));
  ok("três chegaram ao Vantoro", notas.length === 3,
     JSON.stringify(notas.map((x) => x.corpo?.texto)));

  // CADA NOTA NA FICHA DO SEU DONO. A leitura em lote traz as notas dos dois
  // clientes juntas e ordenadas por data; se a separação errar, a nota de um vai
  // parar no histórico do outro.
  const enderecoDe = (texto) =>
    notas.find((x) => x.corpo?.texto === texto)?.caminho;
  ok("as do primeiro cliente vão para a ficha dele",
     enderecoDe("primeira") === "/clientes/v-1/nota"
     && enderecoDe("segunda") === "/clientes/v-1/nota",
     JSON.stringify(notas.map((x) => [x.corpo?.texto, x.caminho])));
  ok("e a do SEGUNDO não entra na ficha do primeiro",
     enderecoDe("do outro cliente") === "/clientes/v-3/nota",
     JSON.stringify(notas.map((x) => [x.corpo?.texto, x.caminho])));

  // SEM PROCESSO — é tudo passado.
  ok("todas como NOTA GERAL, sem processo",
     notas.every((x) => x.corpo?.processo_id === null),
     JSON.stringify(notas.map((x) => x.corpo?.processo_id)));

  // O AUTOR É O DA NOTA, e não quem mandou subir. Assinar tudo com o nome de
  // quem rodou o retroativo reescreveria a autoria de meses de histórico.
  ok("o autor é quem escreveu a nota, não quem rodou o retroativo",
     notas.some((x) => x.corpo?.autor === "Isabela")
     && notas.some((x) => x.corpo?.autor === "Davi"),
     JSON.stringify(notas.map((x) => x.corpo?.autor)));

  // MAIS ANTIGA PRIMEIRO: o histórico é lido em ordem.
  ok("na ordem em que foram escritas",
     notas[0]?.corpo?.texto === "primeira" && notas[1]?.corpo?.texto === "segunda",
     JSON.stringify(notas.map((x) => x.corpo?.texto)));

  // QUEM NÃO É CLIENTE FICA DE FORA — não há ficha para receber.
  ok("a nota de quem não tem cadastro não sobe",
     !notas.some((x) => /nao e cliente/.test(x.corpo?.texto || "")),
     JSON.stringify(notas.map((x) => x.corpo?.texto)));

  await t.parar();
}

//  O RETROATIVO EM FATIAS — é o que permite ele virar um botão.
//
//  Rodando de ponta a ponta, ele sobe uma nota de cada vez para o Vantoro, que
//  é outra hospedagem e que hiberna. Com centenas de clientes, a chamada passa
//  do tempo que a Render dá a uma requisição e morre no meio — sem dizer onde
//  parou. Em fatias, cada chamada termina depressa e o painel pede a seguinte.
//
//  O QUE ESTE BLOCO PROTEGE é a propriedade que faz as fatias valerem alguma
//  coisa: percorrer todas elas tem de cobrir TODO MUNDO, sem repetir e sem
//  pular. Uma fatia que pula um cliente não dá erro nenhum — só deixa o
//  histórico dele sem as notas, e ninguém descobre.
console.log("\nO retroativo em fatias cobre todo mundo, sem pular ninguém");
{
  const TABELAS = {
    contatos: [], conversas: [], notas: [],
    usuarios: [{ id: "u1", nome: "Rodrigo", admin: true }],
  };
  // Sete clientes, uma nota cada. Sete e não dois: com fatias de dois, o
  // último grupo fica INCOMPLETO — e é no grupo incompleto que uma conta de
  // fim mal feita erra, tanto para mais (repete) quanto para menos (pula).
  for (let i = 1; i <= 7; i += 1) {
    TABELAS.contatos.push({ id: `ct-${i}`, numero: `551190000${i}`, vantoro_cliente_id: `v-${i}` });
    TABELAS.conversas.push({ id: `cv-${i}`, contato_id: `ct-${i}`, advogado_id: "adv-1" });
    TABELAS.notas.push({ id: `nt-${i}`, conversa_id: `cv-${i}`, texto: `nota ${i}`,
                         autor: "Ana", criado_em: `2026-01-0${i}T10:00:00Z`,
                         vantoro_atividade_id: null, apagada_em: null });
  }

  const t = await subirTudo({}, { tabelas: TABELAS, vantoro: {} });
  const fatia = (de) => fetch(
    `http://127.0.0.1:${t.porta}/vantoro/notas/subir-tudo?de=${de}&quantos=2`,
    { method: "POST", headers: { Authorization: "Bearer jwt-bom" } }).then((x) => x.json());

  const primeira = await fatia(0);
  ok("a primeira fatia pega só os dois primeiros", primeira.clientes === 2,
     JSON.stringify(primeira));
  ok("e diz que NÃO acabou", primeira.fim === false, JSON.stringify(primeira));
  ok("dizendo também quantos existem ao todo", primeira.total_clientes === 7,
     JSON.stringify(primeira));
  // O NÚMERO QUE O PAINEL USA PARA PEDIR A SEGUINTE. Se ele vier errado, o
  // laço repete a mesma fatia para sempre ou pula um pedaço do escritório.
  ok("e onde ela parou", primeira.ate === 2, JSON.stringify(primeira));
  ok("o texto avisa que é uma fatia, para quem chamar na mão",
     /fatia/.test(primeira.detalhe || "") && /de=2/.test(primeira.detalhe || ""),
     primeira.detalhe);

  // O LAÇO INTEIRO, como o painel faz.
  let r = primeira, voltas = 1;
  while (!r.fim && voltas < 20) { r = await fatia(r.ate); voltas += 1; }
  ok("percorrendo as fatias, chega ao fim", r.fim === true, JSON.stringify(r));

  const notas = t.van.recebidas.filter((x) => /\/nota$/.test(x.caminho));
  ok("e TODAS as sete notas chegaram", notas.length === 7,
     JSON.stringify(notas.map((x) => x.corpo?.texto)));
  // NENHUMA REPETIDA. A fatia que se sobrepõe à anterior manda a mesma nota
  // duas vezes; aqui ela ainda não tem marca, então nada a pararia.
  ok("cada uma uma vez só",
     new Set(notas.map((x) => x.corpo?.texto)).size === 7,
     JSON.stringify(notas.map((x) => x.corpo?.texto)));
  // E CADA UMA NA FICHA DO SEU DONO — a fatia não pode embaralhar donos.
  ok("cada nota na ficha do seu dono",
     notas.every((x) => x.caminho === `/clientes/v-${x.corpo?.texto?.split(" ")[1]}/nota`),
     JSON.stringify(notas.map((x) => [x.corpo?.texto, x.caminho])));

  await t.parar();
}

console.log("\nA fatia não deixa uma URL torta pular gente em silêncio");
{
  const TABELAS = {
    contatos: [], conversas: [], notas: [],
    usuarios: [{ id: "u1", nome: "Rodrigo", admin: true }],
  };
  for (let i = 1; i <= 3; i += 1) {
    TABELAS.contatos.push({ id: `ct-${i}`, numero: `551190000${i}`, vantoro_cliente_id: `v-${i}` });
    TABELAS.conversas.push({ id: `cv-${i}`, contato_id: `ct-${i}`, advogado_id: "adv-1" });
    TABELAS.notas.push({ id: `nt-${i}`, conversa_id: `cv-${i}`, texto: `nota ${i}`,
                         autor: "Ana", criado_em: `2026-01-0${i}T10:00:00Z`,
                         vantoro_atividade_id: null, apagada_em: null });
  }
  const t = await subirTudo({}, { tabelas: TABELAS, vantoro: {} });
  const chamar = (q) => fetch(`http://127.0.0.1:${t.porta}/vantoro/notas/subir-tudo?${q}`,
    { method: "POST", headers: { Authorization: "Bearer jwt-bom" } }).then((x) => x.json());

  // Chave que não pode existir não é filtro: na dúvida, o padrão — e o padrão
  // cobre todo mundo. O contrário seria uma URL torta fazendo o retroativo
  // pular clientes sem dizer nada.
  const torto = await chamar("de=banana&quantos=-5");
  ok("com valores impossíveis, percorre desde o começo",
     torto.de === 0 && torto.clientes === 3, JSON.stringify(torto));
  ok("e diz que acabou", torto.fim === true, JSON.stringify(torto));

  // Passando do fim: nada a fazer, e ele diz isso em vez de dar erro.
  const depoisDoFim = await chamar("de=999");
  ok("pedindo depois do último, não faz nada e não quebra",
     depoisDoFim.ok === true && depoisDoFim.clientes === 0 && depoisDoFim.fim === true,
     JSON.stringify(depoisDoFim));

  await t.parar();
}

console.log("\nRodar o retroativo DE NOVO não duplica");
{
  const TABELAS = {
    contatos: [{ id: "ct-1", numero: "5511900001111", vantoro_cliente_id: "v-1" }],
    conversas: [{ id: "cv-1", contato_id: "ct-1", advogado_id: "adv-1" }],
    notas: [{ id: "nt-1", conversa_id: "cv-1", texto: "uma so", autor: "Ana",
              criado_em: "2026-01-01T10:00:00Z", vantoro_atividade_id: null, apagada_em: null }],
    usuarios: [{ id: "u1", nome: "Rodrigo", admin: true }],
  };
  const t = await subirTudo({}, { tabelas: TABELAS, vantoro: {} });
  const chamar = () => fetch(`http://127.0.0.1:${t.porta}/vantoro/notas/subir-tudo`,
    { method: "POST", headers: { Authorization: "Bearer jwt-bom" } }).then((x) => x.json());

  await chamar();
  const segunda = await chamar();
  ok("na segunda rodada nada sobe de novo", segunda.subiram === 0,
     JSON.stringify(segunda));
  ok("e ela reconhece que já estava lá", segunda.jaEstavam === 1,
     JSON.stringify(segunda));
  await t.parar();
}

console.log("\nO retroativo não para no milésimo contato");
{
  // O DEFEITO QUE MAIS SE REPETIU NESTE PROJETO, e o pior lugar possível para
  // ele voltar. O PostgREST devolve no máximo 1000 linhas e NÃO AVISA: a
  // resposta vem com cara de resposta inteira. Um `select` solto aqui leria
  // 1000 contatos, subiria as notas deles, e responderia "pronto" — e as notas
  // de todo mundo a partir do milésimo primeiro ficariam para trás em silêncio,
  // que é a pior forma de perder informação: sem erro, sem lista, sem rastro.
  //
  // 1100 contatos, portanto: acima do teto, para a conta bater só se a leitura
  // for paginada de verdade.
  const QUANTOS = 1100;
  const contatos = [], conversas = [], notas = [];
  for (let i = 0; i < QUANTOS; i++) {
    // ID COM ZEROS À ESQUERDA. A leitura é ordenada por `id`, e sem os zeros
    // "ct-1000" viria antes de "ct-999" na ordem de texto — as páginas se
    // sobreporiam e o teste passaria por acaso, medindo outra coisa.
    const n = String(i).padStart(4, "0");
    contatos.push({ id: `ct-${n}`, numero: `55119${n}0000`, vantoro_cliente_id: `v-${n}` });
    conversas.push({ id: `cv-${n}`, contato_id: `ct-${n}`, advogado_id: "adv-1" });
    notas.push({ id: `nt-${n}`, conversa_id: `cv-${n}`, texto: `nota ${n}`, autor: "Ana",
                 criado_em: "2026-01-01T10:00:00Z", vantoro_atividade_id: null,
                 apagada_em: null });
  }
  const t = await subirTudo({}, {
    tabelas: { contatos, conversas, notas,
               usuarios: [{ id: "u1", nome: "Rodrigo", admin: true }] },
    vantoro: {} });

  // EM SIMULAÇÃO: a conta é a mesma e nada sai pela rede. É a leitura que está
  // sendo medida aqui, não o envio.
  //
  // `quantos=tudo` porque a fatia padrão pararia nos primeiros 50 e esta prova
  // ficaria medindo a fatia em vez do teto de leitura — o teto do PostgREST
  // continuaria escondido, que é justamente o que ela existe para pegar.
  const r = await (await fetch(
    `http://127.0.0.1:${t.porta}/vantoro/notas/subir-tudo?simular=1&quantos=tudo`,
    { method: "POST", headers: { Authorization: "Bearer jwt-bom" } })).json();
  ok("leu os 1100 clientes, e não só os 1000 do teto", r.clientes === QUANTOS,
     JSON.stringify({ clientes: r.clientes, subiram: r.subiram }));
  ok("e contou a nota de cada um deles", r.subiram === QUANTOS,
     JSON.stringify({ clientes: r.clientes, subiram: r.subiram }));
  await t.parar();
}

console.log("\nUm lote com problema não derruba o retroativo inteiro");
{
  // O RETROATIVO RODA UMA VEZ, sobre o histórico inteiro do escritório. Se um
  // pedaço da leitura falhar — e o Supabase falha: instabilidade, tempo
  // esgotado, o Auth no chão como em 19/08 —, parar tudo deixaria o resto do
  // escritório sem retroativo NENHUM, e sem dizer de quem foi o problema.
  //
  // O certo é o oposto: conta o lote que falhou, NOMEIA quem estava nele, e
  // segue com os outros. Quem for refazer sabe exatamente o que refazer.
  const QUANTOS = 250;   // 2 lotes: 200 + 50
  const contatos = [], conversas = [], notas = [];
  for (let i = 0; i < QUANTOS; i++) {
    const n = String(i).padStart(4, "0");
    contatos.push({ id: `ct-${n}`, numero: `55119${n}0000`, vantoro_cliente_id: `v-${n}` });
    conversas.push({ id: `cv-${n}`, contato_id: `ct-${n}`, advogado_id: "adv-1" });
    notas.push({ id: `nt-${n}`, conversa_id: `cv-${n}`, texto: `nota ${n}`, autor: "Ana",
                 criado_em: "2026-01-01T10:00:00Z", vantoro_atividade_id: null,
                 apagada_em: null });
  }
  const t = await subirTudo({}, {
    tabelas: { contatos, conversas, notas,
               usuarios: [{ id: "u1", nome: "Rodrigo", admin: true }] },
    vantoro: {},
    // SÓ O PRIMEIRO LOTE QUEBRA. O `ct-0000` só aparece na consulta do lote que
    // o contém — é assim que se derruba um pedaço e se deixa o outro de pé.
    // Quebrar tudo provaria apenas que dá erro, e não que os outros seguem.
    quebrar: (metodo, tabela, busca) =>
      (metodo === "GET" && tabela.startsWith("conversas") && String(busca).includes("ct-0000"))
        ? "conexão perdida no meio da leitura" : null,
  });

  // `quantos=tudo`: o que se mede aqui é um lote de leitura cair no meio do
  // caminho, e com a fatia padrão os dois lotes nem seriam alcançados.
  const r = await (await fetch(
    `http://127.0.0.1:${t.porta}/vantoro/notas/subir-tudo?simular=1&quantos=tudo`,
    { method: "POST", headers: { Authorization: "Bearer jwt-bom" } })).json();

  ok("responde, em vez de estourar", r.ok === true, JSON.stringify(r));
  ok("o lote que sobreviveu subiu assim mesmo", r.subiram === 50,
     JSON.stringify({ subiram: r.subiram, falharam: r.falharam }));
  ok("e o que falhou é contado, e não esquecido", r.falharam === 200,
     JSON.stringify({ subiram: r.subiram, falharam: r.falharam }));
  // NOMEADOS. "200 falharam" no meio de um número grande é um dado que ninguém
  // consegue usar: sem saber QUAIS, não há o que refazer.
  ok("com os telefones de quem ficou para trás",
     (r.com_problema || []).includes("5511900000000"),
     JSON.stringify((r.com_problema || []).slice(0, 3)));
  await t.parar();
}

console.log("\nSó quem administra pode rodar o retroativo");
{
  const t = await subirTudo({}, {
    tabelas: { usuarios: [{ id: "u1", nome: "Rodrigo", admin: false }] },
    vantoro: {} });
  const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/notas/subir-tudo`,
    { method: "POST", headers: { Authorization: "Bearer jwt-bom" } });
  ok("quem não é admin é recusado", r.status === 403, `veio ${r.status}`);
  await t.parar();
}

console.log("\nUM contato só — quando ele acaba de virar cliente");
{
  const TABELAS = {
    contatos: [{ id: "ct-1", numero: "5511900001111", vantoro_cliente_id: "v-7" }],
    // DUAS CONVERSAS. Um contato que voltou meses depois tem mais de uma, e as
    // notas das duas são do mesmo cliente — com uma conversa só, um caminho que
    // lesse apenas a primeira passaria batido.
    conversas: [
      { id: "cv-1", contato_id: "ct-1", advogado_id: "adv-1" },
      { id: "cv-2", contato_id: "ct-1", advogado_id: "adv-1" },
    ],
    // PLANTADAS FORA DE ORDEM de propósito: se o caminho de um contato só não
    // ordenar, ele sobe na ordem em que o banco devolver, e o histórico do
    // cliente fica ilegível para quem for entender o caso meses depois.
    notas: [
      { id: "nt-2", conversa_id: "cv-2", texto: "a segunda coisa", autor: "Davi",
        criado_em: "2026-03-01T10:00:00Z", vantoro_atividade_id: null, apagada_em: null },
      { id: "nt-1", conversa_id: "cv-1", texto: "antes do cadastro", autor: "Ana",
        criado_em: "2026-01-01T10:00:00Z", vantoro_atividade_id: null, apagada_em: null },
    ],
    usuarios: [{ id: "u1", nome: "Rodrigo", admin: false }],
  };
  const t = await subirTudo({}, { tabelas: TABELAS, vantoro: {} });
  const r = await (await fetch(`http://127.0.0.1:${t.porta}/vantoro/contato/ct-1/subir-notas`,
    { method: "POST", headers: { Authorization: "Bearer jwt-bom" } })).json();
  ok("sobe o que ele já tinha anotado", r.subiram === 2, JSON.stringify(r));
  ok("e NÃO exige ser admin — é o fluxo normal de quem atende", r.ok === true);

  const enviadas = t.van.recebidas.filter((x) => /\/nota$/.test(x.caminho));
  const nota = enviadas[0];
  ok("no cliente que acabou de ser criado", nota?.caminho === "/clientes/v-7/nota",
     nota?.caminho);
  ok("como nota geral", nota?.corpo?.processo_id === null);
  ok("das duas conversas dele, e não só da primeira", enviadas.length === 2,
     JSON.stringify(enviadas.map((x) => x.corpo?.texto)));
  ok("e na ordem em que foram escritas",
     enviadas[0]?.corpo?.texto === "antes do cadastro"
     && enviadas[1]?.corpo?.texto === "a segunda coisa",
     JSON.stringify(enviadas.map((x) => x.corpo?.texto)));
  await t.parar();
}

console.log("\nContato sem cadastro: diz que não há para onde subir");
{
  const t = await subirTudo({}, {
    tabelas: {
      contatos: [{ id: "ct-9", numero: "5511900009999", vantoro_cliente_id: null }],
      usuarios: [{ id: "u1", nome: "Rodrigo", admin: false }],
    }, vantoro: {} });
  const r = await (await fetch(`http://127.0.0.1:${t.porta}/vantoro/contato/ct-9/subir-notas`,
    { method: "POST", headers: { Authorization: "Bearer jwt-bom" } })).json();
  ok("responde sem erro", r.ok === true, JSON.stringify(r));
  ok("e explica que a nota fica na conversa",
     /ainda não tem cadastro/i.test(r.detalhe || ""), r.detalhe);
  await t.parar();
}

// ==================================================================
//  O CAMINHO DE VOLTA — o Vantoro contando que a nota mudou lá
// ==================================================================
//
//  Até agora a nota andava num sentido só. Quem corrigisse o texto pela tela do
//  Vantoro via a correção ficar lá: na conversa continuava o texto velho, e quem
//  lê a conversa durante o atendimento não tinha como saber que havia versão
//  mais nova. Nada dava erro.
//
//  A porta fica na INTERNET ABERTA, sem sessão e sem token de usuário. O que
//  prova que o aviso veio do Vantoro é a assinatura do corpo.

const SEGREDO_VANTORO = "segredo-do-vantoro";

function avisarQueMudou(porta, corpo, { segredo = SEGREDO_VANTORO, assinatura } = {}) {
  // ASSINA OS BYTES QUE VÃO SER MANDADOS, e não o objeto. É o que o Vantoro faz
  // do outro lado, e é o único jeito de a conferência ser sobre a mesma coisa.
  const bytes = Buffer.from(JSON.stringify(corpo), "utf8");
  const assinada = assinatura !== undefined ? assinatura
    : crypto.createHmac("sha256", segredo).update(bytes).digest("hex");
  return fetch(`http://127.0.0.1:${porta}/vantoro/nota-mudou`, {
    method: "POST",
    headers: { "Content-Type": "application/json",
               "X-Vantoro-Assinatura": assinada },
    body: bytes,
  });
}

const notaBase = (extra = {}) => ({
  id: "nt-1", conversa_id: "cv-1", texto: "texto de antes", autor: "Ana",
  criado_em: "2026-01-01T10:00:00Z", atualizado_em: "2026-01-01T10:00:00Z",
  vantoro_atividade_id: null, apagada_em: null, ...extra,
});
const tabelasComNota = (extra = {}) => ({
  contatos: [{ id: "ct-1", numero: "5511900001111", vantoro_cliente_id: "v-1" }],
  conversas: [{ id: "cv-1", contato_id: "ct-1", advogado_id: "adv-1" }],
  notas: [notaBase(extra)],
  usuarios: [{ id: "u1", nome: "Rodrigo", admin: true }],
});
const notaDe = (t) => t.sb.dados.notas.find((n) => n.id === "nt-1");

console.log("\nO Vantoro avisa que a nota mudou lá, e a conversa acompanha");
{
  const t = await subirTudo({ VANTORO_WEBHOOK_SECRET: SEGREDO_VANTORO },
                            { tabelas: tabelasComNota(), vantoro: {} });
  const r = await avisarQueMudou(t.porta, {
    nota_id: "nt-1", atividade_id: 77, texto: "corrigido na tela do Vantoro",
    processo_id: null, atualizado_em: "2026-06-01T10:00:00Z",
  });
  const corpo = await r.json();
  ok("o aviso é aceito", r.status === 200 && corpo.atualizada === true,
     `${r.status} ${JSON.stringify(corpo)}`);
  ok("e o texto da conversa passa a ser o do Vantoro",
     notaDe(t)?.texto === "corrigido na tela do Vantoro", notaDe(t)?.texto);
  // O CARIMBO QUE CHEGOU, e não `now()`. Gravar a hora de agora faria esta
  // linha parecer mais nova do que a versão que ela ACABOU de copiar — e no
  // próximo aviso ela ganharia dele, desfazendo a cópia.
  ok("guardando o carimbo do Vantoro, e não a hora de agora",
     notaDe(t)?.atualizado_em === "2026-06-01T10:00:00Z", notaDe(t)?.atualizado_em);
  ok("e o elo com a atividade de lá", String(notaDe(t)?.vantoro_atividade_id) === "77",
     String(notaDe(t)?.vantoro_atividade_id));
  await t.parar();
}

console.log("\nO Vantoro escreve JSON do jeito do Python, e a assinatura bate");
{
  // ESTA CONFERÊNCIA EXISTE POR CAUSA DE UMA SABOTAGEM QUE NÃO MORDEU.
  //
  // A porta confere a assinatura sobre os BYTES QUE CHEGARAM, e não sobre o
  // objeto já lido e escrito de novo. Sabotei isso — trocando por
  // `JSON.stringify(req.body)` — e a bancada inteira passou, porque aqui QUEM
  // MANDA TAMBÉM É JAVASCRIPT: os dois lados serializam igual, e reserializar
  // devolve exatamente os mesmos bytes.
  //
  // O Vantoro é Python, e o Python escreve diferente — foi medido:
  //
  //   Python : {"nota_id": "nt-1", "texto": "oi"}
  //   JS     : {"nota_id":"nt-1","texto":"oi"}
  //
  // Com espaço, sem espaço. Bytes diferentes, assinatura diferente. Reserializar
  // recusaria TODA entrega legítima do Vantoro, e o sintoma seria a nota
  // parando de refletir sem erro em lugar nenhum.
  //
  // Então este corpo é montado À MÃO, com os separadores do Python.
  const t = await subirTudo({ VANTORO_WEBHOOK_SECRET: SEGREDO_VANTORO },
                            { tabelas: tabelasComNota(), vantoro: {} });

  const comoOPythonEscreve =
    '{"nota_id": "nt-1", "atividade_id": 77, "texto": "veio do Python", '
    + '"processo_id": null, "atualizado_em": "2026-06-01T10:00:00Z"}';
  const bytes = Buffer.from(comoOPythonEscreve, "utf8");
  const assinatura = crypto.createHmac("sha256", SEGREDO_VANTORO)
    .update(bytes).digest("hex");

  const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/nota-mudou`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Vantoro-Assinatura": assinatura },
    body: bytes,
  });
  ok("a assinatura do Python é aceita", r.status === 200, `veio ${r.status}`);
  ok("e a nota é reescrita", notaDe(t)?.texto === "veio do Python", notaDe(t)?.texto);
  await t.parar();
}

console.log("\nA última edição vence — TAMBÉM deste lado");
{
  // A regra precisa existir nos DOIS lados. Se só um comparasse, a nota ficaria
  // indo e voltando: o lado sem comparação aceitaria a versão velha e a
  // devolveria como se fosse novidade.
  const t = await subirTudo({ VANTORO_WEBHOOK_SECRET: SEGREDO_VANTORO },
    { tabelas: tabelasComNota({ texto: "escrito aqui agora",
                                atualizado_em: "2026-07-01T10:00:00Z" }),
      vantoro: {} });
  const r = await avisarQueMudou(t.porta, {
    nota_id: "nt-1", texto: "versão VELHA do Vantoro",
    atualizado_em: "2026-01-01T10:00:00Z",
  });
  const corpo = await r.json();
  ok("o aviso velho é ignorado", corpo.ignorada === true, JSON.stringify(corpo));
  ok("e o texto daqui NÃO é apagado", notaDe(t)?.texto === "escrito aqui agora",
     notaDe(t)?.texto);
  await t.parar();
}

console.log("\nSem a assinatura certa, a porta não abre");
{
  const t = await subirTudo({ VANTORO_WEBHOOK_SECRET: SEGREDO_VANTORO },
                            { tabelas: tabelasComNota(), vantoro: {} });
  const carga = { nota_id: "nt-1", texto: "invasão", atualizado_em: "2026-06-01T10:00:00Z" };

  const semNada = await avisarQueMudou(t.porta, carga, { assinatura: "" });
  ok("sem assinatura, recusa", semNada.status === 401, `veio ${semNada.status}`);

  const comOutro = await avisarQueMudou(t.porta, carga, { segredo: "outro-segredo" });
  ok("com o segredo errado, recusa", comOutro.status === 401, `veio ${comOutro.status}`);

  // O CORPO TROCADO NO CAMINHO. É o ataque que a assinatura existe para
  // impedir: o aviso é legítimo, mas o texto foi mexido depois de assinado.
  const bytes = Buffer.from(JSON.stringify(carga), "utf8");
  const assinaturaBoa = crypto.createHmac("sha256", SEGREDO_VANTORO).update(bytes).digest("hex");
  const mexido = await fetch(`http://127.0.0.1:${t.porta}/vantoro/nota-mudou`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Vantoro-Assinatura": assinaturaBoa },
    body: JSON.stringify({ ...carga, texto: "TROCADO no caminho" }),
  });
  ok("com o corpo trocado depois de assinado, recusa", mexido.status === 401,
     `veio ${mexido.status}`);

  ok("e nada disso encostou na nota", notaDe(t)?.texto === "texto de antes",
     notaDe(t)?.texto);
  await t.parar();
}

console.log("\nSem o segredo configurado, a porta TRANCA");
{
  // Diferente do `/webhook` da Uazapi, que deixa passar enquanto não há segredo.
  // Aquele já estava no ar recebendo mensagem de cliente quando ganhou trava;
  // esta porta nasce agora, sem tráfego legítimo para proteger. Deixá-la aberta
  // seria deixar qualquer um que descubra o endereço reescrever nota no
  // histórico do escritório.
  const t = await subirTudo({}, { tabelas: tabelasComNota(), vantoro: {} });
  const r = await avisarQueMudou(t.porta, {
    nota_id: "nt-1", texto: "sem segredo nenhum", atualizado_em: "2026-06-01T10:00:00Z",
  });
  ok("recusa mesmo com assinatura bem feita", r.status === 401, `veio ${r.status}`);
  ok("e a nota fica intacta", notaDe(t)?.texto === "texto de antes", notaDe(t)?.texto);
  // NO LOG, e não na resposta: dizer a quem bateu QUAL conferência falhou é
  // ensinar a passar pela próxima. No log é a diferença entre "o segredo está
  // diferente dos dois lados" e "a variável não foi preenchida".
  await espera(300);
  ok("e o log diz que a variável não foi preenchida",
     /VANTORO_WEBHOOK_SECRET não está preenchida/.test(t.registro.join("")),
     t.registro.join("").slice(-300));
  await t.parar();
}

console.log("\nAviso sobre nota que não existe mais não vira erro");
{
  // A nota pode ter sido apagada aqui, ou a atividade de lá pode ter nascido de
  // outro lugar. Responder 404 faria o Vantoro registrar falha e reclamar no
  // log dele de uma coisa que está certa.
  const t = await subirTudo({ VANTORO_WEBHOOK_SECRET: SEGREDO_VANTORO },
                            { tabelas: tabelasComNota(), vantoro: {} });
  const r = await avisarQueMudou(t.porta, {
    nota_id: "nt-que-nao-existe", texto: "oi", atualizado_em: "2026-06-01T10:00:00Z",
  });
  const corpo = await r.json();
  ok("responde 200, e não erro", r.status === 200, `veio ${r.status}`);
  ok("dizendo que ignorou e por quê", corpo.ignorada === true
     && /não existe mais/i.test(corpo.motivo || ""), JSON.stringify(corpo));
  await t.parar();
}

console.log("\nAviso sem nota_id é recusado dizendo o que falta");
{
  const t = await subirTudo({ VANTORO_WEBHOOK_SECRET: SEGREDO_VANTORO },
                            { tabelas: tabelasComNota(), vantoro: {} });
  const r = await avisarQueMudou(t.porta, { texto: "sem id", atualizado_em: "2026-06-01T10:00:00Z" });
  const corpo = await r.json();
  ok("recusa com 400", r.status === 400, `veio ${r.status}`);
  ok("dizendo que falta o nota_id", /nota_id/.test(corpo.erro || ""), corpo.erro);
  await t.parar();
}

console.log("\nA nota que sobe daqui leva o carimbo deste lado");
{
  // Sem mandar o carimbo, o Vantoro não tem o que comparar e o comportamento
  // antigo volta: o Zorvin sobrescrevendo sempre, apagando correções feitas lá.
  const t = await subirTudo({}, {
    tabelas: { usuarios: [{ id: "u1", nome: "Rodrigo", admin: false }],
               notas: [{ id: "n-x", conversa_id: "cv-1", texto: "nota nova",
                         vantoro_atividade_id: null }] },
    vantoro: {} });
  await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente/v-1/nota`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: "Bearer jwt-bom" },
    body: JSON.stringify({ id: "n-x", texto: "nota nova", processo_id: null }),
  });
  const enviada = t.van.recebidas.find((x) => /\/nota$/.test(x.caminho));
  ok("o carimbo vai junto", !!enviada?.corpo?.atualizado_em,
     JSON.stringify(enviada?.corpo));

  // A MARCA DE QUE SUBIU, que esta rota não gravava.
  //
  // ESTA CONFERÊNCIA VEIO DE UM DEFEITO MEDIDO NO ESCRITÓRIO. O Vantoro devolve
  // o id da atividade que a nota virou, e este caminho jogava fora — só o
  // retroativo gravava. Toda nota escrita normalmente ficava com
  // `vantoro_atividade_id` nulo PARA SEMPRE, mesmo tendo chegado perfeitamente.
  //
  // O estrago não foi o campo vazio: foi o diagnóstico lendo esse zero e
  // concluindo "a subida está sendo recusada", mandando procurar defeito no
  // token do Vantoro, que estava certo.
  ok("e a marca de que subiu é gravada",
     String(t.sb.dados.notas.find((n) => n.id === "n-x")?.vantoro_atividade_id || "") !== "",
     JSON.stringify(t.sb.dados.notas));
  await t.parar();
}

console.log("\nSe a marca não puder ser gravada, a nota ainda assim subiu");
{
  // A nota JÁ chegou ao Vantoro, que é o que importava. Devolver erro aqui faria
  // o painel avisar que a nota não subiu quando ela subiu — e a pessoa
  // reescreveria uma nota que já está lá.
  const t = await subirTudo({}, {
    tabelas: { usuarios: [{ id: "u1", nome: "Rodrigo", admin: false }],
               notas: [{ id: "n-y", conversa_id: "cv-1", texto: "nota",
                         vantoro_atividade_id: null }] },
    vantoro: {},
    quebrar: (metodo, tabela) =>
      (metodo === "PATCH" && tabela.startsWith("notas")) ? "sem conexão" : null });
  const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente/v-1/nota`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: "Bearer jwt-bom" },
    body: JSON.stringify({ id: "n-y", texto: "nota", processo_id: null }),
  });
  ok("a resposta continua sendo de sucesso", r.status >= 200 && r.status < 300,
     `veio ${r.status}`);
  ok("e a nota chegou ao Vantoro assim mesmo",
     t.van.recebidas.some((x) => /\/nota$/.test(x.caminho)),
     JSON.stringify(t.van.recebidas.map((x) => x.caminho)));
  await espera(200);
  ok("o log conta que a marca não foi gravada",
     /não consegui gravar a marca/i.test(t.registro.join("")),
     t.registro.join("").slice(-200));
  await t.parar();
}

// ==================================================================
//  POR QUE A NOTA NÃO CHEGOU NO VANTORO
// ==================================================================
//
//  O escritório relatou que as notas internas não aparecem no histórico do
//  cliente. O caminho tem quatro pontos onde ela pode parar, e três deles são
//  MUDOS — nada dá erro, a nota simplesmente fica na conversa.
//
//  Esta rota responde QUAL dos quatro é, em números. Ela existe porque o
//  defeito aparece em quem atende, e pedir para alguém abrir o inspetor do
//  navegador no meio de um atendimento não é caminho.

const diagnosticar = async (t) =>
  (await fetch(`http://127.0.0.1:${t.porta}/vantoro/diagnostico-notas`)).json();

console.log("\nO diagnóstico conta o que existe");
{
  const t = await subirTudo({}, { vantoro: {}, tabelas: {
    contatos: [{ id: "c1", numero: "1", vantoro_cliente_id: "v-1" },
               { id: "c2", numero: "2", vantoro_cliente_id: null },
               { id: "c3", numero: "3", vantoro_cliente_id: "v-3" }],
    notas: [{ id: "n1", conversa_id: "cv", vantoro_atividade_id: 5 },
            { id: "n2", conversa_id: "cv", vantoro_atividade_id: null }] } });
  const r = await diagnosticar(t);

  // AS CONTAGENS SÃO O TOTAL QUE CASA COM O FILTRO, e não o tamanho da página.
  // Contar o que veio na resposta esbarraria no teto de mil linhas do PostgREST
  // e diria "1000 contatos" para um escritório com três mil — que é o defeito
  // que mais se repetiu neste projeto, agora dentro da ferramenta que existe
  // para diagnosticar defeito.
  ok("conta os contatos", r.contatos === 3, JSON.stringify(r));
  ok("e quantos têm cadastro no Vantoro", r.contatos_com_cadastro_no_vantoro === 2,
     JSON.stringify(r));
  ok("conta as notas", r.notas === 2, JSON.stringify(r));
  ok("e quantas já subiram", r.notas_que_ja_subiram === 1, JSON.stringify(r));
  await t.parar();
}

console.log("\nA contagem é o TOTAL, e não o que coube na página");
{
  // ESTA CONFERÊNCIA EXISTE POR CAUSA DE UMA SABOTAGEM QUE NÃO MORDEU.
  //
  // Troquei a contagem exata por `select('id').length` — contar o tamanho da
  // resposta — e a bancada inteira passou. Porque a amostra tinha TRÊS
  // contatos: abaixo do teto, contar a página e contar o total dão o mesmo
  // número, e a conferência media as duas coisas ao mesmo tempo sem distinguir.
  //
  // O PostgREST corta em 1000 linhas e NÃO AVISA. Num escritório com três mil
  // contatos, a ferramenta que existe para DIAGNOSTICAR defeito passaria a
  // conter o defeito que mais se repetiu neste projeto: diria "1000" com cara
  // de resposta inteira, e o diagnóstico sairia errado com toda a confiança.
  //
  // 1100 contatos, portanto: acima do teto, para os dois jeitos de contar
  // deixarem de coincidir.
  const QUANTOS = 1100;
  const contatos = [];
  for (let i = 0; i < QUANTOS; i++) {
    const n = String(i).padStart(4, "0");
    contatos.push({ id: `ct-${n}`, numero: `55119${n}0000`, vantoro_cliente_id: `v-${n}` });
  }
  const t = await subirTudo({}, { vantoro: {}, tabelas: { contatos, notas: [] } });
  const r = await diagnosticar(t);
  ok("conta os 1100, e não os 1000 do teto", r.contatos === QUANTOS,
     JSON.stringify({ contatos: r.contatos }));
  ok("e o mesmo vale para os que têm cadastro",
     r.contatos_com_cadastro_no_vantoro === QUANTOS,
     JSON.stringify({ com_cadastro: r.contatos_com_cadastro_no_vantoro }));
  await t.parar();
}

console.log("\nColuna que não existe é a causa mais silenciosa, e ele diz isso");
{
  // O CASO MAIS PROVÁVEL, e o mais mudo dos quatro: o painel pede
  // `vantoro_cliente_id`, o banco recusa a consulta INTEIRA, e ele desce para o
  // conjunto de colunas antigo pela sessão toda. A partir daí o `if` que decide
  // subir nunca é verdadeiro, e ninguém vê erro nenhum.
  //
  // A FALTA DA COLUNA É DE VERDADE AGORA, e não mais um erro forjado.
  //
  // Este teste vivia com um remendo: o Supabase de mentira aceitava qualquer
  // coluna — guardava objetos, e pedir um campo que nenhum tinha devolvia
  // indefinido em vez de recusar —, então a recusa era simulada com `quebrar`,
  // mandando o texto do erro escrito na mão. Ficava anotado aqui como lacuna da
  // bancada: enquanto o falso aceitasse coluna inexistente, QUALQUER prova
  // podia passar pedindo campo que o banco não tem.
  //
  // A lacuna foi fechada. `semColunas` diz ao falso que aquela coluna não
  // existe naquela tabela — o estado de uma base em que o SQL ainda não foi
  // rodado —, e é o PRÓPRIO FALSO que recusa a consulta inteira com 42703,
  // como o PostgREST faz. O caminho exercitado aqui passa a ser o de lá.
  const t = await subirTudo({}, { vantoro: {}, tabelas: {
    contatos: [{ id: "c1", numero: "1" }],
    notas: [{ id: "n1", conversa_id: "cv" }] },
    semColunas: { contatos: ["vantoro_cliente_id"] } });
  const r = await diagnosticar(t);
  ok("percebe que a coluna não existe",
     r.coluna_contatos_vantoro_cliente_id === false, JSON.stringify(r));
  ok("e diz QUE SQL rodar, em vez de só apontar o defeito",
     /NÃO EXISTE/.test(r.diagnostico || "") && /SQL/.test(r.diagnostico || ""),
     r.diagnostico);
  await t.parar();
}

console.log("\nColuna existe e ninguém está ligado: isso é o CERTO, e ele explica");
{
  // Aqui não há defeito nenhum — enquanto o contato não tem cadastro, a nota
  // fica na conversa, que é o desenho. Chamar isto de erro mandaria alguém
  // caçar um problema que não existe.
  const t = await subirTudo({}, { vantoro: {}, tabelas: {
    contatos: [{ id: "c1", numero: "1", vantoro_cliente_id: null }],
    notas: [{ id: "n1", conversa_id: "cv", vantoro_atividade_id: null }] } });
  const r = await diagnosticar(t);
  ok("vê a coluna", r.coluna_contatos_vantoro_cliente_id === true, JSON.stringify(r));
  ok("e diz que isso é o certo, com o que fazer",
     /é o certo/.test(r.diagnostico || "") && /ficha/.test(r.diagnostico || ""),
     r.diagnostico);
  await t.parar();
}

console.log("\nTem cadastro, tem nota, nenhuma marcada: ele DIZ QUE NÃO SABE");
{
  // ESTA CONFERÊNCIA MUDOU POR CAUSA DE UM ERRO MEU, medido no escritório.
  //
  // Antes ela cobrava a frase "a subida está sendo tentada e recusada" — e essa
  // frase era CONCLUSÃO, não medição. Por muito tempo a rota normal não gravava
  // `vantoro_atividade_id`, então zero aqui era o esperado até para nota que
  // chegou perfeitamente. A ferramenta mandou procurar defeito no token do
  // Vantoro, que estava certo.
  //
  // A conferência antiga não estava frouxa: ela EXIGIA a afirmação errada. Uma
  // prova que cobra uma conclusão sem base a cimenta no lugar de pegá-la.
  //
  // Agora ela cobra o oposto: que a ferramenta admita as duas causas possíveis
  // e ensine o teste que as separa.
  const t = await subirTudo({}, { vantoro: {}, tabelas: {
    contatos: [{ id: "c1", numero: "1", vantoro_cliente_id: "v-1" }],
    notas: [{ id: "n1", conversa_id: "cv", vantoro_atividade_id: null }] } });
  const r = await diagnosticar(t);
  ok("admite que daqui não dá para separar as causas",
     /não dá para separar/i.test(r.diagnostico || ""), r.diagnostico);
  ok("e ensina o teste que separa, em vez de chutar uma delas",
     /nota NOVA/.test(r.diagnostico || "")
     && /Apareceu/.test(r.diagnostico || ""), r.diagnostico);
  ok("citando as duas: retroativo e subida recusada",
     /retroativo/i.test(r.diagnostico || "")
     && /recusada/i.test(r.diagnostico || ""), r.diagnostico);
  await t.parar();
}

console.log("\nO diagnóstico não vaza dado nenhum");
{
  // SÓ CONTAGENS. É o que permite deixar esta rota aberta como as outras de
  // diagnóstico — e aberta é justamente o que ela precisa ser, porque a
  // pergunta que ela responde é a de quem não está conseguindo entrar.
  const t = await subirTudo({}, { vantoro: {}, tabelas: {
    contatos: [{ id: "c1", numero: "5511987654321", nome: "Maria Silva",
                 vantoro_cliente_id: "v-1" }],
    notas: [{ id: "n1", conversa_id: "cv", texto: "segredo do cliente",
              autor: "Isabela", vantoro_atividade_id: null }] } });
  const bruto = await (await fetch(
    `http://127.0.0.1:${t.porta}/vantoro/diagnostico-notas`)).text();
  ok("nenhum nome de contato", !/Maria Silva/.test(bruto));
  ok("nenhum telefone", !/5511987654321/.test(bruto));
  ok("nenhum texto de nota", !/segredo do cliente/.test(bruto));
  ok("e nenhum nome de quem escreveu", !/Isabela/.test(bruto));
  await t.parar();
}

//  A BANCADA CONFERINDO A SI MESMA.
//
//  Toda conferência deste arquivo vale o que valer o Supabase de mentira. Ele
//  aceitava QUALQUER coluna — guardava objetos, e pedir um campo que nenhum
//  tinha devolvia indefinido em vez de recusar. Quer dizer: qualquer prova
//  podia passar pedindo uma coluna que o banco de verdade não tem.
//
//  Não é hipótese. Foi assim que a subida das notas ficou meses sem funcionar:
//  o código pedia `contatos.vantoro_cliente_id`, a coluna não existia, o
//  PostgREST recusava a CONSULTA INTEIRA, e ninguém via erro nenhum.
//
//  As conferências abaixo são sobre o instrumento, e não sobre a ponte. Sem
//  elas, a regra nova poderia estar desligada e todo o resto continuaria verde
//  do mesmo jeito — que é exatamente o problema que ela veio resolver.
console.log("\nO Supabase de mentira recusa coluna que não existe");
{
  const { recusarColunaInexistente, colunasDoSelect } =
    await import("./falso-supabase.mjs");

  const dados = { contatos: [{ id: "c1", numero: "1" }] };

  ok("coluna inventada é recusada, com o código do PostgREST",
     recusarColunaInexistente(dados, "contatos", ["banana"])?.code === "42703");
  ok("e a mensagem diz QUAL coluna e de qual tabela",
     /column contatos\.banana does not exist/.test(
       recusarColunaInexistente(dados, "contatos", ["banana"])?.message || ""));

  // COLUNA QUE EXISTE NO BANCO E NÃO NA AMOSTRA NÃO É RECUSADA, e esta é a
  // conferência que impede a regra de virar um estorvo. Numa amostra de três
  // linhas quase toda coluna está vazia; recusar por isso obrigaria a encher as
  // montagens de `null` até o falso calar a boca — ruído sem informação.
  ok("coluna que existe no banco passa mesmo sem aparecer na amostra",
     recusarColunaInexistente(dados, "contatos", ["vantoro_cliente_id"]) === null);
  ok("e uma coluna que só a amostra tem também passa",
     recusarColunaInexistente({ contatos: [{ id: "c1", inventada_na_montagem: 1 }] },
                              "contatos", ["inventada_na_montagem"]) === null);

  // "NÃO SEI" NÃO É "NÃO EXISTE". Tabela desconhecida e vazia não recusa nada:
  // transformar ignorância em recusa reprovaria consulta correta.
  ok("tabela que ninguém conhece e está vazia não recusa nada",
     recusarColunaInexistente({}, "tabela_que_nao_conheco", ["qualquer"]) === null);

  // O `select` é lido sem confundir a junção embutida com coluna solta.
  ok("o select é lido sem tropeçar na junção embutida",
     JSON.stringify(colunasDoSelect("id, texto, contato:contato_id (numero, nome)"))
       === JSON.stringify(["id", "texto", "contato_id"]));
  ok("e `*` não é uma coluna",
     colunasDoSelect("*").length === 0);
}

console.log("\nE recusa DE PONTA A PONTA, pela rede, como o PostgREST");
{
  // O de cima prova a função. Este prova que ela está LIGADA no caminho da
  // rede — uma regra certa e desconectada não protege nada.
  const t = await subirTudo({}, { tabelas: {
    contatos: [{ id: "c1", numero: "5511900001111" }] } });
  const base = `${t.sb.url}/rest/v1/contatos`;

  const pedindoColuna = await fetch(`${base}?select=id,banana`);
  const corpo = await pedindoColuna.json();
  ok("pedir coluna inventada devolve 400", pedindoColuna.status === 400,
     String(pedindoColuna.status));
  ok("com o código e a mensagem do banco de verdade",
     corpo.code === "42703" && /banana/.test(corpo.message || ""),
     JSON.stringify(corpo));

  // FILTRAR POR COLUNA QUE NÃO EXISTE TAMBÉM RECUSA — e este é o caso mais
  // traiçoeiro dos dois: antes o filtro simplesmente não casava com nada, e a
  // resposta vinha vazia. Lista vazia parece "não achei", não parece defeito.
  const filtrando = await fetch(`${base}?select=id&banana=eq.1`);
  ok("filtrar por coluna inventada também recusa, em vez de devolver vazio",
     filtrando.status === 400, String(filtrando.status));

  const certo = await fetch(`${base}?select=id,numero`);
  ok("e a consulta certa continua passando", certo.status === 200);

  await t.parar();
}

//  TIPO DE MENSAGEM QUE ESTE CÓDIGO NÃO CONHECE.
//
//  O escritório relatou: um álbum de três fotos chegou como UMA bolha só,
//  escrita "Documento — indisponível", com o texto "Album: 3 images". As três
//  fotos não apareceram.
//
//  Este bloco não conserta o álbum — para consertá-lo é preciso saber o que a
//  Uazapi manda num, e isso ainda não foi lido. Ele conserta a razão de não se
//  saber: a mensagem entrava como "documento" ou "texto" SEM DEIXAR RASTRO de
//  que era outra coisa, então a única forma de descobrir o formato era chutar.
//
//  Um evento desconhecido continua virando bolha — anexo que não se sabe ler é
//  melhor na tela do que sumido —, mas agora deixa no log o NOME EXATO do tipo
//  e o corpo. É a mesma decisão já tomada para as reações.
console.log("\nTipo de mensagem desconhecido fica registrado, com o nome exato");
{
  const t = await subirTudo();
  const evento = (extra, id) => ({
    EventType: "messages",
    owner: TELEFONE.numero,
    message: {
      id, messageid: id, chatid: "5511999998888@s.whatsapp.net",
      sender: "5511999998888@s.whatsapp.net", fromMe: false, isGroup: false,
      messageTimestamp: Date.now(), wasSentByApi: false, senderName: "Cliente Teste",
      ...extra,
    },
  });
  const mandar = (corpo) => fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(corpo),
  });

  // O caso do relato, com o tipo cru trocado por um nome inventado: o que se
  // prova aqui é que QUALQUER tipo desconhecido é nomeado no log — não que o
  // álbum se chame assim, o que ainda não se sabe.
  await mandar(evento({ messageType: "tipoQueNinguemConhece",
                        text: "Album: 3 images" }, "msg-desconhecida"));
  await espera(700);

  const log = t.registro.join("");
  ok("o log diz o NOME EXATO do tipo que não foi reconhecido",
     /DESCONHECIDO: "tipoQueNinguemConhece"/.test(log),
     (log.match(/Tipo de mensagem.*/) || [""])[0].slice(0, 160));
  // O CORPO JUNTO. É com um exemplo real em mãos que se ajusta a leitura.
  ok("e manda o corpo junto, para não precisar adivinhar o formato",
     /Album: 3 images/.test(log));
  // E ELA NÃO SOME DA CONVERSA. Anexo que não se sabe ler é melhor na tela do
  // que sumido: quem atende ao menos vê que algo chegou.
  ok("e a mensagem entra na conversa assim mesmo",
     t.sb.dados.mensagens.length === 1,
     JSON.stringify(t.sb.dados.mensagens.map((m) => [m.tipo, m.texto])));

  // O QUE JÁ É CONHECIDO NÃO VIRA RUÍDO. Um aviso em toda mensagem faria
  // ninguém ler o log — e é lá que o aviso precisa ser visto.
  await mandar(mensagemDaUazapi("bom dia", "msg-comum"));
  await mandar(evento({ messageType: "imageMessage", mediaType: "image" }, "msg-foto"));
  await mandar(evento({ messageType: "audioMessage", mediaType: "ptt" }, "msg-audio"));
  await espera(800);
  const avisos = (t.registro.join("").match(/Tipo de mensagem DESCONHECIDO/g) || []).length;
  ok("e o aviso NÃO sai para os tipos que já são conhecidos", avisos === 1,
     `saiu ${avisos} vez(es)`);

  await t.parar();
}

//  DUAS MENSAGENS DIFERENTES COM A MESMA CHAVE.
//
//  `ignoreDuplicates` descarta em silêncio, e é o certo para o caso comum: a
//  Uazapi reenvia a mesma mensagem quando desconfia que não entregou.
//
//  Mas o descarte também acontece quando chegam DUAS MENSAGENS DIFERENTES com o
//  mesmo `messageid` — e aí não é repetição, é perda. O escritório relatou
//  exatamente isso: um álbum de três fotos em que só DUAS apareceram, junto de
//  uma bolha "Album: 3 images".
//
//  Este bloco não conserta o álbum. Ele faz a perda deixar rastro: sem isso,
//  não há como distinguir "a terceira foto nunca chegou" de "chegou e foi
//  engolida aqui" — e são consertos diferentes.
console.log("\nDuas mensagens DIFERENTES com a mesma chave deixam rastro");
{
  const t = await subirTudo();
  const evento = (extra, id) => ({
    EventType: "messages",
    owner: TELEFONE.numero,
    message: {
      id, messageid: id, chatid: "5511999998888@s.whatsapp.net",
      sender: "5511999998888@s.whatsapp.net", fromMe: false, isGroup: false,
      messageTimestamp: Date.now(), wasSentByApi: false, senderName: "Cliente Teste",
      ...extra,
    },
  });
  const mandar = (corpo) => fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(corpo),
  });

  // O ÁLBUM E UMA DAS FOTOS DIVIDINDO A CHAVE — a forma do relato.
  await mandar(evento({ messageType: "conversation", text: "Album: 3 images" }, "msg-album"));
  await espera(600);
  await mandar(evento({ messageType: "imageMessage", mediaType: "image",
                        text: "a foto que some" }, "msg-album"));
  await espera(700);

  const log = t.registro.join("");
  ok("o log diz que duas mensagens diferentes dividiram a chave",
     /DUAS MENSAGENS DIFERENTES COM A MESMA CHAVE/.test(log),
     (log.match(/DUAS MENSAGENS.*/) || [""])[0].slice(0, 200));
  ok("e diz QUAL foi descartada, com o que ela trazia",
     /a foto que some/.test(log), "sem isso não há o que investigar");
  ok("e qual já estava lá",
     /Album: 3 images/.test(log));
  // A REALIDADE CONTINUA A MESMA: uma linha só. O aviso é diagnóstico, não
  // conserto — gravar as duas com a mesma chave é o que a coluna única impede.
  ok("e a conversa continua com uma mensagem só",
     t.sb.dados.mensagens.length === 1,
     JSON.stringify(t.sb.dados.mensagens.map((m) => m.texto)));

  // O REENVIO LEGÍTIMO NÃO VIRA RUÍDO. A Uazapi repete a MESMA mensagem quando
  // desconfia que não entregou; um aviso em cada repetição faria ninguém ler o
  // log, e é lá que este precisa ser visto.
  const antes = (t.registro.join("").match(/DUAS MENSAGENS DIFERENTES/g) || []).length;
  await mandar(evento({ messageType: "conversation", text: "bom dia" }, "msg-repetida"));
  await espera(500);
  await mandar(evento({ messageType: "conversation", text: "bom dia" }, "msg-repetida"));
  await espera(600);
  const depois = (t.registro.join("").match(/DUAS MENSAGENS DIFERENTES/g) || []).length;
  ok("a mesma mensagem reenviada NÃO gera aviso", depois === antes,
     `o aviso saiu ${depois - antes} vez(es) a mais`);
  ok("e ela continua sem duplicar", t.sb.dados.mensagens.length === 2,
     JSON.stringify(t.sb.dados.mensagens.map((m) => m.texto)));

  await t.parar();
}

//  O CADASTRO MUDOU NO VANTORO: nome e telefone.
//
//  Pedido do escritório: "quando eu altero alguma informação no Vantoro, não
//  está atualizando no Zorvin". Não era um sincronismo quebrado — era a
//  ausência de um.
//
//  AS DUAS METADES SÃO DIFERENTES, e é isso que este bloco protege:
//
//    NOME é cópia, e cópia velha se atualiza.
//
//    TELEFONE não é cópia. Aqui o número É o da conversa do WhatsApp, e não
//    pode ser sobrescrito por nada que venha do Vantoro. O que a mudança dele
//    faz é tornar FALSO um vínculo que existe — o caso da mãe e do filho no
//    mesmo número, com o telefone da mãe corrigido lá. Sem desfazer o vínculo,
//    a nota escrita naquela conversa continuaria subindo para a ficha de quem
//    não atende mais por aquele número.
function avisarCadastroMudou(porta, corpo, { segredo = SEGREDO_VANTORO, assinatura } = {}) {
  const bytes = Buffer.from(JSON.stringify(corpo), "utf8");
  const assinada = assinatura !== undefined ? assinatura
    : crypto.createHmac("sha256", segredo).update(bytes).digest("hex");
  return fetch(`http://127.0.0.1:${porta}/vantoro/cliente-mudou`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Vantoro-Assinatura": assinada },
    body: bytes,
  });
}

const contatosDeTeste = () => ([
  // A MÃE e o FILHO no mesmo número — a montagem do relato. Só a conversa da
  // mãe está ligada a ela.
  { id: "ct-mae", numero: "5567992183107", vantoro_cliente_id: "v-mae",
    vantoro_nome: "MARIA DAS GRACAS" },
  // Outro contato, de outro cliente: ele NÃO pode ser tocado por um aviso que
  // não é dele. Sem esta linha na amostra, um `update` sem filtro passaria.
  { id: "ct-outro", numero: "5511900001111", vantoro_cliente_id: "v-outro",
    vantoro_nome: "OUTRO CLIENTE" },
]);

console.log("\nNome mudou no Vantoro: a conversa passa a mostrar o nome novo");
{
  const t = await subirTudo({ VANTORO_WEBHOOK_SECRET: SEGREDO_VANTORO },
                            { tabelas: { contatos: contatosDeTeste() } });
  const r = await avisarCadastroMudou(t.porta, {
    cliente_id: "v-mae", nome: "MARIA DAS GRACAS PEREIRA",
    chaves_de_telefone: ["92183107"],
  });
  const corpo = await r.json();
  ok("a ponte aceita o aviso", r.status === 200 && corpo.ok === true, JSON.stringify(corpo));
  ok("e renomeia o contato ligado",
     t.sb.dados.contatos.find((c) => c.id === "ct-mae")?.vantoro_nome === "MARIA DAS GRACAS PEREIRA",
     JSON.stringify(t.sb.dados.contatos.map((c) => [c.id, c.vantoro_nome])));
  // O VÍNCULO CONTINUA: o número não mudou, então nada a desfazer.
  ok("sem desligar o vínculo, porque o número continua sendo dele",
     t.sb.dados.contatos.find((c) => c.id === "ct-mae")?.vantoro_cliente_id === "v-mae");
  // NINGUÉM MAIS É TOCADO. Um `update` sem o filtro do cliente renomearia o
  // escritório inteiro com o nome de um cliente só.
  ok("e o contato de OUTRO cliente não é tocado",
     t.sb.dados.contatos.find((c) => c.id === "ct-outro")?.vantoro_nome === "OUTRO CLIENTE");
  await t.parar();
}

console.log("\nTelefone mudou: o vínculo que deixou de ser verdade é desfeito");
{
  const t = await subirTudo({ VANTORO_WEBHOOK_SECRET: SEGREDO_VANTORO },
                            { tabelas: { contatos: contatosDeTeste() } });
  // A mãe passou a atender por OUTRO número. A conversa antiga não é mais dela.
  const r = await avisarCadastroMudou(t.porta, {
    cliente_id: "v-mae", nome: "MARIA DAS GRACAS",
    chaves_de_telefone: ["11112222"],
  });
  const corpo = await r.json();
  ok("a ponte responde quantos desligou", corpo.desligados === 1, JSON.stringify(corpo));

  const mae = t.sb.dados.contatos.find((c) => c.id === "ct-mae");
  ok("o vínculo foi desfeito", mae?.vantoro_cliente_id == null, JSON.stringify(mae));
  ok("e o nome copiado saiu junto", mae?.vantoro_nome == null, JSON.stringify(mae));

  // O NÚMERO DA CONVERSA NÃO É TOCADO. Ele é do WhatsApp, não do Vantoro:
  // trocá-lo desligaria a conversa do aparelho que a mandou.
  ok("o número da conversa continua o mesmo",
     mae?.numero === "5567992183107", JSON.stringify(mae));
  await t.parar();
}

console.log("\nSem as chaves, o vínculo NÃO é desfeito");
{
  // "Não sei" não pode virar "não é". Um aviso que chegue sem a lista de
  // telefones — versão antiga do Vantoro, campo perdido no caminho — desligaria
  // TODOS os vínculos do escritório se a ausência fosse lida como ausência de
  // número.
  const t = await subirTudo({ VANTORO_WEBHOOK_SECRET: SEGREDO_VANTORO },
                            { tabelas: { contatos: contatosDeTeste() } });
  await avisarCadastroMudou(t.porta, { cliente_id: "v-mae", nome: "NOME NOVO" });
  const mae = t.sb.dados.contatos.find((c) => c.id === "ct-mae");
  ok("o vínculo fica de pé", mae?.vantoro_cliente_id === "v-mae", JSON.stringify(mae));
  ok("e o nome é atualizado assim mesmo", mae?.vantoro_nome === "NOME NOVO");
  await t.parar();
}

console.log("\nA porta do cadastro exige a assinatura, como a da nota");
{
  const t = await subirTudo({ VANTORO_WEBHOOK_SECRET: SEGREDO_VANTORO },
                            { tabelas: { contatos: contatosDeTeste() } });
  const semAssinatura = await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente-mudou`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ cliente_id: "v-mae", nome: "INVASOR" }),
  });
  ok("sem assinatura, recusa", semAssinatura.status === 401, String(semAssinatura.status));

  const comOutroSegredo = await avisarCadastroMudou(
    t.porta, { cliente_id: "v-mae", nome: "INVASOR" }, { segredo: "outro" });
  ok("com o segredo errado, recusa", comOutroSegredo.status === 401,
     String(comOutroSegredo.status));

  ok("e nada foi alterado",
     t.sb.dados.contatos.find((c) => c.id === "ct-mae")?.vantoro_nome === "MARIA DAS GRACAS");
  await t.parar();
}

console.log("\nCliente sem conversa nenhuma aqui não é erro");
{
  const t = await subirTudo({ VANTORO_WEBHOOK_SECRET: SEGREDO_VANTORO },
                            { tabelas: { contatos: contatosDeTeste() } });
  const r = await avisarCadastroMudou(t.porta, {
    cliente_id: "v-que-nao-tem-conversa", nome: "FULANO",
    chaves_de_telefone: ["99998888"],
  });
  const corpo = await r.json();
  // É o normal para a maior parte do cadastro do escritório. Responder erro
  // faria o Vantoro registrar falha no log dele de uma coisa que está certa.
  ok("responde ok, com zero ligados", r.status === 200 && corpo.ligados === 0,
     JSON.stringify(corpo));
  await t.parar();
}

// ==================================================================
//  O ÁLBUM DE FOTOS: três fotos são três bolhas, e não quatro
// ==================================================================
//
// Relato do escritório, com o log em mãos: mandar três fotos de uma vez fazia
// aparecer uma bolha vazia ANTES delas — "Documento — indisponível", com o
// texto "Album: 3 images".
//
// O corpo abaixo é o que veio no log de produção, palavra por palavra. Guardá-lo
// aqui é o que impede o conserto de ser um palpite: se a Uazapi mudar o
// formato, esta prova é que vai dizer, e não o escritório.
//
//   messageType: "AlbumMessage",  mediaType: "collection",
//   content: { expectedImageCount: 3, expectedVideoCount: 0 },
//   text: "Album: 3 images"
//
// O aviso não carrega arquivo — o `content` dele são dois números. Era por isso
// que o download falhava e a bolha nascia vazia: não havia o que baixar. As
// três fotos chegam em seguida, cada uma como mensagem própria, e são elas que
// a pessoa mandou.
{
  console.log("\nO álbum de fotos");

  /** O aviso de álbum, exatamente como a Uazapi mandou em produção. */
  const avisoDeAlbum = {
    EventType: "messages",
    owner: TELEFONE.numero,
    message: {
      id: "5511992057503:3A6D12E5AA5DCB8B6C19",
      messageid: "3A6D12E5AA5DCB8B6C19",
      chatid: "5511999998888@s.whatsapp.net",
      sender: "5511999998888@s.whatsapp.net",
      fromMe: false, isGroup: false,
      messageType: "AlbumMessage", mediaType: "collection", type: "media",
      content: { expectedImageCount: 3, expectedVideoCount: 0 },
      text: "Album: 3 images",
      messageTimestamp: Date.now(), wasSentByApi: false,
      senderName: "Cliente Teste",
    },
  };

  /** Uma das fotos do álbum — chega logo depois, com id e arquivo próprios. */
  const fotoDoAlbum = (id) => ({
    EventType: "messages",
    owner: TELEFONE.numero,
    message: {
      id, messageid: id, chatid: "5511999998888@s.whatsapp.net",
      sender: "5511999998888@s.whatsapp.net", fromMe: false, isGroup: false,
      messageType: "imageMessage", mediaType: "image", type: "media",
      content: {}, text: "",
      messageTimestamp: Date.now(), wasSentByApi: false,
      senderName: "Cliente Teste",
    },
  });

  const t = await subirTudo();
  const mandar = (corpo) => fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(corpo),
  });

  await mandar(avisoDeAlbum);
  await espera(700);
  ok("o aviso de álbum NÃO vira bolha",
     t.sb.dados.mensagens.length === 0,
     `entraram ${t.sb.dados.mensagens.length}: ` +
     JSON.stringify(t.sb.dados.mensagens.map((m) => [m.tipo, m.texto])));
  ok("e o log diz que ele chegou, em vez de sumir calado",
     t.registro.join("").includes("Aviso de álbum"),
     t.registro.join("").slice(-300));
  // O ALERTA DE TIPO DESCONHECIDO TAMBÉM PARA. Ele existe para dizer "há algo
  // a investigar aqui", e não há mais: 800 caracteres de log por álbum
  // recebido enterrariam o alerta do dia em que houver mesmo.
  ok("e não grita mais 'tipo DESCONHECIDO' por um formato que já se conhece",
     !t.registro.join("").includes("Tipo de mensagem DESCONHECIDO"),
     t.registro.join("").slice(-300));

  // E AS FOTOS ENTRAM. É a conferência que impede o conserto largo demais:
  // descartar o álbum inteiro seria mais fácil e apagaria o que a pessoa mandou.
  await mandar(fotoDoAlbum("3AB6491AA389F1A53C2F"));
  await mandar(fotoDoAlbum("3A2B447468DAF6A8D7F8"));
  await mandar(fotoDoAlbum("3A57BB31ED8EB0B9CB04"));
  await espera(1500);
  const imagens = t.sb.dados.mensagens.filter((m) => m.tipo === "imagem");
  ok("as três fotos do álbum entram, cada uma na sua bolha",
     imagens.length === 3, `entraram ${imagens.length} de 3`);
  ok("e nenhuma bolha de documento sobrou no meio delas",
     !t.sb.dados.mensagens.some((m) => m.tipo === "documento"),
     JSON.stringify(t.sb.dados.mensagens.map((m) => [m.tipo, m.texto])));

  await t.parar();
}

// ==================================================================
//  O TOQUE QUE CHEGA NO MEIO DO CICLO NÃO PODE SER JOGADO FORA
// ==================================================================
//
// Relato do escritório: "ao enviar mensagem tá demorando muito, fica só com um
// relógio carregando".
//
// O painel toca a campainha da ponte a cada mensagem que entra na fila, para
// ela despachar na hora em vez de esperar o `setInterval` de 3 segundos. Mas
// `filaRodando` fazia a chamada voltar EM SILÊNCIO quando um ciclo já estava
// rodando — e o toque se perdia.
//
// Três mensagens seguidas: a primeira acorda a fila e o ciclo começa; as duas
// seguintes tocam enquanto ele roda, e os dois toques eram descartados. Elas só
// saíam no próximo tique de 3 segundos. É esse o relóginho parado na bolha.
//
// A PROVA SEGURA O CICLO ABERTO de propósito: a falsa Uazapi demora 900 ms para
// responder o envio. Nesse intervalo entra a segunda mensagem e toca de novo —
// o toque que antes se perdia. Se ela sair logo depois do primeiro envio, o
// toque foi aproveitado; se demorar até o tique, foi jogado fora.
{
  console.log("\nO toque perdido no meio do ciclo");
  const t = await subirTudo({}, { uazapi: { demoraDoEnvio: 900 } });
  t.sb.dados.contatos.push({ id: 1, numero: "5511999998888", nome: "Cliente Teste" });
  t.sb.dados.conversas.push({ id: 1, advogado_id: TELEFONE.id, contato_id: 1 });
  t.sb.dados.fila_envio.push({
    id: 1, conversa_id: 1, tipo: "texto", texto: "PRIMEIRA", status: "pendente",
    tentativas: 0, criado_em: new Date().toISOString(),
  });

  const comecou = Date.now();
  await fetch(`http://127.0.0.1:${t.porta}/ping`);       // acorda: o ciclo começa
  await espera(300);                                     // o ciclo está no meio do envio

  // A SEGUNDA ENTRA AGORA, com o ciclo aberto — e toca a campainha.
  t.sb.dados.fila_envio.push({
    id: 2, conversa_id: 1, tipo: "texto", texto: "SEGUNDA", status: "pendente",
    tentativas: 0, criado_em: new Date().toISOString(),
  });
  await fetch(`http://127.0.0.1:${t.porta}/ping`);       // o toque que antes se perdia

  // Espera o suficiente para o primeiro envio terminar (900 ms) e o ciclo
  // seguinte rodar — e NÃO o suficiente para o `setInterval` de 3 s salvar.
  await espera(1500);
  const quando = Date.now() - comecou;

  const sairam = t.uaz.recebidas
    .map((x) => (JSON.stringify(x.corpo).match(/(PRIMEIRA|SEGUNDA)/) || [])[1])
    .filter(Boolean);
  console.log(`     saíram ${JSON.stringify(sairam)} em ${quando} ms`);

  ok("a primeira sai assim que a campainha toca",
     sairam.includes("PRIMEIRA"), JSON.stringify(sairam));
  // A CONFERÊNCIA QUE PEGA O DEFEITO. Antes, a segunda ficava esperando o
  // tique de 3 segundos: aqui, em 1,8 s de janela, ela não tinha saído.
  ok("e a segunda sai logo atrás, sem esperar o tique de 3 segundos",
     sairam.includes("SEGUNDA"),
     `saiu só ${JSON.stringify(sairam)} — o toque do meio do ciclo foi jogado fora`);
  ok("e na ordem certa", sairam.join(",") === "PRIMEIRA,SEGUNDA",
     `saiu ${JSON.stringify(sairam)}`);

  await t.parar();
}

// ==================================================================
//  QUANDO NÃO HÁ RESPOSTA NENHUMA, A TELA TEM DE SABER POR QUÊ
// ==================================================================
//
// Relato do escritório, com a tela do celular: a ficha do cliente mostrava
// "Não foi possível falar com o Vantoro agora." e nada mais.
//
// Essa frase era a MESMA para três coisas diferentes: o serviço do Vantoro
// dormindo, o endereço dele escrito errado, e a internet do celular oscilando.
// Três causas, três consertos, uma frase só — e quem atende não tem acesso ao
// log da hospedagem para desempatar.
//
// A ponte já sabia explicar o que o Vantoro RESPONDE (página HTML, 401, 404…).
// O que faltava era o caso em que não houve resposta nenhuma: a exceção era
// engolida e virava a frase genérica.
//
// AQUI A CONEXÃO É RECUSADA, que é o caso de serviço parado ou suspenso — e é
// rápido de provar. Um endereço que aceita e nunca responde já tem prova
// própria mais acima (a da entrada que não fica pendurada).
{
  console.log("\nO Vantoro sem resposta explica o que houve");

  // Uma porta onde ninguém atende. Sobe e desce um servidor só para pegar um
  // número de porta que com certeza está livre.
  const efemero = http.createServer(() => {});
  await new Promise((r) => efemero.listen(0, "127.0.0.1", r));
  const portaMorta = efemero.address().port;
  await new Promise((r) => efemero.close(r));
  const urlMorta = `http://127.0.0.1:${portaMorta}`;

  const t = await subirTudo({ VANTORO_API_URL: urlMorta, VANTORO_API_TOKEN: "tok" });
  const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente?telefone=5511999998888`,
    { headers: { Authorization: "Bearer jwt-bom" } });
  const corpo = await r.json().catch(() => ({}));
  console.log(`     veio ${r.status}: ${JSON.stringify(corpo.erro || corpo).slice(0, 120)}`);

  ok("responde, em vez de ficar pendurada", r.status >= 400 && r.status < 600,
     `veio ${r.status}`);
  // A CONFERÊNCIA QUE PEGA O DEFEITO: a frase não pode ser a genérica.
  ok("e a frase NÃO é a genérica de sempre",
     !/^Não foi possível falar com o Vantoro agora\.$/.test(corpo.erro || ""),
     `veio "${corpo.erro}" — a mesma frase para toda causa não ajuda ninguém`);
  ok("ela diz que a conexão foi recusada, que é serviço parado",
     /recusou a conexão|parado|suspenso/i.test(corpo.erro || ""),
     `veio "${corpo.erro}"`);
  // E NÃO PODE VAZAR O TOKEN. A frase vai para a tela de quem atende, e a tela
  // é do lado de lá — qualquer um que abra o inspecionar lê o que estiver ali.
  ok("e não deixa escapar o token do Vantoro",
     !/tok\b|Bearer/i.test(JSON.stringify(corpo)),
     JSON.stringify(corpo).slice(0, 200));

  await t.parar();
}

// ---------------------------------------------------------------------------
//  O PAPEL DO PRÉ-CADASTRO CHEGA INTEIRO AO VANTORO
//
//  Pedido do escritório: "ao fazer o pré-cadastro do Lead pelo Zorvin, precisa
//  ter a opção de cliente ou réu". A escolha é feita no painel e decide, do
//  outro lado, se nasce uma ORDEM DE SERVIÇO — trabalho de gente.
//
//  A ponte é a única coisa entre os dois. Hoje ela repassa o corpo inteiro, o
//  que é a coisa certa a fazer: uma lista de campos permitidos aqui dentro
//  significaria que todo campo novo do cadastro precisa ser lembrado em DOIS
//  repositórios, e o esquecimento não dá erro nenhum — o campo simplesmente
//  some no caminho, e o cadastro nasce errado sem ninguém saber.
//
//  Esta conferência existe para que esse dia não chegue calado.
{
  console.log("\nO pré-cadastro leva o papel (cliente ou réu) até o Vantoro");

  for (const papel of ["cliente", "contraria"]) {
    const t = await subirTudo({}, { vantoro: {} });
    await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente`, {
      method: "POST",
      headers: { Authorization: "Bearer jwt-bom", "Content-Type": "application/json" },
      body: JSON.stringify({ nome: "Fulano de Tal", telefone: "5511999998888",
                             cpf: "", papel }),
    });
    // TODOS os POSTs que o Vantoro recebeu: a ponte chama "/clientes" lá
    // dentro, e filtrar pelo endereço DELA daria zero — uma conferência que
    // passa sem olhar nada.
    const posts = t.van.recebidas.filter((x) => x.metodo === "POST");
    const corpo = (posts[0] && posts[0].corpo) || {};
    ok(`o cadastro chegou ao Vantoro (papel=${papel})`, posts.length === 1,
       `recebeu ${posts.length} POSTs`);
    ok(`e com papel="${papel}" dentro`, corpo.papel === papel,
       `chegou papel=${JSON.stringify(corpo.papel)} — corpo: ${JSON.stringify(corpo).slice(0, 200)}`);
    // O RESTO DO CORPO TAMBÉM. Um repasse que perde o nome no caminho cria um
    // cadastro "Sem nome", que é um cliente que ninguém acha na busca.
    ok("e sem perder o nome nem o telefone",
       corpo.nome === "Fulano de Tal" && String(corpo.telefone) === "5511999998888",
       JSON.stringify(corpo).slice(0, 200));
    await t.parar();
  }
}

// ==================================================================
//  A MESMA MENSAGEM DE GRUPO, NOS DOIS TELEFONES NOSSOS QUE ESTÃO NELE
// ==================================================================
//
// RELATO DE 02/09, com dois prints. O grupo "Suporte Legal Mail" tem dois
// telefones nossos dentro. Abrindo a MESMA conversa por um e por outro, as
// mensagens são diferentes — e não se repetem: cada lado tem um pedaço da
// discussão, e nenhum tem ela inteira. Até a última mensagem da lista é outra
// em cada telefone.
//
// A CAUSA, medida no banco do escritório:
//
//     CREATE UNIQUE INDEX mensagens_id_uazapi_key ON mensagens (id_uazapi)
//
// `id_uazapi` é o identificador que o WhatsApp dá à mensagem, e ele era único
// no banco INTEIRO. Num grupo com dois dos nossos, a MESMA mensagem chega DUAS
// vezes — uma por telefone — com o mesmo identificador. A primeira entrava; a
// segunda batia no índice e era descartada.
//
// EM SILÊNCIO, e é o que fez isso durar: existe na ponte um aviso para "duas
// mensagens diferentes com a mesma chave", e ele se cala justamente quando o
// texto é igual — que é o caso de uma mensagem de grupo chegando duas vezes.
//
// A pergunta certa não é "esta mensagem já existe no Zorvin?" e sim "esta
// mensagem já existe NESTA conversa?": cada telefone nosso tem a sua caixa.
{
  console.log("\n34. A mensagem de grupo chega aos DOIS telefones nossos");

  const SEGUNDO = { id: "adv-2", nome: "Estratégico", numero: "5511976299371",
                    token: "tok-2", servidor: null, ativo: true, departamento_id: 1 };
  const GRUPO = "120363000000000001@g.us";

  // A mesma mensagem, com o MESMO messageid, entregue por cada um dos dois
  // telefones — que é o que a Uazapi faz quando os dois estão no grupo.
  const doGrupo = (dono, texto, id) => ({
    EventType: "messages",
    owner: dono,
    chat: { id: GRUPO, name: "Suporte Legal Mail", isGroup: true },
    message: {
      id, messageid: id, chatid: GRUPO, isGroup: true,
      sender: "5511988887777@s.whatsapp.net", fromMe: false,
      messageType: "conversation", text: texto, content: texto,
      messageTimestamp: Date.now(), wasSentByApi: false,
      senderName: "Eduarda Chirov",
    },
  });

  const t = await subirTudo({}, { tabelas: { advogados: [{ ...TELEFONE }, { ...SEGUNDO }] } });
  SEGUNDO.servidor = TELEFONE.servidor;

  const mandar = (dono, texto, id) => fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(doGrupo(dono, texto, id)),
  });

  await mandar(TELEFONE.numero, "esse processo foi excluído hoje às 05h41", "grp-1");
  await espera(700);
  await mandar(SEGUNDO.numero, "esse processo foi excluído hoje às 05h41", "grp-1");
  await espera(900);

  const conversas = t.sb.dados.conversas;
  ok("o grupo vira uma conversa para CADA telefone nosso", conversas.length === 2,
     `ficaram ${conversas.length}: ${JSON.stringify(conversas.map((c) => c.advogado_id))}`);

  // ESTA É A CONFERÊNCIA QUE DESCREVE O DEFEITO. Com a chave global, a segunda
  // gravação era descartada e este número era 1 — a mensagem existia só na
  // caixa de quem chegou primeiro.
  ok("e a mensagem existe nas DUAS caixas", t.sb.dados.mensagens.length === 2,
     `ficaram ${t.sb.dados.mensagens.length}`);

  const porAdv = {};
  for (const m of t.sb.dados.mensagens) {
    const conv = conversas.find((c) => String(c.id) === String(m.conversa_id));
    porAdv[conv && conv.advogado_id] = (porAdv[conv && conv.advogado_id] || 0) + 1;
  }
  ok("uma em cada, e não duas numa só",
     porAdv["adv-1"] === 1 && porAdv["adv-2"] === 1, JSON.stringify(porAdv));

  // A METADE QUE PROTEGE: o reenvio de verdade continua sendo descartado.
  // Sem ela, o conserto viraria o defeito oposto — a Uazapi reenvia quando
  // desconfia que não entregou, e cada reenvio viraria uma bolha repetida.
  await mandar(TELEFONE.numero, "esse processo foi excluído hoje às 05h41", "grp-1");
  await espera(700);
  ok("e o REENVIO no mesmo telefone continua não duplicando",
     t.sb.dados.mensagens.length === 2, `ficaram ${t.sb.dados.mensagens.length}`);

  await t.parar();
}

// ==================================================================
//  35. O HORÁRIO DA BOLHA É O DE QUEM ENVIOU
// ==================================================================
//
// O segundo defeito dos mesmos dois prints de 02/09: no grupo com dois
// telefones nossos, a mesma discussão aparecia com HORÁRIOS DIFERENTES em cada
// telefone.
//
// A causa: o caminho do webhook nunca preenchia `criado_em`, e a coluna tem
// `now()` por padrão — então a "hora da mensagem" era a hora em que NÓS
// gravamos. Dois telefones recebem o mesmo texto em dois instantes
// ligeiramente diferentes: daí o minuto de diferença.
//
// E O GRUPO FOI SÓ ONDE ISSO FICOU VISÍVEL. A ponte roda no plano free do
// Render, que DORME: quando acorda, a fila de webhooks entra toda de uma vez, e
// uma mensagem enviada às 09h12 é carimbada 09h30. Num escritório que trabalha
// com prazo, a hora errada não é enfeite.
//
// O FALSO SUPABASE NÃO PREENCHE PADRÃO DE COLUNA, e é isso que torna esta
// prova legível: linha COM `criado_em` = a ponte gravou o horário de quem
// enviou; linha SEM = ela deixou para o `now()` do banco, que é o defeito.
{
  console.log("\n35. O horário da bolha é o de quem enviou");

  const QUARENTA_MIN = 40 * 60 * 1000;
  const chegando = (id, ts) => ({
    EventType: "messages",
    owner: TELEFONE.numero,
    message: {
      id, messageid: id, chatid: "5511999998888@s.whatsapp.net",
      sender: "5511999998888@s.whatsapp.net", fromMe: false, isGroup: false,
      messageType: "conversation", type: "text", text: "chegou atrasada",
      wasSentByApi: false, senderName: "Cliente Teste",
      ...(ts === undefined ? {} : { messageTimestamp: ts }),
    },
  });

  const t = await subirTudo();
  const mandar = (corpo) => fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(corpo),
  });
  const achar = (id) => t.sb.dados.mensagens.find((m) => m.id_uazapi === id);

  // 1) O CASO DE TODO DIA: o WhatsApp conta o tempo EM SEGUNDOS, e a ponte tem
  //    de multiplicar antes de gravar. Sem isso o horário viraria 1970 e a
  //    mensagem afundaria no começo da conversa.
  const enviadaEm = Date.now() - QUARENTA_MIN;
  await mandar(chegando("ts-1", Math.floor(enviadaEm / 1000)));
  await espera(600);
  const comHora = achar("ts-1");
  ok("a mensagem guarda o horário que veio no webhook",
     !!(comHora && comHora.criado_em), JSON.stringify(comHora));
  // A FOLGA É DE UM SEGUNDO, e é só o arredondamento dos segundos. Uma folga
  // larga aqui deixaria passar justamente o defeito: o `now()` está a QUARENTA
  // MINUTOS de distância, não a um segundo.
  const distancia = comHora && comHora.criado_em
    ? Math.abs(new Date(comHora.criado_em).getTime() - enviadaEm) : Infinity;
  ok("e é o de QUEM ENVIOU, não o de quando gravamos",
     distancia < 1000, `ficou a ${Math.round(distancia / 1000)}s do horário enviado`);

  // 2) EM MILISSEGUNDOS TAMBÉM. Os dois formatos chegam no mesmo campo, e
  //    tratar só um deles erra por um fator de mil — isto é, por décadas.
  const outroEnvio = Date.now() - QUARENTA_MIN;
  await mandar(chegando("ts-2", outroEnvio));
  await espera(600);
  const emMili = achar("ts-2");
  const distMili = emMili && emMili.criado_em
    ? Math.abs(new Date(emMili.criado_em).getTime() - outroEnvio) : Infinity;
  ok("o horário em milissegundos vale igual", distMili < 1000, JSON.stringify(emMili));

  // 3) RELÓGIO DE CELULAR ERRA, e horário absurdo é pior que horário nenhum: um
  //    ano à frente prega a mensagem no topo da conversa PARA SEMPRE. Fora da
  //    faixa, a ponte desiste dele e deixa valer o `now()` do banco — impreciso,
  //    mas nunca absurdo.
  await mandar(chegando("ts-3", Math.floor(Date.UTC(2999, 0, 1) / 1000)));
  await mandar(chegando("ts-4", 1));
  await espera(700);
  ok("um horário no ano 2999 é descartado (senão a mensagem gruda no topo)",
     !!achar("ts-3") && achar("ts-3").criado_em === undefined,
     JSON.stringify(achar("ts-3")));
  ok("e um de 1970 também (senão ela afunda no começo)",
     !!achar("ts-4") && achar("ts-4").criado_em === undefined,
     JSON.stringify(achar("ts-4")));

  // 4) SEM HORÁRIO, NADA QUEBRA — E O LOG DIZ.
  //
  //    O corpo do webhook da Uazapi não está documentado campo a campo, e não
  //    tenho captura de tráfego real que prove que `messageTimestamp` vem
  //    sempre. Se não vier, o comportamento é exatamente o de antes. O que não
  //    pode é isso valer em silêncio — aí a minha suposição viraria verdade sem
  //    ninguém ter medido. Então o log conta QUAIS campos a Uazapi mandou.
  await mandar(chegando("ts-5", undefined));
  await espera(600);
  ok("sem horário no webhook, a mensagem entra do mesmo jeito",
     !!achar("ts-5"), JSON.stringify(t.sb.dados.mensagens.map((m) => m.id_uazapi)));
  ok("e o log diz que ficou com a hora da gravação, e com os campos que chegaram",
     t.registro.join("").includes("SEM horário de envio")
     && t.registro.join("").includes("messageid"),
     t.registro.join("").slice(-400));

  await t.parar();
}

// ==================================================================
//  36. O MESMO MINUTO NOS DOIS TELEFONES DO GRUPO
// ==================================================================
//
// A junção das duas correções: a mensagem de grupo agora existe nas duas
// caixas (34), e as duas mostram O MESMO HORÁRIO (35). É literalmente o print
// que o escritório mandou — a mesma frase, dois relógios diferentes.
//
// A pausa entre uma entrega e outra é DE PROPÓSITO, e larga: é ela que fabrica
// o defeito. Com `now()`, um segundo de diferença entre os dois webhooks vira
// um segundo de diferença na tela; a espera aqui garante que a conferência
// falharia se a correção saísse.
{
  console.log("\n36. O mesmo minuto nos dois telefones do grupo");

  const SEGUNDO = { id: "adv-2", nome: "Estratégico", numero: "5511976299371",
                    token: "tok-2", servidor: null, ativo: true, departamento_id: 1 };
  const GRUPO = "120363000000000001@g.us";
  const ENVIADA_EM = Date.now() - 10 * 60 * 1000;

  const doGrupo = (dono) => ({
    EventType: "messages",
    owner: dono,
    chat: { id: GRUPO, name: "Suporte Legal Mail", isGroup: true },
    message: {
      id: "grp-hora", messageid: "grp-hora", chatid: GRUPO, isGroup: true,
      sender: "5511988887777@s.whatsapp.net", fromMe: false,
      messageType: "conversation", text: "podemos excluir essa regra?",
      content: "podemos excluir essa regra?",
      messageTimestamp: Math.floor(ENVIADA_EM / 1000),
      wasSentByApi: false, senderName: "Eduarda Chirov",
    },
  });

  const t = await subirTudo({}, { tabelas: { advogados: [{ ...TELEFONE }, { ...SEGUNDO }] } });
  SEGUNDO.servidor = TELEFONE.servidor;
  const mandar = (dono) => fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(doGrupo(dono)),
  });

  await mandar(TELEFONE.numero);
  await espera(1200);            // o intervalo que produzia relógios diferentes
  await mandar(SEGUNDO.numero);
  await espera(900);

  const copias = t.sb.dados.mensagens.filter((m) => m.id_uazapi === "grp-hora");
  ok("a mensagem está nas duas caixas", copias.length === 2, `ficaram ${copias.length}`);
  // O `criado_em` TEM DE EXISTIR, e não só ser igual dos dois lados. Sem esta
  // metade a conferência PASSAVA com o conserto desligado — as duas linhas
  // ficavam sem a coluna, e `undefined === undefined` é igual. Foi a sabotagem
  // que mostrou isso: no banco de verdade o `now()` daria dois valores
  // diferentes, mas a bancada não preenche padrão, e a prova lia o vazio como
  // acerto.
  ok("e as duas marcam o MESMO horário",
     copias.length === 2 && !!copias[0].criado_em
     && copias[0].criado_em === copias[1].criado_em,
     JSON.stringify(copias.map((m) => m.criado_em)));
  ok("que é o horário em que a pessoa escreveu",
     copias.length === 2
     && Math.abs(new Date(copias[0].criado_em).getTime() - ENVIADA_EM) < 1000,
     JSON.stringify(copias.map((m) => m.criado_em)));

  await t.parar();
}

// ==================================================================
//  37. O RESGATE: RELER O HISTÓRICO DE UM GRUPO
// ==================================================================
//
// Consertar a gravação (#126) impede o buraco novo; não devolve o antigo. As
// mensagens descartadas nunca foram gravadas — não há de onde tirá-las no
// banco. Elas continuam no WhatsApp, e a releitura pela Uazapi é o caminho.
//
// Só que a releitura foi escrita para conversa de UMA PESSOA SÓ, e num grupo
// batia em três paredes:
//
//   1. `replace(/\D/g, '')` no que se digita. "120363...@g.us" virava
//      "120363...", que parece telefone — e a rotina criava um CONTATO NOVO,
//      uma CONVERSA NOVA, e despejava lá o histórico do grupo. O resgate
//      produziria a bagunça que `juntarConversasDoGrupo` existe para limpar.
//   2. O endereço `@s.whatsapp.net` num grupo devolve VAZIO. A rotina
//      anunciaria "0 mensagens" para um grupo cheio delas.
//   3. Sem `enviado_por`, o histórico entrava como monólogo de balões sem
//      autor — diferente das mensagens que o webhook grava na mesma conversa.
{
  console.log("\n37. O resgate: reler o histórico de um grupo");

  const SEGUNDO = { id: "adv-2", nome: "Estratégico", numero: "5511976299371",
                    token: "tok-2", servidor: null, ativo: true, departamento_id: 1 };
  const JID = "120363000000000001";
  const CHAVE = `grupo:${JID}`;
  const ONTEM = Date.now() - 24 * 60 * 60 * 1000;

  // A discussão inteira, como a Uazapi devolve para QUALQUER telefone do grupo.
  const historico = [
    { messageid: "g-1", fromMe: false, text: "esse processo foi excluído hoje",
      messageTimestamp: Math.floor(ONTEM / 1000), messageType: "conversation",
      senderName: "Eduarda Chirov" },
    { messageid: "g-2", fromMe: false, text: "podemos excluir essa regra?",
      messageTimestamp: Math.floor((ONTEM + 60000) / 1000), messageType: "conversation",
      senderName: "Max Canaverde" },
    { messageid: "g-3", fromMe: false, text: "pode excluir",
      messageTimestamp: Math.floor((ONTEM + 120000) / 1000), messageType: "conversation",
      senderName: "Eduarda Chirov" },
  ];

  // O ESTADO DO ESCRITÓRIO, tal como os prints mostraram: o mesmo grupo em duas
  // conversas, cada telefone com um PEDAÇO da discussão e nenhum com ela toda.
  const comoEstavaNoEscritorio = {
    uazapi: { historico, sufixo: "@g.us" },
    tabelas: {
      advogados: [{ ...TELEFONE }, { ...SEGUNDO }],
      contatos: [{ id: 900, numero: CHAVE, nome: "Suporte Legal Mail" }],
      conversas: [{ id: 901, advogado_id: "adv-1", contato_id: 900 },
                  { id: 902, advogado_id: "adv-2", contato_id: 900 }],
      mensagens: [
        { id: 910, conversa_id: 901, id_uazapi: "g-1", origem: "contato",
          tipo: "texto", texto: "esse processo foi excluído hoje" },
        { id: 911, conversa_id: 902, id_uazapi: "g-2", origem: "contato",
          tipo: "texto", texto: "podemos excluir essa regra?" },
      ],
    },
  };

  const t = await subirTudo({ IMPORT_TOKEN: "senha-do-escritorio" }, comoEstavaNoEscritorio);
  // O ENDEREÇO DA UAZAPI DE MENTIRA SÓ EXISTE DEPOIS QUE ELA SOBE, e a tabela
  // acima foi montada ANTES — as linhas ficaram com o endereço de um servidor
  // já derrubado por outra seção, e o resgate morria em "fetch failed". Quem
  // sobrescreve `advogados` na bancada precisa corrigir as linhas aqui.
  for (const a of t.sb.dados.advogados) a.servidor = TELEFONE.servidor;
  const resgatar = (advogado, contato) =>
    fetch(`http://127.0.0.1:${t.porta}/importar-historico?token=senha-do-escritorio`
          + `&advogado=${advogado}&contato=${encodeURIComponent(contato)}`);

  const r = await resgatar(TELEFONE.numero, `${JID}@g.us`);
  const frase = await r.text();
  ok("o resgate de um grupo responde 200", r.status === 200,
     `veio ${r.status}: ${frase.slice(0, 200)}`);

  // A CONFERÊNCIA QUE DESCREVE A PAREDE 1, e a mais importante das três: um
  // contato a mais aqui significa que o resgate INVENTOU um telefone com os
  // dígitos do grupo, e escreveu a discussão numa conversa que ninguém abre.
  ok("e NÃO inventa um contato com os dígitos do grupo",
     t.sb.dados.contatos.length === 1,
     JSON.stringify(t.sb.dados.contatos.map((c) => c.numero)));
  ok("nem uma terceira conversa",
     t.sb.dados.conversas.length === 2,
     JSON.stringify(t.sb.dados.conversas.map((c) => c.advogado_id)));

  const doMax = t.sb.dados.mensagens.filter((m) => String(m.conversa_id) === "901");
  ok("a caixa do primeiro telefone passa a ter a discussão INTEIRA",
     doMax.length === 3, `ficaram ${doMax.length}: `
     + JSON.stringify(doMax.map((m) => m.id_uazapi)));
  ok("sem duplicar a que já estava lá",
     doMax.filter((m) => m.id_uazapi === "g-1").length === 1,
     JSON.stringify(doMax.map((m) => m.id_uazapi)));

  // PAREDE 3: quem escreveu cada linha. Num grupo isto não é enfeite — é a
  // diferença entre ler uma discussão e ler um monólogo.
  const resgatadas = doMax.filter((m) => m.id_uazapi !== "g-1");
  ok("e cada bolha resgatada diz QUEM escreveu",
     resgatadas.length === 2 && resgatadas.every((m) => !!m.enviado_por),
     JSON.stringify(doMax.map((m) => [m.id_uazapi, m.enviado_por])));
  ok("com o nome da pessoa, e não o número dela",
     doMax.find((m) => m.id_uazapi === "g-3")?.enviado_por === "Eduarda Chirov",
     JSON.stringify(doMax.map((m) => [m.id_uazapi, m.enviado_por])));

  // O OUTRO TELEFONE CONTINUA INTOCADO até ser resgatado também. É o que torna
  // o resgate uma operação por telefone, e não uma que mexe onde não foi pedida.
  ok("o segundo telefone ainda não foi mexido",
     t.sb.dados.mensagens.filter((m) => String(m.conversa_id) === "902").length === 1,
     `ficaram ${t.sb.dados.mensagens.filter((m) => String(m.conversa_id) === "902").length}`);

  // E ENTÃO ELE TAMBÉM. Aqui está o coração do resgate: `g-1` e `g-3` JÁ
  // EXISTEM no banco — na caixa do outro telefone. Se a pergunta "já conheço
  // esta mensagem?" fosse feita ao banco inteiro, as duas seriam puladas, o
  // resgate diria "0 novas" e deixaria o buraco exatamente onde estava.
  const r2 = await resgatar(SEGUNDO.numero, `${JID}@g.us`);
  await r2.text();
  const doEstrategico = t.sb.dados.mensagens.filter((m) => String(m.conversa_id) === "902");
  ok("e o segundo telefone também recebe a discussão inteira",
     doEstrategico.length === 3, `ficaram ${doEstrategico.length}: `
     + JSON.stringify(doEstrategico.map((m) => m.id_uazapi)));

  // RODAR DE NOVO NÃO MEXE EM NADA. Quem opera isto é uma pessoa num navegador,
  // e a dúvida "será que já rodei?" tem de custar nada.
  const antes = t.sb.dados.mensagens.length;
  const r3 = await resgatar(TELEFONE.numero, `${JID}@g.us`);
  const frase3 = await r3.text();
  ok("rodar o resgate de novo não duplica nada",
     t.sb.dados.mensagens.length === antes,
     `eram ${antes}, ficaram ${t.sb.dados.mensagens.length}`);
  ok("e a frase final não diz que importou o que já estava lá",
     /Importei 0 /.test(frase3) || /nenhuma mensagem nova/i.test(frase3),
     `disse: "${frase3.trim().slice(0, 160)}"`);

  await t.parar();
}

// ==================================================================
//  38. O RESGATE DE UMA PESSOA CONTINUA COMO ERA
// ==================================================================
//
// A mudança acima mexeu no caminho que TODO resgate usa. A conferência que
// importa aqui não é a do grupo — é a de que a conversa de uma pessoa só, que
// funcionava, continua funcionando igual.
{
  console.log("\n38. O resgate de uma pessoa continua como era");

  const historico = [
    { messageid: "p-1", fromMe: false, text: "Bom dia, doutor",
      messageTimestamp: Math.floor((Date.now() - 3600000) / 1000),
      messageType: "conversation", senderName: "Cliente Teste" },
  ];

  const t = await subirTudo({ IMPORT_TOKEN: "senha-do-escritorio" }, {
    uazapi: { historico },   // sufixo padrão: @s.whatsapp.net
    tabelas: { contatos: [], conversas: [], mensagens: [] },
  });
  const r = await fetch(`http://127.0.0.1:${t.porta}/importar-historico`
    + `?token=senha-do-escritorio&advogado=${TELEFONE.numero}&contato=5511999998888`);
  await r.text();

  ok("só com os dígitos, a conversa de uma pessoa é resgatada como sempre",
     t.sb.dados.mensagens.length === 1, `vieram ${t.sb.dados.mensagens.length}`);
  ok("e o contato é o telefone, sem prefixo de grupo",
     t.sb.dados.contatos.length === 1 && t.sb.dados.contatos[0].numero === "5511999998888",
     JSON.stringify(t.sb.dados.contatos.map((c) => c.numero)));
  // O AUTOR NÃO ENTRA NUMA CONVERSA DE DUAS PESSOAS. Numa conversa de um para
  // um a bolha já diz quem falou pela posição — carimbar o nome do cliente em
  // cada linha seria repetir na tela o que a tela já mostra, e ficaria
  // diferente do que o webhook grava na mesma conversa.
  ok("e a bolha NÃO ganha o carimbo de autor (isso é coisa de grupo)",
     t.sb.dados.mensagens[0] && !t.sb.dados.mensagens[0].enviado_por,
     JSON.stringify(t.sb.dados.mensagens[0]));

  // A FRASE QUE ENSINA. Quem abre este endereço é uma pessoa num navegador:
  // "informe advogado e contato" não conta que um grupo se escreve de outro
  // jeito, e ela tentaria com os dígitos — que é o caminho da parede 1.
  const vazia = await fetch(`http://127.0.0.1:${t.porta}/importar-historico`
    + `?token=senha-do-escritorio&advogado=${TELEFONE.numero}&contato=`);
  const recado = await vazia.text();
  ok("sem contato, a resposta ENSINA como se escreve um grupo",
     vazia.status === 400 && /@g\.us/.test(recado), `disse: "${recado.trim()}"`);

  await t.parar();
}

// ==================================================================
//  39. SAIR COM CALMA — o que está no meio termina antes
// ==================================================================
//
//  Toda publicação derruba este processo, e são várias por semana. Sem
//  tratamento do SIGTERM, o Node morre no mesmo instante em que o recebe — com
//  o que estivesse fazendo.
//
//  Esta seção exercita os dois estragos que isso causava, pela porta por onde
//  eles acontecem em produção:
//
//    - um ENVIO no meio: a Uazapi já aceitou, a marca de "enviada" ainda não
//      chegou ao banco. Morrendo ali, o item fica preso em "enviando" e cinco
//      minutos depois é reenviado — o cliente recebe duas vezes;
//    - um WEBHOOK novo chegando durante a saída: responder "OK" seria dizer à
//      Uazapi que a mensagem está guardada, segundos antes de morrer com ela
//      pela metade.
//
//  `DESLIGAR_PRAZO_MS` encurta o teto de 25 segundos: provar a espera com o
//  valor de produção seria uma prova que ninguém roda.
{
  console.log("\n39. Sair com calma");
  // O envio demora 1,5s: é a janela em que o SIGTERM chega com a Uazapi já
  // tendo aceitado a mensagem e o banco ainda sem saber disso.
  const t = await subirTudo({ DESLIGAR_PRAZO_MS: "8000" }, { uazapi: { demoraDoEnvio: 1500 } });
  t.sb.dados.contatos.push({ id: 1, numero: "5511999998888", nome: "Cliente Teste" });
  t.sb.dados.conversas.push({ id: 1, advogado_id: TELEFONE.id, contato_id: 1 });
  t.sb.dados.fila_envio.push({
    id: 1, conversa_id: 1, tipo: "texto", texto: "No meio do envio", status: "pendente",
    tentativas: 0, criado_em: new Date().toISOString(),
  });

  // Toca a campainha e espera só o bastante para o envio estar EM VOO.
  await fetch(`http://127.0.0.1:${t.porta}/ping`);
  await espera(400);
  ok("o envio está mesmo no meio quando o sinal chega",
     t.sb.dados.fila_envio[0]?.status === "enviando",
     `estava "${t.sb.dados.fila_envio[0]?.status}" — a prova não pegou a janela`);

  const antesDoSinal = Date.now();
  t.filho.kill("SIGTERM");

  // A porta para de aceitar quem chega, e o webhook que chegar não recebe um
  // "OK" que a ponte não vai honrar. Recusa explícita (503) ou conexão
  // recusada: as duas dizem "não guardei", que é a verdade.
  await espera(150);
  let respostaDurante = null;
  try {
    const r = await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(mensagemDaUazapi("chegou durante a saída", "DURANTE-1")),
    });
    respostaDurante = r.status;
  } catch (_e) {
    respostaDurante = "conexão recusada";
  }
  ok("webhook que chega durante a saída NÃO recebe um 'OK' falso",
     respostaDurante === 503 || respostaDurante === "conexão recusada",
     `respondeu ${respostaDurante}`);

  const codigo = await t.esperarSair(12000);
  const demorou = Date.now() - antesDoSinal;

  ok("a ponte sai sozinha, e sem erro", codigo === 0, `saiu com ${codigo}`);
  // Esperou pelo envio: ele levava 1,5s e o sinal chegou aos 0,4s.
  ok("e só depois de o envio em andamento terminar", demorou >= 800,
     `saiu em ${demorou}ms — cedo demais para ter esperado o envio`);
  ok("sem ficar pendurada até o prazo", demorou < 7000, `demorou ${demorou}ms`);

  ok("o item NÃO ficou preso em 'enviando'",
     t.sb.dados.fila_envio[0]?.status === "enviada",
     `ficou "${t.sb.dados.fila_envio[0]?.status}" — em produção seria reenviado, `
     + "e o cliente receberia a mesma mensagem duas vezes");
  ok("e a mensagem que a Uazapi aceitou entrou no histórico",
     t.sb.dados.mensagens.some((m) => m.texto === "No meio do envio"),
     JSON.stringify(t.sb.dados.mensagens.map((m) => m.texto)));
  ok("a mensagem recusada durante a saída não entrou pela metade",
     !t.sb.dados.mensagens.some((m) => m.texto === "chegou durante a saída"),
     "uma mensagem recusada não pode ter deixado rastro");

  const log = t.registro.join("");
  ok("o log diz que a saída foi tratada, e não que o processo sumiu",
     /SIGTERM recebido/.test(log) && /Desligamento:/.test(log),
     log.slice(-400));

  await t.parar();
}

// ==================================================================
//  40. A ETIQUETA É DO CLIENTE, E NÃO DA CAIXA EM QUE ELE FALOU
// ==================================================================
//
// Relato de quem usa: "a etiqueta que é incluída no contato deve aparecer nas
// conversas com o contato em todos os telefones".
//
// `conversa_tags` tem uma linha por (conversa, etiqueta). Como cada telefone
// nosso tem a SUA conversa com o mesmo cliente, etiquetar "Urgente" no
// telefone do Dr. Max não mudava nada no do Estratégico — e etiqueta serve
// para achar e para priorizar. Uma que só metade do escritório enxerga faz o
// filtro devolver metade, sem dizer que devolveu metade.
//
// ESPALHAR, E NÃO LER A CAIXA DO OUTRO: a alternativa era o painel ler as
// etiquetas das conversas dos outros telefones, o que abriria exceção na regra
// de acesso que o #124 fechou. Aqui cada conversa ganha a SUA linha.
//
// E PELA PONTE porque o navegador NÃO ALCANÇA as conversas dos outros
// telefones: um espalhamento feito lá cobriria só as que a pessoa já vê —
// deixando a etiqueta pela metade, que é o defeito de origem com outra roupa.
{
  console.log("\n40. A etiqueta é do cliente, e não da caixa em que ele falou");

  const SEGUNDO = { id: "adv-2", nome: "Estratégico", numero: "5511976299371",
                    token: "tok-2", servidor: null, ativo: true, departamento_id: 1 };
  const t = await subirTudo({}, { tabelas: {
    advogados: [{ ...TELEFONE }, { ...SEGUNDO }],
    contatos: [{ id: 700, numero: "5511999998888", nome: "Cliente de Dois" }],
    // O MESMO CLIENTE, nas caixas dos DOIS telefones.
    conversas: [{ id: 701, advogado_id: "adv-1", contato_id: 700 },
                { id: 702, advogado_id: "adv-2", contato_id: 700 }],
    // E uma conversa de OUTRO contato, para provar que o espalhamento não
    // transborda: etiquetar um cliente não pode etiquetar o escritório.
    conversa_tags: [],
  } });

  const etiquetar = (corpo) => fetch(`http://127.0.0.1:${t.porta}/etiqueta/contato`, {
    method: "POST",
    headers: { Authorization: "Bearer jwt-bom", "Content-Type": "application/json" },
    body: JSON.stringify(corpo),
  });
  const daTag = () => t.sb.dados.conversa_tags.filter((x) => String(x.tag_id) === "9");

  const r = await etiquetar({ contato_id: 700, tag_id: 9 });
  const corpo = await r.json();
  ok("etiquetar o contato responde 200", r.status === 200, `veio ${r.status}: ${JSON.stringify(corpo)}`);

  // A CONFERÊNCIA QUE DESCREVE O PEDIDO: uma linha por conversa, nos dois
  // telefones. Com a etiqueta presa a uma conversa só, este número era 1.
  const postas = daTag();
  ok("a etiqueta cai nas conversas dos DOIS telefones", postas.length === 2,
     `ficaram ${postas.length}: ${JSON.stringify(postas.map((x) => x.conversa_id))}`);
  ok("uma em cada, e não duas numa só",
     new Set(postas.map((x) => String(x.conversa_id))).size === 2,
     JSON.stringify(postas.map((x) => x.conversa_id)));

  // APLICAR DE NOVO NÃO DUPLICA. Quem etiqueta pelo segundo telefone (sem
  // saber que já está etiquetado no primeiro) cai exatamente aqui.
  const r2 = await etiquetar({ contato_id: 700, tag_id: 9 });
  const corpo2 = await r2.json();
  ok("aplicar de novo não duplica nada", daTag().length === 2, `ficaram ${daTag().length}`);
  ok("e a resposta diz que nada de novo entrou", corpo2 && corpo2.novas === 0,
     JSON.stringify(corpo2));

  // TIRAR TIRA DOS DOIS. A metade que faltaria: uma etiqueta que se aplica em
  // todos e sai de um só é pior do que a de antes — some da sua tela e continua
  // no filtro de quem procura.
  const r3 = await etiquetar({ contato_id: 700, tag_id: 9, aplicar: false });
  ok("tirar a etiqueta tira dos DOIS telefones",
     r3.status === 200 && daTag().length === 0, `ficaram ${daTag().length}`);

  // CONTATO SEM CONVERSA NENHUMA É ERRO, e não sucesso calado: o painel já
  // pintou a etiqueta na tela, e um "ok" deixaria a marca no ecrã e nada no
  // banco.
  const r4 = await etiquetar({ contato_id: 999, tag_id: 9 });
  ok("contato sem conversa nenhuma é recusado, e não aceito em silêncio",
     r4.status === 404, `veio ${r4.status}`);

  // SEM LOGIN NÃO ENTRA. A rota escreve no banco do escritório inteiro.
  const r5 = await fetch(`http://127.0.0.1:${t.porta}/etiqueta/contato`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ contato_id: 700, tag_id: 9 }),
  });
  ok("sem login, a rota recusa", r5.status === 401, `veio ${r5.status}`);

  await t.parar();
}

// ==================================================================
//  41. O ÍCONE DE HISTÓRICO DIZ QUANTAS CONVERSAS EXISTEM
// ==================================================================
//
// Relato: "na conversa, no ícone de histórico, quero que indique de alguma
// forma quantas conversas existem com aquele contato em outros telefones".
//
// O ícone era mudo: só clicando dava para saber que o mesmo cliente estava
// sendo atendido por outro telefone nosso — e ninguém clica num ícone para
// descobrir que não há nada lá. A informação existia e não era vista: duas
// pessoas atendendo o mesmo cliente sem saber uma da outra.
{
  console.log("\n41. O ícone de histórico diz quantas conversas existem");

  const SEGUNDO = { id: "adv-2", nome: "Estratégico", numero: "5511976299371",
                    token: "tok-2", servidor: null, ativo: true, departamento_id: 1 };
  const t = await subirTudo({}, { tabelas: {
    advogados: [{ ...TELEFONE }, { ...SEGUNDO }],
    contatos: [{ id: 700, numero: "5511999998888", nome: "Cliente de Dois" },
               { id: 701, numero: "5511999997777", nome: "Cliente de Um" }],
    conversas: [{ id: 801, advogado_id: "adv-1", contato_id: 700 },
                { id: 802, advogado_id: "adv-2", contato_id: 700 },
                { id: 803, advogado_id: "adv-1", contato_id: 701 }],
  } });

  const contar = (id) => fetch(`http://127.0.0.1:${t.porta}/historico/contato/${id}/quantas`,
    { headers: { Authorization: "Bearer jwt-bom" } }).then((r) => r.json());

  const dois = await contar(700);
  ok("o contato de dois telefones conta 2", dois && dois.conversas === 2, JSON.stringify(dois));
  ok("e diz que são 2 telefones nossos", dois && dois.telefones === 2, JSON.stringify(dois));

  // O CLIENTE DE UM TELEFONE SÓ TAMBÉM RESPONDE, e responde 1. É o caso comum,
  // e é ele que decide quando o painel NÃO desenha número nenhum — um "1"
  // pendurado em toda conversa seria ruído em cima da tela inteira.
  const um = await contar(701);
  ok("o contato de um telefone só conta 1", um && um.conversas === 1, JSON.stringify(um));

  const semLogin = await fetch(`http://127.0.0.1:${t.porta}/historico/contato/700/quantas`);
  ok("sem login, a contagem recusa", semLogin.status === 401, `veio ${semLogin.status}`);

  await t.parar();
}

// ==================================================================
//  40. O VANTORO SAI DA FRENTE DA MENSAGEM
// ==================================================================
//
//  A frente (cliente, parte contrária, lead) sai de uma pergunta ao Vantoro, e
//  ela era feita ANTES de a mensagem ser gravada. O Vantoro roda no plano
//  gratuito da Render e dorme; acordá-lo leva de trinta segundos a um minuto.
//
//  Ou seja: a mensagem do cliente ficava esperando um serviço que nem precisa
//  estar de pé para ela existir. Fora do expediente e nos fins de semana, isso
//  era a REGRA — o Vantoro dorme de propósito nesses horários.
{
  console.log("\n40. O Vantoro sai da frente da mensagem");

  // ---- a mensagem não espera pela classificação ----
  {
    // 1,5s é bem menos do que a Render leva para acordar de verdade, e já é
    // muito mais do que uma gravação no banco. Se a mensagem esperar por isto,
    // a conferência vê.
    const t = await subirTudo({}, { vantoro: { demora: 1500, usuarios: [] } });
    const comecou = Date.now();
    await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(mensagemDaUazapi("chegou agora", "SEM-ESPERA-1")),
    });

    // Espera a LINHA aparecer, e não um tempo fixo: é o instante em que a bolha
    // nasce na tela de quem atende.
    let apareceuEm = null;
    for (let i = 0; i < 60; i++) {
      if (t.sb.dados.mensagens.length) { apareceuEm = Date.now() - comecou; break; }
      await espera(50);
    }
    ok("a mensagem é gravada", apareceuEm !== null, "não apareceu em 3s");
    ok("e sem esperar o Vantoro acordar", apareceuEm !== null && apareceuEm < 1200,
       `demorou ${apareceuEm}ms — o Vantoro leva 1500ms nesta bancada`);

    // A ETIQUETA CHEGA DEPOIS, e chegar depois é o combinado — não some.
    let frente = null;
    for (let i = 0; i < 60; i++) {
      frente = t.sb.dados.conversas[0]?.frente || null;
      if (frente) break;
      await espera(100);
    }
    ok("a frente é gravada assim mesmo, logo em seguida", Boolean(frente),
       `a conversa ficou com frente="${frente}"`);
    ok("e o Vantoro chegou a ser perguntado",
       t.van.recebidas.some((c) => c.caminho === "/contatos/classificar"),
       JSON.stringify(t.van.recebidas.map((c) => c.caminho)));
    await t.parar();
  }

  // ---- o Vantoro mudo não é perguntado a cada mensagem ----
  {
    // `naoJson` é o Vantoro respondendo uma página de erro com 503 — o retrato
    // do serviço fora do ar ou suspenso na hospedagem.
    const t = await subirTudo({}, { vantoro: { naoJson: { status: 503 }, usuarios: [] } });

    // Contatos DIFERENTES em cada mensagem: com o mesmo, a segunda não
    // perguntaria de qualquer jeito (a classificação vale por uma semana), e a
    // prova mediria a validade em vez do freio.
    const mandar = async (numero, id) => {
      const corpo = mensagemDaUazapi(`mensagem de ${numero}`, id);
      corpo.message.sender = `${numero}@s.whatsapp.net`;
      corpo.message.sender_pn = `${numero}@s.whatsapp.net`;
      corpo.message.chatid = `${numero}@s.whatsapp.net`;
      corpo.chat = { phone: numero, wa_name: `Cliente ${numero.slice(-4)}` };
      await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify(corpo),
      });
    };
    const perguntasAte = () =>
      t.van.recebidas.filter((c) => c.caminho === "/contatos/classificar").length;

    // A RAJADA: três mensagens enquanto a primeira pergunta ainda nem voltou.
    // Contra um serviço fora do ar ela leva 26 segundos (20 do tempo limite,
    // mais 6 da espera com segunda tentativa), então o freio ainda não existe —
    // quem segura as outras duas é a trava de "uma pergunta de cada vez".
    await mandar("5511900000001", "MUDO-1");
    await espera(300);
    await mandar("5511900000002", "MUDO-2");
    await espera(300);
    await mandar("5511900000003", "MUDO-3");
    await espera(600);

    ok("as três mensagens entraram, com o Vantoro fora do ar",
       t.sb.dados.mensagens.length === 3, `entraram ${t.sb.dados.mensagens.length}`);
    ok("e o Vantoro foi perguntado UMA vez, e não três", perguntasAte() === 1,
       `perguntou ${perguntasAte()} vez(es) — cada uma custa o tempo limite inteiro`);

    // AGORA O FREIO. Esperamos aquela primeira pergunta terminar de falhar; é
    // quando a ponte conclui que o Vantoro está mudo e passa a pular.
    let calou = false;
    for (let i = 0; i < 100; i++) {
      if (/Frente: o Vantoro não respondeu/.test(t.registro.join(""))) { calou = true; break; }
      await espera(200);
    }
    ok("quando a pergunta falha, o log diz que ele foi calado e por quanto tempo",
       calou, t.registro.join("").slice(-300));

    // Com o Vantoro calado, uma mensagem nova NÃO pergunta — e é isso que
    // impede a rajada de sábado de virar uma fila de esperas de meio minuto.
    const antes = perguntasAte();
    await mandar("5511900000004", "MUDO-4");
    await espera(800);
    ok("e a mensagem seguinte não pergunta mais nada", perguntasAte() === antes,
       `perguntou de novo (${antes} → ${perguntasAte()})`);
    ok("mas ela entra na conversa do mesmo jeito",
       t.sb.dados.mensagens.length === 4, `entraram ${t.sb.dados.mensagens.length}`);
    await t.parar();
  }

  // ---- e uma RESPOSTA de erro não cala ninguém ----
  {
    // 404 é o Vantoro DE PÉ dizendo alguma coisa. Calar por causa dele
    // esconderia um erro de endereço atrás de cinco minutos de silêncio.
    const t = await subirTudo({}, { vantoro: { naoJson: { status: 404 }, usuarios: [] } });
    for (const [i, numero] of ["5511900000011", "5511900000012"].entries()) {
      const corpo = mensagemDaUazapi(`mensagem ${i}`, `RESPOSTA-${i}`);
      corpo.message.sender = `${numero}@s.whatsapp.net`;
      corpo.message.sender_pn = `${numero}@s.whatsapp.net`;
      corpo.message.chatid = `${numero}@s.whatsapp.net`;
      corpo.chat = { phone: numero, wa_name: `Cliente ${i}` };
      await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify(corpo),
      });
      await espera(400);
    }
    await espera(500);
    const perguntas = t.van.recebidas.filter((c) => c.caminho === "/contatos/classificar").length;
    ok("um 404 do Vantoro NÃO o cala — ele está de pé e respondeu", perguntas === 2,
       `perguntou ${perguntas} vez(es); esperava 2`);
    await t.parar();
  }
}


// ==================================================================
//  41. A CAIXA DE ENTRADA — o evento existe antes de ser entendido
// ==================================================================
//
//  O "OK" que a ponte responde à Uazapi é uma promessa: dali em diante ela
//  considera a mensagem entregue e não manda de novo. A ponte prometia ANTES de
//  gravar — e morrer nesse intervalo (uma publicação, e são várias por semana)
//  era a mensagem do cliente sumindo, sem rastro nenhum de que existiu.
//
//  Agora o evento cru é gravado antes do "OK". Estas conferências exercitam os
//  quatro caminhos que isso cria, incluindo os dois que mais assustam: a caixa
//  desligada (o SQL que ninguém rodou) e o banco recusando a gravação.
{
  console.log("\n41. A caixa de entrada do webhook");

  // ---- o evento é guardado, e depois fechado ----
  {
    const t = await subirTudo();
    await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(mensagemDaUazapi("guarde antes de prometer", "CAIXA-1")),
    });
    await espera(900);

    const caixa = t.sb.dados.eventos_recebidos || [];
    ok("o evento cru foi guardado", caixa.length === 1, `guardou ${caixa.length}`);
    ok("com o corpo inteiro, e não um resumo",
       caixa[0] && caixa[0].corpo && caixa[0].corpo.message
         && caixa[0].corpo.message.text === "guarde antes de prometer",
       JSON.stringify(caixa[0] && caixa[0].corpo).slice(0, 120));
    ok("e foi marcado como resolvido depois de tratado",
       Boolean(caixa[0] && caixa[0].processado_em), JSON.stringify(caixa[0]));
    ok("a mensagem entrou na conversa, como sempre",
       t.sb.dados.mensagens.length === 1, `entraram ${t.sb.dados.mensagens.length}`);
    await t.parar();
  }

  // ---- SEM A TABELA, nada muda ----
  //
  // É o estado de hoje, e o de todo dia entre uma entrega e alguém rodar o SQL.
  // Se a ponte dependesse da tabela sem ela existir, TODA mensagem passaria a
  // ser recusada — uma perda rara viraria uma parada total.
  {
    const t = await subirTudo({}, { semTabelas: ["eventos_recebidos"] });
    const r = await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(mensagemDaUazapi("sem a tabela ainda", "CAIXA-2")),
    });
    await espera(900);

    ok("sem a tabela, o webhook responde 200 como sempre", r.status === 200, `respondeu ${r.status}`);
    ok("e a mensagem entra na conversa do mesmo jeito",
       t.sb.dados.mensagens.length === 1, `entraram ${t.sb.dados.mensagens.length}`);
    ok("e o log DIZ que a caixa está desligada, em vez de calar",
       /caixa de entrada está DESLIGADA/i.test(t.registro.join("")),
       t.registro.join("").slice(-300));
    await t.parar();
  }

  // ---- O BANCO RECUSANDO: não se promete o que não se guardou ----
  {
    const t = await subirTudo({}, {
      quebrar: (metodo, tabela) => (metodo === "POST" && tabela === "eventos_recebidos")
        ? "banco fora do ar" : null,
    });
    const r = await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(mensagemDaUazapi("o banco recusou", "CAIXA-3")),
    });
    await espera(600);

    // 503 E NÃO 200: a mensagem continua sendo da Uazapi para reentregar. Um
    // "OK" aqui seria dizer que ela está a salvo quando não está em lugar
    // nenhum — que é o defeito de origem, agora com o banco no lugar da queda.
    ok("não conseguindo guardar, a ponte NÃO promete (503)", r.status === 503,
       `respondeu ${r.status} — a Uazapi consideraria entregue`);
    ok("e diz no log por que recusou",
       /não consegui guardar o evento/i.test(t.registro.join("")),
       t.registro.join("").slice(-300));
    await t.parar();
  }

  // ---- O QUE FICOU PELA METADE É TERMINADO ----
  //
  // O coração desta etapa. Um evento guardado e nunca fechado é exatamente o
  // que uma publicação no meio do tratamento deixa para trás.
  {
    const t = await subirTudo({ CAIXA_INTERVALO_MS: "700" }, {
      tabelas: {
        eventos_recebidos: [{
          id: 1,
          corpo: mensagemDaUazapi("ficou pela metade na publicação", "CAIXA-4"),
          // Velho o bastante para a rodada considerá-lo parado, e não "sendo
          // tratado agora".
          recebido_em: new Date(Date.now() - 5 * 60 * 1000).toISOString(),
          processado_em: null, processando_em: null, tentativas: 0, erro: null,
        }],
      },
    });
    // Espera a rodada de recuperação passar.
    let entrou = false;
    for (let i = 0; i < 40; i++) {
      if (t.sb.dados.mensagens.some((m) => m.id_uazapi === "CAIXA-4")) { entrou = true; break; }
      await espera(250);
    }
    ok("o evento que ficou pela metade vira mensagem na conversa", entrou,
       "ele continuaria pendente para sempre, e a mensagem nunca teria entrado");
    const linha = (t.sb.dados.eventos_recebidos || []).find((e) => String(e.id) === "1");
    ok("e a linha dele é fechada", Boolean(linha && linha.processado_em), JSON.stringify(linha));
    ok("tendo contado a tentativa", linha && linha.tentativas >= 1, JSON.stringify(linha));
    await t.parar();
  }

  // ---- O QUE NUNCA DÁ CERTO PARA DE SER TENTADO, MAS É DITO ----
  //
  // Sem teto, um evento que a ponte não consegue tratar seria tentado para
  // sempre, enchendo o log e batendo no banco. Com teto e sem aviso, ele
  // viraria uma linha numa tabela que ninguém abre — e é uma mensagem de
  // cliente que não entrou.
  {
    const t = await subirTudo({ CAIXA_INTERVALO_MS: "400" }, {
      quebrar: (metodo, tabela) => (metodo === "POST" && tabela === "mensagens")
        ? "o banco recusa esta mensagem" : null,
      tabelas: {
        eventos_recebidos: [{
          id: 1,
          corpo: mensagemDaUazapi("esta nunca vai entrar", "CAIXA-5"),
          recebido_em: new Date(Date.now() - 5 * 60 * 1000).toISOString(),
          processado_em: null, processando_em: null, tentativas: 0, erro: null,
        }],
      },
    });
    let desistiu = false;
    for (let i = 0; i < 60; i++) {
      if (/falhou 5 vezes/i.test(t.registro.join(""))) { desistiu = true; break; }
      await espera(250);
    }
    const linha = (t.sb.dados.eventos_recebidos || []).find((e) => String(e.id) === "1");
    ok("o evento que sempre falha para de ser tentado", linha && linha.tentativas <= 5,
       `tentou ${linha && linha.tentativas} vezes`);
    ok("e o log GRITA que a mensagem não entrou", desistiu,
       t.registro.join("").slice(-400));
    ok("a linha guarda o motivo, para quem for investigar",
       Boolean(linha && linha.erro), JSON.stringify(linha));
    ok("e ela NÃO é dada como resolvida", !(linha && linha.processado_em),
       "marcar como resolvida esconderia uma mensagem que não entrou");
    await t.parar();
  }
}


// ==================================================================
//  42. OS TELEFONES DO CLIENTE PASSAM PELA PONTE
// ==================================================================
//
// Três pedidos do escritório, em 04/09: o mesmo número em dois CPF tem de
// ficar dito na tela e com dono escolhível; o cadastro precisa de mais de dois
// números; e a troca do WhatsApp passa a poder ser feita pelo Zorvin.
//
// A REGRA TODA MORA NO VANTORO — quem é o principal, o que acontece com o
// número velho na troca, o que não pode ser apagado. A ponte só repassa.
// Duplicar a regra aqui daria duas respostas para a mesma pergunta, e a que o
// escritório veria dependeria de por onde ela passou.
//
// O QUE ESTA SEÇÃO PROVA, então, é o que é responsabilidade DELA: que os
// quatro gestos chegam ao Vantoro no caminho certo, com o método certo e o
// corpo intacto — e que nenhum deles responde sem sessão do Zorvin. O token do
// Vantoro dá acesso à base inteira do escritório; é por isso que estas rotas
// existem, em vez de o painel falar direto com ele.
{
  console.log("\n42. Os telefones do cliente passam pela ponte");

  const t = await subirTudo({}, { vantoro: {} });
  const comLogin = (caminho, opcoes = {}) =>
    fetch(`http://127.0.0.1:${t.porta}${caminho}`, {
      headers: { Authorization: "Bearer jwt-bom", "Content-Type": "application/json" },
      ...opcoes,
    });
  const noVantoro = (metodo, pedaco) => t.van.recebidas.filter(
    (x) => x.metodo === metodo && x.caminho.includes(pedaco));

  // 1) LISTAR
  await comLogin("/vantoro/cliente/77/telefones");
  ok("listar os telefones chega ao Vantoro no caminho certo",
     noVantoro("GET", "/clientes/77/telefones").length === 1,
     JSON.stringify(t.van.recebidas.map((x) => `${x.metodo} ${x.caminho}`)));

  // 2) ACRESCENTAR — e o corpo tem de chegar INTEIRO. É nele que vai o "o
  //    aparelho é do filho", que é o pedido 1; perder um campo no caminho
  //    gravaria o número sem dono e ninguém veria falta.
  await comLogin("/vantoro/cliente/77/telefones", {
    method: "POST",
    body: JSON.stringify({ numero: "11988882222", proprio: false,
                           dono: "do filho, JOAO", principal: true }),
  });
  const posto = noVantoro("POST", "/clientes/77/telefones")[0];
  ok("acrescentar um número chega ao Vantoro", !!posto,
     JSON.stringify(t.van.recebidas.map((x) => `${x.metodo} ${x.caminho}`)));
  ok("e o corpo chega inteiro, com o dono do aparelho",
     posto && posto.corpo && posto.corpo.numero === "11988882222"
     && posto.corpo.proprio === false && posto.corpo.dono === "do filho, JOAO"
     && posto.corpo.principal === true,
     JSON.stringify(posto && posto.corpo));

  // 3) EDITAR
  await comLogin("/vantoro/cliente/77/telefones/5", {
    method: "PATCH", body: JSON.stringify({ proprio: true }),
  });
  const editado = noVantoro("PATCH", "/clientes/77/telefones/5")[0];
  ok("editar um telefone chega ao Vantoro, com o id da linha",
     !!editado && editado.corpo && editado.corpo.proprio === true,
     JSON.stringify(t.van.recebidas.map((x) => `${x.metodo} ${x.caminho}`)));

  // 4) REMOVER
  await comLogin("/vantoro/cliente/77/telefones/5", { method: "DELETE" });
  ok("remover um telefone chega ao Vantoro",
     noVantoro("DELETE", "/clientes/77/telefones/5").length === 1,
     JSON.stringify(t.van.recebidas.map((x) => `${x.metodo} ${x.caminho}`)));

  // SEM SESSÃO, NENHUMA DAS QUATRO RESPONDE. O token do Vantoro dá acesso à
  // base inteira; uma rota aberta aqui é a base do escritório aberta.
  const antes = t.van.recebidas.length;
  const sem = [
    await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente/77/telefones`),
    await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente/77/telefones`, { method: "POST" }),
    await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente/77/telefones/5`, { method: "PATCH" }),
    await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente/77/telefones/5`, { method: "DELETE" }),
  ];
  ok("sem sessão do Zorvin, as quatro recusam",
     sem.every((r) => r.status === 401), JSON.stringify(sem.map((r) => r.status)));
  // E NÃO CHEGAM AO VANTORO. Recusar depois de já ter perguntado seria vazar a
  // existência do cadastro para quem não pode vê-lo.
  ok("e nenhuma delas chega a tocar o Vantoro",
     t.van.recebidas.length === antes,
     `chegaram ${t.van.recebidas.length - antes} a mais`);

  await t.parar();
}


// ==================================================================
//  43. A MENSAGEM QUE NÃO SAIU TENTA DE NOVO SOZINHA
// ==================================================================
//
// Uma falha, e a mensagem morria ali: virava bolha vermelha e só saía se
// alguém estivesse com aquela conversa aberta para clicar em reenviar. Fora do
// horário, não saía.
//
// O QUE ESTA SEÇÃO GUARDA não é "tenta de novo" — é a RÉGUA de quando tentar.
// Reenviar sozinho uma mensagem que talvez tenha saído é o cliente recebendo
// duas vezes, e disso não há desfazer; por isso cada conferência abaixo é
// sobre um caso ficar de um lado ou do outro da linha, e as que provam que a
// ponte NÃO insiste valem tanto quanto as que provam que ela insiste.
{
  console.log("\n43. A mensagem que não saiu tenta de novo sozinha");

  /** Põe uma mensagem na fila, deixa o envio falhar, e devolve a linha. */
  async function enfileirarEFalhar(falharEnvio, { tentativas = 0, opcoes = {}, env = {},
                                                  servidorMorto = false } = {}) {
    const t = await subirTudo(env, { uazapi: { falharEnvio }, ...opcoes });
    if (servidorMorto) {
      // NINGUÉM ATENDENDO DO OUTRO LADO. É o `ECONNREFUSED` de verdade — a
      // conexão que nunca abre —, e não uma imitação dele: para separar "não
      // consegui nem falar com o servidor" de "falei e a resposta se perdeu",
      // a prova precisa do erro que o Node lança de fato.
      //
      // UMA PORTA LIVRE, e não a porta 1. Com a 1 esta prova reprovava por um
      // motivo que não é o assunto dela: o Node recusa as portas reservadas
      // ANTES de tentar conectar ("bad port"), e o erro sai sem `code` nenhum —
      // então não havia `ECONNREFUSED` para a ponte reconhecer, e o item ia
      // para erro com razão. Medido, e não deduzido.
      t.sb.dados.advogados[0].servidor = `http://127.0.0.1:${await portaLivre()}`;
    }
    t.sb.dados.contatos.push({ id: 1, numero: "5511999998888", nome: "Cliente" });
    t.sb.dados.conversas.push({ id: 1, advogado_id: TELEFONE.id, contato_id: 1 });
    t.sb.dados.fila_envio.push({
      id: 1, conversa_id: 1, tipo: "texto", texto: "Bom dia", status: "pendente",
      tentativas, criado_em: new Date().toISOString(),
    });
    await fetch(`http://127.0.0.1:${t.porta}/ping`);
    await espera(1600);
    const linha = t.sb.dados.fila_envio.find((f) => f.id === 1);
    return { t, linha, registro: t.registro.join("") };
  }

  // ---- 43a. "mandou demais" volta para a fila, e não para a bolha vermelha ----
  //
  // 429 é a própria Uazapi dizendo que NÃO PROCESSOU. A mensagem não foi para
  // o WhatsApp, e é a falha que mais aparece no dia movimentado — que é o dia
  // em que a resposta perdida custa caro.
  {
    const { t, linha, registro } = await enfileirarEFalhar(
      { status: 429, corpo: { error: "too many requests" } });
    ok("o item volta a ser pendente, em vez de virar erro",
       linha?.status === "pendente", `ficou ${linha?.status}`);
    ok("com hora marcada para a próxima tentativa",
       Boolean(linha?.tentar_em), JSON.stringify(linha));
    ok("e essa hora está no futuro — ele não é da vez agora",
       new Date(linha?.tentar_em).getTime() > Date.now(), String(linha?.tentar_em));
    ok("a tentativa foi contada", (linha?.tentativas || 0) === 1,
       `contou ${linha?.tentativas}`);
    ok("o motivo fica guardado para quem for investigar",
       /429|too many/i.test(linha?.erro_detalhe || ""), JSON.stringify(linha?.erro_detalhe));
    ok("e o log diz de quantas é a tentativa e quando é a próxima",
       /tentativa 1 de 5/.test(registro) && /nova tentativa em \d+s/.test(registro),
       registro.slice(-400));
    // A BOLHA NÃO FICA VERMELHA. O painel pinta de vermelho pelo `status`, e
    // este item voltou a ser um item pendente: para quem atende, a mensagem
    // ainda está indo — que é a verdade.
    ok("e a tela NÃO recebe motivo de erro para mostrar",
       !linha?.erro_motivo, JSON.stringify(linha?.erro_motivo));
    await t.parar();
  }

  // ---- 43b. a espera é respeitada ----
  //
  // Sem isto a retentativa não seria retentativa: o ciclo roda de 3 em 3
  // segundos e gastaria as cinco tentativas no primeiro minuto, bem quando o
  // problema que causou a falha ainda está de pé.
  {
    const t = await subirTudo({}, { uazapi: { falharEnvio: { status: 429, corpo: { error: "x" } } } });
    t.sb.dados.contatos.push({ id: 1, numero: "5511999998888", nome: "Cliente" });
    t.sb.dados.conversas.push({ id: 1, advogado_id: TELEFONE.id, contato_id: 1 });
    t.sb.dados.fila_envio.push({
      id: 1, conversa_id: 1, tipo: "texto", texto: "Bom dia", status: "pendente",
      tentativas: 1, criado_em: new Date().toISOString(),
      tentar_em: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
    });
    await fetch(`http://127.0.0.1:${t.porta}/ping`);
    await espera(1600);
    const tentou = t.uaz.recebidas.filter((c) => /\/send\//.test(c.caminho)).length;
    ok("o item que está esperando a hora NÃO é tentado", tentou === 0,
       `tentou ${tentou} vez(es)`);
    ok("e continua pendente, sem gastar tentativa",
       t.sb.dados.fila_envio[0].status === "pendente" && t.sb.dados.fila_envio[0].tentativas === 1,
       JSON.stringify(t.sb.dados.fila_envio[0]));
    await t.parar();
  }

  // ---- 43c. chegada a hora, ela sai ----
  //
  // A conferência que fecha o círculo: sem ela, "voltou para pendente" poderia
  // ser só um jeito mais bonito de a mensagem nunca sair.
  {
    const t = await subirTudo({});
    t.sb.dados.contatos.push({ id: 1, numero: "5511999998888", nome: "Cliente" });
    t.sb.dados.conversas.push({ id: 1, advogado_id: TELEFONE.id, contato_id: 1 });
    t.sb.dados.fila_envio.push({
      id: 1, conversa_id: 1, tipo: "texto", texto: "Bom dia", status: "pendente",
      tentativas: 1, criado_em: new Date().toISOString(),
      tentar_em: new Date(Date.now() - 1000).toISOString(),
    });
    await fetch(`http://127.0.0.1:${t.porta}/ping`);
    await espera(1600);
    ok("passada a hora, a mensagem sai",
       t.sb.dados.fila_envio[0].status === "enviada",
       JSON.stringify(t.sb.dados.fila_envio[0]));
    ok("e entra no histórico da conversa",
       (t.sb.dados.mensagens || []).some((m) => m.texto === "Bom dia"),
       JSON.stringify(t.sb.dados.mensagens));
    await t.parar();
  }

  // ---- 43d. a conexão que nunca abriu ----
  //
  // Não houve conversa com a Uazapi, então não houve mensagem. É o único caso
  // de rede em que a certeza existe — e o código que o prova (`ECONNREFUSED`)
  // vinha do Node em `cause` e era jogado fora antes desta mudança.
  {
    const { t, linha } = await enfileirarEFalhar(null, { servidorMorto: true });
    ok("servidor fora do ar devolve o item para a fila",
       linha?.status === "pendente", `ficou ${linha?.status}`);
    ok("e o código da falha de rede é guardado, em vez de descartado",
       /ECONNREFUSED/i.test(linha?.erro_detalhe || ""), JSON.stringify(linha?.erro_detalhe));
    await t.parar();
  }

  // ---- 43e. o que NÃO pode ser tentado de novo ----
  //
  // Estas três são o coração da régua. Em nenhuma delas a ponte pode insistir
  // sozinha: nas duas primeiras porque insistir não resolveria nada e adiaria
  // o aviso que uma pessoa precisa ver; na terceira porque a mensagem PODE ter
  // saído, e reenviar seria o cliente recebendo duas vezes.
  {
    const { t, linha } = await enfileirarEFalhar(
      { status: 400, corpo: { error: "number not exists" } });
    ok("número que não existe vira erro na hora, sem insistir",
       linha?.status === "erro", `ficou ${linha?.status}`);
    ok("sem hora marcada — não há o que tentar de novo",
       !linha?.tentar_em, String(linha?.tentar_em));
    await t.parar();
  }
  {
    const { t, linha, registro } = await enfileirarEFalhar(
      { status: 503, corpo: { error: true, message: "WhatsApp disconnected: session is not reconnectable" } });
    ok("linha do escritório caída vira erro, e não retentativa",
       linha?.status === "erro", `ficou ${linha?.status}`);
    // Insistir aqui gastaria as cinco tentativas em vinte minutos para terminar
    // na mesma bolha vermelha — só que mais tarde, e depois de o aviso já ter
    // passado. Este caso pede uma pessoa, não uma retentativa.
    ok("e o aviso de linha caída continua saindo na hora",
       /LINHA DESCONECTADA/.test(registro), registro.slice(-400));
    await t.parar();
  }
  {
    // O TEMPO LIMITE FICA DE FORA DE PROPÓSITO. A Uazapi demora e nós
    // desistimos — mas o pedido pode ter chegado inteiro, e ela pode ter
    // mandado a mensagem. Enquanto isso não for medido contra a Uazapi de
    // verdade, a decisão é de quem atende.
    const { t, linha } = await enfileirarEFalhar(null, {
      opcoes: { uazapi: { demoraDoEnvio: 3000 } },
      env: { UAZAPI_TIMEOUT_MS: "300" },
    });
    ok("tempo limite estourado vira erro, e a ponte NÃO reenvia sozinha",
       linha?.status === "erro", `ficou ${linha?.status}`);
    ok("sem hora marcada", !linha?.tentar_em, String(linha?.tentar_em));
    await t.parar();
  }

  // ---- 43f. o teto continua valendo ----
  //
  // Uma retentativa sem teto seria um laço que reentrega a mesma mensagem para
  // sempre. Na última tentativa a régua muda de lado: vira bolha vermelha, que
  // é onde uma pessoa consegue agir.
  {
    const { t, linha } = await enfileirarEFalhar(
      { status: 429, corpo: { error: "too many requests" } }, { tentativas: 4 });
    ok("esgotadas as tentativas, vira erro em vez de insistir para sempre",
       linha?.status === "erro", `ficou ${linha?.status}`);
    ok("e a tela diz que tentamos várias vezes",
       /v[áa]rias vezes/i.test(linha?.erro_motivo || ""), JSON.stringify(linha?.erro_motivo));
    // SEM PERDER A CAUSA. Dizer só "tentamos várias vezes" tiraria de quem
    // investiga a única pista do porquê — e o porquê é o que decide se o
    // conserto é esperar, arrumar o cadastro ou reconectar um aparelho.
    ok("sem jogar fora o motivo técnico",
       /429|too many/i.test(linha?.erro_detalhe || ""), JSON.stringify(linha?.erro_detalhe));
    await t.parar();
  }

  // ---- 43g. base sem a coluna: tudo como antes ----
  //
  // O estado real de produção entre a entrega e o SQL rodado. A fila NÃO pode
  // parar por causa de uma coluna que falta: uma fila que não é lida é o
  // escritório inteiro sem enviar nada, bem pior do que ficar sem a
  // retentativa automática.
  {
    const { t, linha, registro } = await enfileirarEFalhar(
      { status: 429, corpo: { error: "too many requests" } },
      { opcoes: { semColunas: { fila_envio: ["tentar_em"] } } });
    ok("sem a coluna, a falha vira erro — exatamente como antes",
       linha?.status === "erro", `ficou ${linha?.status}`);
    ok("e o log diz o que rodar para ligar a retentativa",
       /tentar_em.*n[ãa]o existe/s.test(registro)
       && /2026-09-a-mensagem-que-nao-saiu-tenta-de-novo\.sql/.test(registro),
       registro.slice(-600));
    await t.parar();
  }
  {
    // E a fila continua ENVIANDO. Sem esta, a anterior provaria só que a ponte
    // avisa antes de parar de funcionar.
    const t = await subirTudo({}, { semColunas: { fila_envio: ["tentar_em"] } });
    t.sb.dados.contatos.push({ id: 1, numero: "5511999998888", nome: "Cliente" });
    t.sb.dados.conversas.push({ id: 1, advogado_id: TELEFONE.id, contato_id: 1 });
    t.sb.dados.fila_envio.push({
      id: 1, conversa_id: 1, tipo: "texto", texto: "Bom dia", status: "pendente",
      tentativas: 0, criado_em: new Date().toISOString(),
    });
    await fetch(`http://127.0.0.1:${t.porta}/ping`);
    await espera(1600);
    ok("e a fila segue enviando normalmente sem a coluna",
       t.sb.dados.fila_envio[0].status === "enviada",
       JSON.stringify(t.sb.dados.fila_envio[0]));
    await t.parar();
  }
}

// ==================================================================
//  44. DE QUEM É ESTE CPF — perguntado enquanto se digita
// ==================================================================
//
// Relato do escritório, em 08/09: "está sendo permitido cadastrar o mesmo
// cliente com o mesmo CPF... o ideal é que ao digitar o CPF o sistema avise
// que já existe o cadastro e se o usuário quer ver a ficha".
//
// O Vantoro passou a RECUSAR o CPF de outro cadastro (vantoro#232). Recusar no
// fim, porém, é tarde: a pessoa preencheu nome, nascimento, endereço e
// profissão, e só então descobre que o cadastro já existia — o trabalho todo
// refeito à toa.
//
// Esta rota é a pergunta feita ANTES, e a ponte só repassa: quem sabe de quem
// é o CPF é o Vantoro.
{
  console.log("\n44. De quem é este CPF, perguntado enquanto se digita");

  const t = await subirTudo({}, { vantoro: {} });
  const perguntar = (cpf) => fetch(
    `http://127.0.0.1:${t.porta}/vantoro/cpf-existe?cpf=${encodeURIComponent(cpf)}`,
    { headers: { Authorization: "Bearer jwt-bom" } });
  const noVantoro = () => t.van.recebidas.filter((x) => x.caminho.includes("/clientes/cpf-existe"));

  const r = await perguntar("398.506.618-36");
  ok("o CPF completo chega ao Vantoro", noVantoro().length === 1,
     JSON.stringify(t.van.recebidas.map((x) => x.caminho)));
  // SÓ OS DÍGITOS ATRAVESSAM. O Vantoro compara por dígitos; mandar a
  // pontuação junto faria a comparação depender de como cada tela formata.
  ok("e só com os dígitos, sem a pontuação",
     noVantoro()[0] && noVantoro()[0].busca.includes("cpf=39850661836"),
     noVantoro()[0] && noVantoro()[0].busca);
  ok("e a rota responde 200", r.status === 200, `veio ${r.status}`);

  // O CPF PELA METADE NEM SAI DAQUI.
  //
  // A tela chama a cada tecla. Mandar "398" ao Vantoro seria uma ida à rede por
  // caractere digitado, num serviço que hiberna — e para uma pergunta que não
  // tem resposta possível.
  const antes = noVantoro().length;
  const meio = await perguntar("398");
  const corpo = await meio.json();
  ok("o CPF pela metade não vira ida à rede", noVantoro().length === antes,
     `foram ${noVantoro().length - antes} idas a mais`);
  ok("e a resposta diz que está incompleto, sem inventar um 'não achei'",
     meio.status === 200 && corpo.encontrado === false && corpo.incompleto === true,
     JSON.stringify(corpo));

  // SEM SESSÃO NÃO RESPONDE, e nem toca o Vantoro. A rota diz se um CPF está
  // na base do escritório — é informação de cadastro, não de tela pública.
  const semLogin = await fetch(`http://127.0.0.1:${t.porta}/vantoro/cpf-existe?cpf=39850661836`);
  ok("sem sessão do Zorvin, recusa", semLogin.status === 401, `veio ${semLogin.status}`);
  ok("e nem chega a perguntar ao Vantoro", noVantoro().length === antes,
     `perguntou ${noVantoro().length - antes} vez(es)`);

  await t.parar();
}


// ==================================================================
//  45. O DOCUMENTO QUE CHEGA — E O QUE FICOU "INDISPONÍVEL"
//
//  RELATO DO ESCRITÓRIO, em 10/09, com a foto da tela: uma bolha escrita
//  "Documento — indisponível" numa conversa de atendimento. "Documentos
//  recebidos no Zorvin estão como indisponível. Favor corrigir."
//
//  Três coisas estavam erradas, e as três aparecem naquela bolha:
//
//  1. A SEGUNDA CHANCE FICAVA DO LADO DE FORA. O endereço que a Uazapi manda à
//     parte só era usado quando o download não respondia NADA. Se ele
//     respondia 200 com um corpo sem arquivo dentro — que é o que ela faz
//     quando não conseguiu o arquivo no WhatsApp —, a ponte seguia em frente,
//     não achava bytes e desistia sem olhar para o endereço que estava na mão.
//
//  2. UMA TENTATIVA ERA TUDO. Falhou, a bolha ficava vazia para sempre. A
//     Uazapi busca o arquivo no WhatsApp na hora do pedido: falhar uma vez e
//     servir na seguinte é o normal dela, não a exceção.
//
//  3. O NOME NUNCA FOI GRAVADO. `midia_nome` só era escrito no que o
//     escritório ENVIA. Todo documento recebido aparecia como "Documento", e o
//     nome — que é o que distingue a procuração assinada do panfleto
//     encaminhado — ficava só do lado do WhatsApp.
// ==================================================================
console.log("\n45. O documento que chega, e o que ficou indisponível");
{
  const CHAT = "5511999998888@s.whatsapp.net";
  const documentoDaUazapi = (id, nome = "procuracao assinada.pdf") => ({
    EventType: "messages",
    owner: TELEFONE.numero,
    message: {
      id, messageid: id, chatid: CHAT, sender: CHAT, fromMe: false, isGroup: false,
      messageType: "documentMessage", mimetype: "application/pdf",
      content: { mimetype: "application/pdf", fileName: nome },
      messageTimestamp: Date.now(), wasSentByApi: false, senderName: "Cliente",
    },
  });
  const mandar = (t, corpo) => fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(corpo),
  });
  const mensagemDe = (t, id) => (t.sb.dados.mensagens || []).find((m) => m.id_uazapi === id);
  const enderecoDoArquivoDe = (t, ids) => ({
    BaseUrl: t.uaz.url,
    EventType: "messages_update",
    event: { Chat: CHAT, FileURL: `${t.uaz.url}/files/abc.pdf?assinatura=xyz`,
             MessageIDs: ids, Type: "Delivered" },
  });

  // ---- 45a. o nome do arquivo entra na mensagem ----
  {
    const t = await subirTudo({}, { uazapi: { mimeDoDownload: "application/pdf" } });
    await mandar(t, documentoDaUazapi("DOC-NOME"));
    await espera(1200);

    const m = mensagemDe(t, "DOC-NOME");
    ok("o documento entra com o arquivo", !!(m && m.midia_url), `veio ${m && m.midia_url}`);
    // SEM ISTO A BOLHA DIZ "Documento" mesmo com o arquivo dentro — que é
    // metade do que o escritório fotografou.
    ok("e com o NOME que o cliente mandou",
       m && m.midia_nome === "procuracao assinada.pdf", `veio ${m && m.midia_nome}`);
    await t.parar();
  }

  // ---- 45b. o caminho do relato: responde 200, sem arquivo ----
  {
    // `falhasDeDownload: 1` é o servidor que ATENDE e não traz nada — a falha
    // que a bancada não sabia imitar. `rotaDeDownload: null` imitava só o
    // outro caso, o do servidor que não responde, e os dois caminhos dentro da
    // ponte eram diferentes.
    //
    // A espera curta é para a prova caber num teste; em produção são 20s, 1min
    // e 5min.
    //
    // A PRIMEIRA É A MAIS LONGA DAS DUAS, de propósito. Com ela em 400ms, a
    // segunda tentativa já tinha enchido o anexo antes de a conferência de
    // baixo olhar — e "na primeira tentativa não vem arquivo nenhum" reprovava
    // por causa do relógio da prova, e não do que ela mede. É a armadilha de
    // sempre: uma conferência que depende de chegar primeiro não mede o que
    // diz medir.
    const t = await subirTudo({ ESPERA_DO_ANEXO_MS: "1500,400" },
                              { uazapi: { falhasDeDownload: 1, mimeDoDownload: "application/pdf" } });
    await mandar(t, documentoDaUazapi("DOC-TEIMOSO"));
    await espera(600);

    const vazio = mensagemDe(t, "DOC-TEIMOSO");
    ok("na primeira tentativa não vem arquivo nenhum", vazio && !vazio.midia_url,
       `veio ${vazio && vazio.midia_url}`);
    ok("mas a bolha existe, para ninguém ficar sem saber que chegou algo", !!vazio);

    // AQUI ESTÁ O CONSERTO. Antes, esta espera não mudava nada: nada no
    // sistema voltava a pedir o arquivo, nunca.
    await espera(2000);
    const cheio = mensagemDe(t, "DOC-TEIMOSO");
    ok("a ponte tenta de novo, e o documento chega", !!(cheio && cheio.midia_url),
       "sem isto o documento fica 'indisponível' para sempre");
    ok("e o log conta em que tentativa ele veio",
       /chegou na tentativa/.test(t.registro.join("")), t.registro.join("").slice(-400));
    await t.parar();
  }

  // ---- 45b-bis. a resposta inútil também merece a segunda chance ----
  {
    // A BRECHA, em uma frase: a segunda chance — o endereço que a Uazapi
    // manda à parte, guardado pelo id EXATO da mensagem — só era tentada
    // quando o download não respondia NADA. Se ele respondia 200 com um corpo
    // sem arquivo dentro, a ponte seguia em frente, não achava bytes e
    // desistia sem olhar para o endereço que estava ali na mão.
    //
    // A ORDEM AQUI É A DO CASO REAL: o evento do arquivo chega ANTES da
    // mensagem, que é o que acontece sempre que a Uazapi manda o `FileURL` na
    // frente. Ele fica guardado esperando; a mensagem chega logo depois, o
    // download atende sem trazer nada, e é este endereço que salva o anexo.
    //
    // Sem o conserto: a bolha fica vazia com o arquivo a um passo de distância.
    const t = await subirTudo({ ESPERA_DO_ANEXO_MS: "60000" },
                              { uazapi: { falhasDeDownload: 99 } });
    await mandar(t, enderecoDoArquivoDe(t, ["DOC-DE-BANDEJA"]));
    await espera(400);
    await mandar(t, documentoDaUazapi("DOC-DE-BANDEJA"));
    await espera(1500);

    const m = mensagemDe(t, "DOC-DE-BANDEJA");
    ok("o download responde sem arquivo, e o endereço guardado salva o anexo",
       !!(m && m.midia_url), "era o documento do cliente a um passo de distância");
    ok("e o log conta por onde ele veio",
       /mandou à parte/.test(t.registro.join("")), t.registro.join("").slice(-300));
    await t.parar();
  }

  // ---- 45b-ter. o servidor que recusa POST e atende GET ----
  {
    // MEDIDO no servidor do escritório, em 11/09, nos 35 anexos vazios:
    //
    //     POST /message/downloadmedia  ->  405   (nas 35, sem exceção)
    //     POST /downloadmedia          ->  405   (nas 35, sem exceção)
    //     POST /message/download       ->  400, 404 ou 500
    //
    // 405 é "método não permitido": o endereço EXISTE e o POST é que não serve
    // ali. Quer dizer que a rota preferida da ponte nunca funcionou nessa conta
    // — em nenhum dia, para nenhum anexo. O que enchia as bolhas era só o outro
    // caminho, o do endereço que a Uazapi manda à parte.
    //
    // A bancada só sabia imitar servidor que aceita POST, então isso podia
    // estar quebrado em produção desde sempre sem reprovar uma prova sequer.
    const t = await subirTudo({}, { uazapi: { metodoDoDownload: "GET",
                                              mimeDoDownload: "application/pdf" } });
    await mandar(t, documentoDaUazapi("DOC-SO-GET"));
    await espera(1500);

    const m = mensagemDe(t, "DOC-SO-GET");
    ok("num servidor que recusa POST, a ponte pede por GET e o arquivo vem",
       !!(m && m.midia_url), `veio ${m && m.midia_url}`);
    const pediu = t.uaz.recebidas.filter((c) => String(c.caminho).includes("download"));
    ok("e ela só recorre ao GET depois de tentar o POST em todas as rotas",
       pediu.length > 3, `foram ${pediu.length} tentativas`);

    // E NÃO PAGA A FILA DE NOVO NO PRÓXIMO DOCUMENTO.
    //
    // Guardando só a rota, o servidor que atende por GET pagava seis idas por
    // anexo, para sempre. Um servidor não troca de versão entre um documento e
    // o seguinte: descobre-se o par que serve, e lembra-se dele. "Funciona" e
    // "funciona sem martelar o serviço" são duas coisas.
    const antes = pediu.length;
    await mandar(t, documentoDaUazapi("DOC-SO-GET-2"));
    await espera(1200);
    const agora = t.uaz.recebidas.filter((c) => String(c.caminho).includes("download")).length;
    const m2 = mensagemDe(t, "DOC-SO-GET-2");
    ok("o segundo documento chega", !!(m2 && m2.midia_url));
    ok("e custa UMA ida, porque o método que serve ficou lembrado",
       agora - antes === 1, `custou ${agora - antes} idas`);
    await t.parar();
  }

  // ---- 45c. a insistência tem fim ----
  {
    // Um serviço que tem limite de uso não pode ser martelado. Depois das
    // tentativas combinadas, desiste — e diz no log que desistiu, com o id, que
    // é por onde o resgate manual acha a mensagem depois.
    const t = await subirTudo({ ESPERA_DO_ANEXO_MS: "300,300" },
                              { uazapi: { rotaDeDownload: null } });
    await mandar(t, documentoDaUazapi("DOC-PERDIDO"));
    await espera(2000);

    const pedidos = () => t.uaz.recebidas.filter(
      (c) => String(c.caminho).includes("download")).length;
    // O TETO ACOMPANHOU O GET. São três rotas por dois métodos, e três
    // tentativas: dezoito no pior caso, que é o servidor em que NADA serve.
    // Onde alguma coisa serve, a lembrança corta isso para uma — e é a
    // conferência logo abaixo, na 45b-ter, que mede essa parte.
    ok("desiste depois das tentativas combinadas, e não fica batendo",
       pedidos() <= 18, `foram ${pedidos()} idas ao servidor`);
    ok("e o log diz que desistiu, com o id da mensagem",
       /sem arquivo depois de \d+ tentativas/.test(t.registro.join(""))
       && /DOC-PERDIDO/.test(t.registro.join("")), t.registro.join("").slice(-400));

    // O NOME SOBREVIVE À FALTA DO ARQUIVO, e esta conferência tem de estar
    // AQUI, e não na 45a.
    //
    // Lá o download funciona, e aí o nome entra pela gravação de depois — a
    // que troca a miniatura pelo arquivo. Uma sabotagem que apagasse a
    // gravação inicial passava despercebida: a conferência aprovava um nome
    // que tinha chegado pelo outro caminho. Foi a sabotagem que mostrou isso.
    //
    // Sem arquivo não há gravação de depois, então o que se vê aqui só pode
    // ter vindo do momento em que a mensagem nasceu. E é justamente a bolha
    // que o escritório fotografou: sem o nome, ela diz "Documento —
    // indisponível", sem dizer que documento era.
    const perdido = mensagemDe(t, "DOC-PERDIDO");
    ok("e mesmo sem o arquivo a bolha sabe QUE documento é",
       perdido && perdido.midia_nome === "procuracao assinada.pdf",
       `veio ${perdido && perdido.midia_nome}`);
    await t.parar();
  }

  // ---- 45c-bis. o documento que o ESCRITÓRIO manda também tem nome ----
  {
    // O painel já grava o nome na FILA, e é dele que sai o `docName` mandado ao
    // WhatsApp. Mas a linha de `mensagens` — a que a conversa desenha — nunca o
    // recebia: o nome fazia a viagem inteira até o cliente e não sobrava para o
    // escritório. Quem mandou "contrato assinado.pdf" via, na própria conversa,
    // uma bolha escrita "Documento".
    const t = await subirTudo();
    t.sb.dados.contatos.push({ id: 1, numero: "5511999998888", nome: "Cliente Teste" });
    t.sb.dados.conversas.push({ id: 1, advogado_id: TELEFONE.id, contato_id: 1 });
    t.sb.dados.fila_envio.push({
      id: 1, conversa_id: 1, tipo: "documento", texto: "", status: "pendente",
      midia_url: "https://falsa/anexos/contrato.pdf", midia_mime: "application/pdf",
      midia_nome: "contrato assinado.pdf",
      tentativas: 0, criado_em: new Date().toISOString(),
    });
    await fetch(`http://127.0.0.1:${t.porta}/ping`);
    await espera(1500);

    const enviada = (t.sb.dados.mensagens || []).find((m) => m.tipo === "documento");
    ok("o documento enviado vira mensagem", !!enviada);
    ok("e leva o nome do arquivo junto",
       enviada && enviada.midia_nome === "contrato assinado.pdf",
       `veio ${enviada && enviada.midia_nome}`);
    await t.parar();
  }

  // ---- 45d. o resgate do que JÁ está vazio ----
  {
    // A insistência conserta o que chega de agora em diante. O documento que o
    // escritório fotografou já está na conversa, vazio, e nada no sistema volta
    // a olhar para ele.
    const t = await subirTudo({ IMPORT_TOKEN: "senha-boa", ESPERA_DO_ANEXO_MS: "300" },
                              { uazapi: { rotaDeDownload: null } });
    await mandar(t, documentoDaUazapi("DOC-ANTIGO"));
    await espera(1500);
    ok("o documento está lá, vazio, como o da foto",
       (() => { const m = mensagemDe(t, "DOC-ANTIGO"); return m && !m.midia_url; })());

    // O servidor volta a servir — é o caso real: o arquivo não veio naquele
    // minuto e vem agora.
    t.uaz.servirDownloadDeNovo("application/pdf");

    const semSenha = await fetch(`http://127.0.0.1:${t.porta}/anexos/resgatar`);
    ok("sem o token, a porta não abre", semSenha.status === 403, `veio ${semSenha.status}`);

    const r = await fetch(`http://127.0.0.1:${t.porta}/anexos/resgatar?token=senha-boa&dias=7`);
    const corpo = await r.json();
    ok("com o token, ela responde", r.status === 200 && corpo.ok === true, JSON.stringify(corpo).slice(0, 200));
    ok("acha o anexo vazio e o enche", corpo.recuperados === 1,
       JSON.stringify(corpo).slice(0, 300));

    const m = mensagemDe(t, "DOC-ANTIGO");
    ok("e a mensagem passa a ter o arquivo", !!(m && m.midia_url), `veio ${m && m.midia_url}`);
    // A RESPOSTA NÃO CARREGA CONVERSA DE CLIENTE. É uma página aberta num
    // navegador, com uma senha que várias pessoas do escritório têm.
    const cru = JSON.stringify(corpo);
    ok("e a resposta não devolve texto de mensagem nenhuma",
       !/procuracao|Cliente|5511999998888/.test(cru), cru.slice(0, 200));
    await t.parar();
  }

  // ---- 45e. quando o resgate NÃO traz, ele diz por quê ----
  {
    // Sem isto, "115 documentos não voltaram" é um beco: pode ser token
    // vencido, arquivo que a Uazapi já apagou, ou Storage recusando — três
    // consertos diferentes. E quem lê a resposta é alguém num navegador, sem
    // acesso ao log da Render.
    const t = await subirTudo({ IMPORT_TOKEN: "senha-boa", ESPERA_DO_ANEXO_MS: "300" },
                              { uazapi: { rotaDeDownload: null } });
    await mandar(t, documentoDaUazapi("DOC-SEM-JEITO"));
    await espera(1500);

    const r = await fetch(`http://127.0.0.1:${t.porta}/anexos/resgatar?token=senha-boa&dias=7`);
    const corpo = await r.json();
    ok("não recupera o que a Uazapi não tem mais", corpo.recuperados === 0,
       JSON.stringify(corpo).slice(0, 200));
    ok("mas diz o motivo, e não só o id",
       Array.isArray(corpo.nao_deram) && corpo.nao_deram[0]
       && /rota de download/.test(corpo.nao_deram[0].porque || ""),
       JSON.stringify(corpo.nao_deram || []).slice(0, 250));
    // O QUE CADA ROTA RESPONDEU, e não só "não deu".
    //
    // Em 11/09 os 35 anexos vieram todos com o mesmo motivo, e ele juntava
    // três diagnósticos opostos: 404 é a Uazapi já não ter o arquivo (não há
    // o que fazer), 401 é token vencido (conserto de cadastro), estouro de
    // rede é outra coisa ainda. Sem o número, a resposta diz que falhou e não
    // diz o que fazer.
    ok("e diz o que cada rota respondeu, com o número",
       /respondeu 404/.test(corpo.nao_deram[0].porque || ""),
       corpo.nao_deram[0].porque);
    // A FRASE DA RECUSA, e não só o número. Em 11/09 a Uazapi respondeu 400 em
    // vinte dos trinta e cinco — e 400 é "o pedido está errado", não "o arquivo
    // sumiu". A explicação vinha no corpo, e o corpo era jogado fora: ficávamos
    // com o número e sem a frase, que é olhar para o erro pela fechadura.
    ok("e traz a frase com que a Uazapi recusou, além do número",
       /não existe nesta versão/.test(corpo.nao_deram[0].porque || ""),
       corpo.nao_deram[0].porque);
    // DE QUAL TELEFONE. Trinta e cinco falhas iguais podem ser o sistema
    // inteiro ou UM telefone com o cadastro errado, e são consertos opostos.
    ok("e de qual telefone é cada anexo que não voltou",
       !!corpo.nao_deram[0].telefone && corpo.por_telefone
       && Object.keys(corpo.por_telefone).length === 1,
       JSON.stringify(corpo.por_telefone || {}));
    // CONTADOS, e não só listados: com 115 linhas iguais ninguém lê a lista.
    ok("e resume por motivo, para a lista longa se ler de relance",
       corpo.por_motivo && Object.values(corpo.por_motivo)[0] === 1,
       JSON.stringify(corpo.por_motivo || {}));
    await t.parar();
  }

  // ---- 45e. "não existe" NÃO é "não consegui agora" ----
  //
  // MEDIDO em 11/09, resgatando os anexos vazios do escritório. A rota que
  // serve naquele servidor respondeu:
  //
  //     400 {"error":"Message does not contain downloadable media"}
  //
  // Isso não é a rota falhando: é a rota FUNCIONANDO e dizendo que aquela
  // mensagem não tem arquivo. A resposta não muda daqui a cinco minutos.
  //
  // E a ponte insistia assim mesmo — mais três rodadas de seis pedidos cada,
  // para ouvir a mesma frase. Dezoito chamadas num serviço que tem limite de
  // uso e que já nos devolve 429; e é o mesmo 429 que faz a fila segurar a
  // mensagem que o atendente escreveu. Insistir no impossível custa na coisa
  // que importa.
  {
    const t = await subirTudo({ ESPERA_DO_ANEXO_MS: "300,300,300" },
      { uazapi: { recusaDefinitiva: "Message does not contain downloadable media" } });
    await mandar(t, documentoDaUazapi("DOC-QUE-NAO-EXISTE"));
    await espera(2500);   // tempo de sobra para três rodadas, se houvesse

    const m = mensagemDe(t, "DOC-QUE-NAO-EXISTE");
    ok("a bolha existe, para ninguém ficar sem saber que chegou algo", !!m);
    ok("e ela guarda o motivo de o arquivo não vir mais",
       !!(m && m.midia_erro && /does not contain downloadable media/i.test(m.midia_erro)),
       JSON.stringify(m && m.midia_erro));
    ok("o log diz que não vai insistir, e por quê",
       /não insisto/i.test(t.registro.join("")), t.registro.join("").slice(-400));

    // O NÚMERO É A PROVA. Sem ele, "não insiste" seria uma frase no log com a
    // ponte martelando o serviço por baixo.
    const pedidos = t.uaz.recebidas.filter((c) => /download/i.test(c.caminho)).length;
    ok("e a Uazapi é procurada UMA rodada, e não quatro", pedidos <= 7,
       `foram ${pedidos} pedidos; uma rodada são seis`);
    await t.parar();
  }

  // ---- 45f. a falha passageira continua merecendo insistência ----
  //
  // A metade que segura a régua. Sem esta, bastaria parar em toda falha para
  // a de cima passar — e aí a ponte desistiria do documento que chega na
  // segunda tentativa, que é o comportamento normal da Uazapi e o motivo de a
  // insistência existir.
  {
    const t = await subirTudo({ ESPERA_DO_ANEXO_MS: "400,400" },
                              { uazapi: { falhasDeDownload: 1 } });
    await mandar(t, documentoDaUazapi("DOC-QUE-DEMORA"));
    await espera(2000);

    const m = mensagemDe(t, "DOC-QUE-DEMORA");
    ok("o arquivo que só vem na segunda tentativa continua chegando",
       !!(m && m.midia_url), "a régua não pode parar de insistir no passageiro");
    ok("e a mensagem NÃO fica marcada como perdida", !(m && m.midia_erro),
       JSON.stringify(m && m.midia_erro));
    await t.parar();
  }

  // ---- 45g. na dúvida, insiste ----
  //
  // A ponte só para diante das frases que RECONHECE. Uma recusa que ela nunca
  // viu é tratada como passageira — e tem de ser: parar por engano é desistir
  // de um documento que viria, e isso não tem quem conserte depois.
  {
    const t = await subirTudo({ ESPERA_DO_ANEXO_MS: "300,300,300" },
      { uazapi: { recusaDefinitiva: "erro novo que ninguém nunca viu" } });
    await mandar(t, documentoDaUazapi("DOC-DE-MOTIVO-NOVO"));
    await espera(2500);

    const m = mensagemDe(t, "DOC-DE-MOTIVO-NOVO");
    ok("motivo desconhecido NÃO marca a mensagem como perdida",
       !(m && m.midia_erro), JSON.stringify(m && m.midia_erro));
    const pedidos = t.uaz.recebidas.filter((c) => /download/i.test(c.caminho)).length;
    ok("e a ponte insiste, como insistia antes", pedidos > 7,
       `foram ${pedidos} pedidos; uma rodada só são seis`);
    await t.parar();
  }

  // ---- 45h. sem a coluna, tudo como antes ----
  //
  // O estado real entre a entrega e o SQL rodado. Uma coisa nova não pode
  // derrubar o que já funcionava: a bolha continua existindo, o anexo continua
  // vazio como sempre esteve, e o log diz o que rodar.
  {
    const t = await subirTudo({ ESPERA_DO_ANEXO_MS: "300" },
      { uazapi: { recusaDefinitiva: "Message does not contain downloadable media" },
        semColunas: { mensagens: ["midia_erro"] } });
    await mandar(t, documentoDaUazapi("DOC-SEM-A-COLUNA"));
    await espera(1500);

    const m = mensagemDe(t, "DOC-SEM-A-COLUNA");
    ok("sem a coluna, a mensagem continua existindo", !!m);
    ok("e o log diz o que rodar para a tela poder avisar",
       /midia_erro.*não existe/s.test(t.registro.join(""))
       && /2026-09-o-anexo-que-nao-vem-mais\.sql/.test(t.registro.join("")),
       t.registro.join("").slice(-600));
    await t.parar();
  }
}


// ==================================================================
//  46. A PORTA DIZ O QUE NÃO BATE
//
//  Em 10/09, com os 115 documentos vazios esperando: "O ?token= não confere
//  com o IMPORT_TOKEN deste servidor. A variável existe — o que não bate é o
//  valor. O engano mais comum é um espaço em branco colado junto no começo ou
//  no fim."
//
//  O palpite estava errado, e era o único que a porta tinha. Quem está do
//  outro lado fica comparando dois textos longos de olho, caractere a
//  caractere, sem saber o que procurar.
//
//  O ENDEREÇO DE NAVEGADOR MEXE NO QUE PASSA POR ELE: um "+" dentro do token
//  vira ESPAÇO no caminho, e um "#" corta o endereço ali. Nos dois casos a
//  pessoa jura ter colado o valor certo, e colou.
//
//  E O VALOR NUNCA APARECE. As pistas só são ditas quando o que veio já É o
//  token a menos de uma transformação — quem chega nelas já tem a senha
//  inteira. Nada aqui confirma PEDAÇO de senha: um "você acertou o começo"
//  transformaria a porta numa máquina de adivinhar letra por letra, e é a
//  conferência mais importante desta seção.
// ==================================================================
console.log("\n46. A porta diz o que não bate");
{
  const SENHA = "ab+cd-EFGH-1234";
  const t = await subirTudo({ IMPORT_TOKEN: SENHA });
  const bater = async (token) => {
    const url = `http://127.0.0.1:${t.porta}/anexos/resgatar?token=${token}`;
    const r = await fetch(url);
    return { status: r.status, texto: await r.text() };
  };

  // O "+" COLADO CRU, que é o caso do relato: o navegador o entrega como
  // espaço, e o token chega diferente do que está no Render.
  const comMais = await bater("ab+cd-EFGH-1234");
  ok("o '+' colado cru é recusado, como tem de ser", comMais.status === 403);
  // O QUE SÓ ESTE RAMO DIZ, e não o que o texto genérico também diria.
  //
  // A primeira versão desta conferência procurava "%2B" e "vira espaço" — e as
  // duas expressões estão TAMBÉM na lista genérica que a porta manda quando
  // não reconhece o engano. Quer dizer que ela passaria com o ramo do "+"
  // apagado, aprovando um diagnóstico que não foi feito. Foi a sabotagem que
  // mostrou isso; sem ela, ficaria verde para sempre falando de outro assunto.
  ok("e a porta explica que o '+' virou espaço no endereço",
     /É o token certo, mas ele tem/.test(comMais.texto) && /%2B/.test(comMais.texto),
     comMais.texto.slice(0, 200));

  // ESCRITO DO JEITO CERTO, a mesma senha entra.
  const certo = await bater("ab%2Bcd-EFGH-1234");
  ok("e com %2B no lugar do '+' a porta abre", certo.status === 200,
     certo.texto.slice(0, 160));

  const comEspaco = await bater(encodeURIComponent("  ab+cd-EFGH-1234 "));
  ok("espaço em volta continua sendo dito", /espaço em branco colado em volta/.test(comEspaco.texto),
     comEspaco.texto.slice(0, 200));

  // O ESPAÇO DO LADO DE LÁ. Uma ponte cuja variável foi criada com uma quebra
  // de linha colada junto: quem confere de olho no Render vê o texto certo, e
  // não vê o que está depois dele. Mandar o valor certo continua sendo recusado,
  // e mexer no endereço não conserta — o conserto é editar a variável.
  {
    const t2 = await subirTudo({ IMPORT_TOKEN: "abcd-1234\n" });
    const r = await fetch(`http://127.0.0.1:${t2.porta}/anexos/resgatar?token=abcd-1234`);
    const texto = await r.text();
    ok("quando o espaço está no valor guardado, ela aponta para o Render",
       r.status === 403 && /GUARDADO no Render/.test(texto), texto.slice(0, 220));
    await t2.parar();
  }

  const exemplo = await bater("SEU_IMPORT_TOKEN");
  ok("quem cola o exemplo ouve que colou o exemplo",
     /colou o exemplo/.test(exemplo.texto), exemplo.texto.slice(0, 200));

  const caixa = await bater(encodeURIComponent("AB+CD-efgh-1234"));
  ok("maiúscula trocada por minúscula é dita", /maiúscula/.test(caixa.texto),
     caixa.texto.slice(0, 200));

  const semNada = await fetch(`http://127.0.0.1:${t.porta}/anexos/resgatar`);
  const semNadaTexto = await semNada.text();
  ok("sem ?token= nenhum, ela ensina onde ele entra",
     /Não veio \?token=/.test(semNadaTexto), semNadaTexto.slice(0, 200));

  // ------------------------------------------------------------
  //  A CONFERÊNCIA QUE IMPEDE O CONSERTO ESPERTO DEMAIS
  //
  //  Dizer "você acertou o começo" seria a pista mais útil de todas, e é
  //  justamente a que não se pode dar: com ela, adivinha-se a senha letra por
  //  letra, e uma senha de vinte caracteres cai em algumas centenas de
  //  tentativas.
  // ------------------------------------------------------------
  //
  // A CONFERÊNCIA É DE INDISTINGUIBILIDADE, e não de palavras proibidas.
  //
  // A primeira versão procurava as palavras "começo", "acertou" e afins no
  // texto — e reprovava a frase genérica, que tem "no começo ou no fim" num
  // sentido inocente. Pior do que o falso alarme: procurar palavra não mede o
  // que importa. O que importa é que "ab", que É o começo do token, receba
  // EXATAMENTE a mesma resposta que "zz", que não é nada. Byte a byte.
  const pedaco = await bater("ab");
  const nada = await bater("zz");
  ok("um pedaço certo do token responde igualzinho a um palpite qualquer",
     pedaco.status === 403 && pedaco.status === nada.status
     && pedaco.texto === nada.texto,
     `pedaço: ${pedaco.texto.slice(0, 90)} | qualquer: ${nada.texto.slice(0, 90)}`);
  ok("e o valor de verdade não aparece em resposta nenhuma",
     ![comMais, comEspaco, exemplo, caixa, pedaco, nada].some((r) => r.texto.includes(SENHA))
     && !semNadaTexto.includes(SENHA));

  // A PORTA DO HISTÓRICO É A MESMA PORTA. Eram duas cópias da mesma frase, e
  // consertar uma deixaria a outra com o palpite velho.
  const hist = await fetch(`http://127.0.0.1:${t.porta}/importar-historico?token=ab+cd-EFGH-1234`);
  const histTexto = await hist.text();
  ok("o importador de histórico ganha a mesma explicação",
     /%2B/.test(histTexto), histTexto.slice(0, 200));

  await t.parar();
}


// ==================================================================
//  47. O QUE NUNCA FOI DOCUMENTO
//
//  MEDIDO em 11/09, cruzando os 35 anexos vazios com o evento cru que a Uazapi
//  mandou. Dos vinte que ela ainda conhecia, NENHUM era documento:
//
//      link com prévia (ExtendedTextMessage)   5
//      contato compartilhado (vcard)           6
//      localização e localização ao vivo       4
//      mensagem de modelo, de marketing        4
//      "não foi possível descriptografar"      2
//
//  A regra `if (m.type === 'media') return 'documento'` era a rede para o
//  anexo que a Uazapi anunciasse de um jeito novo, e pegava tudo isto junto. A
//  bolha virava "Documento — indisponível", a ponte saía pedindo um arquivo
//  que não existe, e a Uazapi respondia com todas as letras: "Message does not
//  contain downloadable media".
//
//  E NÃO ERA SÓ A BOLHA ERRADA, era conteúdo PERDIDO: um link do eproc e um
//  documento do Adobe chegaram como balão vazio, porque o texto deles mora em
//  `content.text` e o código só olhava `m.text`.
//
//  Os corpos abaixo são os do banco, copiados como vieram.
// ==================================================================
console.log("\n47. O que nunca foi documento");
{
  const CHAT = "5511999998888@s.whatsapp.net";
  const t = await subirTudo({}, { uazapi: { rotaDeDownload: null } });
  const mandar = (corpo) => fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(corpo),
  });
  const evento = (id, campos) => ({
    EventType: "messages",
    owner: TELEFONE.numero,
    message: {
      id, messageid: id, chatid: CHAT, sender: CHAT, fromMe: false, isGroup: false,
      type: "media", messageTimestamp: Date.now(), wasSentByApi: false,
      senderName: "Cliente", ...campos,
    },
  });
  const achar = (id) => (t.sb.dados.mensagens || []).find((m) => m.id_uazapi === id);

  // ---- a localização, que é a bolha da foto do escritório ----
  await mandar(evento("EV-LOCAL", {
    messageType: "LocationMessage", mediaType: "location",
    content: { degreesLatitude: -20.4697, degreesLongitude: -54.6201,
               JPEGThumbnail: "/9j/4AAQSkZJRgABAQAA" },
  }));
  // ---- o contato compartilhado ----
  await mandar(evento("EV-CONTATO", {
    messageType: "ContactMessage", mediaType: "vcard",
    content: { displayName: "Atendimento Canaverde",
               vcard: "BEGIN:VCARD\nVERSION:3.0\nN:;Atendimento Canaverde;;;\n"
                    + "FN:Atendimento Canaverde\nTEL;type=CELL;waid=5511969401932:+55 11 96940-1932\nEND:VCARD" },
  }));
  // ---- o link com prévia: o do eproc, que sumiu de verdade ----
  await mandar(evento("EV-LINK", {
    messageType: "ExtendedTextMessage", mediaType: "url",
    content: { text: "https://eproc2g.tjsp.jus.br/eproc/controlador.php?acao=processo_cadastrar_4",
               title: ":: eproc ::", matchedText: "https://eproc2g.tjsp.jus.br/" },
  }));
  // ---- a mensagem de modelo, que vinha como imagem vazia ----
  await mandar(evento("EV-MODELO", {
    messageType: "TemplateMessage", mediaType: "image",
    content: { Format: { InteractiveMessageTemplate: {
      body: { text: "Seu cartão está com limite pré-aprovado!" } } } },
  }));
  // ---- A RESPOSTA DE BOTÃO, que não é anexo nenhum ----
  //
  // MEDIDA em 12/09, no evento cru guardado pela caixa de entrada: `type` vem
  // como "media" e `mediaType` como "buttons_response", e o texto da resposta
  // mora em `content.Response`. Era o que restava escapando da rede de
  // segurança — e o estrago é de outra natureza: não é um anexo que se perdeu,
  // é uma RESPOSTA DO CLIENTE que nunca apareceu na tela. Ele tocou em "Sim" e
  // o escritório viu "Documento — indisponível".
  await mandar(evento("EV-BOTAO", {
    messageType: "ButtonsResponseMessage", mediaType: "buttons_response",
    content: { type: "response", Response: "Sim, pode enviar o acordo",
               selectedButtonID: "btn_1", contextInfo: {} },
  }));
  // ---- a mesma coisa sem texto legível: só o id de máquina ----
  await mandar(evento("EV-BOTAO-MUDO", {
    messageType: "ButtonsResponseMessage", mediaType: "buttons_response",
    content: { type: "response", selectedButtonID: "btn_7", contextInfo: {} },
  }));
  // ---- a que o WhatsApp não conseguiu abrir ----
  await mandar(evento("EV-CIFRADA", {
    messageType: "error", mediaType: null,
    content: "[Undecryptable] [media] [collection] Não foi possível descriptografar a mensagem.",
  }));
  await espera(2000);

  const local = achar("EV-LOCAL");
  ok("a localização deixa de ser 'documento'", local && local.tipo === "texto",
     `veio tipo ${local && local.tipo}`);
  ok("e a bolha leva o endereço do mapa, que é o que serve ao atendimento",
     local && /maps\?q=-20\.4697,-54\.6201/.test(local.texto || ""),
     `dizia: ${local && local.texto}`);

  const contato = achar("EV-CONTATO");
  ok("o contato compartilhado vira contato, com nome e telefone",
     contato && contato.tipo === "texto"
     && /Atendimento Canaverde/.test(contato.texto || "")
     && /96940-1932/.test(contato.texto || ""),
     `dizia: ${contato && contato.texto}`);

  // O QUE MAIS DOEU: conteúdo perdido, e não só bolha feia.
  const link = achar("EV-LINK");
  ok("o link com prévia chega com o link dentro",
     link && /eproc2g\.tjsp\.jus\.br/.test(link.texto || ""),
     `dizia: ${link && link.texto}`);

  const modelo = achar("EV-MODELO");
  ok("a mensagem de modelo chega com o texto dela",
     modelo && /limite pré-aprovado/.test(modelo.texto || ""),
     `dizia: ${modelo && modelo.texto}`);

  const cifrada = achar("EV-CIFRADA");
  ok("a que não pôde ser aberta diz isso, e diz o que fazer",
     cifrada && /não conseguiu/i.test(cifrada.texto || "")
     && /enviar de novo/i.test(cifrada.texto || ""),
     `dizia: ${cifrada && cifrada.texto}`);

  const botao = achar("EV-BOTAO");
  ok("a resposta de botão deixa de ser 'documento'",
     botao && botao.tipo === "texto", `veio tipo ${botao && botao.tipo}`);
  // O QUE O CLIENTE RESPONDEU, na bolha. Sem isto o conserto seria só trocar
  // uma bolha errada por uma bolha vazia — a resposta dele continuaria perdida.
  ok("e a bolha traz o que ele respondeu",
     botao && /Sim, pode enviar o acordo/.test(botao.texto || ""),
     `dizia: ${botao && botao.texto}`);
  // SEM DECORAÇÃO. A palavra que ele tocou É a resposta dele, e é assim que o
  // próprio WhatsApp a mostra; "Respondeu: Sim" seria a ponte narrando por
  // cima do cliente.
  ok("e sem a ponte narrando por cima dele",
     botao && !/respondeu/i.test(botao.texto || ""), `dizia: ${botao && botao.texto}`);

  const mudo = achar("EV-BOTAO-MUDO");
  ok("sem texto legível, a bolha diz o que houve",
     mudo && /tocando num botão/i.test(mudo.texto || ""), `dizia: ${mudo && mudo.texto}`);
  // O ID DO BOTÃO É COISA DE MÁQUINA. Pô-lo na bolha seria mostrar jargão
  // fingindo que é a palavra de alguém.
  ok("e nunca mostra o id do botão como se fosse a palavra do cliente",
     mudo && !/btn_7/.test(mudo.texto || ""), `dizia: ${mudo && mudo.texto}`);

  // ------------------------------------------------------------
  //  E NENHUMA DELAS SAI PEDINDO ARQUIVO
  //
  //  Pedir o arquivo de uma localização é uma ida à rede que só pode falhar —
  //  e, com a insistência, são três tentativas vezes seis caminhos por
  //  mensagem, num serviço que tem limite de uso.
  // ------------------------------------------------------------
  const pedidos = t.uaz.recebidas.filter((c) => String(c.caminho).includes("download"));
  ok("e nenhuma delas sai pedindo arquivo à Uazapi", pedidos.length === 0,
     `foram ${pedidos.length} idas`);

  // O DOCUMENTO DE VERDADE CONTINUA SENDO DOCUMENTO. Sem isto, o conserto
  // poderia ter jogado fora o caso que funciona.
  await mandar(evento("EV-DOC", {
    messageType: "documentMessage", mediaType: "document",
    content: { mimetype: "application/pdf", fileName: "peticao.pdf" },
  }));
  await espera(1200);
  const doc = achar("EV-DOC");
  ok("e o documento de verdade continua sendo documento",
     doc && doc.tipo === "documento", `veio tipo ${doc && doc.tipo}`);

  await t.parar();
}


// ==================================================================
//  48. DESATIVAR TEM DE DESATIVAR
// ==================================================================
//
//  `advogados.ativo = false` só tirava o telefone do SELETOR do painel. Nada
//  mais olhava para ele — nem a fila de envio, nem o caminho automático dos
//  avisos de audiência. Quer dizer: uma linha que o escritório considera
//  desligada continuava mandando mensagem para cliente.
//
//  E no pior formato possível: ninguém escolheu, e ninguém vê. O telefone
//  sumiu da tela, então não há para onde olhar para perceber.
//
//  O CAMINHO AUTOMÁTICO É O QUE MAIS ASSUSTA. O Vantoro pede, a ponte escolhe
//  a linha e manda, sem ninguém no meio. Um advogado sai do escritório, é
//  desativado, e os clientes dele continuam recebendo avisos de audiência em
//  nome dele.
//
//  O QUE ESTA SEÇÃO NÃO PROVA, de propósito: que a linha desativada pare de
//  RECEBER. Ela continua recebendo, e isso é decisão, não esquecimento —
//  perder mensagem de cliente é o pior desfecho deste sistema, e um número
//  desativado continua sendo um número para onde clientes escrevem.
// ==================================================================
console.log("\n48. Desativar tem de desativar");
{
  const enfileirar = async (t, ativo) => {
    t.sb.dados.advogados[0].ativo = ativo;
    t.sb.dados.contatos.push({ id: 1, numero: "5511999998888", nome: "Cliente" });
    t.sb.dados.conversas.push({ id: 1, advogado_id: TELEFONE.id, contato_id: 1 });
    t.sb.dados.fila_envio.push({
      id: 1, conversa_id: 1, tipo: "texto", texto: "Bom dia", status: "pendente",
      tentativas: 0, criado_em: new Date().toISOString(),
    });
    await fetch(`http://127.0.0.1:${t.porta}/ping`);
    await espera(1600);
    return t.sb.dados.fila_envio.find((f) => f.id === 1);
  };

  // ---- 48a. a linha desativada não envia ----
  {
    const t = await subirTudo({});
    const linha = await enfileirar(t, false);
    ok("a mensagem NÃO sai por uma linha desativada", linha?.status === "erro",
       `ficou ${linha?.status}`);
    // A UAZAPI NEM É PROCURADA. Recusar depois de já ter mandado não recusaria
    // nada — o cliente já teria recebido.
    const enviados = t.uaz.recebidas.filter((c) => /\/send\//.test(c.caminho)).length;
    ok("e a Uazapi nem chega a ser procurada", enviados === 0,
       `foram ${enviados} envio(s)`);
    ok("a tela diz que a linha está desativada, e o que fazer",
       /desativada/i.test(linha?.erro_motivo || "")
       && /outro telefone/i.test(linha?.erro_motivo || ""),
       JSON.stringify(linha?.erro_motivo));
    await t.parar();
  }

  // ---- 48b. e a linha ATIVA continua enviando ----
  //
  // A metade que segura a régua. Sem ela, bastaria recusar tudo para a de cima
  // passar — e aí o escritório inteiro ficaria mudo.
  {
    const t = await subirTudo({});
    const linha = await enfileirar(t, true);
    ok("a linha ativa continua enviando normalmente", linha?.status === "enviada",
       `ficou ${linha?.status}`);
    await t.parar();
  }

  // ---- 48c. base antiga, com a coluna nula ----
  //
  // Tratar nulo como desativado calaria o escritório inteiro de uma vez — o
  // oposto do que este conserto existe para fazer. Só o `false` explícito
  // desativa.
  {
    const t = await subirTudo({});
    const linha = await enfileirar(t, null);
    ok("coluna nula NÃO é linha desativada", linha?.status === "enviada",
       `ficou ${linha?.status}`);
    await t.parar();
  }

  // ---- 48d. o aviso de audiência não sai por linha desativada ----
  {
    const t = await subirTudo({ AVISOS_INTERVALO_MS: "500" }, {
      vantoro: { avisos: [{ id: "AV-1", telefone: "11999998888",
                            texto: "Sua audiência é amanhã às 14h.",
                            remetente: TELEFONE.numero, finalidade: "CLIENTE" }] },
    });
    t.sb.dados.advogados[0].ativo = false;
    await espera(5000);   // a rodada roda 4s depois de subir

    const naFila = (t.sb.dados.fila_envio || []).length;
    ok("o aviso NÃO é enfileirado por uma linha desativada", naFila === 0,
       `foram ${naFila} item(ns) para a fila`);
    // O MOTIVO VOLTA PARA O VANTORO. Calando aqui, o aviso sumiria e o cliente
    // faltaria à audiência sem ninguém saber por quê.
    //
    // E O TEXTO É CONFERIDO, não só a chamada. Esta conferência era
    // `recebidas.some(caminho === /avisos/AV-1/erro)` e PASSAVA mesmo com a
    // proteção deste caminho arrancada — porque, sem ela, o aviso ia para a
    // fila e a OUTRA proteção (a do envio) o recusava e avisava o Vantoro
    // pelo mesmo endereço. Ela dizia "este caminho avisou" e media "alguém
    // avisou".
    //
    // As duas frases são diferentes de propósito, e é só por isso que dá para
    // distinguir: só a deste caminho manda REATIVAR a linha.
    const erroDoVantoro = t.van.recebidas.find(
      (c) => /\/avisos\/AV-1\/erro$/.test(c.caminho));
    ok("e o Vantoro fica sabendo por que o aviso não saiu, por ESTE caminho",
       /desativada/i.test(erroDoVantoro?.corpo?.motivo || "")
       && /reative/i.test(erroDoVantoro?.corpo?.motivo || ""),
       JSON.stringify(erroDoVantoro?.corpo || t.van.recebidas.map((c) => c.caminho)));
    await t.parar();
  }

  // ---- 48e. com a linha ativa, o aviso sai ----
  {
    const t = await subirTudo({ AVISOS_INTERVALO_MS: "500" }, {
      vantoro: { avisos: [{ id: "AV-2", telefone: "11999998888",
                            texto: "Sua audiência é amanhã às 14h.",
                            remetente: TELEFONE.numero, finalidade: "CLIENTE" }] },
    });
    await espera(6000);
    const saiu = (t.sb.dados.fila_envio || []).some((f) => /audiência/i.test(f.texto || ""));
    ok("com a linha ativa, o aviso de audiência continua saindo", saiu,
       JSON.stringify(t.sb.dados.fila_envio));
    await t.parar();
  }
}


// ==================================================================
//  49. QUANTO O VANTORO DEMORA — medido, e não adivinhado
// ==================================================================
//
//  Relato de 14/09: "está demorando para aparecer o resultado do Vantoro.
//  Demora, mas aparece."
//
//  Demora QUANTO? Ninguém sabia dizer. Havia três explicações plausíveis à
//  mão — o Vantoro hibernando, a consulta do cadastro, a própria ponte — e
//  escolher entre elas de olho é como se conserta o que não está quebrado.
//  Neste projeto isso já custou uma rodada inteira: o "documento indisponível"
//  teve dois consertos CERTOS antes de a medição mostrar que vinte dos trinta
//  e cinco casos nunca tinham sido documentos.
//
//  O QUE ESTA SEÇÃO VIGIA, e a ordem é a da gravidade:
//
//    1. que o que foi PERGUNTADO não fique guardado. A busca vai na consulta
//       do endereço — nome e CPF de cliente —, e uma janela de diagnóstico que
//       vaza cadastro é pior do que não existir;
//    2. que a conta seja de UMA rota, e não de um cliente: `/clientes/123` e
//       `/clientes/456` são a mesma pergunta, e guardadas separadas fariam a
//       tabela crescer sem fim, com o id de cada cliente dentro dela;
//    3. que o número BATA com a demora de verdade — inclusive a espera do
//       "acordando", que é tempo que quem procurou esperou;
//    4. que a chamada que não voltou conte como falha em vez de sumir: uma
//       média feita só do que deu certo diria "tudo rápido" justamente quando
//       o que incomoda é a que não voltou;
//    5. e que a porta seja do administrador.
// ==================================================================
console.log("\n49. Quanto o Vantoro demora");
{
  const SENHA = "senha-do-escritorio";
  const comBilhete = { Authorization: "Bearer jwt-bom" };
  const tempos = async (t, extra = "") => {
    const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/tempos?token=${SENHA}${extra}`);
    return { status: r.status, texto: await r.text() };
  };
  const emJson = async (t) => {
    const r = await tempos(t, "&formato=json");
    return JSON.parse(r.texto);
  };
  const linhaDe = (json, onde) => (json.linhas || []).find((l) => l.onde === onde);

  // ---- 49a. o que foi perguntado NÃO fica guardado ----
  {
    // A CONFERÊNCIA MAIS IMPORTANTE DA SEÇÃO. O termo da busca é o nome do
    // cliente, e o outro caminho leva o CPF. Guardá-los para "ver os tempos
    // depois" transformaria uma janela de manutenção num vazamento de cadastro
    // — e ninguém iria procurar por ele ali.
    const t = await subirTudo({ IMPORT_TOKEN: SENHA }, { vantoro: {} });
    await fetch(`http://127.0.0.1:${t.porta}/vantoro/buscar?q=ELIANA%20ALVES%20DA%20SILVA`,
                { headers: comBilhete });
    await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente?cpf=52998224725`,
                { headers: comBilhete });

    const { texto } = await tempos(t);
    const json = await emJson(t);
    const tudo = texto + JSON.stringify(json) + t.registro.join("");
    ok("o nome procurado não aparece na janela nem no log", !/ELIANA/i.test(tudo),
       tudo.slice(0, 300));
    ok("nem o CPF", !/52998224725/.test(tudo), tudo.slice(0, 300));
    // E A MEDIÇÃO ACONTECEU MESMO ASSIM: sem isto, a conferência de cima
    // passaria com o cronômetro inteiro arrancado — nada guardado, nada
    // vazado, nada medido.
    //
    // CADA PERGUNTA NA SUA LINHA. Procurar por nome e achar por telefone vão
    // ao MESMO caminho do Vantoro (`/clientes/buscar`) e são trabalhos muito
    // diferentes: uma varre o cadastro por texto e ainda procura processo sem
    // dono; a outra acha pelo telefone e devolve no máximo cinco. Somadas numa
    // linha só, o "típico" não é o típico de nenhuma das duas — foi o que a
    // primeira leitura de verdade mostrou, em 14/09.
    // A CHAVE LEVA O `leve` JUNTO desde que a ponte passou a pedir o resumo
    // curto — é o cronômetro contando a verdade, e não um detalhe de escrita.
    ok("a busca por nome tem a linha dela",
       (linhaDe(json, "vantoro GET /clientes/buscar?leve&q") || {}).chamadas === 1,
       JSON.stringify(json.linhas));
    ok("e a busca por CPF, a dela",
       (linhaDe(json, "vantoro GET /clientes/buscar?cpf") || {}).chamadas === 1,
       JSON.stringify(json.linhas));
    await t.parar();
  }

  // ---- 49b. um cliente por linha não faz uma linha por cliente ----
  {
    const t = await subirTudo({ IMPORT_TOKEN: SENHA }, { vantoro: {} });
    for (const id of [123, 456, 789]) {
      await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente/${id}`, { headers: comBilhete });
    }
    const json = await emJson(t);
    const daFicha = (json.linhas || []).filter((l) => /^vantoro GET \/clientes\//.test(l.onde));
    ok("três fichas diferentes viram UMA linha só", daFicha.length === 1,
       JSON.stringify(daFicha.map((l) => l.onde)));
    ok("e ela conta as três", (daFicha[0] || {}).chamadas === 3, JSON.stringify(daFicha));
    ok("com os ids fora da chave", /:id/.test((daFicha[0] || {}).onde || ""),
       (daFicha[0] || {}).onde);
    await t.parar();
  }

  // ---- 49c. o número bate com a demora de verdade ----
  {
    // O VANTORO DE MENTIRA DEMORA 400ms DE PROPÓSITO. Um cronômetro que
    // sempre diz zero também "mede", e passaria em tudo o que confere só a
    // existência da linha.
    const t = await subirTudo({ IMPORT_TOKEN: SENHA }, { vantoro: { demora: 400 } });
    // TRÊS LETRAS, E NÃO DUAS: com menos que isso a rota responde "digite ao
    // menos 3" sem chegar a falar com o Vantoro — e não haveria tempo nenhum
    // para medir. Foi o que esta conferência fez na primeira vez que rodou.
    await fetch(`http://127.0.0.1:${t.porta}/vantoro/buscar?q=abc`, { headers: comBilhete });
    const json = await emJson(t);

    const doVantoro = linhaDe(json, "vantoro GET /clientes/buscar?leve&q");
    ok("o tempo medido bate com a demora de verdade",
       doVantoro && doVantoro.tipico_ms >= 350 && doVantoro.tipico_ms < 3000,
       JSON.stringify(doVantoro));

    // AS DUAS MEDIDAS, e é nisto que está a resposta da pergunta: a de cima é
    // o que o navegador espera, a de baixo é o que o Vantoro leva por dentro.
    // Com uma medida só não dá para saber de quem é o tempo.
    const daPonte = linhaDe(json, "ponte GET /vantoro/buscar");
    ok("e o pedido inteiro é medido separado", !!daPonte, JSON.stringify(json.linhas));
    ok("valendo pelo menos o que a ida ao Vantoro valeu",
       !!daPonte && !!doVantoro && daPonte.tipico_ms >= doVantoro.tipico_ms,
       `ponte ${daPonte && daPonte.tipico_ms}ms / vantoro ${doVantoro && doVantoro.tipico_ms}ms`);

    const { texto } = await tempos(t);
    ok("a janela responde em texto que se lê de olho",
       /TEMPOS DAS IDAS AO VANTORO/.test(texto) && /vantoro GET \/clientes\/buscar\?leve&q\b/.test(texto),
       texto.slice(0, 300));
    // ELA DIZ QUE ZERA. Sem esta frase, "12 chamadas" lido numa segunda de
    // manhã parece "o escritório quase não usa" — quando o que houve foi a
    // Render reiniciar o serviço.
    ok("e avisa que a conta zera quando o serviço reinicia", /ZERA a cada reinício/.test(texto),
       texto.slice(0, 400));
    await t.parar();
  }

  // ---- 49d. a espera do "acordando" entra na conta ----
  {
    // O CASO QUE DÁ SENTIDO AO RESTO. Quando a Render devolve a página de
    // "serviço subindo", a ponte espera 6s e tenta de novo. Um cronômetro em
    // volta só dos `fetch` contaria "duas chamadas de 200ms" para uma espera
    // de sete segundos — e diria que está tudo rápido enquanto a pessoa olha
    // a tela parada.
    //
    // JANELA DE MANUTENÇÃO FECHADA (`VANTORO_ACORDADO_ATE: "0"`), como na
    // seção que mede o reenvio: com ela aberta, o ping que mantém o Vantoro
    // acordado absorve a primeira resposta "dormindo" e a espera nunca chega a
    // acontecer — a conferência media uma chamada comum de 4ms e reprovava
    // sem que houvesse nada errado no cronômetro. Foi o que ela fez na
    // primeira rodada.
    const t = await subirTudo({ IMPORT_TOKEN: SENHA, VANTORO_ACORDADO_ATE: "0" },
                              { vantoro: { dormeAsPrimeiras: 1 } });
    await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente?telefone=5511999998888`,
                { headers: comBilhete });
    const json = await emJson(t);
    const linha = linhaDe(json, "vantoro GET /clientes/buscar?telefone");
    ok("a espera pelo Vantoro acordar é contada", linha && linha.pior_ms >= 6000,
       JSON.stringify(linha));
    ok("e a chamada é marcada como lenta", linha && linha.lentas >= 1, JSON.stringify(linha));
    // A LINHA DIZ DE QUAL MEDIDA ELA É. Sem o `vantoro` no padrão, esta
    // conferência passava com a espera arrancada do cronômetro da ida: o
    // pedido inteiro é medido à parte, também passou dos 3s, e logou sozinho.
    // Ela dizia "a ida lenta deixou rastro" e media "alguma coisa lenta
    // deixou rastro" — foi a sabotagem que mostrou.
    ok("com uma linha no log, dizendo que foi a ida ao Vantoro",
       /Vantoro devagar: vantoro GET/.test(t.registro.join("")),
       t.registro.join("").slice(-400));
    await t.parar();
  }

  // ---- 49e. a chamada que não volta conta como falha ----
  {
    // Uma média feita só do que deu certo diz "tudo rápido" justamente quando
    // o que incomoda é a chamada que não voltou. A falha tem coluna própria.
    const morto = http.createServer(() => {});
    await new Promise((r) => morto.listen(0, "127.0.0.1", r));
    const porta = morto.address().port;
    await new Promise((r) => morto.close(r));   // agora ninguém atende ali

    const t = await subirTudo({ IMPORT_TOKEN: SENHA,
                                VANTORO_API_URL: `http://127.0.0.1:${porta}`,
                                VANTORO_API_TOKEN: "tok" });
    const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/buscar?q=abc`, { headers: comBilhete });
    ok("a chamada realmente falhou", r.status >= 500, `veio ${r.status}`);

    const json = await emJson(t);
    const linha = linhaDe(json, "vantoro GET /clientes/buscar?leve&q");
    ok("ela é contada", linha && linha.chamadas === 1, JSON.stringify(json.linhas));
    ok("e marcada como falha, em vez de sumir da conta",
       linha && linha.falhas === 1, JSON.stringify(linha));
    await t.parar();
  }

  // ---- 49f. a porta é do administrador ----
  {
    const t = await subirTudo({ IMPORT_TOKEN: SENHA }, { vantoro: {} });
    const semToken = await fetch(`http://127.0.0.1:${t.porta}/vantoro/tempos`);
    ok("sem o token, a janela não abre", semToken.status === 403, `veio ${semToken.status}`);
    const errado = await fetch(`http://127.0.0.1:${t.porta}/vantoro/tempos?token=quase`);
    ok("com o token errado, também não", errado.status === 403, `veio ${errado.status}`);
    const certo = await fetch(`http://127.0.0.1:${t.porta}/vantoro/tempos?token=${SENHA}`);
    ok("com o certo, abre", certo.status === 200, `veio ${certo.status}`);
    await t.parar();
  }

  // ---- 49g. sem chamada nenhuma, ela diz isso ----
  {
    // Uma tabela vazia sem uma palavra parece defeito da janela. Ela tem de
    // dizer que não houve chamada, que é outra coisa.
    const t = await subirTudo({ IMPORT_TOKEN: SENHA }, { vantoro: {} });
    const { texto } = await tempos(t);
    ok("sem chamada nenhuma, a janela diz isso em vez de aparecer vazia",
       /Nenhuma chamada ao Vantoro/.test(texto), texto.slice(0, 400));
    await t.parar();
  }
}

// ==================================================================
//  50. A BUSCA PEDE SÓ O QUE O PAINEL USA
// ==================================================================
//
//  Medido em 14/09, com o cronômetro dos dois lados. A busca do cadastro
//  custava 1532ms vista daqui, e o Vantoro gastava 1250ms disso esperando o
//  banco — 99% do tempo dele.
//
//  E não era a consulta. Cada ida e volta ao Postgres custa ~180ms de lá, e a
//  conta fecha rota por rota: uma ida 180ms, três idas 534ms, sete idas
//  1261ms. Um pedido sem consulta nenhuma custa ZERO. Não é trabalho de banco,
//  é distância — e o preço de um pedido é quantas idas ele faz.
//
//  Das sete da busca, quatro montavam processos, documentos, telefones e
//  pendências de até vinte fichas. Os dois lugares do painel que leem esta
//  resposta usam QUATRO campos: id, nome, telefone, telefone2.
//
//  Agora ela pede `leve=1`. Sobram duas idas.
//
//  O QUE ESTA SEÇÃO VIGIA:
//
//    1. que a ponte REALMENTE peça o resumo curto — sem isso o conserto está
//       no Vantoro e ninguém o usa;
//    2. que o painel continue recebendo os quatro campos de que vive;
//    3. e que a FICHA INTEIRA continue vindo inteira: é ela que abre o cadastro
//       na conversa, e cortá-la ali seria trocar um problema por outro bem
//       pior.
// ==================================================================
console.log("\n50. A busca pede só o que o painel usa");
{
  const comBilhete = { Authorization: "Bearer jwt-bom" };

  // ---- 50a. a ponte pede o resumo curto ----
  {
    const t = await subirTudo({}, { vantoro: {} });
    await fetch(`http://127.0.0.1:${t.porta}/vantoro/buscar?q=eliana`, { headers: comBilhete });

    const pedido = t.van.recebidas.find((c) => c.caminho === "/clientes/buscar");
    ok("a ponte chegou a perguntar ao Vantoro", !!pedido,
       JSON.stringify(t.van.recebidas.map((c) => c.caminho)));
    // A CONFERÊNCIA DO CONSERTO. Sem ela, o `leve=1` pode cair do endereço numa
    // edição e nada na bancada reclama: a resposta continua chegando, só que
    // cinco viagens mais cara — e lentidão não quebra prova nenhuma.
    ok("pedindo o resumo curto", /(^|[?&])leve=1(&|$)/.test(pedido?.busca || ""),
       `foi com "${pedido?.busca}"`);
    ok("e com o termo que veio da tela", /[?&]q=eliana/.test(pedido?.busca || ""),
       pedido?.busca);
    await t.parar();
  }

  // ---- 50b. e o painel continua recebendo os quatro campos de que vive ----
  {
    // O falso Vantoro faz o mesmo recorte do de verdade quando lhe pedem leve.
    // Sem isso esta conferência mediria o falso: ele devolvia `{ok:true}` seco,
    // e nada que dependa da FORMA da busca podia ser provado.
    const t = await subirTudo({}, { vantoro: { clientes: [{
      id: 7, nome: "ELIANA ALVES DA SILVA", cpf: "529.982.247-25",
      telefone: "5511967973545", telefone2: "", email: "e@x.com",
      processos: [{ numero: "1" }], telefones: [{ numero: "5511967973545" }],
    }] } });
    const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/buscar?q=eliana`,
                          { headers: comBilhete });
    ok("a busca responde 200", r.status === 200, `veio ${r.status}`);
    const cliente = ((await r.json().catch(() => ({}))).clientes || [])[0];

    // OS QUATRO CAMPOS DE QUE O PAINEL VIVE. É com eles que a busca da lista
    // casa telefone com conversa e que a agenda oferece começar conversa.
    ok("o painel recebe id, nome e os dois telefones",
       cliente && cliente.id === 7 && /ELIANA/.test(cliente.nome)
       && cliente.telefone === "5511967973545" && "telefone2" in cliente,
       JSON.stringify(cliente));
    // E A RESPOSTA DIZ QUE É CURTA. Sem a marca, "sem processos" é o que se lê
    // de uma ficha que não os pediu — e quem lê "não tem" decide coisas.
    ok("e a ficha vem marcada como resumo", cliente && cliente.leve === true,
       JSON.stringify(cliente));
    ok("sem a carga que ninguém lê daqui", cliente && !("processos" in cliente),
       JSON.stringify(cliente));
    await t.parar();
  }

  // ---- 50c. a ficha inteira continua inteira ----
  {
    // A TRAVA CONTRA O CONSERTO QUE CORTA DEMAIS. É por esta rota que a ficha
    // do cliente abre na conversa, com processos, documentos e as pendências da
    // ordem de serviço. Pedir leve AQUI economizaria as mesmas viagens e
    // esvaziaria a tela que existe para mostrar exatamente isso.
    const t = await subirTudo({}, { vantoro: {} });
    await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente/77`, { headers: comBilhete });
    await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente?telefone=5511999998888`,
                { headers: comBilhete });

    const daFicha = t.van.recebidas.filter((c) => /^\/clientes\//.test(c.caminho)
                                                || c.caminho === "/clientes/buscar");
    ok("a ficha e a busca por telefone foram pedidas", daFicha.length === 2,
       JSON.stringify(t.van.recebidas.map((c) => c.caminho + c.busca)));
    ok("e NENHUMA delas pediu o resumo curto",
       daFicha.every((c) => !/leve=1/.test(c.busca || "")),
       JSON.stringify(daFicha.map((c) => c.caminho + c.busca)));
    await t.parar();
  }
}

// ==================================================================
//  51. OS SCRIPTS QUE SE APLICAM SOZINHOS
//
//  ESTA SEÇÃO NÃO USA O SUPABASE DE MENTIRA. Ela sobe um POSTGRES DE VERDADE e
//  aponta a ponte para ele, porque o que está sendo provado é `create table`,
//  `begin`/`rollback` e travas — coisas que um falso que fala PostgREST não tem
//  como ter. Um falso que respondesse "apliquei" provaria o falso.
//
//  Sem um Postgres à mão a seção é PULADA — mas nunca na integração contínua:
//  lá a ausência é FALHA. Prova que se pula sozinha no lugar onde importa é
//  prova que não existe, e este projeto já teve duas.
// ==================================================================
{
  console.log("\n51. Os scripts que se aplicam sozinhos");

  const BANCO_BASE = String(process.env.PROVA_DATABASE_URL || "").trim();

  if (!BANCO_BASE && process.env.CI) {
    ok("há um Postgres para provar os scripts automáticos (obrigatório na integração contínua)",
       false, "PROVA_DATABASE_URL não foi definida");
  } else if (!BANCO_BASE) {
    console.log("  (pulada: sem PROVA_DATABASE_URL. Na integração contínua isto seria FALHA.)");
  } else {
    const pg = await import("pg");

    const falarCom = async (url, sql, args) => {
      const c = new pg.Client({ connectionString: url, ssl: false });
      await c.connect();
      try { return await c.query(sql, args); } finally { await c.end(); }
    };

    /** Um banco novo, vazio, só desta conferência — para uma não sujar a outra. */
    async function bancoNovo() {
      const nome = `prova_${crypto.randomBytes(5).toString("hex")}`;
      await falarCom(BANCO_BASE, `create database ${nome}`);
      const u = new URL(BANCO_BASE);
      u.pathname = `/${nome}`;
      u.searchParams.set("sslmode", "disable");
      const url = u.toString();
      return {
        url,
        consultar: (sql, args) => falarCom(url, sql, args),
        /** true/false — a tabela existe mesmo no banco? */
        temTabela: async (t) => {
          const { rows } = await falarCom(url, "select to_regclass($1) as achou", [`public.${t}`]);
          return rows[0].achou !== null;
        },
      };
    }

    /** Escreve scripts de mentira numa pasta temporária e devolve o caminho. */
    const fs = await import("node:fs");
    const os = await import("node:os");
    const path = await import("node:path");
    function pastaCom(scripts) {
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), "scripts-"));
      for (const [nome, corpo] of Object.entries(scripts)) {
        fs.writeFileSync(path.join(dir, nome), corpo);
      }
      return dir;
    }

    // PONTE QUE NÃO SOBE ESTOURA, E AQUI ISSO ESTAVA ERRADO.
    //
    // `subirTudo` joga um erro quando a porta não responde, e nas outras 49
    // seções isso é o certo: ponte que não sobe é falha da bancada, e falha de
    // bancada tem de dizer o próprio nome.
    //
    // Nesta seção, não. Aqui a ponte SOBE e pode morrer logo depois, por causa
    // de um script — que é exatamente o defeito que esta seção existe para
    // caçar. Medido numa sabotagem: pondo `process.exit(1)` onde a ponte hoje
    // só anota a falha, o erro subia, a prova morria no meio, e a rodada
    // terminava SEM UMA LINHA DE FALHA — calada sobre o defeito. Por isso os
    // cenários com script quebrado sobem por aqui: ponte que não fica de pé
    // vira `null`, e `null` vira reprovação com nome logo abaixo.
    async function pontOuNada(banco, pasta, extra) {
      try { return await pontComScripts(banco, pasta, extra); }
      catch (_e) { return null; }
    }

    /** Sobe a ponte apontada para este banco e esta pasta, e espera a rodada. */
    async function pontComScripts(banco, pasta, extra = {}) {
      const t = await subirTudo({
        DATABASE_URL: banco ? banco.url : "",
        SCRIPTS_PASTA: pasta,
        ...extra,
      });
      // A rodada sai logo depois do listen. Espera-se o LOG dela, e não um
      // tempo fixo: tempo fixo passa a reprovar no dia em que a máquina do
      // GitHub estiver lenta, falando de outro assunto.
      for (let i = 0; i < 80; i++) {
        if (/Scripts autom[áa]ticos:/.test(t.registro.join(""))) break;
        await espera(100);
      }
      await espera(400);
      return t;
    }

    // ---- 51a. sem DATABASE_URL, tudo como antes ----
    {
      const b = await bancoNovo();
      const dir = pastaCom({ "001-cria.sql": "create table marca_a (n int);" });
      // A ponte sobe SEM o endereço, mas o banco existe e está ali do lado.
      const t = await pontComScripts(null, dir);
      ok("sem DATABASE_URL, a ponte diz que está desligado",
         /Scripts automáticos: desligados/.test(t.registro.join("")),
         t.registro.join("").slice(-400));
      ok("e NÃO cria a tabela do script no banco", (await b.temTabela("marca_a")) === false);
      ok("nem a tabela de controle", (await b.temTabela("zorvin_scripts_aplicados")) === false);
      await t.parar();
    }

    // ---- 51b. o padrão é conferir, e conferir não escreve nada ----
    {
      const b = await bancoNovo();
      const dir = pastaCom({ "001-cria.sql": "create table marca_b (n int);" });
      const t = await pontComScripts(b, dir); // sem SCRIPTS_AUTOMATICOS
      const log = t.registro.join("");
      ok("diz quantos estão pendentes e quais", /1 pendente\(s\).*001-cria\.sql/s.test(log), log.slice(-500));
      ok("diz que não aplicou nada", /NÃO apliquei nada/.test(log));
      // AS DUAS CONFERÊNCIAS DE VERDADE: o banco continua sem nada. Sem elas,
      // esta seção estaria provando o texto do log, e não o comportamento.
      ok("a tabela do script NÃO foi criada", (await b.temTabela("marca_b")) === false);
      ok("a tabela de controle NÃO foi criada", (await b.temTabela("zorvin_scripts_aplicados")) === false);
      await t.parar();
    }

    // ---- 51c. aplicar aplica de verdade ----
    {
      const b = await bancoNovo();
      const dir = pastaCom({
        "001-cria.sql": "create table marca_c (n int);",
        "002-enche.sql": "insert into marca_c (n) values (7);",
      });
      const t = await pontComScripts(b, dir, { SCRIPTS_AUTOMATICOS: "aplicar" });
      ok("a tabela existe no Postgres", (await b.temTabela("marca_c")) === true);
      const { rows } = await b.consultar("select n from marca_c");
      ok("e o segundo script rodou DEPOIS do primeiro", rows.length === 1 && rows[0].n === 7,
         JSON.stringify(rows));
      const ctl = await b.consultar("select nome, sucesso, impressao, tempo_ms from zorvin_scripts_aplicados order by nome");
      ok("os dois ficaram anotados como aplicados", ctl.rows.length === 2 && ctl.rows.every((r) => r.sucesso === true),
         JSON.stringify(ctl.rows));
      ok("com a impressão digital guardada", ctl.rows.every((r) => /^[0-9a-f]{64}$/.test(r.impressao)));
      await t.parar();
    }

    // ---- 51d. a tabela de controle nasce fechada ----
    {
      // Armadilha nº 5 do CLAUDE.md: tabela nova em `public` já nasceu aberta
      // uma vez neste projeto. Esta tem de nascer com RLS ligada e SEM política
      // — só a ponte (`service_role`) a alcança.
      const b = await bancoNovo();
      const dir = pastaCom({ "001-x.sql": "create table marca_d (n int);" });
      const t = await pontComScripts(b, dir, { SCRIPTS_AUTOMATICOS: "aplicar" });
      const rls = await b.consultar(
        "select relrowsecurity from pg_class where oid = 'public.zorvin_scripts_aplicados'::regclass");
      ok("a tabela de controle nasce com RLS ligada", rls.rows[0].relrowsecurity === true);
      const pol = await b.consultar(
        "select count(*)::int as n from pg_policies where tablename = 'zorvin_scripts_aplicados'");
      ok("e sem política nenhuma (ninguém além da ponte alcança)", pol.rows[0].n === 0, JSON.stringify(pol.rows));
      await t.parar();
    }

    // ---- 51e. cada script roda UMA vez, mesmo publicando de novo ----
    {
      const b = await bancoNovo();
      // `insert` é o que prova: rodar duas vezes deixaria duas linhas. Um
      // `create table if not exists` passaria calado nos dois casos.
      const dir = pastaCom({
        "001-cria.sql": "create table marca_e (n int);",
        "002-conta.sql": "insert into marca_e (n) values (1);",
      });
      const t1 = await pontComScripts(b, dir, { SCRIPTS_AUTOMATICOS: "aplicar" });
      await t1.parar();
      const t2 = await pontComScripts(b, dir, { SCRIPTS_AUTOMATICOS: "aplicar" });
      const log2 = t2.registro.join("");
      ok("a segunda subida diz que não há nada pendente", /nada pendente/.test(log2), log2.slice(-400));
      const { rows } = await b.consultar("select count(*)::int as n from marca_e");
      ok("e o insert continua com UMA linha só", rows[0].n === 1, JSON.stringify(rows));
      await t2.parar();
    }

    // ---- 51f. script que falha não derruba a ponte, e para os seguintes ----
    {
      const b = await bancoNovo();
      const dir = pastaCom({
        "001-boa.sql": "create table marca_f1 (n int);",
        "002-quebrada.sql": "create table marca_f2 (n int) isto nao e sql;",
        "003-depois.sql": "create table marca_f3 (n int);",
      });
      const t = await pontOuNada(b, dir, { SCRIPTS_AUTOMATICOS: "aplicar" });
      // A PRIMEIRA CONFERÊNCIA É ESTA, e antes de qualquer outra: um script
      // quebrado não pode derrubar a ponte. Tudo o mais desta cena só faz
      // sentido se ela estiver de pé.
      ok("a ponte fica de pé com um script quebrado", t !== null && t.filho.exitCode === null,
         t === null ? "não respondeu depois de subir — morreu no script"
                    : `saiu com código ${t.filho.exitCode}`);
      if (!t) { console.log("  (o resto desta cena não roda: a ponte morreu)"); }
      else {
      ok("a primeira entrou", (await b.temTabela("marca_f1")) === true);
      ok("a de depois da quebrada NÃO entrou", (await b.temTabela("marca_f3")) === false);
      const ctl = await b.consultar("select nome, sucesso, erro from zorvin_scripts_aplicados order by nome");
      const ruim = ctl.rows.find((r) => r.nome === "002-quebrada.sql");
      ok("a falha fica GRAVADA na tabela, não só no log", ruim && ruim.sucesso === false, JSON.stringify(ctl.rows));
      ok("com o motivo técnico junto", ruim && /syntax/i.test(String(ruim.erro)), ruim && ruim.erro);
      // E O LOG TAMBÉM GRITA. A linha na tabela é o registro durável (é dela
      // que o painel vai se servir), mas quem está olhando a publicação na hora
      // vê o log — e este projeto já perdeu dois avisos por eles morarem só lá.
      // As duas coisas, e nenhuma no lugar da outra.
      const logF = t.registro.join("");
      ok("o log diz QUAL script falhou, e que a ponte segue atendendo",
         /002-quebrada\.sql FALHOU/.test(logF) && /segue atendendo normalmente/.test(logF),
         logF.slice(-400));
      // O CORAÇÃO DESTA SEÇÃO: um script quebrado não pode calar o WhatsApp do
      // escritório. A ponte tem de continuar recebendo mensagem de cliente.
      //
      // O `then` COM DOIS BRAÇOS NÃO É ENFEITE, e entrou por causa de uma
      // sabotagem: pondo um `process.exit(1)` no lugar em que a ponte hoje só
      // anota a falha, o `fetch` estourava (conexão recusada) e derrubava a
      // PROVA INTEIRA — as conferências seguintes nem chegavam a rodar, e a
      // rodada terminava sem uma linha de FALHA. A prova ficava calada
      // justamente sobre o defeito que ela existe para pegar. Ponte morta agora
      // é uma reprovação, e com essas palavras.
      const status = await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify(mensagemDaUazapi("Mesmo com script quebrado", "msg-scripts")),
      }).then((r) => r.status, () => 0);
      await espera(700);
      ok("a ponte continua atendendo o webhook", status === 200,
         status === 0 ? "a ponte não respondeu — morreu com o script quebrado" : `veio ${status}`);
      ok("e a mensagem do cliente entrou no banco", t.sb.dados.mensagens.length === 1,
         JSON.stringify(t.sb.dados.mensagens));
      await t.parar();
      }
    }

    // ---- 51g. um script que quebra no meio não deixa metade aplicada ----
    {
      const b = await bancoNovo();
      // A propriedade que interessa a quem usa: duas instruções num arquivo só,
      // a primeira funciona e a segunda não, e `marca_g` não fica criada. Meio
      // script aplicado é um estado que nenhum arquivo descreve, e que o script
      // seguinte encontraria pela frente.
      //
      // ESTA CONFERÊNCIA SOZINHA NÃO PROVA O `begin` DAQUI — e isso foi MEDIDO
      // numa rodada de sabotagem: tirando o `begin`, ela continuou passando. O
      // Postgres embrulha um LOTE de instruções mandado numa consulta só na
      // própria transação implícita, e é ela que desfaz aqui. O `begin`
      // explícito serve para outra coisa, e quem o prova é 51i-bis: a anotação
      // é uma consulta SEPARADA, e só uma transação aberta por nós a junta ao
      // script.
      //
      // Fica escrito porque a tentação é ler isto como "a prova da transação" e
      // apagar 51i-bis por parecer repetida.
      const dir = pastaCom({
        "001-meio.sql": "create table marca_g (n int);\nselect nao_existe_esta_funcao();",
      });
      // Mesmo cuidado de 51f: aqui um script também quebra de propósito.
      const t = await pontOuNada(b, dir, { SCRIPTS_AUTOMATICOS: "aplicar" });
      ok("a ponte fica de pé (cena com script que quebra)", t !== null && t.filho.exitCode === null);
      ok("o que a primeira metade criou foi desfeito", (await b.temTabela("marca_g")) === false);
      if (t) await t.parar();
    }

    // ---- 51h. script já aplicado que muda faz a ponte PARAR ----
    {
      const b = await bancoNovo();
      const dir = pastaCom({ "001-cria.sql": "create table marca_h (n int);" });
      const t1 = await pontComScripts(b, dir, { SCRIPTS_AUTOMATICOS: "aplicar" });
      await t1.parar();
      // Alguém edita o script que já rodou, e acrescenta outro depois dele.
      fs.writeFileSync(path.join(dir, "001-cria.sql"), "create table marca_h (n int, extra text);");
      fs.writeFileSync(path.join(dir, "002-nova.sql"), "create table marca_h2 (n int);");
      const t2 = await pontComScripts(b, dir, { SCRIPTS_AUTOMATICOS: "aplicar" });
      const log = t2.registro.join("");
      ok("a ponte para e diz QUAL arquivo mudou", /PAREI.*001-cria\.sql/s.test(log), log.slice(-600));
      ok("e não aplica a que veio depois", (await b.temTabela("marca_h2")) === false);
      await t2.parar();
    }

    // ---- 51i. banco que não responde não derruba a ponte ----
    {
      const dir = pastaCom({ "001-x.sql": "create table marca_i (n int);" });
      const u = new URL(BANCO_BASE);
      u.pathname = "/banco_que_nao_existe_mesmo";
      u.searchParams.set("sslmode", "disable");
      const t = await subirTudo({
        DATABASE_URL: u.toString(), SCRIPTS_PASTA: dir, SCRIPTS_AUTOMATICOS: "aplicar",
      });
      for (let i = 0; i < 80; i++) {
        if (/Scripts autom[áa]ticos:/.test(t.registro.join(""))) break;
        await espera(100);
      }
      const log = t.registro.join("");
      ok("diz que não deu para aplicar", /não deu para aplicar agora/.test(log), log.slice(-400));
      ok("e diz que segue atendendo", /segue atendendo normalmente/.test(log));
      // Mesmo cuidado de 51f: ponte morta reprova, em vez de derrubar a prova.
      const status = await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify(mensagemDaUazapi("Banco fora, mensagem entra", "msg-banco-fora")),
      }).then((r) => r.status, () => 0);
      await espera(700);
      ok("e atende mesmo", status === 200 && t.sb.dados.mensagens.length === 1,
         status === 0 ? "a ponte não respondeu — morreu com o banco fora"
                      : `${status} · ${t.sb.dados.mensagens.length}`);
      await t.parar();
    }

    // ---- 51i-bis. a anotação entra junto com o script, não depois ----
    {
      // POR QUE ISTO IMPORTA: anotando depois do `commit`, uma publicação
      // caindo entre os dois deixaria o script aplicado e não anotado — e a
      // subida seguinte o aplicaria DE NOVO. Num `insert`, é a linha duplicada.
      //
      // Provar aquele instante exigiria matar o processo no microssegundo
      // certo. Esta conferência prova a MESMA propriedade por dentro: o script
      // derruba a coluna que a anotação usa, então a anotação falha. Se ela
      // estivesse fora da transação, a tabela que o script criou sobreviveria.
      const b = await bancoNovo();
      const dir = pastaCom({
        "001-antes.sql": "create table marca_m0 (n int);",
        "002-derruba.sql": "create table marca_m (n int);\n"
          + "alter table public.zorvin_scripts_aplicados drop column impressao;",
      });
      // Mesmo cuidado de 51f: aqui um script também quebra de propósito.
      const t = await pontOuNada(b, dir, { SCRIPTS_AUTOMATICOS: "aplicar" });
      ok("a ponte fica de pé (cena com script que quebra)", t !== null && t.filho.exitCode === null);
      ok("o primeiro script, esse sim, entrou", (await b.temTabela("marca_m0")) === true);
      ok("falhando a anotação, o que o script criou vai junto",
         (await b.temTabela("marca_m")) === false);
      const col = await b.consultar(
        "select count(*)::int as n from information_schema.columns "
        + "where table_name = 'zorvin_scripts_aplicados' and column_name = 'impressao'");
      ok("e a coluna que ele derrubou também voltou", col.rows[0].n === 1, JSON.stringify(col.rows));
      if (t) await t.parar();
    }

    // ---- 51j. a trava: duas pontes numa publicação, e só uma aplica ----
    {
      // Toda publicação da Render sobe a ponte nova ENQUANTO a velha ainda
      // está saindo. Por alguns segundos há duas, e as duas acordam querendo
      // aplicar o mesmo script. Aqui a prova segura a trava no lugar da
      // primeira ponte, e confere que a segunda desiste em vez de aplicar.
      const b = await bancoNovo();
      const dir = pastaCom({ "001-cria.sql": "create table marca_j (n int);" });

      const outra = new pg.Client({ connectionString: b.url, ssl: false });
      await outra.connect();
      const { rows: peguei } = await outra.query("select pg_try_advisory_lock(823005001) as peguei");
      ok("a bancada consegue segurar a trava (senão o resto não prova nada)", peguei[0].peguei === true);

      const t = await pontComScripts(b, dir, { SCRIPTS_AUTOMATICOS: "aplicar" });
      const log = t.registro.join("");
      ok("a segunda ponte diz que deixa com a outra", /outra ponte está cuidando disto/.test(log), log.slice(-400));
      ok("e NÃO aplica o script", (await b.temTabela("marca_j")) === false);
      await t.parar();

      // Solta a trava e sobe de novo: agora tem de aplicar. Sem esta metade, a
      // conferência de cima passaria também com a trava quebrada de um jeito
      // que nunca deixa ninguém aplicar nada.
      await outra.end();
      const t2 = await pontComScripts(b, dir, { SCRIPTS_AUTOMATICOS: "aplicar" });
      ok("solta a trava, a ponte seguinte aplica", (await b.temTabela("marca_j")) === true);
      await t2.parar();
    }

    // ---- 51k. `-- sem-transacao`, para o que não roda dentro de uma ----
    {
      // `create index concurrently` é o caso de verdade: o Postgres o RECUSA
      // dentro de uma transação. Sem a saída, um script desses seria impossível
      // de aplicar por aqui — e índice concorrente é justamente o que se usa
      // para não travar a tabela de mensagens de um escritório em expediente.
      const b = await bancoNovo();
      const dir = pastaCom({
        "001-tabela.sql": "create table marca_k (n int);",
        "002-indice.sql": "-- sem-transacao\ncreate index concurrently marca_k_n on marca_k (n);",
      });
      const t = await pontComScripts(b, dir, { SCRIPTS_AUTOMATICOS: "aplicar" });
      const { rows } = await b.consultar(
        "select count(*)::int as n from pg_indexes where indexname = 'marca_k_n'");
      ok("o índice concorrente foi criado", rows[0].n === 1, JSON.stringify(rows));
      const ctl = await b.consultar("select sucesso, erro from zorvin_scripts_aplicados where nome = '002-indice.sql'");
      ok("e ficou anotado como aplicado", ctl.rows[0] && ctl.rows[0].sucesso === true, JSON.stringify(ctl.rows));
      await t.parar();
    }

    // ---- 51l-bis. OS SCRIPTS DE VERDADE, num banco limpo ----
    {
      // As cenas acima provam o MOTOR com scripts de mentira. Esta aponta para
      // a pasta de verdade do repositório — a mesma que vai rodar no banco de
      // um cliente — e confere que o que está escrito lá aplica e faz o que diz.
      //
      // Vale para todo script futuro: um erro de digitação em SQL passa por
      // revisão de código sem ninguém notar, e só aparece na hora de instalar.
      const b = await bancoNovo();
      // O mínimo que o script 001 toca. Não é o banco inteiro do Zorvin: é a
      // conta no Auth e a tabela de gente, que é sobre o que ele fala.
      await b.consultar(`
        create schema if not exists auth;
        create table auth.users (id uuid primary key, email text, raw_user_meta_data jsonb);
        create table public.usuarios (id uuid primary key, login text, nome text, email text,
                                      admin boolean, ativo boolean, visto_em timestamptz);
      `);
      // Pasta vazia = a pasta padrão do repositório, que é o ponto.
      const t = await pontOuNada(b, "", { SCRIPTS_AUTOMATICOS: "aplicar" });
      ok("a ponte fica de pé aplicando os scripts de verdade", t !== null && t.filho.exitCode === null);

      const aplicados = await b.consultar(
        "select nome, sucesso, erro from zorvin_scripts_aplicados order by nome");
      ok("todos os scripts da pasta aplicaram sem falha",
         aplicados.rows.length > 0 && aplicados.rows.every((r) => r.sucesso === true),
         JSON.stringify(aplicados.rows));

      // ---- e o 001 faz o que promete
      await b.consultar(
        "insert into auth.users (id, email, raw_user_meta_data) values "
        + "('11111111-1111-1111-1111-111111111111', 'dono@escritorio.com', '{}'::jsonb)");
      const primeiro = await b.consultar(
        "select nome, email, admin, ativo from public.usuarios "
        + "where id = '11111111-1111-1111-1111-111111111111'");
      ok("quem entra vira gente: a linha nasce junto com a conta",
         primeiro.rows.length === 1, JSON.stringify(primeiro.rows));
      ok("o PRIMEIRO do banco administra (senão ninguém nunca administraria)",
         primeiro.rows[0] && primeiro.rows[0].admin === true, JSON.stringify(primeiro.rows));

      await b.consultar(
        "insert into auth.users (id, email, raw_user_meta_data) values "
        + "('22222222-2222-2222-2222-222222222222', 'atendente@escritorio.com', "
        + "'{\"nome\": \"Maria\"}'::jsonb)");
      const segundo = await b.consultar(
        "select nome, admin from public.usuarios "
        + "where id = '22222222-2222-2222-2222-222222222222'");
      ok("o segundo NÃO nasce administrador",
         segundo.rows[0] && segundo.rows[0].admin === false, JSON.stringify(segundo.rows));
      ok("e o nome vem do cadastro quando ele existe",
         segundo.rows[0] && segundo.rows[0].nome === "Maria", JSON.stringify(segundo.rows));

      // ---- A PROPRIEDADE QUE MAIS IMPORTA: o gatilho nunca tranca a porta.
      //
      // No caminho COM Vantoro é a ponte que cria a conta no Auth na primeira
      // entrada da vida de alguém. Um gatilho que estoure ali faz a criação
      // inteira falhar — e o sintoma é "fulano não entra de jeito nenhum", no
      // dia em que fulano foi contratado. Aqui a tabela some debaixo dele.
      await b.consultar("drop table public.usuarios");
      let contaCriada = true;
      try {
        await b.consultar(
          "insert into auth.users (id, email, raw_user_meta_data) values "
          + "('33333333-3333-3333-3333-333333333333', 'depois@escritorio.com', '{}'::jsonb)");
      } catch (_e) { contaCriada = false; }
      ok("o gatilho falhando NÃO impede a conta de ser criada", contaCriada);
      if (t) await t.parar();
    }

    // ---- 51l. sem a marca, o mesmo script é recusado ----
    {
      // A metade que prova que a marca faz alguma coisa. Sem esta, 51k passaria
      // igual se a ponte simplesmente nunca usasse transação nenhuma — e aí a
      // conferência 51g estaria provando o contrário do que 51k prova.
      const b = await bancoNovo();
      const dir = pastaCom({
        "001-tabela.sql": "create table marca_l (n int);",
        "002-indice.sql": "create index concurrently marca_l_n on marca_l (n);",
      });
      // Mesmo cuidado de 51f: aqui um script também quebra de propósito.
      const t = await pontOuNada(b, dir, { SCRIPTS_AUTOMATICOS: "aplicar" });
      ok("a ponte fica de pé (cena com script que quebra)", t !== null && t.filho.exitCode === null);
      const ctl = await b.consultar("select sucesso, erro from zorvin_scripts_aplicados where nome = '002-indice.sql'");
      ok("sem a marca, o Postgres recusa e a falha fica anotada",
         ctl.rows[0] && ctl.rows[0].sucesso === false, JSON.stringify(ctl.rows));
      ok("com o motivo dizendo que é a transação",
         ctl.rows[0] && /transaction/i.test(String(ctl.rows[0].erro)), ctl.rows[0] && ctl.rows[0].erro);
      if (t) await t.parar();
    }
  }
}

console.log(`\n${feitas - falhas}/${feitas} conferências passaram`);
process.exit(falhas ? 1 : 0);
