// ============================================================
//  ZORVIN by Ropelimi — Ponte (middleware)
//  Liga o WhatsApp (via Uazapi) ao banco do Zorvin (Supabase).
//
//  Faz duas coisas:
//   1) RECEBE mensagens do WhatsApp e guarda no banco.
//   2) ENVIA respostas: lê a "fila de envio" que o painel preenche
//      e manda cada mensagem pela Uazapi.
// ============================================================

const express = require('express');
const { createClient } = require('@supabase/supabase-js');

const app = express();
// O CORPO CRU FICA GUARDADO, e não só o JSON já lido.
//
// O aviso que o Vantoro manda vem assinado sobre os BYTES que ele enviou. Para
// conferir a assinatura é preciso ter esses bytes — reserializar o objeto já
// lido NÃO devolve os mesmos: o Python separa os campos com ", " e o JavaScript
// sem espaço nenhum, então a assinatura nunca bateria, e o sintoma seria toda
// entrega legítima sendo recusada por "assinatura inválida".
app.use(express.json({ limit: '15mb', verify: (req, _res, buf) => { req.corpoCru = buf; } }));

// Rede de segurança: um erro assíncrono não tratado NÃO pode derrubar a ponte
// (é um único processo no plano free do Render). Registra e segue vivo.
process.on('unhandledRejection', (err) => {
  console.error('unhandledRejection:', (err && err.message) || err);
});
process.on('uncaughtException', (err) => {
  console.error('uncaughtException:', (err && err.message) || err);
});

// ============================================================
//  A PONTE ESTÁ SAINDO DO AR — E ISSO PRECISA SER SABIDO AQUI DENTRO
//
//  Toda publicação derruba este processo. A Render manda um pedido de
//  encerramento (SIGTERM) e, se ninguém o trata, o Node MORRE NA HORA — no meio
//  do que estivesse fazendo.
//
//  O que estivesse fazendo, num escritório em expediente, é isto:
//
//    - um webhook que já foi respondido com "OK" para a Uazapi e ainda está
//      sendo gravado. A Uazapi considera entregue; aqui a mensagem do cliente
//      some, sem erro e sem log. Não há como saber depois qual foi;
//    - um envio que a Uazapi já aceitou e cuja marca de "enviada" ainda não
//      chegou ao banco. O item fica preso em "enviando" e é reenviado cinco
//      minutos depois — o cliente recebe duas vezes.
//
//  Estas duas contas são o que permite esperar por eles antes de sair. Ficam
//  aqui no alto, e não junto do desligamento lá embaixo, porque é aqui que a
//  ponte declara as suas redes de segurança — e porque quem for mexer no
//  webhook precisa esbarrar nelas.
// ============================================================
let desligando = false;
let webhooksEmVoo = 0;

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
);

// UM TETO PARA O TEMPO LIMITE, E ISSO É O QUE TORNA O CAMINHO TESTÁVEL.
//
// O caminho do tempo esgotado nunca tinha sido provado, e não por descuido:
// os limites vão de 8 a 45 segundos, e prová-lo custava esperar por eles. Um
// caminho que nenhuma prova exercita é onde um defeito mora à vontade — e
// morava: o Node anuncia o tempo esgotado como "This operation was aborted", a
// lista de motivos procurava `aborterror` (que é o NOME DA CLASSE, não o texto
// da mensagem), e a bolha vermelha mostrava inglês cru para quem atende.
//
// É um TETO, e não um padrão, de propósito: as chamadas passam o limite delas
// explicitamente (o envio pede 45 s, o JWKS 8 s), e um padrão não alcançaria
// nenhuma delas. Sem a variável definida — que é o caso em produção — o teto
// não existe e nada muda.
const UAZAPI_TETO_MS = Number(process.env.UAZAPI_TIMEOUT_MS) || 0;

// fetch com timeout: evita que uma chamada à Uazapi fique pendurada e
// segure a fila. Aborta após `ms` milissegundos.
async function fetchComTimeout(url, opts = {}, ms = 15000) {
  const limite = UAZAPI_TETO_MS ? Math.min(ms, UAZAPI_TETO_MS) : ms;
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), limite);
  try {
    return await fetch(url, { ...opts, signal: ctrl.signal });
  } finally {
    clearTimeout(t);
  }
}

// ============================================================
//  GRUPO É UMA CONVERSA SÓ — e não uma por participante.
//
//  O erro que isto conserta: mensagem de GRUPO virava conversa nova.
//
//  A ponte tratava todo chat como pessoa. Num grupo, isso dá dois estragos
//  diferentes, e os dois foram vistos:
//
//    - mensagem que NÓS mandamos ao grupo (fromMe) tinha como "contato" o
//      identificador do grupo, que não é telefone de ninguém. Nascia uma
//      conversa com nome de número esquisito ("+70929710"), separada do grupo;
//    - mensagem RECEBIDA no grupo tinha como "contato" o PARTICIPANTE. Um grupo
//      de cinco pessoas ia virando cinco conversas de um-para-um, cada uma com
//      um pedaço da mesma discussão.
//
//  A identidade certa de um grupo é o JID dele (`...@g.us`): ele não muda
//  quando o grupo é renomeado, e é o mesmo para todo mundo lá dentro. Guardamos
//  como `grupo:<jid>` em `contatos.numero` — o mesmo prefixo que a importação de
//  histórico já usava, então o painel continua reconhecendo grupo do mesmo jeito.
// ============================================================
function chatDaMensagem(body, m) {
  const chat = body.chat || {};
  const candidatos = [chat.id, chat.jid, chat.chatid, m && m.chatid, m && m.chatId]
    .filter(Boolean).map(String);
  const jid = candidatos.find((c) => c.toLowerCase().includes('@g.us'));
  const marcado = chat.isGroup === true || body.isGroup === true || (m && m.isGroup === true);

  if (jid || marcado) {
    // Sem o JID não dá para inventar uma chave estável — e chave instável é
    // exatamente o defeito que estamos consertando. Melhor deixar seguir pelo
    // caminho de sempre do que criar um grupo por mensagem.
    if (!jid) return { ehGrupo: false, chave: numeroRealDoContato(body, m), nome: null };
    return {
      ehGrupo: true,
      chave: 'grupo:' + jid.split('@')[0].toLowerCase(),
      // O nome do GRUPO vem do chat, e vale inclusive em mensagem nossa: aqui
      // `chat.name` é o nome do grupo, e não o do advogado (que é o motivo de o
      // nome ser ignorado em fromMe nas conversas de uma pessoa só).
      nome: chat.name || chat.wa_name || chat.subject || chat.pushName || null,
    };
  }
  return { ehGrupo: false, chave: numeroRealDoContato(body, m), nome: null };
}

// Quem escreveu ESTA mensagem dentro do grupo. Sem isto, a conversa do grupo
// vira um monólogo de balões sem autor — que é como se lê uma discussão de
// cinco pessoas quando ninguém está identificado.
function autorNoGrupo(body, m) {
  if (m && m.fromMe) return 'WhatsApp';
  const nome = (m && m.senderName) || (body.chat && body.chat.wa_name) || '';
  if (nome && !/^\+?\d[\d\s()-]*$/.test(nome)) return String(nome).slice(0, 80);
  const fone = String((m && (m.sender_pn || m.sender)) || '').split('@')[0].replace(/\D/g, '');
  return fone ? '+' + fone : 'Participante';
}

// ------------------------------------------------------------
//  O QUE JÁ FOI GRAVADO ERRADO SE JUNTA SOZINHO
//
//  Consertar daqui para a frente não resolve o que a equipe está vendo hoje: o
//  mesmo grupo espalhado em duas ou três conversas, cada uma com um pedaço da
//  discussão. Pedir um SQL para isso seria empurrar para quem não escreve SQL o
//  conserto de um erro nosso.
//
//  Então a primeira mensagem que chegar do grupo depois deste deploy junta tudo:
//  acha as conversas antigas daquele grupo, muda as mensagens delas para a
//  conversa boa e apaga o que ficou vazio. Roda uma vez por grupo — depois disso
//  não há mais o que achar.
//
//  Os dois rastros que o erro deixou, e como cada um é reconhecido:
//    1. os DÍGITOS CRUS do JID, virados "telefone" (a conversa "+70929710");
//    2. o grupo IMPORTADO do histórico, que tem chave `grupo:<hash do nome>` —
//       reconhecido pelo NOME, que é o único dado que os dois têm em comum.
//
//  O caso 2 só junta quando há UM candidato com aquele nome exato. Dois grupos
//  de mesmo nome é o momento de não adivinhar: fica como está, e o log diz.
// ------------------------------------------------------------
async function juntarConversasDoGrupo(advId, chave, jidDigitos, nome) {
  // O rastro 1 nem sempre são os dígitos INTEIROS do JID: no caso que motivou
  // este conserto, a conversa nasceu como "+70929710" — um PEDAÇO do fim do
  // identificador do grupo. Então procuramos por todas as terminações dele.
  //
  // E só entram as SEM NOME. É a diferença entre juntar o estrago e destruir
  // dado bom: a mensagem que NÓS mandamos criou contato sem nome nenhum (é o
  // sintoma), enquanto a recebida criou contato com o nome do PARTICIPANTE — e
  // esse é uma pessoa de verdade, que provavelmente tem conversa de um-para-um
  // com o escritório. Juntar essa apagaria a conversa dela.
  const terminacoes = [];
  for (let n = 6; n <= jidDigitos.length; n++) terminacoes.push(jidDigitos.slice(-n));

  const { data: achados, error } = await supabase
    .from('contatos').select('id, numero, nome')
    .in('numero', [chave, ...terminacoes]);
  if (error) { console.log(`Grupo: não consegui procurar as conversas antigas (${error.message}).`); return; }

  const candidatos = (achados || []).filter((c) => c.numero === chave || !c.nome);
  if (nome) {
    const { data: porNome } = await supabase
      .from('contatos').select('id, numero, nome')
      .like('numero', 'grupo:%').eq('nome', nome);
    const outros = (porNome || []).filter((c) => c.numero !== chave);
    if (outros.length === 1) candidatos.push(outros[0]);
    else if (outros.length > 1) {
      console.log(`Grupo "${nome}": ${outros.length} conversas com esse nome — não juntei, `
                + 'para não misturar grupos diferentes de mesmo nome.');
    }
  }
  // ------------------------------------------------------------
  //  A PESSOA QUE FICOU COM O NOME DO GRUPO — ISTO SÓ AVISA
  //
  //  Relato do escritório, com print: quatro conversas na lista, todas
  //  chamadas "Edifício Nova Brasília". A consulta ao banco mostrou o que
  //  eram: UMA com a chave certa do grupo, e quatro com TELEFONE DE GENTE,
  //  todas de 28/07 — de antes do conserto, uma por participante.
  //
  //  A ponte de antes escrevia o nome do CHAT no contato, e num grupo o nome do
  //  chat é o nome do grupo. Sobraram quatro pessoas reais carregando o nome de
  //  um prédio — e se alguma escrever no particular, a conversa dela aparece
  //  com esse nome.
  //
  //  POR QUE ISTO NÃO CONSERTA SOZINHO, e são duas razões independentes:
  //
  //    JUNTAR AS CONVERSAS seria mover histórico. As mensagens de julho foram
  //    gravadas pelo caminho de "uma pessoa só", então nem têm o `enviado_por`
  //    que marca quem falou no grupo: não existe, no banco, sinal que separe
  //    "esta era do grupo" de "esta era particular". Mover às cegas poderia pôr
  //    a conversa privada de alguém dentro do grupo, e isso não se desfaz.
  //
  //    LIMPAR O NOME parece inofensivo e não é. A regra seria "contato com
  //    telefone de gente e nome igual ao do grupo" — e um grupo chamado
  //    "Rodrigo" apagaria o nome do Rodrigo de verdade. Aqui não há como
  //    distinguir, e apagar nome de cadastro por regra genérica é o tipo de
  //    conserto que se descobre tarde.
  //
  //  Então isto AVISA, com nome e número, e quem decide é gente. O aviso sai
  //  uma vez por grupo, quando a mensagem chega.
  if (nome) {
    const { data: homonimos } = await supabase
      .from('contatos').select('id, numero, nome')
      .eq('nome', nome).not('numero', 'like', 'grupo:%');
    for (const c of homonimos || []) {
      console.log(`Grupo "${nome}": ATENÇÃO — o contato ${c.numero} é um TELEFONE DE PESSOA `
                + 'com o nome deste grupo. Veio de uma conversa criada antes do conserto de '
                + 'grupos. As mensagens dele NÃO foram movidas (não dá para saber quais eram '
                + 'do grupo); o nome NÃO foi apagado (poderia ser o nome real de alguém). '
                + 'Confira e corrija o cadastro à mão.');
    }
  }

  const antigos = candidatos.filter((c) => c.numero !== chave);
  if (!antigos.length) return;

  // O contato DEFINITIVO: o que já tem a chave certa; se não existe nenhum,
  // promove o primeiro antigo (renomear preserva as mensagens dele).
  let bom = candidatos.find((c) => c.numero === chave) || null;
  if (!bom) {
    bom = antigos.shift();
    const { error: erroRen } = await supabase
      .from('contatos').update({ numero: chave, nome: nome || bom.nome }).eq('id', bom.id);
    if (erroRen) { console.log(`Grupo: não consegui promover a conversa antiga (${erroRen.message}).`); return; }
    console.log(`Grupo "${nome || chave}": a conversa "${bom.numero}" era o mesmo grupo — passou a ser a conversa dele.`);
    bom = { ...bom, numero: chave };
    if (!antigos.length) return;
  }

  const { data: convBoa } = await supabase
    .from('conversas').select('id').eq('advogado_id', advId).eq('contato_id', bom.id).maybeSingle();
  if (!convBoa) return;   // ainda não existe; a mensagem de agora vai criá-la

  for (const velho of antigos) {
    const { data: convs } = await supabase
      .from('conversas').select('id').eq('advogado_id', advId).eq('contato_id', velho.id);
    for (const cv of convs || []) {
      if (cv.id === convBoa.id) continue;
      const { erro: erroMove } = await mudarDeConversa(cv.id, convBoa.id);
      if (erroMove) { console.log(`Grupo: não consegui mover as mensagens (${erroMove}).`); continue; }
      await supabase.from('conversas').delete().eq('id', cv.id);
      console.log(`Grupo "${nome || chave}": juntei as mensagens de "${velho.numero}" na conversa do grupo.`);
    }
    // O contato antigo só sai se não sobrou conversa nenhuma nele (ele pode ser
    // de outro telefone do escritório, e aí não é nosso para apagar).
    const { data: sobrou } = await supabase
      .from('conversas').select('id').eq('contato_id', velho.id).limit(1);
    if (!sobrou || !sobrou.length) await supabase.from('contatos').delete().eq('id', velho.id);
  }
}

// ------------------------------------------------------------
//  MUDAR TUDO DE UMA CONVERSA PARA OUTRA
//
//  Juntar duas conversas é mover o que está pendurado nelas — e o que está
//  pendurado não é só a mensagem. A NOTA INTERNA (o combinado da equipe, que
//  nunca foi para o WhatsApp), a ETIQUETA e o ENVIO QUE AINDA ESTÁ NA FILA
//  moram em tabelas separadas, todas apontando para `conversa_id`. Mover só as
//  mensagens e apagar a conversa levava as outras três junto, em silêncio: o
//  banco apaga em cascata, e ninguém fica sabendo que a nota sumiu.
//
//  A etiqueta é o único caso com regra própria: se a conversa de destino JÁ tem
//  aquela etiqueta, a da origem é descartada em vez de movida — senão a mesma
//  etiqueta apareceria duas vezes na mesma conversa.
//
//  O "não lidas" das duas se soma. A conversa que sai pode ter mensagem que
//  ninguém leu, e essas mensagens continuam existindo depois da junção; zerar
//  a conta faria a equipe passar por elas sem ver.
//
//  `notas` e `fila_envio` podem não existir numa instalação mais antiga. O erro
//  delas é registrado e a junção segue — perder a nota é ruim, mas parar no
//  meio, com as mensagens já movidas, seria pior.
// ------------------------------------------------------------
async function mudarDeConversa(origemId, destinoId) {
  const { count, error } = await supabase
    .from('mensagens').update({ conversa_id: destinoId }, { count: 'exact' })
    .eq('conversa_id', origemId);
  if (error) return { erro: error.message };

  for (const tabela of ['notas', 'fila_envio']) {
    const { error: e } = await supabase
      .from(tabela).update({ conversa_id: destinoId }).eq('conversa_id', origemId);
    if (e) console.log(`Junção: não movi "${tabela}" (${e.message}).`);
  }

  const { data: doDestino } = await supabase
    .from('conversa_tags').select('tag_id').eq('conversa_id', destinoId);
  const jaTem = new Set((doDestino || []).map((t) => t.tag_id));
  const { data: daOrigem } = await supabase
    .from('conversa_tags').select('tag_id').eq('conversa_id', origemId);
  for (const t of daOrigem || []) {
    const { error: e } = jaTem.has(t.tag_id)
      ? await supabase.from('conversa_tags').delete()
          .eq('conversa_id', origemId).eq('tag_id', t.tag_id)
      : await supabase.from('conversa_tags').update({ conversa_id: destinoId })
          .eq('conversa_id', origemId).eq('tag_id', t.tag_id);
    if (e) console.log(`Junção: não movi a etiqueta (${e.message}).`);
  }

  const { data: duas } = await supabase
    .from('conversas').select('id, nao_lidas').in('id', [origemId, destinoId]);
  const soma = (duas || []).reduce((t, c) => t + (c.nao_lidas || 0), 0);
  if (soma) await supabase.from('conversas').update({ nao_lidas: soma }).eq('id', destinoId);

  return { movidas: count || 0 };
}

// ------------------------------------------------------------
//  Descobre o telefone REAL do contato, ignorando o "@lid"
//  (identificador de privacidade da WhatsApp que criava contatos e
//  conversas duplicados). Para mensagens que NÓS enviamos (fromMe),
//  o contato é o "chat"; para recebidas, é o remetente (sender_pn).
// ------------------------------------------------------------
function numeroRealDoContato(body, m) {
  const chatPhone = body.chat && body.chat.phone;
  const chatId = body.chat && body.chat.id;
  // Em mensagens que NÓS enviamos (fromMe), o remetente (sender_pn/sender) é o
  // ADVOGADO — nunca pode ser usado como número do contato. O contato é sempre
  // o "chat". Em mensagens recebidas, o contato é o remetente.
  const fontes = (m && m.fromMe)
    ? [chatPhone, chatId]
    : [m && m.sender_pn, chatPhone, chatId, m && m.sender];
  const limpos = fontes.filter(Boolean).map(String);
  // 1ª passada: só telefone real (ignora @lid).
  for (const f of limpos) {
    if (f.includes('@lid')) continue;
    const num = f.split('@')[0].replace(/\D/g, '');
    if (num.length >= 8) return num;
  }
  // 2ª passada: qualquer coisa com dígitos suficientes (última tentativa).
  for (const f of limpos) {
    const num = f.split('@')[0].replace(/\D/g, '');
    if (num.length >= 8) return num;
  }
  return null;
}

// ------------------------------------------------------------
//  Verificação de saúde (usada pelo cronjob para não "dormir").
// ------------------------------------------------------------
app.get('/', (req, res) => {
  res.status(200).send('Zorvin bridge online');
  // Aproveita CADA acesso (o cronjob que mantém a ponte acordada E o "toque"
  // que o painel dá ao enviar) para despachar a fila na hora. Assim, se a
  // ponte tinha acabado de acordar, as mensagens não ficam "carregando"
  // esperando o próximo ciclo do setInterval.
  processarFilaDeEnvio().catch(() => {});
});

// Endereço enxuto para o cronjob de keep-alive: responde 200 com corpo VAZIO
// (evita o "output too large" que desativava o job no cron-job.org) e ainda
// aproveita para despachar a fila. Aponte o cronjob para .../ping.
app.get('/ping', (req, res) => {
  res.status(200).end();
  processarFilaDeEnvio().catch(() => {});
});

// ------------------------------------------------------------
//  IMPORTAR HISTÓRICO de um contato (backfill via Uazapi /message/find).
//  Uso administrativo e MANUAL — protegido por senha (env IMPORT_TOKEN).
//  Ex.: /importar-historico?token=SENHA&advogado=5511...&contato=5511...&limite=500
//  Seguro rodar de novo: id_uazapi é único, então não duplica.
// ------------------------------------------------------------
// QUE TIPO DE MENSAGEM É ESTA — um lugar só, para o webhook e para a
// importação de histórico.
//
// Eram dois lugares. O do webhook só olhava `mediaType`, e só quando `type`
// era exatamente 'media'; qualquer outro formato caía em 'texto', e uma
// figurinha — que não tem texto — era descartada logo depois como "evento sem
// conteúdo". Sumia dos dois lados: nada na conversa e nada no log dizendo que
// uma figurinha havia chegado.
//
// Agora olha os três campos, como a importação já fazia. E um anexo que a
// Uazapi anuncie de um jeito novo vira documento: um botão de baixar é melhor
// que uma bolha vazia, e muito melhor que a mensagem desaparecer.
function tipoDaMensagem(m) {
  const mt = String(m.mediaType || m.messageType || m.type || '').toLowerCase();
  if (mt.includes('sticker') || mt.includes('figurinha')) return 'figurinha';
  if (mt.includes('image')) return 'imagem';
  if (mt === 'ptt' || mt.includes('audio') || mt.includes('voice')) return 'audio';
  if (mt.includes('video')) return 'video';
  if (mt.includes('document') || mt.includes('file')) return 'documento';
  if (m.type === 'media') return 'documento';
  return 'texto';
}

// O NOME DO ARQUIVO QUE O CLIENTE MANDOU.
//
// A ponte nunca gravou `midia_nome` de nada que CHEGA — só do que o escritório
// envia. Então todo documento recebido aparecia na conversa escrito
// "Documento", e o nome, que é o que distingue a procuração assinada do
// panfleto encaminhado, ficava só do lado do WhatsApp.
//
// Isso é metade do relato de 10/09 ("Documento — indisponível"): a outra
// metade é o arquivo não chegar, e esta é a que fica visível mesmo quando ele
// chega.
//
// SÓ A PONTA DO CAMINHO: `fileName` costuma vir como o nome puro, mas um
// remetente pode mandar "C:\\Users\\...\\procuracao.pdf". Guardar o caminho de
// outra pessoa não serve para nada e ainda diz onde ela guarda as coisas.
function nomeDoArquivo(m) {
  const c = (m && m.content) || {};
  const cru = c.fileName || c.filename || c.title || c.docName
           || (m && (m.fileName || m.filename || m.docName)) || null;
  if (!cru) return null;
  const so = String(cru).split(/[\\/]/).pop().trim().slice(0, 200);
  return so || null;
}

// "ESTE TIPO EU RECONHECI, OU SÓ CHUTEI UM PADRÃO?"
//
// É uma pergunta diferente de "que tipo é este", e a diferença some no
// resultado: `tipoDaMensagem` devolve 'documento' tanto para um PDF de verdade
// quanto para qualquer coisa que a Uazapi anuncie de um jeito que este código
// não conhece — e devolve 'texto' para todo o resto. Nos dois casos a mensagem
// entra na conversa parecendo entendida.
//
// O ESCRITÓRIO RELATOU ISTO: um álbum de três fotos chegou como uma bolha só,
// escrita "Documento — indisponível", com o texto "Album: 3 images". A bolha
// não diz que tipo era, e o log também não dizia — então não havia como saber
// o que a Uazapi manda num álbum sem sair adivinhando.
//
// Devolve o tipo CRU quando nenhuma regra casou pelo nome, e `null` quando
// casou. Uma linha de log com o nome exato vale mais do que três tentativas de
// conserto baseadas em palpite.
// O AVISO DE ÁLBUM — que não é mensagem, e por isso não pode virar bolha.
//
// Relato do escritório, agora com o log em mãos: um álbum de três fotos
// aparecia como QUATRO bolhas — as três fotos, e antes delas uma bolha vazia
// escrita "Documento — indisponível", com o texto "Album: 3 images".
//
// O log mostrou exatamente o que ela é:
//
//   messageType: "AlbumMessage",  mediaType: "collection",
//   content: { expectedImageCount: 3, expectedVideoCount: 0 },
//   text: "Album: 3 images"
//
// É um AVISO. O WhatsApp diz "vêm três imagens aí" e manda as três em seguida,
// cada uma como mensagem própria, com id próprio e arquivo próprio — o log da
// mesma rodada mostra as três chegando e as três recebendo o arquivo dois
// segundos depois.
//
// O aviso não carrega arquivo nenhum: o `content` dele são dois números. Era
// por isso que o download falhava ("Mídia que não deu para baixar (content)")
// e a bolha nascia vazia — não havia o que baixar. Aquela bolha era o retrato
// de um download impossível, tentado toda vez que alguém manda um álbum.
//
// Então ele não entra. As três fotos entram, que é o que a pessoa mandou.
//
// O QUE SE PERDE, e é de propósito: dá para reagir a um álbum INTEIRO no
// WhatsApp, e essa reação aponta para o aviso. Sem a linha dele, ela não tem
// onde se prender e fica registrada no log. Uma reação sem lugar é muito menos
// ruim do que uma bolha vazia permanente em toda conversa que receba um álbum.
function ehAvisoDeAlbum(m) {
  if (!m) return false;
  const tipo = String(m.messageType || '').toLowerCase();
  const midia = String(m.mediaType || '').toLowerCase();
  return tipo.includes('album') || midia === 'collection';
}

/** Quantas peças o aviso diz que vêm — só para o log dizer algo útil. */
function quantasNoAlbum(m) {
  const c = (m && m.content) || {};
  const n = Number(c.expectedImageCount || 0) + Number(c.expectedVideoCount || 0);
  return Number.isFinite(n) && n > 0 ? n : null;
}

function tipoCruNaoReconhecido(m) {
  // O álbum já tem tratamento próprio: não é tipo desconhecido, é aviso
  // conhecido. Sem isto, todo álbum recebido imprimiria no log um alerta de
  // 800 caracteres pedindo investigação — e não há mais o que investigar.
  if (ehAvisoDeAlbum(m)) return null;
  const mt = String(m.mediaType || m.messageType || m.type || '').trim();
  if (!mt) return null;                       // não anunciou tipo: não há o que registrar
  const b = mt.toLowerCase();
  const conhecido = ['sticker', 'figurinha', 'image', 'audio', 'voice', 'video',
                     'document', 'file', 'text', 'chat', 'conversation', 'reaction']
    .some((p) => b.includes(p)) || b === 'ptt';
  return conhecido ? null : mt;
}
const tipoDaMidiaHist = tipoDaMensagem;
function previaMidiaHist(tipo) {
  if (tipo === 'figurinha') return '🩹 Figurinha';
  if (tipo === 'imagem') return '📷 Foto';
  if (tipo === 'audio') return '🎤 Mensagem de voz';
  if (tipo === 'video') return '🎬 Vídeo';
  if (tipo === 'documento') return '📄 Documento';
  return '';
}
// ------------------------------------------------------------
//  O HORÁRIO DA BOLHA É O DE QUEM ENVIOU — E NÃO O DE QUANDO GRAVAMOS
//
//  Relato de 02/09, com dois prints: no grupo com dois telefones nossos, a
//  mesma discussão aparecia com horários DIFERENTES em cada telefone.
//
//  A causa: o caminho do webhook nunca preenchia `criado_em`. A coluna tem
//  `now()` por padrão, então o que a equipe lia como "a hora da mensagem" era
//  na verdade A HORA EM QUE O NOSSO SERVIDOR GRAVOU. Dois telefones no mesmo
//  grupo recebem o mesmo texto em dois instantes ligeiramente diferentes — daí
//  o minuto de diferença.
//
//  E O GRUPO É SÓ ONDE ISSO FICOU VISÍVEL. A ponte roda no plano free do
//  Render, que DORME. Quando ela acorda, a fila de webhooks entra toda de uma
//  vez — e uma mensagem enviada às 09h12 pode ser gravada, e mostrada, às
//  09h30. Numa conversa de prazo, a hora errada não é enfeite.
//
//  A importação de histórico JÁ gravava o horário certo. Ou seja: a mesma
//  conversa misturava dois significados de "hora" conforme a mensagem tivesse
//  vindo pelo webhook ou pela releitura — e a ordem das bolhas saía trocada.
//  Por isso os dois caminhos passam a usar ESTA função, e não duas cópias.
//
//  OS LIMITES DE SANIDADE existem porque o horário vem do RELÓGIO DO APARELHO
//  de quem enviou, e relógio de celular erra. Um ano à frente fixaria a
//  mensagem no topo da conversa para sempre; um de 1970, no fundo. Fora da
//  faixa, o horário é descartado e vale o `now()` de antes — que é impreciso,
//  mas nunca absurdo.
// ------------------------------------------------------------
const HORARIO_MINIMO = Date.UTC(2020, 0, 1);       // antes disto, o Zorvin não existia
const FOLGA_DE_RELOGIO = 5 * 60 * 1000;            // 5 min adiantado ainda passa

function horarioDeQuemEnviou(m) {
  if (!m) return null;
  const cru = m.messageTimestamp || m.timestamp || m.momment || m.t || null;
  if (!cru) return null;
  let ts = Number(cru);
  if (!Number.isFinite(ts) || ts <= 0) return null;
  if (ts < 1e12) ts = ts * 1000;                   // veio em segundos
  if (ts < HORARIO_MINIMO) return null;
  if (ts > Date.now() + FOLGA_DE_RELOGIO) return null;
  return new Date(ts).toISOString();
}

// SE O WEBHOOK NÃO TROUXER HORÁRIO, O LOG DIZ — UMA VEZ POR HORA.
//
// O corpo do webhook da Uazapi não está documentado campo a campo, e eu não
// tenho uma captura de tráfego real para afirmar que `messageTimestamp` vem
// sempre. Se não vier, o comportamento é EXATAMENTE o de antes (o `now()` do
// banco) — nada quebra, e nada melhora. O que não pode é isso acontecer em
// silêncio, porque aí a suposição vira verdade sem ninguém ter medido.
//
// Uma vez por hora, e com os nomes das chaves do corpo: é o suficiente para
// saber COMO o horário se chama de verdade, sem encher o log do Render (que no
// plano free é o único lugar onde se enxerga o que a ponte faz).
let ultimoAvisoDeHorario = 0;
function avisarQueOWebhookNaoTrazHorario(m) {
  const agora = Date.now();
  if (agora - ultimoAvisoDeHorario < 60 * 60 * 1000) return;
  ultimoAvisoDeHorario = agora;
  const chaves = m && typeof m === 'object' ? Object.keys(m).join(', ') : '(sem corpo)';
  console.log(
    'O webhook veio SEM horário de envio, então a mensagem fica com a hora em que gravamos. '
    + `Campos que a Uazapi mandou: ${chaves}`);
}

// ------------------------------------------------------------
//  QUEM É A CONVERSA QUE SE VAI RELER — PESSOA OU GRUPO
//
//  A releitura de histórico foi escrita para conversa de uma pessoa só, e num
//  grupo ela batia em três paredes. A primeira era esta: o endereço fazia
//  `replace(/\D/g, '')` no que a pessoa digitava, e um grupo NÃO é um número.
//
//    "120363000000000001@g.us"  ->  "120363000000000001"
//
//  O que sobra parece um telefone e é tratado como um: a rotina criava um
//  CONTATO NOVO com esses dígitos, uma CONVERSA NOVA para ele, e despejava lá
//  dentro o histórico do grupo. O resgate produziria exatamente a bagunça que
//  `juntarConversasDoGrupo` existe para limpar — um grupo espalhado em duas
//  conversas —, e ainda por cima sem resgatar nada na conversa certa.
//
//  A chave de um grupo no banco é `grupo:<jid sem o @g.us>`, e o endereço que a
//  Uazapi entende é `<jid>@g.us`. São duas formas do mesmo grupo, e as duas
//  precisam sair daqui certas.
//
//  NÃO SE ADIVINHA PELO TAMANHO DO NÚMERO. Um JID de grupo tem 18 dígitos e um
//  telefone tem 12 ou 13, e seria fácil (e errado) decidir por aí: no dia em
//  que a WhatsApp mudar o formato, a regra passa a mandar o histórico de um
//  grupo para a conversa de uma pessoa, calada. Quem chama DIZ o que quer —
//  colando o `@g.us` ou o prefixo `grupo:` —, e sem isso vale o de sempre.
// ------------------------------------------------------------
function alvoDoHistorico(entrada) {
  const cru = String(entrada || '').trim();
  const ehGrupo = /@g\.us/i.test(cru) || /^grupo:/i.test(cru);
  const digitos = cru.replace(/^grupo:/i, '').split('@')[0].replace(/\D/g, '');
  if (!digitos) return null;
  if (ehGrupo) {
    return {
      ehGrupo: true,
      chave: 'grupo:' + digitos,
      // Um só: no grupo a Uazapi não tem os dois formatos de sufixo que as
      // conversas de uma pessoa têm.
      enderecos: [`${digitos}@g.us`],
    };
  }
  return {
    ehGrupo: false,
    chave: digitos,
    enderecos: [`${digitos}@s.whatsapp.net`, `${digitos}@c.us`],
  };
}

// Converte uma mensagem do /message/find no formato da nossa tabela "mensagens".
//
// `ehGrupo` decide se a bolha ganha o nome de QUEM ESCREVEU. Era a segunda
// parede do resgate: sem ele, o histórico do grupo entrava como um monólogo de
// balões sem autor — cinco pessoas discutindo e nenhuma identificada —, e ficava
// diferente das mensagens que o webhook grava, que têm o autor desde sempre.
// Duas metades da mesma conversa escritas de dois jeitos é a próxima confusão.
function mapearMensagemHistorico(m, conversaId, ehGrupo = false) {
  const idUazapi = m.messageid || m.id || (m.key && m.key.id) || null;
  if (!idUazapi) return null;
  // O AVISO DE ÁLBUM TAMBÉM NÃO ENTRA POR AQUI. É a mesma mensagem lida por
  // outra porta: importar o histórico de quem já mandou álbuns encheria a
  // conversa das mesmas bolhas vazias que o webhook acabou de parar de criar.
  // Duas leituras diferentes do mesmo evento é sempre uma delas errada.
  if (ehAvisoDeAlbum(m)) return null;
  const fromMe = m.fromMe === true || (m.key && m.key.fromMe === true);
  const tipo = tipoDaMidiaHist(m);
  const texto = m.text || (typeof m.content === 'string' ? m.content : '') || m.caption || null;
  const midiaUrl = m.fileURL || m.mediaUrl || m.url || null;
  const midiaMime = m.mimetype || (m.content && m.content.mimetype) || null;
  const linha = {
    conversa_id: conversaId,
    origem: fromMe ? 'advogado' : 'contato',
    tipo,
    texto,
    midia_url: midiaUrl,
    midia_mime: midiaMime,
    id_uazapi: idUazapi,
    status: fromMe ? 'enviada' : 'recebida',
  };
  const quando = horarioDeQuemEnviou(m);
  if (quando) linha.criado_em = quando;
  // O MESMO `autorNoGrupo` DO WEBHOOK, e não uma segunda leitura dos mesmos
  // campos: duas cópias combinariam hoje e divergiriam na primeira vez que uma
  // delas fosse corrigida. O `{}` no lugar do corpo é de propósito — no
  // histórico não há `body.chat`, e a função já sabe passar sem ele.
  if (ehGrupo) linha.enviado_por = autorNoGrupo({}, m);
  return linha;
}

// ============================================================
//  A PORTA DIZ O QUE NÃO BATE
//
//  Era uma frase só para duas situações opostas: "Acesso negado. Configure
//  IMPORT_TOKEN e informe ?token= correto."
//
//  Quem a recebe não tem como saber se a variável NÃO EXISTE no Render ou se
//  ela existe e o token não confere — e os consertos são diferentes: criar uma
//  variável, ou reconferir o que se colou. Aconteceu em 02/09, no resgate do
//  histórico do grupo: a resposta mandou procurar um erro de digitação num
//  token que estava certo, porque a variável nunca tinha sido criada.
//
//  ACONTECEU DE NOVO em 10/09, e a frase já separava os dois casos: "a variável
//  existe — o que não bate é o valor", com um palpite só, o do espaço em
//  branco. O palpite errou, e quem está do outro lado fica comparando dois
//  textos longos de olho, caractere a caractere, sem saber o que procurar.
//
//  O ENDEREÇO DE NAVEGADOR MEXE NO QUE PASSA POR ELE, e é aí que mora o
//  engano que ninguém desconfia: um `+` dentro do token vira ESPAÇO no
//  caminho, e um `#` corta o endereço ali — o que vem depois nem chega ao
//  servidor. Nos dois casos a pessoa jura ter colado o valor certo, e colou.
//
//  O VALOR NUNCA APARECE: nem no acerto, nem no erro, nem no log. E as pistas
//  abaixo só são ditas quando o que veio já É o token a menos de uma
//  transformação — quem chega nelas já tem a senha inteira na mão. Nada aqui
//  confirma pedaço de senha: um "você acertou o começo" transformaria a porta
//  numa máquina de adivinhar letra por letra.
// ============================================================
const EXEMPLOS_DE_TOKEN = new Set([
  'SEU_IMPORT_TOKEN', 'SEU_TOKEN', 'IMPORT_TOKEN', 'TOKEN', 'seu-token', 'o-token',
]);

const CHECKLIST_DO_TOKEN =
  'Confira, nesta ordem:\n\n'
  + '1. Copie o valor do próprio Render (Environment → o olhinho que revela), e não '
  + 'de anotação guardada.\n'
  + '2. Se o token tiver "+", escreva %2B no lugar dele no endereço: num endereço de '
  + 'navegador, o "+" vira espaço.\n'
  + '3. Se o token tiver "#", o navegador corta o endereço ali e o resto nem chega '
  + 'aqui. Nesse caso troque o token no Render por um sem "#".\n'
  + '4. Confira se não colou junto um espaço ou uma quebra de linha.';

/** Devolve `null` quando a porta pode abrir, ou `{ status, texto }` com o que
 *  responder. O `nome` só aparece no log do servidor. */
function recusaDaPortaAdmin(req, nome) {
  const senha = process.env.IMPORT_TOKEN;
  if (!senha) {
    console.log(`${nome}: recusado porque IMPORT_TOKEN não está configurada no ambiente.`);
    return { status: 403, texto:
      'Esta porta está fechada para todo mundo: a variável IMPORT_TOKEN não existe '
      + 'neste servidor.\n\n'
      + 'Para abri-la: Render → o serviço da ponte → Environment → Add Environment '
      + 'Variable, com o nome IMPORT_TOKEN e uma senha forte que você escolher. '
      + 'Salvar reinicia o serviço; depois use esse MESMO valor no ?token=.' };
  }

  const veio = req.query.token == null ? '' : String(req.query.token);
  if (veio === senha) return null;

  let pista;
  if (!veio) {
    pista = 'Não veio ?token= nenhum no endereço. Ele entra no fim, assim: '
          + '…?token=SEU_VALOR (e, se já houver outro ?algo=, com & no lugar do ?).';
  } else if (EXEMPLOS_DE_TOKEN.has(veio)) {
    pista = `Você colou o exemplo, "${veio}", em vez do valor de verdade. `
          + 'Ele está no Render, em Environment, na variável IMPORT_TOKEN.';
  } else if (veio.trim() === senha) {
    pista = 'É o token certo com espaço em branco colado em volta. Tire o espaço '
          + '(ou a quebra de linha) do começo e do fim.';
  } else if (veio === senha.trim() || veio.trim() === senha.trim()) {
    // O ESPAÇO ESTÁ DO LADO DE LÁ, e o conserto é outro: não adianta mexer no
    // endereço. Colar numa caixa de variável costuma levar uma quebra de linha
    // junto, e aí o valor GUARDADO é que tem o sobrando — quem confere de olho
    // no Render vê o texto certo e não vê o que está depois dele.
    pista = 'O que você mandou está certo. Quem tem espaço em branco em volta é o '
          + 'valor GUARDADO no Render — provavelmente uma quebra de linha colada '
          + 'junto quando a variável foi criada.\n\n'
          + 'Render → o serviço da ponte → Environment → IMPORT_TOKEN → editar, '
          + 'apagar tudo e colar o valor sem espaço no fim. Salvar reinicia a ponte.';
  } else if (veio.replace(/ /g, '+') === senha) {
    // O ENGANO QUE NINGUÉM DESCONFIA. O "+" é a forma antiga de escrever espaço
    // num endereço, então o token chega aqui com espaços onde tinha "+".
    pista = 'É o token certo, mas ele tem "+" — e num endereço de navegador o "+" '
          + 'vira espaço. Escreva %2B no lugar de cada "+", ou troque o token no '
          + 'Render por um sem "+".';
  } else if (veio.replace(/^["'\s]+|["'\s]+$/g, '') === senha) {
    pista = 'É o token certo com aspas em volta. Tire as aspas.';
  } else if (veio.toLowerCase() === senha.toLowerCase()) {
    pista = 'É o token certo, com maiúscula onde era minúscula (ou o contrário). '
          + 'Ele diferencia as duas.';
  } else {
    pista = CHECKLIST_DO_TOKEN;
  }

  return { status: 403, texto:
    'O ?token= não confere com o IMPORT_TOKEN deste servidor.\n\n'
    + 'A variável existe — o que não bate é o valor.\n\n' + pista };
}

app.get('/importar-historico', async (req, res) => {
  try {
    const recusa = recusaDaPortaAdmin(req, 'Histórico');
    if (recusa) return res.status(recusa.status).send(recusa.texto);
    const advogadoNumero = String(req.query.advogado || '').replace(/\D/g, '');
    const alvo = alvoDoHistorico(req.query.contato);
    const limiteTotal = Math.min(parseInt(req.query.limite || '500', 10) || 500, 5000);
    if (!advogadoNumero || !alvo) {
      // A MENSAGEM DIZ O QUE DIGITAR. Quem abre este endereço é uma pessoa num
      // navegador: "informe advogado e contato" não ensina que um grupo se
      // escreve de outro jeito, e ela tentaria com os dígitos — que é
      // justamente o caminho que criava conversa duplicada.
      return res.status(400).send(
        'Informe advogado e contato.\n\n'
        + 'Pessoa: contato=5511999998888 (só números).\n'
        + 'Grupo:  contato=120363000000000001@g.us (com o @g.us).');
    }
    const contatoNumero = alvo.chave;

    const { data: adv } = await supabase.from('advogados')
      .select('id, token, servidor').eq('numero', advogadoNumero).maybeSingle();
    if (!adv || !adv.token) return res.status(404).send('Advogado não encontrado (ou sem token) no banco.');

    // Garante contato e conversa.
    //
    // O erro destas duas era jogado fora, e o `contUp.id` da linha seguinte
    // estourava em cima do nulo. Quem roda isto é uma pessoa, num navegador, e
    // o que ela recebia era "Cannot read properties of null (reading 'id')" —
    // o sintoma de um erro que ninguém conferiu, mostrado a quem não pode
    // fazer nada com ele.
    const { data: contUp, error: erroContato } = await supabase.from('contatos')
      .upsert({ numero: contatoNumero }, { onConflict: 'numero' }).select('id').single();
    if (erroContato || !contUp) {
      console.error('Histórico: não consegui garantir o contato —', erroContato && erroContato.message);
      return res.status(502).send(
        'Não consegui preparar o contato no banco, então parei antes de importar qualquer coisa. '
        + 'Nada foi alterado. Tente de novo em alguns minutos.');
    }
    const { data: conv, error: erroConversa } = await supabase.from('conversas')
      .upsert({ advogado_id: adv.id, contato_id: contUp.id }, { onConflict: 'advogado_id,contato_id' })
      .select('id').single();
    if (erroConversa || !conv) {
      console.error('Histórico: não consegui garantir a conversa —', erroConversa && erroConversa.message);
      return res.status(502).send(
        'Não consegui preparar a conversa no banco, então parei antes de importar qualquer coisa. '
        + 'Nada foi alterado. Tente de novo em alguns minutos.');
    }

    const servidor = (adv.servidor || 'https://novaera.uazapi.com').replace(/\/$/, '');
    const PAG = 100;

    // Busca uma página do histórico; tenta os dois formatos de "chatid".
    async function buscarPagina(chatid, offset) {
      const r = await fetchComTimeout(`${servidor}/message/find`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'token': adv.token },
        body: JSON.stringify({ chatid, limit: PAG, offset }),
      }, 25000);
      if (!r.ok) { console.error('message/find HTTP', r.status); return null; }
      const dados = await r.json().catch(() => ({}));
      if (Array.isArray(dados)) return dados;
      return dados.messages || dados.data || dados.results || [];
    }

    // Descobre qual sufixo de chatid a Uazapi aceita (varia por versão). Num
    // grupo há um só, e é o `@g.us` — tentar `@s.whatsapp.net` ali devolveria
    // vazio e a rotina anunciaria "0 mensagens" para um grupo cheio delas.
    let chatid = alvo.enderecos[0];
    let primeira = await buscarPagina(chatid, 0);
    for (const alt of alvo.enderecos.slice(1)) {
      if (primeira && primeira.length) break;
      const tent = await buscarPagina(alt, 0);
      if (tent && tent.length) { chatid = alt; primeira = tent; }
    }

    let importadas = 0, vistas = 0, offset = 0, comArquivo = 0, semArquivo = 0;
    let pagina = primeira || [];
    while (pagina && pagina.length && vistas < limiteTotal) {
      // O QUE JÁ ESTÁ AQUI.
      //
      // A gravação ignora repetida em silêncio (é o que torna seguro rodar de
      // novo), então "não deu erro" NÃO quer dizer "entrou". Contando assim, a
      // segunda execução anunciava "Importei 500 mensagens" tendo importado
      // zero — e esse número é a única resposta que a tela dá.
      //
      // Saber de antemão o que já existe serve para duas coisas: contar a
      // verdade, e não baixar de novo as fotos que já estão guardadas.
      const linhas = pagina.map((m) => ({ m, linha: mapearMensagemHistorico(m, conv.id, alvo.ehGrupo) }))
                           .filter((x) => x.linha);
      //
      // O QUE JÁ ESTÁ **NESTA CONVERSA**, e não no banco inteiro.
      //
      // É a diferença que faz esta importação servir de resgate. Num grupo com
      // dois telefones nossos, a mensagem que falta aqui EXISTE lá — na conversa
      // do outro telefone. Perguntando ao banco inteiro, ela seria dada como
      // "já conhecida" e pulada: a importação rodaria, diria "0 novas", e
      // deixaria o buraco exatamente onde estava.
      const idsDaPagina = linhas.map((x) => x.linha.id_uazapi);
      const conhecidas = new Set();
      if (idsDaPagina.length) {
        const { data: jaTem } = await supabase.from('mensagens')
          .select('id_uazapi')
          .eq('conversa_id', conv.id)
          .in('id_uazapi', idsDaPagina);
        for (const x of jaTem || []) conhecidas.add(x.id_uazapi);
      }

      for (const { m, linha } of linhas) {
        if (conhecidas.has(linha.id_uazapi)) continue;

        // A FOTO DO HISTÓRICO PRECISA SER BAIXADA, IGUAL À QUE CHEGA AGORA.
        //
        // O endereço que a Uazapi devolve aponta para o servidor do WhatsApp:
        // é temporário e vem cifrado. Guardá-lo na mensagem importa uma bolha
        // que não abre — hoje ou daqui a alguns dias —, e nada na tela
        // explicaria por quê. O caminho do webhook já copia o arquivo para o
        // Storage; aqui faltava fazer o mesmo.
        if (linha.tipo !== 'texto') {
          const guardada = await baixarMidiaRecebida(
            servidor, adv.token, { messageid: linha.id_uazapi, content: m.content }, linha.midia_mime);
          if (guardada) { linha.midia_url = guardada; comArquivo++; }
          else semArquivo++;
        }

        const erro = await salvarMensagem(linha, null);
        if (!erro) importadas++;
      }
      vistas += pagina.length;
      offset += pagina.length;
      if (pagina.length < PAG) break; // última página
      pagina = await buscarPagina(chatid, offset);
    }

    // Conserta a prévia e a ordem da conversa: a mensagem mais recente pode ter
    // mudado se o histórico trouxe algo posterior ao que havia aqui.
    //
    // O `nao_lidas: 0` que existia aqui saiu. A intenção era "histórico
    // importado não é mensagem nova" — e não é mesmo: esta rotina grava direto
    // em `mensagens`, sem passar pela contagem que o webhook faz, então ela
    // nunca somou nada ao selo. Zerar não corrigia um efeito colateral: apagava
    // aviso de mensagem de verdade, ainda por ler, que nada tinha a ver com a
    // importação. Quem importasse o passado de um cliente marcava como lidas as
    // mensagens que ele mandou hoje de manhã.
    const { data: ult } = await supabase.from('mensagens')
      .select('texto, tipo, criado_em').eq('conversa_id', conv.id)
      .order('criado_em', { ascending: false }).limit(1);
    const u = ult && ult[0];
    if (u) {
      await supabase.from('conversas').update({
        ultima_mensagem: u.texto || previaMidiaHist(u.tipo) || '[mídia]',
        ultima_atividade: u.criado_em,
      }).eq('id', conv.id);
    }

    console.log(`Histórico: ${importadas} novas de ${vistas} vistas (contato ${contatoNumero}).`);
    const sobreArquivos = comArquivo || semArquivo
      ? ` Guardei ${comArquivo} arquivo(s)`
        + (semArquivo ? `; ${semArquivo} não deu(ram) para baixar da Uazapi.` : '.')
      : '';
    return res.status(200).send(
      importadas === 0
        ? `Pronto! Nenhuma mensagem nova: as ${vistas} que a Uazapi tinha do contato `
          + `${contatoNumero} já estavam aqui.${sobreArquivos}`
        : `Pronto! Importei ${importadas} mensagem(ns) do contato ${contatoNumero} `
          + `(vistas ${vistas}).${sobreArquivos} Abra o painel para conferir.`
    );
  } catch (e) {
    console.error('Erro ao importar histórico:', e.message);
    return res.status(500).send('Erro ao importar: ' + e.message);
  }
});

// ============================================================
//  PARTE 1 — RECEBER mensagens
// ============================================================
//
// QUEM PODE ESCREVER AQUI.
//
// Este endereço não pedia nada. Qualquer pessoa que descobrisse a URL da ponte
// podia mandar um POST e a mensagem entrava no banco como se tivesse chegado do
// cliente: aparecia na conversa, contava no Painel, e ficava no histórico do
// escritório. Num escritório de advocacia isso não é um incômodo — é um
// registro forjado.
//
// A trava é um segredo combinado, aceito de duas formas (na URL ou no
// cabeçalho), porque nem todo provedor deixa mandar cabeçalho no webhook.
//
// ENQUANTO `WEBHOOK_TOKEN` NÃO ESTIVER CONFIGURADO, tudo passa — e a ponte
// avisa no log. É de propósito: ligar a exigência antes de o endereço na Uazapi
// ter o segredo faria as mensagens dos clientes pararem de chegar, em silêncio.
// A ordem certa é: primeiro põe o `?token=` no endereço da Uazapi, depois cria
// a variável aqui.
let avisouSemSegredo = false;
function webhookAutorizado(req) {
  const esperado = String(process.env.WEBHOOK_TOKEN || '').trim();
  if (!esperado) {
    if (!avisouSemSegredo) {
      avisouSemSegredo = true;
      console.warn(
        'ATENÇÃO: /webhook está SEM segredo. Qualquer um que saiba o endereço ' +
        'pode inserir mensagens. Configure WEBHOOK_TOKEN (e ponha ?token=… no ' +
        'endereço do webhook na Uazapi).');
    }
    return true;
  }
  const veio = String(
    req.query.token || req.headers['x-webhook-token'] || req.headers['x-api-key'] || '').trim();
  // Comparação de tamanho fixo não faz diferença prática aqui (o segredo vai na
  // URL, e o atacante não tem como medir microssegundos pela internet), mas o
  // custo de fazer certo é zero.
  if (veio.length !== esperado.length) return false;
  let diferenca = 0;
  for (let i = 0; i < esperado.length; i += 1) diferenca |= veio.charCodeAt(i) ^ esperado.charCodeAt(i);
  return diferenca === 0;
}

// ------------------------------------------------------------
//  UM WEBHOOK RECUSADO PRECISA DIZER DE QUEM ERA
//
//  A linha era só "Webhook recusado: segredo ausente ou errado." — e com ela
//  não dá para separar dois casos que pedem coisas opostas:
//
//    • um telefone da Uazapi cadastrado com o endereço SEM o `?token=`. Aí
//      são MENSAGENS DE CLIENTE sendo jogadas fora, e ninguém percebe: a
//      conversa simplesmente não aparece no painel.
//    • alguém varrendo a internet e batendo na porta. Aí é ruído, e recusar é
//      exatamente o certo.
//
//  Em 19/08 apareceram vinte recusas em vinte minutos, sempre em volta dos
//  envios. Vinte mensagens perdidas e vinte batidas de porta se escrevem
//  igual no log — e é essa igualdade que precisa acabar.
//
//  O QUE VAI E O QUE NÃO VAI. Vai o telefone dono do evento, o tipo do
//  evento, de que endereço veio, e SE veio um segredo (ausente é
//  configuração; errado é outra coisa). Não vai o segredo, nem um pedaço
//  dele: um log de escritório de advocacia é lugar onde muita gente entra e
//  nada se apaga.
// ------------------------------------------------------------
const recusasContadas = new Map();   // quem → quantas, desde quando

function contarRecusa(req) {
  const b = (req && req.body) || {};
  const dono = String(b.owner || b.instance || b.instanceName
    || (b.event && (b.event.owner || b.event.Chat)) || '').slice(0, 40) || 'sem dono no corpo';
  const tipo = String(b.EventType || b.event_type || b.event || '').slice(0, 30) || 'sem tipo';
  const veioAlgo = !!String(req.query.token || req.headers['x-webhook-token']
    || req.headers['x-api-key'] || '').trim();
  const de = (req.headers['x-forwarded-for'] || req.ip || '').split(',')[0].trim();

  // AGRUPADO, senão a informação some no próprio volume. Vinte linhas iguais
  // por minuto empurram para fora do log tudo o que interessa — inclusive o
  // que a gente foi ali procurar.
  const chave = `${dono}|${tipo}|${veioAlgo}|${de}`;
  const antes = recusasContadas.get(chave);
  const agora = Date.now();
  if (antes && agora - antes.desde < 60000) { antes.quantas += 1; return; }
  const quantas = antes ? antes.quantas : 0;
  recusasContadas.set(chave, { quantas: 1, desde: agora });

  console.warn(`Webhook recusado (${veioAlgo ? 'segredo ERRADO' : 'sem segredo nenhum'}): `
    + `evento "${tipo}" do telefone "${dono}", vindo de ${de || 'origem desconhecida'}.`
    + (quantas > 1 ? ` [${quantas} iguais no último minuto]` : '')
    + (veioAlgo ? '' : ' Se este telefone é do escritório, o endereço do webhook '
      + 'dele na Uazapi está sem o "?token=…" — e as mensagens dele estão sendo PERDIDAS.'));
}

// ------------------------------------------------------------
//  TELEFONE QUE MANDA MENSAGEM E NÃO ESTÁ CADASTRADO
//
//  O webhook chega, o segredo confere, e o telefone dono do evento não está na
//  tabela `advogados`. A mensagem é descartada — não há em qual conversa
//  colocá-la. Até aqui, correto.
//
//  O QUE ESTAVA ERRADO ERA O SILÊNCIO. A linha era um `console.log` de duas
//  palavras no meio de milhares, e não dizia a única coisa que importa: que
//  são MENSAGENS DE CLIENTE sendo jogadas fora.
//
//  O sintoma para quem usa é cruel, porque o envio continua funcionando: as
//  mensagens saem, chegam no cliente, o cliente responde — e a resposta some.
//  Do lado de cá parece que "o cliente não retorna". Foi exatamente assim que
//  isto chegou, em 21/08: um telefone do escritório onde "os clientes não
//  respondem", e o mesmo cliente respondendo normalmente por outro telefone.
//
//  Agora grita, agrupado, dizendo o número e o que fazer. E fica guardado para
//  o `/webhook/desconhecidos` responder sem ninguém precisar caçar no log — que
//  é o que transforma "achamos que tem interferência" numa resposta.
// ------------------------------------------------------------
// ------------------------------------------------------------
//  QUAL TELEFONE ESTÁ MANDANDO EVENTO, E QUAL ESTÁ MUDO
//
//  Sobrou uma causa que o código não tem como consertar e que ninguém tinha
//  como ver: a URL do webhook é configurada POR TELEFONE, dentro da Uazapi. Se
//  a de um deles estiver vazia ou errada, NADA chega aqui — nenhum log, nenhum
//  descarte, nenhuma recusa. E o envio continua funcionando, porque sai por
//  outro caminho.
//
//  Do lado de quem atende isso é indistinguível de "o cliente não responde". Foi
//  o relato de 21/08, e as duas primeiras explicações (telefone não cadastrado,
//  telefone cadastrado duas vezes) foram descartadas com os dados na mão.
//
//  Nenhuma lista de erro responde isso, porque não há erro: há AUSÊNCIA. A
//  única forma de enxergar ausência é comparar com quem está presente — daí
//  esta tabela, que põe lado a lado todos os telefones cadastrados e quando
//  cada um mandou o último evento. "3857: nunca; 1932: há 2 minutos" responde a
//  pergunta em um segundo.
// ------------------------------------------------------------
const PONTE_SUBIU_EM = Date.now();
const ultimoEventoPorTelefone = new Map();   // número → quando

function anotarEventoDe(numero) {
  if (numero) ultimoEventoPorTelefone.set(String(numero), Date.now());
}

const telefonesDesconhecidos = new Map();   // número → { quantas, desde, ultima, motivo }
const duplicadosAvisados = new Map();      // número → quando avisamos

const MOTIVOS = {
  nao_cadastrado:
    'não está na tabela "advogados". Cadastre o número para as respostas '
    + 'voltarem a entrar.',
  busca:
    'ESTÁ cadastrado, mas a busca por ele FALHOU. A causa mais comum é o mesmo '
    + 'número cadastrado DUAS VEZES em "advogados" — confira e apague a linha '
    + 'repetida.',
};

function mensagemDescartada(numero, motivo, detalhe) {
  const chave = numero || 'sem número no corpo';
  const antes = telefonesDesconhecidos.get(chave);
  const agora = Date.now();
  if (antes) {
    antes.quantas += 1;
    antes.ultima = agora;
    antes.motivo = motivo;
    // Uma linha por minuto por telefone. Sem o freio, um telefone movimentado
    // empurra para fora do log tudo o que interessa — inclusive isto.
    if (agora - antes.avisadoEm < 60000) return;
    antes.avisadoEm = agora;
  } else {
    telefonesDesconhecidos.set(chave, {
      quantas: 1, desde: agora, ultima: agora, avisadoEm: agora, motivo,
    });
  }
  const reg = telefonesDesconhecidos.get(chave);
  console.warn(
    `MENSAGEM DE CLIENTE PERDIDA: o telefone "${chave}" mandou um evento e a `
    + `mensagem foi descartada — ela não aparece em conversa nenhuma no Zorvin. `
    + `Motivo: ${MOTIVOS[motivo] || motivo}`
    + (detalhe ? ` (${String(detalhe).slice(0, 160)})` : '')
    + ` [${reg.quantas} desde ${new Date(reg.desde).toISOString().slice(11, 16)}] `
    + `O envio POR este telefone continua funcionando, e é isso que faz parecer `
    + `que "o cliente não responde".`);
}

// Cadastro repetido não derruba mais nada, mas continua sendo defeito de
// cadastro: duas linhas para o mesmo telefone significam duas configurações
// possíveis (token, servidor, departamento) e nenhuma garantia de qual vale.
function avisarDuplicado(numero) {
  const agora = Date.now();
  const antes = duplicadosAvisados.get(numero);
  if (antes && agora - antes < 3600000) return;   // uma vez por hora, e basta
  duplicadosAvisados.set(numero, agora);
  console.warn(
    `CADASTRO REPETIDO: o telefone "${numero}" aparece MAIS DE UMA VEZ na `
    + 'tabela "advogados". Usei a primeira linha e as mensagens continuam '
    + 'entrando, mas qual token e qual departamento valem passa a ser sorte. '
    + 'Apague a linha repetida.');
}

// Quem está tendo mensagem descartada, e por quê. Aberto de propósito: não
// devolve conteúdo de mensagem nenhuma, só números de telefone do escritório e
// contagem — e serve justamente para quem não tem acesso ao log da Render
// conseguir responder "por que este telefone não recebe resposta?".
app.get('/webhook/desconhecidos', (req, res) => {
  liberarCors(res);
  const lista = [...telefonesDesconhecidos.entries()]
    .map(([numero, r]) => ({
      numero,
      eventos_descartados: r.quantas,
      motivo: r.motivo || 'nao_cadastrado',
      o_que_fazer: MOTIVOS[r.motivo] || 'motivo desconhecido',
      desde: new Date(r.desde).toISOString(),
      ultimo: new Date(r.ultima).toISOString(),
    }))
    .sort((a, b) => b.eventos_descartados - a.eventos_descartados);
  res.json({
    ok: true,
    // Contado desde que a ponte subiu: é memória, não banco. Vazio pode
    // significar "nenhum problema" OU "a ponte reiniciou agora" — dizer isso
    // aqui evita que a lista vazia seja lida como atestado de saúde.
    desde_o_ultimo_reinicio: true,
    cadastros_repetidos: [...duplicadosAvisados.keys()],
    telefones: lista,
    recado: lista.length
      ? 'Estes telefones mandaram mensagem e ela foi DESCARTADA — não aparece '
        + 'em conversa nenhuma. Veja "o_que_fazer" em cada um.'
      : 'Nenhuma mensagem descartada desde que a ponte subiu.',
  });
});

// A TABELA QUE RESPONDE "POR QUE ESTE TELEFONE NÃO RECEBE RESPOSTA?".
//
// Põe lado a lado TODOS os telefones cadastrados e quando cada um mandou o
// último evento. Um telefone mudo enquanto os outros falam é webhook não
// configurado na Uazapi — a única causa que não deixa rastro nenhum aqui.
//
// Não devolve conteúdo de mensagem nenhuma: número, nome e horário.
app.get('/webhook/telefones', async (req, res) => {
  liberarCors(res);
  const desdeMin = Math.round((Date.now() - PONTE_SUBIU_EM) / 60000);
  let cadastrados = [];
  try {
    const { data } = await supabase.from('advogados').select('numero, nome, ativo');
    cadastrados = data || [];
  } catch (_e) { /* sem banco, ainda dá para mostrar quem mandou evento */ }

  const linhas = cadastrados.map((a) => {
    const numero = String(a.numero || '').replace(/\D/g, '');
    const quando = ultimoEventoPorTelefone.get(numero) || null;
    return {
      numero, nome: a.nome || '', ativo: a.ativo !== false,
      ultimo_evento: quando ? new Date(quando).toISOString() : null,
      ha_minutos: quando ? Math.round((Date.now() - quando) / 60000) : null,
      mudo: !quando,
    };
  }).sort((x, y) => Number(y.mudo) - Number(x.mudo));

  // Telefones que mandaram evento e NÃO estão na lista de cadastrados. É o
  // outro lado da mesma pergunta, e some do radar se não for dito.
  const conhecidos = new Set(linhas.map((l) => l.numero));
  const forasteiros = [...ultimoEventoPorTelefone.keys()].filter((n) => !conhecidos.has(n));

  const mudos = linhas.filter((l) => l.mudo && l.ativo);
  res.json({
    ok: true,
    ponte_no_ar_ha_minutos: desdeMin,
    // A contagem vive na MEMÓRIA e zera a cada publicação. Uma ponte que subiu
    // agora mostra todo mundo mudo, e isso não quer dizer nada — dizer o tempo
    // aqui é o que impede a tabela de ser lida como um diagnóstico quando ela
    // ainda é só um cronômetro começando.
    telefones: linhas,
    mandaram_evento_e_nao_estao_cadastrados: forasteiros,
    recado: desdeMin < 30
      ? `A ponte subiu há ${desdeMin} min. Espere o movimento normal de algumas `
        + 'horas antes de concluir qualquer coisa: telefone mudo agora pode ser '
        + 'só falta de mensagem.'
      : (mudos.length
        ? `${mudos.length} telefone(s) ativo(s) não mandaram NENHUM evento em `
          + `${desdeMin} min, enquanto os outros mandaram. O suspeito é a URL do `
          + 'webhook DELES na Uazapi — cada telefone tem a sua, e sem ela as '
          + 'mensagens dos clientes não chegam aqui. O envio continua '
          + 'funcionando, e é isso que faz parecer que "o cliente não responde".'
        : 'Todos os telefones ativos já mandaram evento. O webhook está chegando '
          + 'de todos eles.'),
  });
});

// O CORPO DO WEBHOOK É UMA FUNÇÃO COM NOME, e não uma anônima dentro do
// `app.post`. A diferença é o que permite CONTAR quantos estão em voo: quem
// registra a rota, logo abaixo, envolve a chamada e sabe quando ela termina.
//
// A alternativa seria costurar um `finally` neste corpo — que tem vinte pontos
// de saída, cada um deles um `return` no meio de um `if`. Bastaria esquecer um
// para a conta nunca voltar a zero, e aí o desligamento esperaria o prazo
// inteiro toda vez, para nada.
// ============================================================
//  A CAIXA DE ENTRADA — o evento existe antes de ser entendido
//
//  Este é o conserto do achado mais grave do diagnóstico. O webhook prometia
//  "OK" à Uazapi e só depois ia gravar; morrer nesse intervalo era a mensagem
//  do cliente sumindo, com a Uazapi achando que tinha entregue.
//
//  As etapas anteriores encolheram a janela (o Vantoro saiu do caminho, e a
//  saída passou a esperar o que está em voo), mas ela continuava existindo — e
//  janela pequena é a que morde no dia movimentado, que é o dia em que a
//  mensagem perdida custa caro.
//
//  A CAIXA NÃO É UMA FILA DE PROCESSAMENTO. O evento continua sendo tratado na
//  hora, no mesmo instante de sempre; o que ela acrescenta é um LUGAR onde ele
//  existe enquanto isso. Se o tratamento terminar, a linha é marcada e pronto.
//  Se não terminar — o processo morreu, o banco recusou, deu erro no meio —, a
//  rodada de recuperação a encontra e termina o serviço.
//
//  SEM A TABELA, TUDO FUNCIONA COMO ANTES. `eventos_recebidos` nasce de um SQL
//  que alguém precisa rodar, e é assim que este projeto aplica esquema. Fazer o
//  webhook depender dela sem ela existir seria trocar uma perda rara por uma
//  parada total: TODA mensagem passaria a receber 503. Então a primeira recusa
//  por "tabela não existe" desliga a caixa, avisa no log, e a ponte volta a se
//  comportar exatamente como se comportava — que é o pior caso aceitável, e é o
//  caso de hoje.
// ============================================================
const CAIXA = 'eventos_recebidos';
let caixaDesligada = false;   // a tabela não existe: segue como antes

/** A tabela não existe? É diferente de "o banco recusou agora". */
const semATabela = (erro) => Boolean(erro) && (
  ['42P01', 'PGRST205', 'PGRST106'].includes(String(erro.code))
  || /relation .* does not exist|could not find the table/i.test(String(erro.message || '')));

/**
 * Guarda o evento cru e devolve `{ id }`.
 *
 * `{ recusar: true }` quer dizer "não prometa nada à Uazapi": o banco está
 * fora, e responder OK seria mentir. `{ id: null }` é a caixa desligada — a
 * ponte segue como antes, e o evento é tratado sem rede.
 */
async function guardarNaCaixaDeEntrada(corpo) {
  if (caixaDesligada) return { id: null };
  try {
    const { data, error } = await supabase
      .from(CAIXA).insert({ corpo }).select('id').single();
    if (!error) return { id: data.id };

    if (semATabela(error)) {
      caixaDesligada = true;
      console.warn(
        `ATENÇÃO: a tabela "${CAIXA}" não existe, então a caixa de entrada está `
        + 'DESLIGADA e a ponte volta a se comportar como antes: o webhook responde '
        + '"OK" antes de gravar, e uma queda no meio do tratamento perde a mensagem. '
        + 'Rode sql/2026-09-a-caixa-de-entrada-do-webhook.sql no Supabase para ligá-la.');
      return { id: null };
    }
    return { recusar: true, erro: error.message };
  } catch (e) {
    return { recusar: true, erro: (e && e.message) || String(e) };
  }
}

/** Marca o evento como resolvido — ou guarda o motivo de não ter sido. */
async function fecharEvento(id, erro) {
  if (!id) return;
  const campos = erro
    ? { erro: String(erro).slice(0, 500) }
    : { processado_em: new Date().toISOString(), erro: null };
  const { error } = await supabase.from(CAIXA).update(campos).eq('id', id);
  // Falhar AQUI não perde nada: sem a marca, o evento continua pendente e a
  // rodada de recuperação o pega de novo. O `id_uazapi` único é o que impede
  // isso de virar mensagem repetida.
  if (error) console.log(`Caixa de entrada: não consegui marcar o evento ${id} (${error.message}).`);
}

/** Trata o evento e fecha a linha dele. Nunca levanta: é chamada sem `await`. */
async function concluirEvento(id, corpo) {
  try {
    await processarEventoDoWebhook(corpo);
    await fecharEvento(id, null);
  } catch (e) {
    console.error('Erro inesperado no webhook:', (e && e.message) || e);
    await fecharEvento(id, (e && e.message) || e);
  }
}

// ------------------------------------------------------------
//  A RODADA QUE TERMINA O QUE FICOU PELA METADE
//
//  Pega os eventos que nunca foram fechados e os trata de novo. É ela que
//  transforma a caixa numa rede de verdade: sem ela, a linha pendente seria
//  só um registro de que algo se perdeu.
//
//  SÓ OS PARADOS HÁ MAIS DE UM MINUTO. O evento que chegou agora está sendo
//  tratado neste instante pelo caminho normal — pegá-lo aqui seria tratar duas
//  vezes o que não precisa.
//
//  E REPETIR É SEGURO, que é o que torna isto possível: a mensagem tem
//  `id_uazapi` único, o contato e a conversa são `upsert`, e a fila de envio
//  não é tocada por este caminho. O pior caso de um evento tratado duas vezes é
//  a segunda não fazer nada.
//
//  O TETO DE TENTATIVAS existe porque nem toda falha passa: um evento que a
//  ponte não sabe tratar falharia para sempre, cinco vezes por minuto, enchendo
//  o log e batendo no banco à toa. Cinco vezes e ele para de ser tentado — mas
//  NÃO é apagado, e o log diz que ele existe. Um evento que ninguém consegue
//  tratar é uma mensagem de cliente parada: alguém precisa saber.
// ------------------------------------------------------------
const CAIXA_ESPERA_MS = 60 * 1000;
const CAIXA_MAX_TENTATIVAS = 5;
let caixaRodando = false;
let caixaLimpaEm = 0;

async function terminarOsPendentes() {
  if (desligando || caixaDesligada || caixaRodando) return;
  caixaRodando = true;
  try {
    const limite = new Date(Date.now() - CAIXA_ESPERA_MS).toISOString();
    const { data: pendentes, error } = await supabase
      .from(CAIXA).select('id, corpo, tentativas')
      .is('processado_em', null)
      .lt('recebido_em', limite)
      .lt('tentativas', CAIXA_MAX_TENTATIVAS)
      .order('recebido_em', { ascending: true })
      .limit(20);
    if (error) {
      if (semATabela(error)) { caixaDesligada = true; return; }
      console.log(`Caixa de entrada: não consegui ler os pendentes (${error.message}).`);
      return;
    }
    if (!pendentes || !pendentes.length) return;

    console.log(`Caixa de entrada: ${pendentes.length} evento(s) ficaram pela metade; terminando agora.`);
    for (const ev of pendentes) {
      if (desligando) break;   // a saída manda: o resto fica para a próxima ponte
      // A TENTATIVA É CONTADA ANTES, e não depois. Contar no fim faz o evento
      // que derruba o processo nunca somar nada — e ele voltaria para sempre,
      // derrubando a ponte a cada rodada.
      const { error: erroClaim } = await supabase.from(CAIXA)
        .update({ tentativas: (ev.tentativas || 0) + 1, processando_em: new Date().toISOString() })
        .eq('id', ev.id);
      if (erroClaim) { console.log(`Caixa: não consegui marcar a tentativa (${erroClaim.message}).`); continue; }
      await concluirEvento(ev.id, ev.corpo);
    }

    // A LIMPEZA, UMA VEZ POR HORA. A caixa só cresce, e uma tabela que só
    // cresce é um problema adiado — o valor de uma linha acaba no minuto em que
    // ela é processada. Os PENDENTES nunca são apagados: um evento que não
    // entrou é a única pista de uma mensagem que talvez tenha faltado.
    if (Date.now() - caixaLimpaEm > 60 * 60 * 1000) {
      caixaLimpaEm = Date.now();
      const { data: apagados, error: erroLimpeza } = await supabase.rpc('limpar_eventos_recebidos');
      if (erroLimpeza) console.log(`Caixa de entrada: não consegui limpar (${erroLimpeza.message}).`);
      else if (apagados) console.log(`Caixa de entrada: ${apagados} evento(s) antigo(s) apagado(s).`);
    }

    // OS QUE DESISTIRAM PRECISAM SER DITOS. Um evento que falhou cinco vezes é
    // uma mensagem de cliente que não entrou, e ela não pode ficar só numa
    // linha de tabela que ninguém abre.
    const { data: desistidos } = await supabase
      .from(CAIXA).select('id, erro')
      .is('processado_em', null)
      .gte('tentativas', CAIXA_MAX_TENTATIVAS)
      .limit(5);
    for (const d of desistidos || []) {
      console.error(`CAIXA DE ENTRADA: o evento ${d.id} falhou ${CAIXA_MAX_TENTATIVAS} vezes e `
        + `não será mais tentado. Ele NÃO virou mensagem em conversa nenhuma. `
        + `Último erro: ${d.erro || 'sem detalhe'}`);
    }
  } catch (e) {
    console.error('Caixa de entrada:', (e && e.message) || e);
  } finally {
    caixaRodando = false;
  }
}

// O CORPO DO EVENTO, E NÃO O PEDIDO HTTP.
//
// Esta função passou a receber o `corpo` já lido, e não `req`/`res`. É o que
// permite chamá-la DUAS VEZES pela mesma mensagem: uma quando ela chega, e
// outra mais tarde, a partir da caixa de entrada, se a primeira não terminou.
// Um evento reprocessado não tem pedido HTTP para responder — ele vem do banco.
//
// E ELA DEIXOU DE ENGOLIR O ERRO. Antes o `catch` do fim escrevia uma linha no
// log e devolvia normalmente, então quem chamou não tinha como saber se a
// mensagem entrou. Agora o erro sobe: é ele que faz o evento continuar
// pendente na caixa, para ser tentado de novo, em vez de sumir.
async function processarEventoDoWebhook(corpo) {
  // Antes de qualquer leitura: quem MANDOU já é a informação, mesmo que o
  // evento seja descartado adiante. É o que separa "não chega" de "chega e cai".
  try {
    const b = corpo || {};
    anotarEventoDe(String(b.owner || (b.message && b.message.owner) || '').replace(/\D/g, ''));
  } catch (_e) { /* nunca pode derrubar o webhook */ }

  {
    const body = corpo;
    const evento = (body.EventType || body.event || '').toLowerCase();

    // Eventos que NÃO são mensagens: status (entregue/lida) e presença
    // ("digitando…"). Tentamos tratar os dois; nada quebra se não reconhecer.
    if (evento && evento !== 'messages') {
      await tratarPresenca(body, evento);
      await tratarStatusMensagem(body, evento);
      return;
    }

    if (evento !== 'messages' || !body.message) return;

    const m = body.message;

    // Se a mensagem foi enviada pelo próprio Zorvin (pela API), a ponte já
    // registrou ela no banco na hora do envio. Este aviso é só um "eco" —
    // ignoramos para não duplicar.
    if (m.wasSentByApi === true) {
      console.log('Eco de mensagem enviada pelo Zorvin; ignorado.');
      return;
    }

    // De qual ADVOGADO é esta conversa (owner = número do dono da instância).
    // Normaliza para só dígitos (igual ao contato), senão um owner formatado
    // não bate com o cadastro e a mensagem seria descartada.
    const advogadoNumero = String(body.owner || m.owner || '').replace(/\D/g, '');
    // select('*') em vez da lista de colunas: assim a frente_fixa (números de
    // uso interno, como RH e cadastro) vem junto sem quebrar quem ainda não
    // rodou o SQL das frentes — pedir uma coluna inexistente daria erro e a
    // mensagem seria descartada.
    //
    // `limit(2)` E NÃO `maybeSingle()`. O `maybeSingle` devolve ERRO quando acha
    // mais de uma linha — e um telefone cadastrado DUAS VEZES em `advogados`
    // (coisa que acontece: alguém cadastra de novo achando que faltava) fazia
    // toda mensagem daquele número ser descartada, com um `console.error` que
    // não dizia que eram mensagens de cliente.
    //
    // Era o segundo caminho silencioso, e o pior dos dois: o telefone ESTÁ
    // cadastrado, então quem for conferir vai achar tudo certo. Foi assim que
    // este defeito escapou uma vez — a explicação "não está cadastrado" bateu
    // com o sintoma e estava errada.
    //
    // Duplicidade agora não derruba nada: usa a primeira e reclama. Cadastro
    // repetido é problema de cadastro, e não pode custar as mensagens dos
    // clientes enquanto ninguém arruma.
    const { data: achados, error: advErro } = await supabase
      .from('advogados')
      .select('*')
      .eq('numero', advogadoNumero)
      .limit(2);
    if (advErro) { mensagemDescartada(advogadoNumero, 'busca', advErro.message); return; }
    const adv = (achados || [])[0] || null;
    if (!adv) { mensagemDescartada(advogadoNumero, 'nao_cadastrado'); return; }
    if (achados.length > 1) avisarDuplicado(advogadoNumero);

    // Quem é o CONTATO — SEMPRE o telefone real, ignorando o identificador de
    // privacidade "@lid" que a WhatsApp passou a enviar (ele criava um segundo
    // contato/conversa para a MESMA pessoa).
    // GRUPO ou pessoa: a identidade do grupo é o JID dele, e não o telefone de
    // quem escreveu (recebida) nem o do próprio grupo virado número (enviada).
    const chat = chatDaMensagem(body, m);
    const contatoNumero = chat.chave;
    if (!contatoNumero) {
      console.log('Sem número de contato; ignorando.', JSON.stringify(body).slice(0, 250));
      return;
    }
    // `chat.id` no log porque e ELE que decide se a mensagem e de grupo. Quando
    // uma conversa de grupo nascer errada de novo, esta linha diz por que — sem
    // ela, o diagnostico depende de adivinhar o formato que a Uazapi mandou.
    console.log(`Contato ${contatoNumero}${chat.ehGrupo ? ' (grupo)' : ''} | `
              + `chat.id=${(body.chat && body.chat.id) || '—'} | `
              + `chat.phone=${body.chat && body.chat.phone} | sender_pn=${m.sender_pn} | fromMe=${m.fromMe}`);

    // Antes de gravar, junta o que este mesmo grupo deixou espalhado enquanto o
    // erro existia. Não bloqueia a mensagem: se falhar, ela entra igual e a
    // próxima tenta de novo.
    if (chat.ehGrupo) {
      const jidDigitos = contatoNumero.replace('grupo:', '').replace(/\D/g, '');
      await juntarConversasDoGrupo(adv.id, contatoNumero, jidDigitos, chat.nome).catch(() => {});
    }

    // Foto de perfil do contato (vem no próprio webhook, no chat).
    //
    // A ORDEM IMPORTA, e ela estava invertida. `imagePreview` é a MINIATURA: o
    // WhatsApp manda duas versões da foto de perfil — uma de umas dezenas de
    // pixels, para desenhar em lista, e a cheia, de algumas centenas. Pegando a
    // miniatura primeiro, era a miniatura que ficava guardada. Deu para viver
    // com isso enquanto a foto só aparecia num avatar de 40 pixels; quando o
    // painel passou a abri-la em tamanho grande, ela apareceu embaçada — não
    // está borrada, está sendo ampliada muito além do que tem.
    //
    // A cheia na frente, a miniatura por último: melhor miniatura do que
    // contato sem foto nenhuma.
    const fotoContato =
      (body.chat && (body.chat.imgUrl || body.chat.image || body.chat.profilePicUrl
                  || body.chat.profilePictureUrl || body.chat.imagePreview)) || null;

    // NOME do contato: só confiamos em mensagens RECEBIDAS. Numa mensagem fromMe
    // (o advogado escrevendo pelo próprio WhatsApp), os campos de nome trazem o
    // nome do ADVOGADO (ex.: "Acordos Yunes Kaled"), então NÃO tocamos no nome
    // do contato para não sobrescrever com o dado errado.
    // No GRUPO o nome vem do chat sempre — inclusive em mensagem nossa, porque
    // ali `chat.name` é o nome do grupo. Era isso que fazia a conversa nascer
    // sem nome nenhum e aparecer como "+70929710": a regra de não confiar no
    // nome em `fromMe` existe para conversa de uma pessoa só, onde o campo traz
    // o nome do ADVOGADO.
    const contatoNome = chat.ehGrupo
      ? chat.nome
      : (m.fromMe ? null : ((body.chat && body.chat.wa_name) || m.senderName || null));

    // O MESMO TELEFONE ESCRITO SEM O CÓDIGO DO PAÍS.
    //
    // O painel deixava cadastrar o contato como "11956706171" — o número do
    // jeito que se digita no Brasil, sem o 55. Nós mandávamos a primeira
    // mensagem e ela ia normalmente; quando a pessoa respondia, o WhatsApp
    // devolvia "5511956706171", e aqui, não achando ninguém com esse texto,
    // nascia um SEGUNDO contato e uma SEGUNDA conversa. A resposta aparecia
    // separada da conversa que nós mesmos tínhamos começado.
    //
    // O painel novo já grava com o 55, mas os contatos antigos continuam curtos
    // no banco. Antes de criar qualquer coisa, procuramos a versão curta e,
    // achando, ARRUMAMOS ela — a conversa que já existe segue viva, com o
    // histórico inteiro, e passa a casar com o que o WhatsApp manda.
    //
    // É uma comparação exata (os mesmos dígitos, menos o "55" da frente), e não
    // um "parecido": palpite aqui juntaria conversa de cliente errado.
    if (!chat.ehGrupo && contatoNumero.length > 11 && contatoNumero.startsWith('55')) {
      const semDdi = contatoNumero.slice(2);
      const { data: curto } = await supabase
        .from('contatos').select('id, numero').eq('numero', semDdi).maybeSingle();
      if (curto) {
        const { data: jaTem } = await supabase
          .from('contatos').select('id').eq('numero', contatoNumero).maybeSingle();
        if (jaTem) {
          // Os dois já existem: quem manda é o longo, e o curto some da frente
          // para não voltar a receber nada. Juntar as conversas é decisão de
          // gente — o painel tem "Juntar duas conversas" para isso.
          console.log(`Contato ${semDdi} e ${contatoNumero} coexistem; use "Juntar duas conversas".`);
        } else {
          const { error: arrumou } = await supabase
            .from('contatos').update({ numero: contatoNumero }).eq('id', curto.id);
          console.log(arrumou
            ? `Não consegui pôr o 55 em ${semDdi}: ${arrumou.message}`
            : `Contato ${semDdi} virou ${contatoNumero} (mesma pessoa, agora com o código do país).`);
        }
      }
    }

    // Só inclui foto_url/nome quando temos valor, para não apagar o que já existe.
    const contatoUpsert = { numero: contatoNumero };
    if (contatoNome) contatoUpsert.nome = contatoNome;
    if (fotoContato) contatoUpsert.foto_url = fotoContato;

    // ANTES DE CRIAR, PROCURA O MESMO CELULAR NA OUTRA FORMA DO NONO DÍGITO.
    //
    // O bloco acima resolve o 55; este resolve o 9. O cadastro tem
    // "+55 31 99945-6790" e o WhatsApp devolve "+55 31 9945-6790" — a mesma
    // linha, com um dígito a menos. Sem esta procura nasce um segundo contato,
    // e a resposta do cliente vai parar numa conversa separada daquela em que
    // a equipe escreveu. Foi o caso da MARIA DE JESUS DA SILVA.
    //
    // Achando, o contato existente é PROMOVIDO para o número que o WhatsApp
    // usa: a conversa e o histórico continuam os mesmos, e as próximas
    // mensagens passam a casar. Se os dois já existirem, não se junta nada
    // por conta própria — juntar histórico é decisão de gente, e o painel tem
    // "Juntar duas conversas" para isso.
    let contatoExistente = null;
    if (!chat.ehGrupo) {
      const { data: achados } = await supabase
        .from('contatos').select('id, numero').in('numero', variantesDoNumero(contatoNumero));
      const lista = achados || [];
      contatoExistente = lista.find((c) => c.numero === contatoNumero) || null;
      const outro = lista.find((c) => c.numero !== contatoNumero) || null;
      if (!contatoExistente && outro) {
        const { error: erroPromo } = await supabase
          .from('contatos').update({ numero: contatoNumero }).eq('id', outro.id);
        if (erroPromo) {
          console.log(`Nono dígito: não consegui promover ${outro.numero} (${erroPromo.message}).`);
        } else {
          console.log(`Contato ${outro.numero} virou ${contatoNumero} (mesmo celular, nono dígito).`);
          contatoExistente = { id: outro.id, numero: contatoNumero };
        }
      } else if (contatoExistente && outro) {
        console.log(`Contato ${outro.numero} e ${contatoNumero} são o mesmo celular e coexistem; `
                  + 'use "Juntar duas conversas".');
      }
    }

    // select('*') pelo mesmo motivo do advogado: traz frente/frente_em quando
    // essas colunas já existirem, sem exigir que existam.
    const { data: contato, error: contErro } = await supabase
      .from('contatos')
      .upsert(contatoUpsert, { onConflict: 'numero' })
      .select('*')
      .single();
    // FALHA DE BANCO SOBE, e não vira `return`.
    //
    // Um `return` aqui diz "terminei" para quem chamou — e quem chama é a caixa
    // de entrada, que então marca o evento como resolvido. A mensagem do
    // cliente não teria entrado em lugar nenhum, e o evento não seria tentado
    // de novo: exatamente a perda que a caixa existe para impedir, agora com um
    // registro dizendo que deu tudo certo.
    //
    // Subindo, o evento fica pendente e a rodada de recuperação tenta de novo.
    // O banco fora do ar por um minuto passa a custar um minuto de atraso, e
    // não uma mensagem.
    if (contErro) throw new Error(`não consegui gravar o contato: ${contErro.message}`);

    // A CONVERSA entre este advogado e este contato.
    const { data: conversa, error: convErro } = await supabase
      .from('conversas')
      .upsert(
        { advogado_id: adv.id, contato_id: contato.id },
        { onConflict: 'advogado_id,contato_id' }
      )
      .select('id')
      .single();
    if (convErro) throw new Error(`não consegui gravar a conversa: ${convErro.message}`);

    // ------------------------------------------------------------
    //  DE QUEM É ESTA CONVERSA — E POR QUE ISTO NÃO É ESPERADO
    //
    //  A frente (cliente, advogado da parte contrária, lead) sai de uma
    //  pergunta ao Vantoro. O comentário aqui sempre disse "não bloqueia nada",
    //  e havia um `await` na linha de baixo: bloqueava tudo.
    //
    //  O Vantoro roda no plano gratuito da Render e DORME. Acordá-lo leva de
    //  trinta segundos a um minuto, e é isso que esta linha esperava — ANTES de
    //  a mensagem do cliente ser gravada. Do lado de quem atende, a mensagem
    //  simplesmente não aparecia por meio minuto; e se uma publicação caísse
    //  nessa janela, ela não aparecia nunca (o webhook já tinha respondido "OK"
    //  à Uazapi).
    //
    //  Fora do expediente e nos fins de semana o Vantoro está dormindo de
    //  propósito — ou seja, a espera era a regra, e não a exceção.
    //
    //  Agora a classificação corre POR FORA. A mensagem é gravada logo abaixo,
    //  no tempo do banco, e a etiqueta chega quando chegar — o painel a recebe
    //  pelo tempo real, sem ninguém recarregar nada.
    //
    //  O QUE SE ACEITA COM ISSO, dito para ninguém descobrir depois: se a ponte
    //  for desligada nos segundos seguintes, esta classificação é cortada pela
    //  metade. Ela não é esperada pelo desligamento, de propósito — segurar a
    //  saída por uma etiqueta seria pagar com o que importa (mensagem e envio)
    //  por um extra que se refaz sozinho na próxima mensagem daquele contato.
    // ------------------------------------------------------------
    definirFrente(contato, adv, conversa.id, body).catch((e) => {
      console.log('Frente: não consegui classificar agora —', (e && e.message) || e);
    });

    // REAÇÃO, e não mensagem. Vem antes de tudo o que monta a linha porque uma
    // reação não é uma linha: ela pertence à mensagem que já está na conversa.
    // Se `aplicarReacao` não conseguir prendê-la (mensagem alvo fora do Zorvin,
    // coluna ainda não criada), o código segue e ela vira mensagem, como antes.
    // "ISTO É UMA REAÇÃO?" é uma pergunta diferente de "CONSIGO APLICÁ-LA?",
    // e as duas têm consequências diferentes. Antes eram a mesma: quando a
    // reação não podia ser aplicada, o código seguia adiante e gravava uma
    // mensagem. Na RETIRADA da reação — que chega com todos os campos de texto
    // vazios — isso criava uma BOLHA EM BRANCO na conversa, só com o horário.
    //
    // Agora, se o evento é de reação, ele nunca vira mensagem. Aplicada ou
    // não, o webhook para aqui; o que não deu para ler fica no log.
    const ehEventoDeReacao = /reaction/i.test(String(m.messageType || m.type || ''))
      || (typeof m.reaction === 'string' && m.reaction !== '');
    if (ehEventoDeReacao) {
      const reacao = extrairReacao(m);
      if (reacao) await aplicarReacao(reacao, m.fromMe ? 'advogado' : 'contato');
      else console.log('Reação sem alvo identificável; ignorada (nada foi gravado).');
      return;
    }

    // AVISO DE ÁLBUM: não vira bolha. Ver `ehAvisoDeAlbum`, lá em cima.
    //
    // Aqui e não antes do contato: a chegada do álbum é o que faz a conversa
    // subir na lista e o contato ser criado, e isso continua valendo. O que não
    // pode acontecer é a LINHA.
    if (ehAvisoDeAlbum(m)) {
      const quantas = quantasNoAlbum(m);
      console.log(`Aviso de álbum${quantas ? ` (${quantas} peças)` : ''} de ${contatoNumero}: `
        + 'não vira bolha — cada foto chega como mensagem própria em seguida.');
      return;
    }

    // TIPO da mensagem. Mesma leitura da importação de histórico, agora que
    // as duas usam a mesma função.
    const tipo = tipoDaMensagem(m);

    // TIPO QUE ESTE CÓDIGO NÃO CONHECE: fica registrado com o nome exato.
    //
    // A mensagem entra na conversa do mesmo jeito — um anexo que não se sabe
    // ler ainda é melhor na tela do que sumido. Mas ela entrava como
    // "documento" ou "texto" SEM DEIXAR RASTRO de que era outra coisa, e aí a
    // única forma de descobrir o formato era adivinhar.
    //
    // O corpo vai junto, cortado: é com um exemplo real em mãos que se ajusta
    // a leitura, e não com mais um palpite. É a mesma decisão já tomada para
    // as reações, algumas centenas de linhas abaixo.
    const tipoCru = tipoCruNaoReconhecido(m);
    if (tipoCru) {
      console.log(`Tipo de mensagem DESCONHECIDO: "${tipoCru}". `
        + `Entrou como "${tipo}" para não sumir da conversa. `
        + `Corpo: ${JSON.stringify(m).slice(0, 800)}`);
    }

    const origem = m.fromMe ? 'advogado' : 'contato';
    // `m.caption` É A LEGENDA DA FOTO, e ela não estava sendo lida aqui.
    //
    // O cliente manda a certidão e escreve "essa é a de casamento" por baixo.
    // A legenda vem em `caption`, e este caminho lia só `text` e `content` —
    // a frase sumia, e a bolha chegava com a imagem e mais nada. A importação
    // de histórico já lia `caption` (é a mesma mensagem, lida por outra porta),
    // então o mesmo anexo trazia a legenda quando importado e a perdia quando
    // chegava ao vivo. Duas leituras diferentes do mesmo campo é sempre uma
    // delas errada.
    const texto =
      m.text || (typeof m.content === 'string' ? m.content : '') || m.caption || null;

    // Miniatura embutida (prévia imediata, baixa resolução). Vale para a
    // FIGURINHA também: se o download do arquivo grande falhar, é ela que
    // impede a bolha de nascer vazia.
    let midiaUrl = null;
    if ((tipo === 'imagem' || tipo === 'figurinha') && m.content && m.content.JPEGThumbnail) {
      midiaUrl = 'data:image/jpeg;base64,' + m.content.JPEGThumbnail;
    }
    const midiaMime = (m.content && m.content.mimetype) || null;
    const midiaNome = tipo === 'texto' ? null : nomeDoArquivo(m);

    // ------------------------------------------------------------
    //  O ARQUIVO GRANDE VEM DEPOIS. A BOLHA VEM AGORA.
    //
    //  Aqui se esperava o download inteiro antes de gravar a mensagem:
    //
    //      webhook → downloadmedia (até 20s, e até 3 rotas) → baixa o arquivo
    //              → sobe para o Storage → SÓ ENTÃO grava → só então a bolha
    //
    //  Enquanto isso a conversa fica VAZIA. Não é o arquivo que demora a
    //  aparecer — é a mensagem inteira que ainda não existe. Quem atende vê o
    //  cliente dizer "te mandei a foto" e não vê foto nenhuma. Foi o relato:
    //  "ao enviar ou receber algum arquivo, está demorando para aparecer".
    //
    //  E a miniatura logo acima, cujo comentário promete "prévia imediata",
    //  não era imediata coisa nenhuma: ela era calculada e ficava esperando o
    //  arquivo grande junto com todo o resto.
    //
    //  Agora a ordem se inverte. Grava-se a mensagem com a miniatura, a bolha
    //  nasce na hora pelo tempo real, e o arquivo de verdade entra no lugar
    //  quando chegar — na MESMA bolha, sem piscar e sem duplicar.
    //
    //  Medido na bancada: com o download demorando 1,2s, a bolha nascia em
    //  1287ms e passou a nascer em menos de 200ms.
    // ------------------------------------------------------------
    const buscarOArquivoDepois = tipo !== 'texto'
      ? () => {
          const servidorAdv = (adv.servidor || 'https://novaera.uazapi.com').replace(/\/$/, '');
          // Sem `await` de propósito: quem chamou já respondeu ao webhook.
          perseguirOArquivo({ servidor: servidorAdv, token: adv.token, m, mime: midiaMime,
                              nome: midiaNome, tipo });
        }
      : null;

    // BOLHA EM BRANCO, NUNCA.
    //
    // Texto sem texto e sem mídia não é mensagem: é um evento que não soubemos
    // ler. Gravar cria uma bolha só com o horário — que ninguém consegue
    // interpretar, e que a equipe não tem como apagar pela tela.
    //
    // Vale como rede para além da reação: qualquer evento novo que a Uazapi
    // passe a mandar e que este código ainda não entenda cai aqui, e vira uma
    // linha de log em vez de sujeira na conversa do cliente.
    if (tipo === 'texto' && !texto && !midiaUrl) {
      console.log('Ignorado: evento sem texto e sem mídia. Corpo:', JSON.stringify(m).slice(0, 500));
      return;
    }

    const base = {
      conversa_id: conversa.id,
      origem,
      tipo,
      texto,
      midia_url: midiaUrl,
      midia_mime: midiaMime,
      id_uazapi: m.messageid,
      status: origem === 'contato' ? 'recebida' : 'enviada'
    };
    // O HORÁRIO DE QUEM ENVIOU, quando ele vem. Sem isto a coluna cai no
    // `now()` do banco — a hora em que NÓS gravamos, que é outra coisa.
    const quandoFoiEnviada = horarioDeQuemEnviou(m);
    if (quandoFoiEnviada) base.criado_em = quandoFoiEnviada;
    else avisarQueOWebhookNaoTrazHorario(m);
    // Mensagem "fromMe" que chega pelo webhook (e não é eco de envio pela API,
    // que já foi ignorado acima) = foi enviada DIRETO pelo WhatsApp (app do
    // celular ou desktop), fora do Zorvin. Não sabemos qual atendente foi, então
    // marca com um rótulo de sistema para a equipe distinguir na bolha.
    if (origem === 'advogado') base.enviado_por = 'WhatsApp';
    // No grupo, quem escreveu importa em toda mensagem — inclusive nas recebidas,
    // que num grupo vêm de gente diferente a cada linha. É o mesmo campo que a
    // importação de histórico já preenchia, então a bolha mostra igual.
    if (chat.ehGrupo) base.enviado_por = autorNoGrupo(body, m);
    // Se a mensagem recebida é uma RESPOSTA a outra, guarda a citação.
    // A duração vai junto dos campos de citação, e não dentro de `base`, de
    // propósito: `salvarMensagem` já sabe regravar sem os extras quando o banco
    // não tem a coluna. Numa base sem o script rodado, a mensagem entra do
    // mesmo jeito — só sem o tempo.
    const extras = { ...(extrairResposta(m) || {}) };
    const segundos = segundosDaMidia(m, tipo);
    if (segundos) extras.midia_segundos = segundos;
    // O NOME DO ARQUIVO VAI JUNTO DOS EXTRAS, e não em `base`, pelo mesmo
    // motivo da duração: numa base sem a coluna, um campo em `base` derruba a
    // gravação inteira, e a mensagem do cliente sumiria por causa de um nome.
    if (midiaNome) extras.midia_nome = midiaNome;

    const msgErro = await salvarMensagem(base, Object.keys(extras).length ? extras : null);
    // A MESMA REGRA, e aqui ela é a mais importante das três: se a mensagem não
    // foi gravada, o evento NÃO está resolvido.
    if (msgErro) throw new Error(`não consegui gravar a mensagem: ${msgErro.message}`);

    // A BOLHA JÁ EXISTE. Agora sim vai buscar o arquivo grande.
    //
    // Depois da gravação, e não antes: se a gravação falhar, não há linha para
    // atualizar, e sair baixando megabytes para não escrever em lugar nenhum
    // seria trabalho jogado fora — pior, contra a Uazapi, que tem limite.
    if (buscarOArquivoDepois) buscarOArquivoDepois();

    // A CONVERSA ARQUIVADA VOLTA quando o contato escreve.
    //
    // Arquivar quer dizer "por ora, resolvido". Se a pessoa voltou a falar, não
    // está mais resolvido — e uma mensagem que chega numa conversa arquivada
    // fica invisível: não aparece na lista, e ninguém vai procurá-la dentro de
    // Arquivadas. É assim que o WhatsApp se comporta, e é o comportamento que
    // não deixa cliente sem resposta.
    //
    // Só o CONTATO desarquiva. Mensagem nossa, saindo do próprio Zorvin, não
    // deve tirar da pasta o que a equipe acabou de guardar lá.
    //
    // O `.eq('arquivada', true)` evita uma escrita inútil em toda mensagem: só
    // as que estão arquivadas são tocadas.
    if (origem === 'contato') {
      const { data: voltou, error: erroArq } = await supabase.from('conversas')
        .update({ arquivada: false }).eq('id', conversa.id).eq('arquivada', true).select('id');
      if (erroArq) console.log('Não consegui desarquivar (coluna "arquivada"?):', erroArq.message);
      else if (voltou && voltou.length) console.log(`Conversa ${conversa.id} saiu das arquivadas: o contato escreveu.`);
    }

    console.log(`Recebida (${tipo}) de ${contatoNumero} p/ advogado ${advogadoNumero}.`);
    // A ponte está acordada agora: aproveita para despachar qualquer mensagem
    // que estava esperando na fila (não espera o próximo ciclo do setInterval).
    processarFilaDeEnvio().catch(() => {});
  }
}

// ============================================================
//  O RESGATE DOS ANEXOS QUE JÁ ESTÃO VAZIOS
//
//  A insistência conserta o que chega de agora em diante. Os documentos que já
//  estão na conversa escritos "indisponível" — o do relato de 10/09 entre eles
//  — continuariam vazios para sempre, porque nada no sistema volta a olhar
//  para eles.
//
//  Esta porta volta. Procura no banco as mensagens de anexo sem arquivo,
//  descobre por qual telefone cada uma entrou e pede o arquivo à Uazapi outra
//  vez, uma a uma.
//
//  NÃO DEVOLVE CONTEÚDO DE MENSAGEM NENHUMA: quantas achou, quantas encheu, e
//  os ids da Uazapi das que não deram. É o bastante para saber se funcionou e
//  não expõe conversa de cliente numa página aberta no navegador.
//
//  A MESMA PORTA DO HISTÓRICO, com a mesma senha: quem pode reimportar
//  conversa pode rebuscar anexo, e uma variável a mais no Render é uma a mais
//  para esquecer.
// ============================================================
app.get('/anexos/resgatar', async (req, res) => {
  try {
    const recusa = recusaDaPortaAdmin(req, 'Resgate de anexos');
    if (recusa) return res.status(recusa.status).send(recusa.texto);

    const dias = Math.min(Math.max(parseInt(req.query.dias || '7', 10) || 7, 1), 90);
    const limite = Math.min(Math.max(parseInt(req.query.limite || '30', 10) || 30, 1), 200);
    const desde = new Date(Date.now() - dias * 86400000).toISOString();

    // MAIS DO QUE O LIMITE, de propósito: a peneira do arquivo vazio é feita
    // aqui (uma miniatura `data:` não é "coluna nula", e o banco não sabe
    // disso), então pedir só `limite` linhas devolveria quase só mensagens que
    // já têm arquivo e o resgate acharia meia dúzia.
    const { data: candidatas, error } = await supabase.from('mensagens')
      .select('id, id_uazapi, conversa_id, tipo, midia_url, midia_mime')
      .neq('tipo', 'texto')
      .gte('criado_em', desde)
      .order('criado_em', { ascending: false })
      .limit(limite * 20);
    if (error) return res.status(500).send(`O banco recusou a consulta: ${error.message}`);

    const vazias = (candidatas || [])
      .filter((c) => c.id_uazapi && ehSoMiniatura(c.midia_url))
      .slice(0, limite);
    if (!vazias.length) {
      return res.json({ ok: true, dias, achadas: 0,
        recado: `Nenhum anexo sem arquivo nos últimos ${dias} dia(s).` });
    }

    // De qual telefone é cada mensagem. Duas idas ao banco para o lote inteiro,
    // e não duas por mensagem.
    const idsDeConversa = [...new Set(vazias.map((v) => v.conversa_id).filter(Boolean))];
    const { data: conversas } = await supabase.from('conversas')
      .select('id, advogado_id').in('id', idsDeConversa);
    const advDaConversa = new Map((conversas || []).map((c) => [String(c.id), c.advogado_id]));
    const { data: advs } = await supabase.from('advogados')
      .select('id, nome, token, servidor').in('id', [...new Set((conversas || []).map((c) => c.advogado_id))]);
    const advPorId = new Map((advs || []).map((a) => [String(a.id), a]));

    let encheu = 0;
    const faltaram = [];
    for (const v of vazias) {
      const adv = advPorId.get(String(advDaConversa.get(String(v.conversa_id))));
      if (!adv || !adv.token) {
        faltaram.push({ id: v.id_uazapi, telefone: (adv && adv.nome) || '(não achei)',
                        porque: adv ? 'este telefone está sem token no cadastro'
                                    : 'não achei o telefone desta conversa' });
        continue;
      }
      const servidor = (adv.servidor || 'https://novaera.uazapi.com').replace(/\/$/, '');
      const relato = { motivo: '' };
      const url = await baixarMidiaRecebida(servidor, adv.token,
        { messageid: v.id_uazapi, content: {} }, v.midia_mime, relato);
      if (!url) {
        faltaram.push({ id: v.id_uazapi, telefone: adv.nome || String(adv.id),
                        porque: relato.motivo || 'não deu, e não sei dizer por quê' });
        continue;
      }
      await trocarMiniaturaPeloArquivo(v.id_uazapi, url, v.midia_mime);
      encheu++;
    }

    // OS MOTIVOS CONTADOS, e não só listados. Com 115 anexos vazios, uma lista
    // de 115 linhas iguais não se lê; "113 por isto, 2 por aquilo" se lê de
    // relance e diz qual é o conserto.
    const porMotivo = {};
    for (const f of faltaram) porMotivo[f.porque] = (porMotivo[f.porque] || 0) + 1;
    // E POR TELEFONE. Trinta e cinco falhas iguais podem ser o sistema inteiro
    // ou UM telefone com token vencido — e são consertos opostos. Contadas por
    // telefone, a diferença se vê de relance.
    const porTelefone = {};
    for (const f of faltaram) porTelefone[f.telefone] = (porTelefone[f.telefone] || 0) + 1;

    console.log(`Resgate de anexos: ${vazias.length} sem arquivo, ${encheu} recuperado(s).`);
    res.json({
      ok: true, dias, achadas: vazias.length, recuperados: encheu,
      // Os ids da Uazapi, e não o conteúdo: servem para procurar no log e para
      // saber se vale tentar outra vez daqui a pouco.
      nao_deram: faltaram,
      por_motivo: porMotivo,
      por_telefone: porTelefone,
      recado: encheu
        ? `${encheu} anexo(s) voltaram para a conversa. Recarregue o Zorvin para vê-los.`
        : 'Nenhum voltou. A Uazapi já não tem estes arquivos, ou o telefone perdeu o token.',
    });
  } catch (e) {
    res.status(500).send(`Não consegui resgatar: ${(e && e.message) || e}`);
  }
});

app.post('/webhook', async (req, res) => {
  // JÁ ESTAMOS SAINDO: é melhor recusar do que aceitar e não terminar.
  //
  // Responder "OK" aqui seria dizer à Uazapi que a mensagem está guardada,
  // segundos antes de o processo morrer com ela pela metade. Um 503 é o
  // contrário: diz que não deu, fica no log dela, e a mensagem continua sendo
  // dela para reentregar.
  //
  // A janela é curta — o tempo de a Render trocar um processo pelo outro — e
  // nela a ponte nova já está subindo para atender.
  if (desligando) {
    console.warn('Webhook recusado: a ponte está sendo desligada (publicação ou reinício).');
    return res.status(503).send('reiniciando, tente de novo');
  }
  if (!webhookAutorizado(req)) {
    contarRecusa(req);
    return res.status(403).send('nao autorizado');
  }

  // ------------------------------------------------------------
  //  GUARDAR PRIMEIRO, PROCESSAR DEPOIS
  //
  //  O "OK" para a Uazapi é uma promessa: dali em diante ela considera a
  //  mensagem entregue e não manda de novo. Até agora essa promessa era feita
  //  ANTES de a mensagem existir em qualquer lugar — o que vinha depois (achar
  //  o telefone, o contato, a conversa, gravar) morria junto com o processo, e
  //  a mensagem do cliente sumia sem deixar rastro. Não havia nem como saber
  //  qual tinha sido.
  //
  //  Agora o evento cru é gravado ANTES do "OK". A partir daí ele existe: se a
  //  ponte cair no meio do processamento, a rodada de recuperação o encontra
  //  pendente e termina o serviço.
  //
  //  O CUSTO É UMA IDA AO BANCO antes de responder — algumas dezenas de
  //  milissegundos. É o preço de a promessa ser verdadeira.
  // ------------------------------------------------------------
  const guardado = await guardarNaCaixaDeEntrada(req.body);

  if (guardado.recusar) {
    // NÃO CONSEGUI GUARDAR, ENTÃO NÃO PROMETO. Um "OK" aqui seria dizer que a
    // mensagem está a salvo quando ela não está em lugar nenhum. O 503 fica no
    // log da Uazapi e a mensagem continua sendo dela para reentregar.
    console.error('Webhook: não consegui guardar o evento; respondendo 503 para a Uazapi '
      + `não considerar entregue. Motivo: ${guardado.erro}`);
    return res.status(503).send('nao consegui guardar; reenvie');
  }

  res.status(200).send('OK'); // agora sim: o evento já está guardado

  webhooksEmVoo += 1;
  concluirEvento(guardado.id, req.body)
    .finally(() => { webhooksEmVoo -= 1; });
});

// ------------------------------------------------------------
//  Atualiza o STATUS de uma mensagem que enviamos (entregue/lida).
//  Isso é o que deixa o "tiquinho" azul quando o contato lê.
//
//  ATENÇÃO: o formato exato desses eventos varia entre versões da
//  Uazapi e ainda não foi confirmado em teste. Por isso a função é
//  tolerante (tenta vários formatos) e, quando não reconhece, apenas
//  registra no log — nada quebra. Ao ver no log do Render qual é o
//  formato real, dá para ajustar com precisão.
// ------------------------------------------------------------
async function tratarStatusMensagem(body, evento) {
  try {
    // O ENDEREÇO DO ARQUIVO VEM ANTES DE TUDO.
    //
    // Estava lá embaixo, no ramo de "não reconheci este evento" — e por isso
    // dependia de o evento NÃO trazer um status reconhecível. Alguns trazem
    // ("Delivered") e o endereço passava direto. Aqui em cima ele é aproveitado
    // sempre, e o resto do tratamento de status segue igual.
    const arquivo = body.FileURL || (body.event && body.event.FileURL);
    if (arquivo) {
      const ids = ((body.event && body.event.MessageIDs) || body.MessageIDs || [])
        .map(String).filter(Boolean);
      guardarEnderecoDeArquivo(ids, arquivo);
      console.log(`Endereço de arquivo recebido para ${JSON.stringify(ids)}: `
        + `${String(arquivo).split('?')[0]}`);
      // E, se alguma dessas mensagens já está gravada SEM arquivo, é agora que
      // ela ganha o dela. Sem `await` na sequência: um resgate lento não pode
      // segurar o tratamento do evento.
      for (const id of ids) resgatarAnexoVazio(id, arquivo).catch(() => {});
    }

    const alvo = body.message || body.update || body.data || body;
    const id =
      alvo.messageid || alvo.id || (alvo.key && alvo.key.id) || body.messageid || null;
    const bruto = alvo.status ?? alvo.ack ?? body.status ?? body.ack;

    // Se não achamos id ou status, registramos para referência e saímos. O
    // endereço de arquivo, quando vinha, já foi aproveitado lá em cima.
    if (!id || bruto === undefined || bruto === null) {
      if (arquivo) return;
      console.log('Evento não tratado (p/ referência):', evento, JSON.stringify(body).slice(0, 300));
      return;
    }

    const s = String(bruto).toLowerCase();

    // O CONTATO APAGOU UMA MENSAGEM PARA TODOS.
    //
    // No WhatsApp ela sumiria. AQUI ELA FICA. Este é um escritório de
    // advocacia: o que o cliente escreveu é registro do atendimento, e um
    // registro que a outra parte pode apagar depois não serve para nada — nem
    // para conferir um combinado, nem para se defender de uma reclamação.
    //
    // O que muda é só o aviso na bolha: a equipe passa a saber que houve a
    // tentativa. O texto e o anexo continuam intactos.
    //
    // Isto já acontecia por acidente (o status "Deleted" caía em "não mapeado"
    // e nada era alterado). Agora é decisão escrita, para ninguém "consertar"
    // achando que faltava tratar o evento.
    if (s.includes('delet') || s.includes('revok') || s.includes('apagad')) {
      const { error: erroAviso } = await supabase.from('mensagens')
        .update({ apagada_pelo_contato: true })
        .eq('id_uazapi', id).eq('origem', 'contato');
      if (erroAviso && /apagada_pelo_contato/i.test(erroAviso.message || '')) {
        console.log('Falta a coluna "apagada_pelo_contato"? Rode sql/2026-08-apagar-mensagem.sql.');
      } else if (erroAviso) {
        console.log('Não consegui marcar a exclusão do contato:', erroAviso.message);
      } else {
        console.log(`O contato apagou a mensagem ${id} no WhatsApp; ela CONTINUA no Zorvin.`);
      }
      return;
    }

    let novo = null;
    if (s === '3' || s === '4' || s.includes('read') || s.includes('play')) {
      novo = 'lida';
    } else if (s === '2' || s.includes('deliver') || s.includes('entreg')) {
      novo = 'entregue';
    }
    if (!novo) {
      console.log('Status não mapeado (p/ referência):', evento, bruto);
      return;
    }

    const { error } = await supabase
      .from('mensagens')
      .update({ status: novo })
      .eq('id_uazapi', id)
      .eq('origem', 'advogado'); // só marcamos "lida" nas mensagens que enviamos
    if (error) { console.error('Erro ao atualizar status:', error.message); return; }
    console.log(`Status "${novo}" aplicado à mensagem ${id}.`);
  } catch (e) {
    console.error('Erro ao tratar status de mensagem:', e.message);
  }
}

// ------------------------------------------------------------
//  "Digitando…": detecta eventos de presença (composing) da Uazapi e
//  marca conversas.digitando_ate com uma janela curta. O painel mostra
//  "digitando…" enquanto essa data estiver no futuro.
//
//  ATENÇÃO: o formato do evento de presença da Uazapi ainda NÃO foi
//  confirmado. Detectamos "composing"/"paused" de forma tolerante e
//  registramos no log; nada quebra se não reconhecer ou se a coluna
//  digitando_ate ainda não existir.
// ------------------------------------------------------------
async function tratarPresenca(body, evento) {
  try {
    const bruto = JSON.stringify(body).toLowerCase();
    // "digitando" = composing/recording; "parou" = paused/available/unavailable.
    const digitando = bruto.includes('composing') || bruto.includes('recording');
    const parou = bruto.includes('paused') || bruto.includes('available');
    if (!digitando && !parou) return;

    // O número do contato (e do advogado) pode vir em vários campos, dependendo
    // da versão da Uazapi. Tentamos todos os lugares comuns.
    const d = body.data || body.presence || body.chat || {};
    const advogadoNumero = body.owner || d.owner || (body.message && body.message.owner) || null;
    const contatoBruto =
      (body.chat && body.chat.phone) || body.number || body.phone || body.chatId || body.chat_id ||
      body.sender || body.sender_pn || d.phone || d.number || d.chatId || d.chat_id || d.id || body.id || '';
    const contatoNumero = String(contatoBruto).split('@')[0].replace(/\D/g, '');
    if (!advogadoNumero || !contatoNumero) {
      // Não achamos os números: loga o corpo INTEIRO para eu ver os campos reais.
      console.log('Presença: não localizei os números. Corpo:', JSON.stringify(body).slice(0, 500));
      return;
    }

    const { data: adv } = await supabase.from('advogados').select('id').eq('numero', advogadoNumero).maybeSingle();
    if (!adv) return;
    const { data: cont } = await supabase.from('contatos').select('id').eq('numero', contatoNumero).maybeSingle();
    if (!cont) return;

    const ate = digitando
      ? new Date(Date.now() + 8000).toISOString()   // digitando: some em 8s
      : new Date(Date.now() - 1000).toISOString();  // parou: expira já
    const { error } = await supabase.from('conversas')
      .update({ digitando_ate: ate })
      .eq('advogado_id', adv.id).eq('contato_id', cont.id);
    if (error) console.log('digitando_ate (coluna?):', error.message);
    else console.log(`Presença: ${digitando ? 'digitando' : 'parou'} (${contatoNumero}).`);
  } catch (e) {
    console.error('Erro em tratarPresenca:', e.message);
  }
}

// ------------------------------------------------------------
//  Baixa a mídia RECEBIDA (imagem/áudio/vídeo/doc) em alta resolução
//  pela Uazapi e salva no Storage do Supabase. Retorna a URL pública,
//  ou null se não conseguir (aí mantém a miniatura de antes).
//
//  ATENÇÃO: o endpoint/retorno de download da Uazapi ainda não foi
//  confirmado. Tentamos algumas rotas e formatos comuns e registramos
//  no log a estrutura real, para ajustar com precisão depois. Nada
//  quebra se falhar.
// ------------------------------------------------------------
// A ROTA DE DOWNLOAD QUE SERVE NESTE SERVIDOR.
//
// As três rotas abaixo são a mesma coisa em versões diferentes da Uazapi: cada
// servidor atende uma. A ponte tentava as três, sempre na mesma ordem, e nunca
// guardava qual tinha funcionado. Onde a que serve é a última, toda foto que
// chega custa duas tentativas jogadas fora — e uma delas pode ficar 20 segundos
// esperando resposta, com a mensagem do cliente parada até lá.
//
// Um servidor não troca de versão entre uma foto e a seguinte. Descobre-se uma
// vez e lembra-se. Se um dia a lembrada parar de servir, a busca recomeça
// sozinha pelas três.
const ROTAS_DE_DOWNLOAD = ['/message/downloadmedia', '/message/download', '/downloadmedia'];
const rotaQueServe = new Map();

// QUANTO TEMPO O NAVEGADOR PODE GUARDAR O ARQUIVO.
//
// A biblioteca do Supabase manda `max-age=3600` quando ninguém diz nada — UMA
// HORA. Isso significa que, de hora em hora, cada atendente que abre uma
// conversa BAIXA DE NOVO todas as fotos, áudios e vídeos dela. Com oito pessoas
// rolando conversas o dia inteiro e mais de 1 GB de mídia guardada, é assim que
// a franquia de banda vira zero e o workspace é suspenso — foi o que aconteceu
// em 21/08 e derrubou o atendimento.
//
// Um ano, e `immutable` junto. Não é ousadia: o endereço do arquivo é
// `recebidos/{messageid}`, e o messageid não se repete. Aquele endereço nunca
// vai apontar para outro conteúdo, então não existe o risco que um cache longo
// normalmente traz — o de servir uma versão velha de algo que mudou.
//
// `immutable` é o que faz o navegador nem PERGUNTAR se mudou. Sem ele, ainda
// sai uma ida à rede por arquivo para receber "304, continua igual": pouco
// tráfego, mas uma chamada por imagem por atendente, e é justamente o que deixa
// a conversa lenta ao abrir.
const CACHE_DA_MIDIA = { cacheControl: '31536000, immutable' };

/** A ponta do arquivo guardado no Storage.
 *
 *  Vinha do mime e só dele: `application/pdf` dá "pdf", mas a planilha do
 *  Excel dá `vnd.openxmlformats-officedocument.spreadsheetml.sheet` — sessenta
 *  caracteres de extensão —, e um arquivo que a Uazapi não soube identificar
 *  dá "octet-stream". Quem clica em baixar recebe um nome que o computador
 *  dele não sabe abrir.
 *
 *  O NOME QUE O CLIENTE MANDOU VALE MAIS que o mime justamente nesses casos,
 *  porque foi ele que saiu do computador de alguém com a extensão certa. */
function extensaoDoArquivo(mime, nome) {
  const doNome = String(nome || '').split('.').pop();
  if (doNome && doNome !== nome && /^[a-z0-9]{1,8}$/i.test(doNome)) return doNome.toLowerCase();
  const sub = (String(mime || '').split('/')[1] || '').split(';')[0].toLowerCase();
  if (!sub || sub === 'octet-stream' || sub.length > 8 || !/^[a-z0-9]+$/.test(sub)) return 'bin';
  return sub;
}

async function baixarMidiaRecebida(servidor, token, m, mimeInformado, relato) {
  // POR QUE NÃO DEU — dito para quem chamou, e não só para o log.
  //
  // A porta de resgate devolve uma lista de ids que não deram, e um id sem
  // motivo não ensina nada: "115 documentos não voltaram" pode ser token
  // vencido, arquivo que a Uazapi já apagou, ou Storage recusando. São
  // consertos diferentes, e quem lê a resposta não tem o log da Render.
  const porque = (motivo) => { if (relato) relato.motivo = motivo; return null; };
  try {
    if (!token || !m.messageid) return porque('o telefone está sem token');

    // A lembrada primeiro; as outras continuam na fila, para o dia em que ela
    // deixar de responder.
    const lembrada = rotaQueServe.get(servidor);
    const ordem = lembrada
      ? [lembrada, ...ROTAS_DE_DOWNLOAD.filter((r) => r !== lembrada)]
      : ROTAS_DE_DOWNLOAD;

    let dados = null;
    // O QUE CADA ROTA RESPONDEU — e não só "nenhuma respondeu".
    //
    // Com 35 anexos dando todos o mesmo motivo, "nenhuma rota respondeu"
    // esconde três diagnósticos muito diferentes: 404 é a Uazapi já não ter o
    // arquivo (não há o que fazer); 401 é token vencido (conserto de cadastro);
    // e um estouro de rede é outra coisa ainda. Sem separá-los, a resposta diz
    // que falhou e não diz o que fazer a respeito.
    const respostas = [];
    for (const rota of ordem) {
      try {
        const r = await fetchComTimeout(`${servidor}${rota}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'token': token },
          body: JSON.stringify({ id: m.messageid })
        }, 20000);
        respostas.push(`${rota} respondeu ${r.status}`);
        if (r.ok) {
          dados = await r.json().catch(() => null);
          if (dados) {
            if (lembrada !== rota) {
              console.log(`downloadmedia: este servidor atende por ${rota}.`);
              rotaQueServe.set(servidor, rota);
            }
            break;
          }
        } else if (rota === lembrada) {
          // A que servia parou de servir: esquece e deixa as outras tentarem.
          rotaQueServe.delete(servidor);
        }
      } catch (e) {
        respostas.push(`${rota} estourou (${(e && e.message) || e})`);
        if (rota === lembrada) rotaQueServe.delete(servidor);
        console.log(`downloadmedia ${rota} erro: ${e.message}`);
      }
    }
    // ------------------------------------------------------------
    //  A RESPOSTA INÚTIL É UMA FALHA IGUAL À RESPOSTA NENHUMA
    //
    //  A segunda chance — o endereço que a Uazapi mandou à parte, guardado pelo
    //  id EXATO desta mensagem — só era tentada quando o download não respondia
    //  NADA. Se ele respondia 200 com um corpo sem arquivo dentro, o `dados`
    //  chegava preenchido, a função seguia em frente, não achava bytes e
    //  desistia sem nunca olhar para o endereço que estava ali na mão.
    //
    //  É o caminho do relato de 10/09 ("Documento — indisponível"): o servidor
    //  responde, o corpo não traz o arquivo, e o resgate que existia
    //  justamente para isso ficava do lado de fora do `if`.
    //
    //  Agora as duas falhas passam pelo mesmo lugar.
    // ------------------------------------------------------------
    let mime = mimeInformado || 'application/octet-stream';
    let bytes = null;
    if (dados) {
      mime = dados.mimetype || dados.mime || mimeInformado || 'application/octet-stream';
      const b64 = dados.file || dados.data || dados.base64 || dados.media || dados.buffer;
      const urlBaixavel = dados.url || dados.fileURL || dados.fileUrl || dados.link || dados.mediaUrl;
      if (typeof b64 === 'string' && b64.length > 100) {
        bytes = Buffer.from(b64.replace(/^data:[^;]+;base64,/, ''), 'base64');
      } else if (urlBaixavel) {
        const arq = await fetchComTimeout(urlBaixavel, {}, 20000);
        if (arq.ok) bytes = Buffer.from(await arq.arrayBuffer());
      }
      if (!bytes || !bytes.length) {
        console.log('downloadmedia respondeu sem arquivo reconhecível:',
                    JSON.stringify(dados).slice(0, 300));
      }
    }

    if (!bytes || !bytes.length) {
      // A SEGUNDA CHANCE, antes de desistir: o endereço que a Uazapi mandou
      // por um `messages_update`, guardado pelo id EXATO desta mensagem.
      //
      // Foi o caso de 19/08 ao contrário: lá o endereço chegou DEPOIS do
      // download falhar (e o resgate cuida disso); aqui é quando ele chegou
      // ANTES, o que acontece sempre que o evento de arquivo vem na frente.
      const guardado = enderecoGuardado(m.messageid);
      if (guardado) {
        try {
          const salvo = await guardarArquivoDoEndereco(m.messageid, guardado);
          if (salvo.url) {
            console.log(`Anexo salvo pelo endereço que a Uazapi mandou à parte (${m.messageid}).`);
            return salvo.url;
          }
        } catch (e) {
          console.log(`O endereço guardado também não serviu (${m.messageid}): ${(e && e.message) || e}`);
        }
      }
      // O conteúdo da mensagem só vai para o log QUANDO DÁ ERRADO, que é
      // quando ele serve para alguma coisa. Antes ia sempre — legenda, nome de
      // arquivo, miniatura, de toda mídia recebida. Num escritório de
      // advocacia, log é lugar onde muita gente entra e nada se apaga.
      try {
        console.log('Mídia que não deu para baixar (content):', JSON.stringify(m.content).slice(0, 600));
      } catch (_) { /* ignora */ }
      return porque(dados
        ? 'a Uazapi respondeu, e sem arquivo dentro'
        : `nenhuma rota de download trouxe o arquivo — ${respostas.join('; ') || 'nenhuma tentativa saiu'}`);
    }

    const caminho = `recebidos/${m.messageid}.${extensaoDoArquivo(mime, nomeDoArquivo(m))}`;
    const { error: upErr } = await supabase.storage.from('anexos')
      .upload(caminho, bytes, { contentType: mime, upsert: true, ...CACHE_DA_MIDIA });
    if (upErr) {
      console.error('Erro ao salvar mídia recebida no Storage:', upErr.message);
      return porque(`o Storage recusou: ${upErr.message}`);
    }
    const { data: pub } = supabase.storage.from('anexos').getPublicUrl(caminho);
    return pub?.publicUrl || porque('o Storage guardou e não devolveu endereço');
  } catch (e) {
    console.error('Erro em baixarMidiaRecebida:', e.message);
    return porque(`estourou: ${e.message}`);
  }
}

/** Uma coluna vazia e uma miniatura `data:` são a mesma coisa para quem
 *  procura o arquivo de verdade: nos dois casos ele ainda não chegou. Os dois
 *  caminhos que põem arquivo em mensagem já gravada perguntam por aqui, para
 *  não divergirem no dia em que um deles for mexido. */
const ehSoMiniatura = (v) => !v || String(v).startsWith('data:');

// ============================================================
//  O ANEXO QUE NÃO CHEGOU DE PRIMEIRA — E A INSISTÊNCIA
//
//  RELATO DE 10/09: "Documentos recebidos no Zorvin estão como indisponível."
//
//  Uma tentativa era tudo o que existia. Falhou o download, a bolha ficava
//  vazia PARA SEMPRE: só o `FileURL` de um `messages_update` a salvava, e ele
//  nem sempre vem. Não havia nada — nem na tela, nem por fora — que fizesse a
//  ponte tentar de novo, e o escritório ficava com um documento que o cliente
//  jurava ter mandado.
//
//  A Uazapi vai buscar o arquivo nos servidores do WhatsApp na hora do pedido.
//  Falhar uma vez e servir na seguinte é o comportamento normal dela, e não a
//  exceção: um documento grande, uma fila cheia, um segundo de rede ruim.
//
//  TRÊS TENTATIVAS ESPAÇADAS, e não um laço apertado: 20 segundos, um minuto,
//  cinco minutos. A primeira costuma pegar o arquivo enquanto quem atende
//  ainda está com a conversa aberta, e a última cobre a lentidão de verdade
//  sem virar martelada num serviço que tem limite de uso.
//
//  ANTES DE CADA TENTATIVA, PERGUNTA-SE AO BANCO. O resgate pelo `FileURL`
//  corre por fora e pode ter chegado primeiro; insistir depois disso seria
//  baixar de novo um arquivo que já está guardado.
// ============================================================
const ESPERAS_DO_ANEXO = (process.env.ESPERA_DO_ANEXO_MS || '20000,60000,300000')
  .split(',').map((n) => parseInt(n, 10)).filter((n) => n > 0);

/** A mensagem já tem o arquivo de verdade? (Miniatura não conta.) */
async function jaTemOArquivo(idUazapi) {
  const { data, error } = await supabase
    .from('mensagens').select('midia_url').eq('id_uazapi', idUazapi);
  if (error || !data || !data.length) return false;
  return data.every((c) => !ehSoMiniatura(c.midia_url));
}

async function perseguirOArquivo({ servidor, token, m, mime, nome, tipo, tentativa = 0 }) {
  try {
    const url = await baixarMidiaRecebida(servidor, token, m, mime);
    if (url) {
      await trocarMiniaturaPeloArquivo(m.messageid, url, mime, nome);
      if (tentativa) {
        console.log(`Anexo (${tipo}) ${m.messageid}: chegou na tentativa ${tentativa + 1}.`);
      }
      return;
    }
  } catch (e) {
    console.log(`Anexo (${tipo}) ${m.messageid}: ${(e && e.message) || e}`);
  }

  const espera = ESPERAS_DO_ANEXO[tentativa];
  if (espera === undefined) {
    // O ID VAI JUNTO E INTEIRO — é por ele que se cruza com o `FileURL` que
    // chega depois, num `messages_update`, e é por ele que o resgate manual
    // (`/anexos/resgatar`) encontra a mensagem para tentar outra vez.
    console.log(`Anexo (${tipo}) sem arquivo depois de ${ESPERAS_DO_ANEXO.length + 1} `
      + `tentativas. Mensagem ${m.messageid} fica sem mídia. `
      + 'Quem abrir a conversa vê um anexo vazio.');
    return;
  }
  console.log(`Anexo (${tipo}) ${m.messageid}: não veio. Tento de novo em ${Math.round(espera / 1000)}s.`);
  // `unref` para o relógio não segurar o processo de pé sozinho. Numa ponte que
  // fica meses ligada isso não muda nada; numa bancada que sobe e desce a ponte
  // a cada prova, um relógio de cinco minutos pendurado é uma suíte que não
  // termina.
  const relogio = setTimeout(() => {
    jaTemOArquivo(m.messageid).then((tem) => {
      if (tem) return;
      perseguirOArquivo({ servidor, token, m, mime, nome, tipo, tentativa: tentativa + 1 });
    }).catch(() => {});
  }, espera);
  if (relogio && typeof relogio.unref === 'function') relogio.unref();
}

/**
 * Põe o arquivo de verdade na mensagem que nasceu com a miniatura.
 *
 * A TRAVA É O VALOR QUE ACABEI DE LER, e não "está vazio". Entre esta leitura
 * e a gravação cabe o resgate pelo `FileURL` (que corre por fora e pode ter
 * chegado primeiro): sem trava, o segundo a terminar sobrescreveria o primeiro,
 * e nada garante que o segundo seja o melhor arquivo. Gravando só quando a
 * coluna ainda está exatamente como eu a li, quem chegou depois desiste em
 * silêncio — que é o certo, porque o arquivo já está lá.
 *
 * Vale também para a repetição do mesmo webhook: na segunda vez a coluna já
 * aponta para o Storage, não casa com a miniatura, e nada é reescrito.
 */
async function trocarMiniaturaPeloArquivo(idUazapi, url, mime, nome) {
  if (!idUazapi || !url) return;
  // TODAS AS CÓPIAS, e não uma. Num grupo com dois telefones nossos a mesma
  // mensagem existe em duas conversas: trocar a miniatura só na primeira
  // deixaria a outra com a imagem borrada para sempre. E `maybeSingle()` aqui
  // devolveria ERRO — "mais de uma linha" —, derrubando a troca nas duas.
  const { data: copias, error } = await supabase
    .from('mensagens').select('id, midia_url').eq('id_uazapi', idUazapi);
  if (error) { console.log(`Não consegui achar a mensagem ${idUazapi}: ${error.message}`); return; }
  for (const alvo of copias || []) {
  // Já tem arquivo de verdade: nada a fazer. `data:` é miniatura, e miniatura
  // é justamente o que veio para ser substituído.
  if (!ehSoMiniatura(alvo.midia_url)) continue;

  const remendo = { midia_url: url };
  if (mime) remendo.midia_mime = mime;
  if (nome) remendo.midia_nome = nome;
  // A MESMA TRAVA, DUAS VEZES. A segunda escrita repete a condição inteira em
  // vez de reaproveitar a primeira: `escrita` já foi enviada, e um construtor
  // do supabase-js não se manda duas vezes.
  const comTrava = (remendar) => {
    let e = supabase.from('mensagens').update(remendar).eq('id', alvo.id);
    return alvo.midia_url === null || alvo.midia_url === undefined
      ? e.is('midia_url', null)
      : e.eq('midia_url', alvo.midia_url);
  };
  let { error: erroEscrita } = await comTrava(remendo);
  if (erroEscrita && nome) {
    // Base sem a coluna do nome: grava o arquivo assim mesmo. Perder o nome é
    // um aborrecimento; perder o arquivo por causa dele é o defeito de volta.
    const { midia_nome, ...semNome } = remendo;
    ({ error: erroEscrita } = await comTrava(semNome));
  }
  if (erroEscrita) console.log(`Não consegui pôr o arquivo em ${idUazapi}: ${erroEscrita.message}`);
  }
}

// ============================================================
//  O ANEXO QUE FICOU VAZIO — E O ENDEREÇO QUE CHEGA LOGO DEPOIS
//
//  Do log de 19/08, com um segundo de diferença:
//
//    Anexo (documento) sem arquivo: o download falhou.
//    Mensagem A5F59D4D… fica sem mídia.
//    Evento não tratado: messages_update {…"FileURL":"https://…jpg"…
//
//  Alguém abriu essa conversa e viu um anexo em branco — um documento que o
//  cliente mandou e o escritório não tem. E o endereço do arquivo chegou um
//  segundo depois, de bandeja, indo direto para o balde dos eventos ignorados.
//
//  O QUE TORNA ISTO SEGURO, e é a única coisa que importa aqui: o casamento é
//  pelo id EXATO da mensagem. Nunca por "a última mídia", nunca por "a mesma
//  conversa". Num escritório de advocacia, gravar o arquivo de um cliente na
//  mensagem de outro é pior do que não gravar nenhum — e um resgate esperto
//  demais erraria exatamente assim.
//
//  E a gravação só acontece onde NÃO HÁ arquivo (`midia_url is null`). Um
//  anexo que já chegou nunca é sobrescrito por este caminho.
//
//  Dez minutos de validade: se o download falhou e o endereço não veio nesse
//  tempo, ele não vem mais. Um mapa que só cresce é um vazamento de memória
//  disfarçado de cache, e a ponte é um processo só que fica meses de pé.
// ============================================================
const enderecosDeArquivo = new Map();   // id da mensagem -> { url, ate }
const VALIDADE_DO_ENDERECO_MS = 10 * 60 * 1000;
const TETO_DE_ENDERECOS = 500;

function guardarEnderecoDeArquivo(ids, url) {
  const agora = Date.now();
  for (const [k, v] of enderecosDeArquivo) if (v.ate < agora) enderecosDeArquivo.delete(k);
  // Teto duro, para o caso de uma enxurrada dentro da mesma janela de dez
  // minutos: sai o mais velho.
  while (enderecosDeArquivo.size >= TETO_DE_ENDERECOS) {
    enderecosDeArquivo.delete(enderecosDeArquivo.keys().next().value);
  }
  for (const id of ids) {
    if (id) enderecosDeArquivo.set(String(id), { url, ate: agora + VALIDADE_DO_ENDERECO_MS });
  }
}

function enderecoGuardado(id) {
  const g = enderecosDeArquivo.get(String(id || ''));
  if (!g) return null;
  if (g.ate < Date.now()) { enderecosDeArquivo.delete(String(id)); return null; }
  return g.url;
}

/** O tipo do arquivo pela ponta do endereço. A Uazapi não manda o mime junto
 *  do `FileURL`, e um arquivo salvo como "application/octet-stream" o
 *  navegador oferece para baixar em vez de mostrar. */
function mimePelaPonta(url) {
  const ponta = String(url || '').split('?')[0].split('.').pop().toLowerCase();
  const tabela = {
    jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', webp: 'image/webp',
    gif: 'image/gif', mp4: 'video/mp4', mov: 'video/quicktime', webm: 'video/webm',
    mp3: 'audio/mpeg', ogg: 'audio/ogg', oga: 'audio/ogg', opus: 'audio/ogg',
    m4a: 'audio/mp4', wav: 'audio/wav', pdf: 'application/pdf',
    doc: 'application/msword', xls: 'application/vnd.ms-excel', txt: 'text/plain',
    zip: 'application/zip',
  };
  return tabela[ponta] || 'application/octet-stream';
}

/** Baixa de um endereço e guarda no Storage. Devolve o endereço público, ou
 *  `null` — e o `null` nunca é silencioso, porque quem chama registra. */
async function guardarArquivoDoEndereco(messageid, url) {
  const mime = mimePelaPonta(url);
  const arq = await fetchComTimeout(url, {}, 20000);
  if (!arq.ok) throw new Error(`o endereço respondeu ${arq.status}`);
  const bytes = Buffer.from(await arq.arrayBuffer());
  if (!bytes.length) throw new Error('o endereço respondeu vazio');
  const ext = (String(mime).split('/')[1] || 'bin').split(';')[0];
  const caminho = `recebidos/${messageid}.${ext}`;
  const { error } = await supabase.storage.from('anexos')
    .upload(caminho, bytes, { contentType: mime, upsert: true, ...CACHE_DA_MIDIA });
  if (error) throw new Error(`Storage recusou: ${error.message}`);
  const { data: pub } = supabase.storage.from('anexos').getPublicUrl(caminho);
  return { url: pub && pub.publicUrl, mime };
}

/** O resgate: uma mensagem JÁ GRAVADA e sem arquivo recebe o que chegou.
 *
 *  A trava é o valor lido, e não `is null`: desde que a bolha passou a nascer
 *  com a MINIATURA, "sem arquivo" deixou de querer dizer "coluna vazia". Uma
 *  mensagem com `data:image/...` continua sendo uma mensagem sem o arquivo de
 *  verdade, e era exatamente essa que o resgate existe para salvar — com a
 *  trava velha, ele passaria direto por ela e o anexo ficaria sendo uma
 *  miniatura borrada para sempre.
 *
 *  E se a mensagem ainda não existe no banco (o evento chegou primeiro), não
 *  há o que atualizar — o endereço fica guardado para quando o download dela
 *  falhar, que é o outro caminho. */
async function resgatarAnexoVazio(id, url) {
  try {
    // TODAS AS CÓPIAS. Num grupo com dois telefones nossos a mesma mensagem
    // existe em duas conversas, e resgatar o anexo só de uma deixaria a outra
    // com o balão vazio — o defeito que este resgate existe para não ter.
    // (`maybeSingle()` aqui devolveria ERRO com duas cópias, e o resgate
    // deixaria de funcionar para as duas.)
    const { data: copias } = await supabase.from('mensagens')
      .select('id, midia_url').eq('id_uazapi', id);
    const vazias = (copias || []).filter((c) => ehSoMiniatura(c.midia_url));
    if (!vazias.length) return;   // não existe, ou já tem arquivo

    // O ARQUIVO É BAIXADO UMA VEZ SÓ, e não uma por cópia: é o mesmo arquivo, e
    // baixá-lo duas vezes gastaria a rede e o Storage por nada.
    const guardado = await guardarArquivoDoEndereco(id, url);
    if (!guardado.url) return;
    for (const alvo of vazias) {
      let escrita = supabase.from('mensagens')
        .update({ midia_url: guardado.url, midia_mime: guardado.mime })
        .eq('id', alvo.id);
      escrita = alvo.midia_url === null || alvo.midia_url === undefined
        ? escrita.is('midia_url', null)
        : escrita.eq('midia_url', alvo.midia_url);
      const { error } = await escrita;
      if (error) { console.error(`resgate do anexo ${id}: o banco recusou —`, error.message); continue; }
    }
    console.log(`Anexo resgatado: a mensagem ${id} estava sem arquivo em ${vazias.length} conversa(s) e recebeu o que a Uazapi mandou depois.`);
  } catch (e) {
    console.log(`Não consegui resgatar o anexo de ${id}: ${(e && e.message) || e}`);
  }
}

// ------------------------------------------------------------
//  Extrai o caminho interno do Storage a partir da URL pública.
//  Ex.: https://xxx.supabase.co/storage/v1/object/public/anexos/CAMINHO
//       -> "CAMINHO"
// ------------------------------------------------------------
function caminhoDoStorage(url) {
  if (!url) return null;
  const marca = '/anexos/';
  const i = url.indexOf(marca);
  if (i < 0) return null;
  try { return decodeURIComponent(url.slice(i + marca.length)); }
  catch (_) { return url.slice(i + marca.length); }
}

// ------------------------------------------------------------
//  Grava uma mensagem, tolerando colunas novas que talvez ainda
//  não existam no banco (ex.: as de citação). Se o upsert falhar
//  com os campos extras, tenta de novo só com o básico.
// ------------------------------------------------------------
// A CHAVE É (conversa, id_uazapi) — E NÃO O id_uazapi SOZINHO.
//
// Relato de 02/09, com dois prints: o grupo "Suporte Legal Mail" tem DOIS
// telefones nossos dentro, e cada um mostrava um PEDAÇO da discussão. Nenhuma
// mensagem aparecia nos dois.
//
// A causa era esta linha. `id_uazapi` é o identificador que o WhatsApp dá à
// mensagem, e o índice do banco o exigia único no banco INTEIRO. Isso está
// certo enquanto cada mensagem chega a um telefone nosso só; num grupo com dois
// dos nossos, a MESMA mensagem chega DUAS vezes — uma por telefone — com o
// mesmo identificador. A primeira entrava; a segunda batia no índice e era
// descartada.
//
// EM SILÊNCIO, e é o que fez isso durar: o aviso logo abaixo existe para "duas
// mensagens diferentes com a mesma chave", e ele se cala justamente quando o
// texto é igual — que é o caso de uma mensagem de grupo chegando duas vezes.
//
// A pergunta certa não é "esta mensagem já existe no Zorvin?" e sim "esta
// mensagem já existe NESTA conversa?". Cada telefone nosso tem a sua caixa.
const CHAVE_DA_MENSAGEM = 'conversa_id,id_uazapi';

async function salvarMensagem(base, extras) {
  const temExtras = extras && Object.keys(extras).length > 0;
  const payload = temExtras ? { ...base, ...extras } : base;
  // O `.select('id')` existe para saber SE GRAVOU. Com `ignoreDuplicates`, a
  // chave repetida não dá erro nem grava: sem pedir as linhas de volta, os dois
  // desfechos são indistinguíveis — e um deles é uma mensagem sumindo.
  let { data, error } = await supabase
    .from('mensagens')
    .upsert(payload, { onConflict: CHAVE_DA_MENSAGEM, ignoreDuplicates: true })
    .select('id');
  if (error && temExtras) {
    // Provável coluna inexistente: grava sem os campos de citação.
    console.log('Regravando mensagem sem campos de citação:', error.message);
    ({ data, error } = await supabase
      .from('mensagens')
      .upsert(base, { onConflict: CHAVE_DA_MENSAGEM, ignoreDuplicates: true })
      .select('id'));
  }
  if (!error && Array.isArray(data) && data.length === 0) {
    // Nada foi gravado, e não houve erro: a chave já existia.
    await avisarSeForOutraMensagem(base);
  }
  return error;
}

// DUAS MENSAGENS DIFERENTES COM A MESMA CHAVE — o caso que some sem rastro.
//
// `ignoreDuplicates` descarta em silêncio, e é o certo para o caso comum: a
// Uazapi reenvia a mesma mensagem quando desconfia que não entregou, e gravar
// duas vezes encheria a conversa de repetição.
//
// Mas o descarte também acontece quando chegam DUAS MENSAGENS DIFERENTES com o
// mesmo `messageid` — e aí não é repetição, é perda. O escritório relatou
// exatamente isso: um álbum de três fotos em que só duas apareceram, junto de
// uma bolha "Album: 3 images". Se o contêiner do álbum e uma das fotos dividem
// a chave, a foto é engolida aqui, sem erro e sem log.
//
// NÃO SE AVISA DO REENVIO LEGÍTIMO. Um aviso em toda repetição faria ninguém
// ler o log, e é lá que este precisa ser visto. Por isso a linha que já está
// gravada é LIDA e comparada: mesmo tipo e mesmo texto é reenvio, e sai calado.
//
// Isto NÃO conserta o álbum: consertar exige saber o que a Uazapi manda num, e
// esse dado ainda não foi lido. Isto faz o dado aparecer.
async function avisarSeForOutraMensagem(base) {
  try {
    // NA MESMA CONVERSA, e não no banco inteiro. Depois que a chave passou a
    // ser (conversa, id_uazapi), o mesmo identificador existe legitimamente em
    // duas conversas — e um `maybeSingle()` global passaria a devolver ERRO
    // ("mais de uma linha") justamente na mensagem de grupo, que é o caso que
    // este conserto veio atender.
    const { data: atual } = await supabase.from('mensagens')
      .select('tipo, texto, midia_url')
      .eq('conversa_id', base.conversa_id)
      .eq('id_uazapi', base.id_uazapi).maybeSingle();
    // Sumiu entre uma consulta e outra: não há o que comparar, e inventar uma
    // conclusão aqui seria pior do que ficar calado.
    if (!atual) return;
    const mesmoTexto = String(atual.texto || '') === String(base.texto || '');
    if (atual.tipo === base.tipo && mesmoTexto) return;   // reenvio: silêncio
    console.log(
      `DUAS MENSAGENS DIFERENTES COM A MESMA CHAVE (id_uazapi=${base.id_uazapi}). `
      + `A que já estava: tipo="${atual.tipo}", texto="${String(atual.texto || '').slice(0, 60)}". `
      + `A que foi DESCARTADA: tipo="${base.tipo}", texto="${String(base.texto || '').slice(0, 60)}". `
      + 'A descartada não aparece na conversa.');
  } catch (e) {
    // Uma base sem a coluna, ou uma oscilação: o aviso é diagnóstico, e não
    // pode derrubar a gravação que já deu certo.
    console.log('Não consegui conferir a chave repetida:', (e && e.message) || e);
  }
}

// ------------------------------------------------------------
//  QUANTO TEMPO TEM O ÁUDIO
//
//  No WhatsApp a lista de conversas mostra "Mensagem de voz (1:19)", e o tempo
//  não é enfeite: é o que separa um "ok" de dez segundos de um relato de três
//  minutos, na hora de decidir o que ouvir primeiro. Sem ele, a prévia do
//  Zorvin dizia só que havia um áudio.
//
//  O NOME DO CAMPO NÃO ESTÁ CONFIRMADO. A Uazapi entrega o nó cru da mensagem
//  em `content`, e o WhatsApp guarda a duração ali em `seconds` — mas isso é o
//  que a documentação sugere, não o que eu vi. Então procuramos em vários
//  cantos e por vários nomes, e quando um áudio chega sem nenhum deles o log
//  diz QUAIS campos vieram. É assim que o nome certo se descobre, com um áudio
//  de verdade, em vez de por adivinhação.
// ------------------------------------------------------------
const NOMES_DE_DURACAO = ['seconds', 'duration', 'duracao', 'audioDuration',
                          'mediaDuration', 'durationInSeconds'];
let avisouSemDuracao = false;

function segundosDaMidia(m, tipo) {
  const c = m.content && typeof m.content === 'object' ? m.content : {};
  const cantos = [m, c, c.audioMessage, c.videoMessage, c.message,
                  c.message && c.message.audioMessage];
  for (const canto of cantos) {
    if (!canto || typeof canto !== 'object') continue;
    for (const nome of NOMES_DE_DURACAO) {
      const v = Number(canto[nome]);
      // Um dia inteiro é o teto do absurdo: campos chamados "duration" às
      // vezes vêm em milissegundos, e 79000 viraria "1316:40" na tela.
      if (Number.isFinite(v) && v > 0 && v < 24 * 3600) return Math.round(v);
    }
  }
  if ((tipo === 'audio' || tipo === 'video') && !avisouSemDuracao) {
    avisouSemDuracao = true;
    const chaves = Object.keys(c).slice(0, 25);
    console.log(`Áudio/vídeo sem duração reconhecida. Os campos que vieram em `
      + `content foram: ${JSON.stringify(chaves)}. Se um deles for a duração, `
      + 'é só acrescentar o nome em NOMES_DE_DURACAO.');
  }
  return null;
}

// ------------------------------------------------------------
//  Detecta se uma mensagem recebida é RESPOSTA (citação) a outra.
//  O formato exato da Uazapi ainda não foi confirmado, então
//  tentamos vários campos comuns; se não achar, retorna null.
// ------------------------------------------------------------
function extrairResposta(m) {
  const ctx =
    m.quoted || m.quotedMsg || m.contextInfo ||
    (m.content && (m.content.contextInfo || m.content.quotedMessage)) || null;
  if (!ctx) return null;
  const idCitada =
    ctx.stanzaId || ctx.quotedId || ctx.id || (ctx.key && ctx.key.id) ||
    m.quotedMessageId || null;
  const texto =
    ctx.text || ctx.body || ctx.caption ||
    (ctx.quotedMessage && (ctx.quotedMessage.conversation || ctx.quotedMessage.text)) ||
    (typeof ctx.quotedMessage === 'string' ? ctx.quotedMessage : null);
  if (!idCitada && !texto) return null;
  return {
    responder_id_uazapi: idCitada || null,
    resposta_previa: texto ? String(texto).slice(0, 120) : null,
    resposta_autor: ctx.fromMe === true ? 'advogado' : 'contato',
  };
}

// ------------------------------------------------------------
//  REAÇÃO: o emoji que alguém prende NUMA MENSAGEM QUE JÁ EXISTE.
//
//  Sem isto, o emoji chegava como se fosse mensagem nova. Na tela aparecia uma
//  bolha solta com "😮" e um horário, sem ligação nenhuma com o que estava
//  sendo respondido — e ainda contava como não lida, então a conversa pedia
//  atenção por causa de um emoji. No celular, a mesma reação aparece presa à
//  bolha, que é o que ela é.
//
//  O FORMATO REAL DA UAZAPI, confirmado por um exemplo de produção:
//
//    { "messageType": "ReactionMessage",
//      "type": "reaction",
//      "reaction": "3EB088E41ADA6D9DDA3B71",     <- ID DA MENSAGEM ALVO
//      "text": "\u{1F622}",
//      "content": { "key": { "ID": "3EB088E41ADA6D9DDA3B71", "fromMe": false },
//                   "text": "\u{1F622}" },
//      "messageid": "3ABE8968E64050E659D5" }     <- id da PRÓPRIA reação
//
//  A armadilha está no nome: o campo `reaction` NÃO é a reação, é o id da
//  mensagem reagida. Foi exatamente por confiar nesse nome que a bolha passou a
//  exibir "3EB080DB9CFFC33549C426" no lugar do emoji. O emoji mora em
//  `content.text` (e também no `text` do topo), e o alvo em `content.key.ID` —
//  com ID em maiúsculas, diferente do resto da API.
//
//  Mesmo com o formato conhecido, a busca continua olhando vários campos e
//  filtrando pelo que TEM CARA DE EMOJI: uma versão nova da Uazapi que mude um
//  nome de campo passa a falhar em silêncio, e não a exibir lixo na conversa.
//  Quando NÃO dá para identificar a mensagem alvo, a reação segue o caminho
//  antigo e vira mensagem: continua feio, mas some sem deixar rastro seria
//  pior.
// ------------------------------------------------------------
// Diz se um texto TEM CARA DE EMOJI. É a trava que faltava.
//
// A primeira versão desta detecção pegou o campo errado do webhook e gravou o
// ID DA MENSAGEM no lugar do emoji: a bolha passou a exibir
// "3EB080DB9CFFC33549C426" numa pastilha, e como um id nunca é vazio, a
// retirada da reação também não apagava nada.
//
// A lição não é "acertar o campo" — é que adivinhar o campo de um formato não
// documentado É a situação normal aqui, e o código tem de recusar o que não
// serve em vez de exibir. Um emoji é curto e não é feito de letras e números
// ASCII; um id de mensagem do WhatsApp tem 20 e poucos caracteres e é só isso.
// O TELEFONE NA FORMA QUE A UAZAPI ESPERA: só dígitos, com o código do país.
//
// Um número de 10 ou 11 dígitos é brasileiro sem o 55 — é assim que a pessoa
// digita e é assim que o cadastro guarda. Qualquer outro tamanho já vem com
// DDI (ou é um id de grupo), e nesse caso só a pontuação sai.
function numeroLimpo(bruto) {
  const d = String(bruto || '').replace(/\D/g, '');
  if (d.length === 10 || d.length === 11) return '55' + d;
  return d;
}

// O NONO DÍGITO: as duas formas do mesmo celular.
//
// No Brasil o celular ganhou um 9 na frente do número local. O cadastro guarda
// a forma nova ("+55 31 99945-6790") e o WhatsApp devolve a antiga
// ("+55 31 9945-6790") — ou o contrário, dependendo de quando a conta foi
// criada. São a MESMA linha, e nenhuma limpeza de máscara ou de DDI faz uma
// virar a outra: uma tem um dígito a mais que a outra.
//
// Só vale para CELULAR. Fixo tem 8 dígitos começando em 2..5, e pôr um 9 nele
// criaria um número que não existe — pior que não achar o par.
function variantesDoNumero(bruto) {
  const d = String(bruto || '').replace(/\D/g, '');
  if (!d) return [];
  const com55 = d.startsWith('55') && (d.length === 12 || d.length === 13);
  const nacional = com55 ? d.slice(2) : d;
  const formas = new Set([nacional]);

  if (nacional.length === 11 && nacional[2] === '9') {
    formas.add(nacional.slice(0, 2) + nacional.slice(3));      // tira o nono
  } else if (nacional.length === 10 && '6789'.includes(nacional[2])) {
    formas.add(nacional.slice(0, 2) + '9' + nacional.slice(2)); // põe o nono
  }
  const todas = [];
  for (const f of formas) { todas.push(f, '55' + f); }
  return todas;
}

function pareceEmoji(txt) {
  const t = String(txt == null ? '' : txt).trim();
  if (!t) return false;
  if (Array.from(t).length > 8) return false;      // conta por caractere, não por byte
  return !/^[\w\s.,:;@/+-]+$/.test(t);            // só ASCII "de identificador" não é emoji
}

function extrairReacao(m) {
  const cru = m.reaction || (m.content && m.content.reactionMessage) || null;
  const tipo = String(m.messageType || m.mediaType || m.type || '').toLowerCase();
  if (!cru && !tipo.includes('reaction')) return null;

  // O corpo cru vai para o log SEMPRE que é reação. É o que permite ajustar os
  // campos com um exemplo real em mãos, em vez de com mais um palpite.
  console.log('Reação recebida. Corpo:', JSON.stringify(m).slice(0, 800));

  // O EMOJI: em vez de escolher um campo e torcer, olhamos todos os candidatos
  // e ficamos com o primeiro que TEM CARA DE EMOJI. Assim o campo certo é
  // encontrado mesmo que eu tenha errado a ordem, e o campo errado é recusado
  // mesmo que venha primeiro.
  const candidatos = [
    cru && cru.text, cru && cru.emoji, cru && cru.body,
    typeof cru === 'string' ? cru : null,
    m.content && m.content.text, m.content && m.content.emoji,
    typeof m.content === 'string' ? m.content : null,
    m.text, m.body, m.caption,
  ];
  const emoji = candidatos.find((c) => pareceEmoji(c));
  // Nenhum candidato tem conteúdo = RETIRADA da reação (o WhatsApp manda o
  // mesmo evento com o emoji vazio). Mas se havia conteúdo e nada parecia
  // emoji, é o campo errado de novo — e aí não se grava nada. Melhor a reação
  // não aparecer do que a bolha exibir um código.
  const tinhaAlgo = candidatos.some((c) => String(c == null ? '' : c).trim());
  if (!emoji && tinhaAlgo) {
    console.log('Reação: não achei o emoji em nenhum campo conhecido. Nada foi gravado.');
    return null;
  }

  // O id do ALVO, e nunca o id da própria reação: só vale campo que fale da
  // mensagem reagida. Por isso não há um `m.id` de recurso aqui.
  // O id do ALVO, e nunca o id da própria reação (esse é `m.messageid`, e não
  // aparece em lugar nenhum desta lista de propósito).
  const chave = (cru && cru.key) || (m.content && m.content.key) || null;
  const alvo = (chave && (chave.ID || chave.id))
    || (typeof m.reaction === 'string' ? m.reaction : null)   // o campo mal batizado
    || m.quotedMessageId || m.reactedMessageId
    || (cru && (cru.messageid || cru.stanzaId || cru.id))
    || null;
  if (!alvo) return null;

  return { alvo: String(alvo), emoji: emoji ? String(emoji).trim() : '' };
}

// Prende a reação na mensagem. Devolve `true` quando conseguiu — e é esse
// `true` que faz o webhook parar ali e não gravar uma mensagem nova.
async function aplicarReacao(reacao, de) {
  // TODAS AS CÓPIAS DA MENSAGEM. Num grupo com dois telefones nossos ela existe
  // em duas conversas, e a reação é a MESMA reação: quem reage no WhatsApp
  // reage à mensagem, não à caixa de entrada de alguém. Aplicá-la só na
  // primeira faria o emoji aparecer para metade da equipe.
  //
  // (E `maybeSingle()` aqui devolveria ERRO com duas cópias — "mais de uma
  // linha" —, e a reação deixaria de aparecer para as duas.)
  const { data: copias, error: erroBusca } = await supabase
    .from('mensagens').select('id, reacoes').eq('id_uazapi', reacao.alvo);
  if (erroBusca) {
    console.log('Reação: não consegui procurar a mensagem alvo:', erroBusca.message);
    return false;
  }
  if (!copias || !copias.length) {
    console.log(`Reação a uma mensagem que não está no Zorvin (${reacao.alvo}).`);
    return false;
  }

  let gravou = false;
  for (const alvo of copias) {
    // UMA REAÇÃO POR PESSOA: a nova substitui a anterior e o emoji vazio a
    // retira. É como o WhatsApp se comporta, e é o que evita a mesma pessoa
    // acumular cinco emojis na mesma bolha por ter mudado de ideia.
    // Trava dupla: nada que não pareça emoji entra na bolha, venha de onde vier.
    // Isto também limpa o que a versão anterior gravou errado — na primeira
    // reação da conversa, o id que estava lá é descartado junto.
    const atuais = (Array.isArray(alvo.reacoes) ? alvo.reacoes : [])
      .filter((r) => r && r.de !== de && pareceEmoji(r.emoji));
    if (reacao.emoji && pareceEmoji(reacao.emoji)) {
      atuais.push({ emoji: reacao.emoji, de, em: new Date().toISOString() });
    }

    const { error } = await supabase.from('mensagens').update({ reacoes: atuais }).eq('id', alvo.id);
    if (error) {
      console.log('Reação: não consegui gravar. Falta a coluna "reacoes"? '
                + 'Rode sql/2026-08-reacoes.sql no Supabase. Erro:', error.message);
      continue;
    }
    gravou = true;
  }
  if (!gravou) return false;
  console.log(`Reação ${reacao.emoji || '(retirada)'} de ${de} na mensagem ${reacao.alvo}`
            + (copias.length > 1 ? ` (em ${copias.length} conversas).` : '.'));
  return true;
}

// ============================================================
//  PARTE 2 — ENVIAR respostas (processa a fila_envio)
// ============================================================
//  A cada poucos segundos, a ponte olha a fila de mensagens que o
//  painel quer enviar, e manda cada uma pela Uazapi.
// ------------------------------------------------------------
let filaRodando = false; // impede que dois ciclos processem a fila ao mesmo tempo
// UM PEDIDO QUE CHEGA DURANTE O CICLO NÃO PODE SER JOGADO FORA.
//
// `filaRodando` fazia a chamada voltar em silêncio, e com isso o toque do
// painel se perdia. Envie três mensagens seguidas: a primeira acorda a fila e
// o ciclo começa; as duas seguintes tocam a campainha enquanto ele roda, e os
// dois toques eram descartados. Elas só saíam no `setInterval` de 3 segundos —
// e é isso que o escritório vê como o relóginho parado na bolha.
//
// Agora o toque perdido fica anotado, e o ciclo que estava rodando chama outro
// assim que termina. Um só, por mais toques que tenham chegado: o ciclo seguinte
// lê a fila inteira de qualquer jeito.
let filaPedidaDeNovo = false;
// ============================================================
//  POR QUE A MENSAGEM NÃO SAIU — dito em português
//
//  A bolha vermelha na tela dizia só "não enviado". Quem atende ficava sem
//  saber se o número está errado, se o cliente não tem WhatsApp, se a linha do
//  escritório caiu ou se foi coisa de um minuto que basta tentar de novo — e
//  cada um desses casos pede uma ação diferente. Sem o motivo, a única ação
//  possível era clicar em "reenviar" e torcer.
//
//  O motivo já era gravado em `erro_detalhe`, mas em linguagem de máquina
//  ("Uazapi respondeu 400: {"error":"number not exists"}"). Isso não se mostra
//  a ninguém. Aqui ele é traduzido para uma frase, e o texto técnico continua
//  guardado à parte, para quem precisar investigar.
//
//  O QUE EU SEI E O QUE EU NÃO SEI. As regras por código HTTP e as que vêm dos
//  erros do próprio Zorvin são seguras. As que dependem do vocabulário exato da
//  Uazapi são as prováveis, montadas a partir do que ela costuma responder —
//  não tenho como conferir todas daqui.
//
//  Por isso a regra de ouro: erro que NÃO for reconhecido não vira frase
//  genérica. Ele vai para a tela como está, e para o log com um aviso, para o
//  vocabulário ser aprendido dos casos de verdade em vez de adivinhado.
// ============================================================
/** A linha do escritório caiu do WhatsApp?
 *
 *  Sai daqui e não de dentro de `motivoDoErro` porque duas pessoas diferentes
 *  precisam da resposta: a atendente, que lê a frase na bolha vermelha, e
 *  quem administra, que precisa saber POR QUAL TELEFONE nada mais sai. */
function ehLinhaDesconectada(bruto) {
  const t = String(bruto || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
  return /(disconnected|not connected|desconect|instance.{0,20}(closed|down)|qrcode|qr code|需要)/.test(t);
}

function motivoDoErro(bruto) {
  const cru = String(bruto || '');
  const t = cru.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
  const status = Number((cru.match(/respondeu (\d{3})/) || [])[1]) || 0;

  // ---- 1. erros do próprio Zorvin: destes eu tenho certeza ----
  if (/enviada ao whatsapp, mas nao gravada/.test(t)) {
    return 'A mensagem CHEGOU ao cliente, mas não foi gravada no histórico daqui. '
         + 'Não reenvie — ele receberia duas vezes. Avise quem administra.';
  }
  if (/conversa\/advogado\/contato nao encontrado/.test(t)) {
    return 'O Zorvin não encontrou o telefone ou o contato desta conversa. '
         + 'Avise quem administra: é cadastro, não é a mensagem.';
  }
  if (/falhou apos \d+ tentativas/.test(t)) {
    return 'Tentamos várias vezes seguidas e não deu. Se o número estiver certo, '
         + 'espere alguns minutos e toque em reenviar.';
  }

  // ---- 2. conexão: também vem do nosso lado, e é certo ----
  // `abort` SOLTO, e não só `aborterror`. Foi o que faltava.
  //
  // Quando o nosso tempo limite estoura, quem lança é o próprio Node, e a
  // frase dele é "This operation was aborted" — sem o "error" colado. O filtro
  // procurava `aborterror`, que é o NOME da classe, e não o texto da mensagem;
  // então o tempo limite do Zorvin caía no desconhecido e a bolha vermelha
  // mostrava "This operation was aborted" em inglês para uma advogada.
  //
  // Achado varrendo os 238 erros do banco do escritório: das seis formas de
  // erro que apareciam sem tradução, cinco já eram entendidas — eram registros
  // antigos, de antes de a lista aprendê-las. Esta era a única viva, e era a
  // mais recente de todas.
  if (/demorou demais|abort|timeout|etimedout/.test(t)) {
    return 'O servidor do WhatsApp não respondeu a tempo. Toque em reenviar daqui a pouco.';
  }
  if (/fetch failed|enotfound|econnrefused|econnreset|network|socket hang up/.test(t)) {
    return 'Não conseguimos falar com o servidor do WhatsApp (Uazapi). '
         + 'Costuma ser passageiro — toque em reenviar daqui a pouco.';
  }

  // ---- 3. o que a Uazapi costuma dizer ----
  // Estas são as prováveis. Se alguma nunca casar, o erro cai no fim e aparece
  // como está — nada fica escondido por causa de um palpite errado.
  if (/(numero|number|phone).{0,25}(nao existe|not exist|not found|nao encontrado|invalid|inval)/.test(t)
      || /(not|nao).{0,15}(on|no|tem).{0,10}whatsapp/.test(t)
      || /exists.{0,10}false/.test(t)) {
    return 'Este número não tem conta no WhatsApp, ou está escrito errado. '
         + 'Confira o número na ficha do cliente.';
  }
  if (ehLinhaDesconectada(cru)) {
    return 'A linha do escritório está desconectada do WhatsApp. '
         + 'Avise quem administra: é preciso reconectar o aparelho.';
  }
  if (/blocked|bloquead|forbidden by (the )?(user|contact)/.test(t)) {
    return 'O cliente bloqueou este número do escritório. Tente por outro telefone nosso.';
  }
  if (/(too large|file size|payload too large|arquivo.{0,15}grande)/.test(t) || status === 413) {
    return 'O arquivo é grande demais para o WhatsApp. Reduza o tamanho e mande de novo.';
  }

  // ---- 4. pelo código HTTP: seguro, e é a última rede antes do desconhecido ----
  if (status === 401 || status === 403) {
    return 'A Uazapi recusou o acesso desta linha. Avise quem administra: '
         + 'costuma ser a chave da instância vencida ou trocada.';
  }
  if (status === 429) {
    return 'Muitas mensagens de uma vez. Espere um minuto e toque em reenviar.';
  }
  if (status >= 500) {
    return 'O servidor do WhatsApp (Uazapi) está com problema neste momento. '
         + 'Toque em reenviar daqui a pouco.';
  }

  // ---- 5. não reconhecido ----
  //
  // O log grita de propósito: é assim que a lista acima cresce a partir de
  // casos reais, em vez de adivinhação. E a tela mostra o texto cru: ver algo
  // que não se entende é ruim, mas é melhor do que uma frase bonita e falsa.
  console.log(`MOTIVO DE ERRO NÃO RECONHECIDO (vale acrescentar em motivoDoErro): ${cru.slice(0, 300)}`);
  return null;
}

/** Marca o item como erro, com o motivo em português e o texto técnico à parte. */
async function marcarErroNaFila(itemId, bruto, avisoVantoroId) {
  const motivo = motivoDoErro(bruto);
  const campos = { status: 'erro', erro_detalhe: String(bruto || '').slice(0, 1000) };
  campos.erro_motivo = motivo;
  let { error } = await supabase.from('fila_envio').update(campos).eq('id', itemId);
  // Instalação sem a coluna nova: grava sem ela. O item PRECISA virar erro —
  // se esta gravação falhar por inteiro, a bolha nem fica vermelha e a
  // mensagem some da tela como se nada tivesse acontecido.
  if (error && /erro_motivo/i.test(error.message || '')) {
    delete campos.erro_motivo;
    ({ error } = await supabase.from('fila_envio').update(campos).eq('id', itemId));
  }
  if (error) console.error(`Não consegui marcar o item ${itemId} como erro:`, error.message);
  if (avisoVantoroId) await avisoDeuErro(avisoVantoroId, String(bruto || ''));
}

// LINHA CAÍDA É AVISO, E NÃO MAIS UMA FALHA NA PILHA.
//
// "Uazapi respondeu 503: WhatsApp disconnected: session is not reconnectable"
// não é uma mensagem que deu errado: é um TELEFONE DO ESCRITÓRIO fora do ar,
// e nada mais sai por ele até alguém reconectar. A atendente vê a bolha
// vermelha com a frase certa; quem administra não via nada, e só ficava
// sabendo quando alguém reclamasse.
//
// Uma linha por telefone a cada dez minutos: repetir a cada mensagem
// afogaria o log justamente quando ele mais importa, e calar de vez faria a
// linha ficar caída o fim de semana inteiro sem ninguém notar.
const linhasAvisadas = new Map();
function avisarQueALinhaCaiu(bruto, numero, nome) {
  if (!ehLinhaDesconectada(bruto)) return;
  const ultimo = linhasAvisadas.get(numero) || 0;
  if (Date.now() - ultimo < 10 * 60 * 1000) return;
  linhasAvisadas.set(numero, Date.now());
  console.error(`LINHA DESCONECTADA: o telefone ${numero}${nome ? ` (${nome})` : ''} `
    + 'perdeu a conexão com o WhatsApp e NADA MAIS SAI por ele. '
    + 'É preciso reconectar o aparelho na Uazapi — ler o QR de novo. '
    + 'As mensagens ficam na fila marcadas como erro, e podem ser reenviadas depois.');
}

// ============================================================
//  A MENSAGEM QUE NÃO SAIU TENTA DE NOVO SOZINHA
//
//  Uma falha, e a mensagem morria ali. O item virava 'erro', a bolha ficava
//  vermelha com "toque em reenviar daqui a pouco", e ninguém tentava de novo —
//  nunca. Uma piscada de rede entre a Render e a Uazapi, ou um "mandou demais"
//  de trinta segundos, custava uma resposta ao cliente que só sairia se alguém
//  estivesse com aquela conversa aberta na tela para clicar. Fora do horário,
//  ou numa conversa que a atendente já tinha fechado, não saía.
//
//  O CUIDADO QUE MANDA NO DESENHO: reenviar por conta própria uma mensagem que
//  TALVEZ tenha saído é o cliente recebendo duas vezes, e isso é pior do que a
//  bolha vermelha — a bolha alguém resolve, a duplicata não tem desfazer.
//
//  Por isso a régua não é "deu erro, tenta de novo". É: **só tenta sozinha
//  quando dá para ter certeza de que nada chegou ao cliente.** Fora desses
//  casos, tudo continua exatamente como hoje — vermelho, com o motivo em
//  português, e a decisão nas mãos de quem atende.
// ============================================================

/** A espera antes de cada nova tentativa, pelo número de tentativas já feitas.
 *
 *  Cresce de propósito. As falhas que valem retentativa são justamente as que
 *  duram um tempo (a Uazapi reiniciando, um "mandou demais"), e insistir de
 *  três em três segundos não adiantaria nada — só gastaria as cinco tentativas
 *  no primeiro minuto, bem quando o problema ainda está de pé. */
// Cinco tentativas, e depois a bolha vermelha. Sai do ciclo da fila para
// `tentarDeNovoMaisTarde` poder dizer no log de quantas é a que ele acabou de
// agendar — um número solto ("tentativa 3") não diz se falta muito.
const MAX_TENTATIVAS = 5;
const ESPERA_ENTRE_TENTATIVAS_MS = [30 * 1000, 2 * 60 * 1000, 5 * 60 * 1000, 15 * 60 * 1000];

/** A coluna não existe? É diferente de "o banco recusou agora". */
const semAColuna = (erro) => Boolean(erro) && (
  ['42703', 'PGRST204'].includes(String(erro.code))
  || /column .* does not exist|could not find the .* column/i.test(String(erro.message || '')));

let esperaDesligada = false;  // a coluna `tentar_em` não existe: segue como antes

/**
 * Esta falha permite tentar de novo sem risco de o cliente receber duas vezes?
 *
 *  A resposta só é `true` quando a própria falha PROVA que a mensagem não foi
 *  processada. Na dúvida, `false` — e aí a bolha fica vermelha como sempre
 *  ficou, que é o comportamento que já existia e não piora nada.
 */
function daParaTentarDeNovoSozinho(bruto) {
  const cru = String(bruto || '');
  const t = cru.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
  const status = Number((cru.match(/respondeu (\d{3})/) || [])[1]) || 0;

  // A LINHA DO ESCRITÓRIO CAIU. Aqui a certeza existe — nada saiu —, e mesmo
  // assim a resposta é não: enquanto ninguém reconectar o aparelho, nada vai
  // sair. Insistir gastaria as cinco tentativas em vinte minutos para terminar
  // na mesma bolha vermelha, só que mais tarde e depois de o aviso de linha
  // caída já ter passado. Este caso pede uma pessoa, não uma retentativa.
  if (ehLinhaDesconectada(cru)) return false;

  // 429 É A UAZAPI DIZENDO QUE NÃO PROCESSOU. "Mandou demais" é uma recusa,
  // não um meio-caminho: a mensagem não foi para o WhatsApp. E é a falha que
  // mais aparece no dia movimentado, que é o dia em que a resposta perdida
  // custa caro.
  if (status === 429) return true;

  // A CONEXÃO NUNCA ABRIU. Servidor recusando conexão, nome que não resolve:
  // não houve conversa com a Uazapi, então não houve mensagem. É o único caso
  // de rede em que a certeza existe.
  //
  // Repare no que está DE FORA, e é de propósito: tempo limite estourado,
  // conexão derrubada no meio (`econnreset`, `socket hang up`) e o 5xx do
  // servidor. Nesses, o pedido pode ter chegado inteiro e a resposta é que se
  // perdeu — a Uazapi teria mandado a mensagem, e nós reenviaríamos por cima.
  // Saber quais deles são seguros depende de conhecer o comportamento da
  // Uazapi, e é uma das perguntas ainda em aberto; até lá, ficam com a pessoa.
  if (/enotfound|econnrefused|eai_again/.test(t)) return true;

  return false;
}

/**
 * Devolve o item para a fila com uma espera. `false` quer dizer "não deu" —
 * e aí quem chamou marca como erro, exatamente como antes.
 */
async function tentarDeNovoMaisTarde(item, bruto) {
  if (esperaDesligada) return false;
  const espera = ESPERA_ENTRE_TENTATIVAS_MS[
    Math.min((item.tentativas || 0), ESPERA_ENTRE_TENTATIVAS_MS.length - 1)];
  const { error } = await supabase.from('fila_envio')
    .update({
      status: 'pendente',
      tentar_em: new Date(Date.now() + espera).toISOString(),
      // O MOTIVO FICA GRAVADO MESMO SEM A BOLHA VERMELHA. Quem for investigar
      // "por que esta demorou" precisa da pista, e `status = 'pendente'` não
      // conta nada sozinho. A tela não muda: ela pinta de vermelho pelo
      // `status`, e este item voltou a ser um item pendente.
      erro_detalhe: String(bruto || '').slice(0, 1000),
    })
    .eq('id', item.id);
  if (error && semAColuna(error)) {
    esperaDesligada = true;
    console.warn(
      'ATENÇÃO: a coluna "fila_envio.tentar_em" não existe, então a retentativa '
      + 'automática está DESLIGADA e a ponte volta a se comportar como antes: uma '
      + 'falha de rede marca a mensagem como erro e ela só sai se alguém tocar em '
      + 'reenviar. Rode sql/2026-09-a-mensagem-que-nao-saiu-tenta-de-novo.sql.');
    return false;
  }
  if (error) {
    console.error(`Não consegui reagendar o item ${item.id}:`, error.message);
    return false;
  }
  console.log(`Fila: item ${item.id} não saiu (${String(bruto || '').slice(0, 120)}); `
    + `tentativa ${(item.tentativas || 0) + 1} de ${MAX_TENTATIVAS}, nova tentativa em `
    + `${Math.round(espera / 1000)}s.`);
  return true;
}

async function processarFilaDeEnvio() {
  // SAINDO DO AR: não COMEÇA ciclo novo. O que já está correndo termina — é
  // justamente por ele que o desligamento espera.
  if (desligando) return;
  if (filaRodando) { filaPedidaDeNovo = true; return; } // fica anotado para o fim deste ciclo
  filaRodando = true;
  try {
    // Recuperação: se um item ficou preso em 'enviando' por mais de 5 min
    // (ex.: o Render reiniciou/dormiu no meio de um envio), volta para
    // 'pendente' para ser reprocessado — senão a mensagem some sem aviso.
    //
    // PELO MOMENTO EM QUE O ENVIO COMEÇOU, e não pelo momento em que o item foi
    // criado. Era `criado_em`, e a diferença manda uma mensagem duas vezes para
    // o cliente: um item que esperou 6 minutos na fila e ACABOU de ser
    // reivindicado já se encaixava na regra de "preso há mais de 5 minutos" —
    // então outro ciclo o devolvia para 'pendente' enquanto o primeiro ainda
    // estava falando com a Uazapi, e a mensagem saía de novo.
    //
    // Dentro de um processo só, `filaRodando` evitava o cruzamento. Basta uma
    // segunda instância no ar — o que acontece em toda publicação, com a nova
    // subindo antes de a antiga sair — para o caso acontecer.
    const limiteTravado = new Date(Date.now() - 5 * 60 * 1000).toISOString();
    const { data: destravadas } = await supabase
      .from('fila_envio')
      .update({ status: 'pendente' })
      .eq('status', 'enviando')
      .lt('enviando_em', limiteTravado)
      .select('id');
    // Os itens de antes desta mudança não têm `enviando_em`. Para eles, e só
    // para eles, vale a regra antiga — senão ficariam presos para sempre.
    const { data: antigas } = await supabase
      .from('fila_envio')
      .update({ status: 'pendente' })
      .eq('status', 'enviando')
      .is('enviando_em', null)
      .lt('criado_em', limiteTravado)
      .select('id');
    const quantas = (destravadas || []).length + (antigas || []).length;
    if (quantas) console.log(`Fila: ${quantas} item(ns) preso(s) em 'enviando' devolvido(s) para 'pendente'.`);

    // Pega até 10 mensagens pendentes de cada vez.
    //
    // O ITEM QUE ESTÁ ESPERANDO A PRÓXIMA TENTATIVA NÃO ENTRA. `tentar_em` é a
    // hora a partir da qual ele pode ser tentado de novo; enquanto não chegar,
    // ele é pendente mas não é da vez. Item que nunca falhou não tem a marca, e
    // por isso o `is.null` faz parte da regra — sem ele, a fila normal pararia.
    const agora = new Date().toISOString();
    const lerPendentes = (comEspera) => {
      let q = supabase.from('fila_envio').select('*').eq('status', 'pendente');
      if (comEspera) q = q.or(`tentar_em.is.null,tentar_em.lte.${agora}`);
      return q.order('criado_em', { ascending: true }).limit(10);
    };

    let { data: pendentes, error } = await lerPendentes(!esperaDesligada);
    // BASE SEM A COLUNA: lê de novo sem o filtro, em vez de a fila inteira
    // parar. Uma fila que não é lida é o escritório todo sem enviar nada — bem
    // pior do que ficar sem a retentativa automática.
    if (error && semAColuna(error)) {
      esperaDesligada = true;
      console.warn(
        'ATENÇÃO: a coluna "fila_envio.tentar_em" não existe, então a retentativa '
        + 'automática está DESLIGADA e a ponte segue como antes. '
        + 'Rode sql/2026-09-a-mensagem-que-nao-saiu-tenta-de-novo.sql.');
      ({ data: pendentes, error } = await lerPendentes(false));
    }

    if (error) { console.error('Erro ao ler fila:', error.message); return; }
    if (!pendentes || pendentes.length === 0) return;

    for (const item of pendentes) {
      // Trava de segurança: se o item já tentou demais (ex.: ficou preso e foi
      // devolvido para 'pendente' várias vezes), para de reenviar e marca erro.
      // Evita um laço infinito que reentregaria a mesma mensagem sem parar.
      if ((item.tentativas || 0) >= MAX_TENTATIVAS) {
        await marcarErroNaFila(item.id, `Falhou após ${MAX_TENTATIVAS} tentativas`, item.aviso_vantoro_id);
        console.error(`Fila: item ${item.id} excedeu ${MAX_TENTATIVAS} tentativas; marcado como erro.`);
        continue;
      }
      // Reivindica o item de forma ATÔMICA: só processa se ainda estava
      // 'pendente'. Evita envio duplicado se dois ciclos se cruzarem.
      const { data: claim, error: claimErr } = await supabase.from('fila_envio')
        .update({ status: 'enviando', tentativas: (item.tentativas || 0) + 1,
                  enviando_em: new Date().toISOString() })
        .eq('id', item.id)
        .eq('status', 'pendente')
        .select('id');
      if (claimErr) { console.error('Erro ao reivindicar item da fila:', claimErr.message); continue; }
      if (!claim || claim.length === 0) continue; // outro ciclo já pegou este item

      // Descobre para qual número enviar e por qual advogado (token/servidor).
      const { data: conv } = await supabase
        .from('conversas')
        .select('id, contato:contato_id (numero), advogado:advogado_id (token, servidor, numero, nome)')
        .eq('id', item.conversa_id)
        .single();

      if (!conv || !conv.advogado || !conv.contato) {
        await marcarErroNaFila(item.id, 'Conversa/advogado/contato não encontrado', item.aviso_vantoro_id);
        continue;
      }

      const servidor = (conv.advogado.servidor || 'https://novaera.uazapi.com').replace(/\/$/, '');
      const token = conv.advogado.token;
      // O DESTINO VAI LIMPO, seja como for que o contato tenha entrado.
      //
      // Aqui ia o número exatamente como está no banco. Enquanto todo caminho
      // do painel gravava a forma canônica isso não incomodava — mas o caminho
      // do cadastro do Vantoro gravava como o Vantoro devolve, com máscara
      // ("(11) 93404-2997"), e era isso que saía para a Uazapi. O painel já
      // foi corrigido; esta limpeza é a rede para os contatos que entraram
      // torto antes disso, que continuam funcionando sem depender de arrumar
      // o banco primeiro.
      const numeroDestino = numeroLimpo(conv.contato.numero);

      try {
        // Esta mensagem é um ANEXO (imagem/documento/áudio/vídeo) ou texto?
        const ehMidia = item.tipo && item.tipo !== 'texto' && item.midia_url;
        // REAÇÃO não é mensagem: não vira bolha nova nem entra no histórico.
        // Reaproveita `responder_id_uazapi` porque é exatamente o que a coluna
        // já significa — "a mensagem à qual isto se refere".
        const ehReacao = item.tipo === 'reacao';
        // EDIÇÃO: também não é mensagem nova. Reaproveita `responder_id_uazapi`
        // para apontar a mensagem que será reescrita, como a reação faz.
        const ehEdicao = item.tipo === 'edicao';
        // APAGAR PARA TODOS. A documentação da Uazapi não oferece "apagar só
        // para mim": esta rota tira a mensagem da conversa dos dois lados, e
        // funciona tanto no que nós mandamos quanto no que recebemos.
        const ehExclusao = item.tipo === 'exclusao';

        let resposta;
        if (ehExclusao) {
          resposta = await fetchComTimeout(`${servidor}/message/delete`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'token': token },
            body: JSON.stringify({ id: item.responder_id_uazapi })
          }, 30000);
        } else if (ehEdicao) {
          resposta = await fetchComTimeout(`${servidor}/message/edit`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'token': token },
            body: JSON.stringify({ id: item.responder_id_uazapi, text: item.texto || '' })
          }, 30000);
        } else if (ehReacao) {
          // O número vai no formato de JID que a Uazapi documenta para esta
          // rota. Ela aceita o número cru nas outras, mas aqui seguimos o
          // exemplo da documentação em vez de supor.
          resposta = await fetchComTimeout(`${servidor}/message/react`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'token': token },
            body: JSON.stringify({
              number: `${numeroDestino}@s.whatsapp.net`,
              text: item.texto || '',          // vazio = retirar a reação
              id: item.responder_id_uazapi,
            })
          }, 30000);
        } else if (ehMidia) {
          const tipoUaz =
            item.tipo === 'imagem' ? 'image' :
            item.tipo === 'video' ? 'video' :
            item.tipo === 'figurinha' ? 'sticker' :
            item.tipo === 'audio' ? 'ptt' : 'document';

          // Chama /send/media com um "file" (URL pública ou base64).
          const enviarMidia = async (fileParam, via) => {
            const corpoM = { number: numeroDestino, type: tipoUaz, file: fileParam, text: item.texto || '' };
            if (item.midia_nome) corpoM.docName = item.midia_nome;
            if (item.responder_id_uazapi) corpoM.replyid = item.responder_id_uazapi;
            console.log(`Enviando mídia (${tipoUaz}) via ${via} para ${numeroDestino}.`);
            return fetchComTimeout(`${servidor}/send/media`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json', 'token': token },
              body: JSON.stringify(corpoM)
            }, 45000); // mídia é mais lenta: dá mais tempo antes de abortar
          };

          // 1ª tentativa: URL pública do Storage (bucket público).
          resposta = await enviarMidia(item.midia_url, 'url');

          // Se falhar, 2ª tentativa: baixa o arquivo e envia como base64.
          if (!resposta.ok) {
            const det = await resposta.text().catch(() => '');
            console.log(`Envio por URL falhou (${resposta.status}): ${det.slice(0, 200)}`);
            try {
              const caminho = caminhoDoStorage(item.midia_url);
              if (caminho) {
                const { data: blob, error: dlErr } = await supabase.storage.from('anexos').download(caminho);
                if (dlErr) {
                  console.error('Erro ao baixar anexo do Storage:', dlErr.message);
                } else {
                  const buff = Buffer.from(await blob.arrayBuffer());
                  const mime = item.midia_mime || 'application/octet-stream';
                  resposta = await enviarMidia(`data:${mime};base64,${buff.toString('base64')}`, 'base64');
                }
              }
            } catch (prepErro) {
              console.error('Falha na 2ª tentativa (base64):', prepErro.message);
            }
          }
        } else {
          // Envia texto. Se é uma RESPOSTA, passa o replyid para citar.
          const corpo = { number: numeroDestino, text: item.texto, readchat: true };
          if (item.responder_id_uazapi) corpo.replyid = item.responder_id_uazapi;
          resposta = await fetchComTimeout(`${servidor}/send/text`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'token': token },
            body: JSON.stringify(corpo)
          }, 45000);
        }

        if (!resposta.ok) {
          // .catch: no caminho de mídia a 1ª resposta já pode ter sido lida
          // (linha da tentativa por URL) — evita o erro "body already read".
          const detalhe = await resposta.text().catch(() => '');
          throw new Error(`Uazapi respondeu ${resposta.status}: ${detalhe}`);
        }

        // Tenta capturar o id que a Uazapi deu à mensagem enviada.
        // Serve como trava extra: se um eco chegar com o mesmo id, o banco
        // recusa a duplicata automaticamente.
        let idUazapi = null;
        try {
          const dados = await resposta.json();
          idUazapi = dados?.messageid || dados?.id || dados?.message?.messageid || null;
        } catch (_) { /* resposta sem JSON: seguimos sem o id */ }

        // Deu certo: marca como enviada e registra a mensagem no histórico.
        const { error: okErr } = await supabase.from('fila_envio')
          .update({ status: 'enviada', enviado_em: new Date().toISOString() })
          .eq('id', item.id);
        if (okErr) console.error(`Enviada ao WhatsApp mas falhou ao marcar 'enviada' (item ${item.id}):`, okErr.message);

        // Era um aviso de audiência? Só AGORA o Vantoro pode marcar como
        // enviado — é aqui que a mensagem realmente saiu. Confirmar lá atrás,
        // na hora de enfileirar, faria o Vantoro achar que o cliente foi
        // avisado mesmo quando a Uazapi recusou.
        if (item.aviso_vantoro_id) {
          try {
            await chamarAudiencias(`/avisos/${item.aviso_vantoro_id}/enviado`, { method: 'POST' });
            console.log(`Aviso ${item.aviso_vantoro_id} confirmado no Vantoro.`);
          } catch (e) {
            console.error('Não consegui confirmar o aviso no Vantoro:', (e && e.message) || e);
          }
        }

        // A EXCLUSÃO PARA AQUI. A bolha não sai do histórico do Zorvin: ela
        // vira "Esta mensagem foi apagada", como no WhatsApp. Apagar a linha
        // deixaria um buraco silencioso na conversa — a equipe veria a resposta
        // sem a pergunta, e não teria como saber que algo foi removido nem por
        // quem.
        if (ehExclusao) {
          const dados = await resposta.json().catch(() => null);
          if (dados && (dados.success === false || dados.error)) {
            throw new Error(`Uazapi recusou apagar: ${dados.error || dados.message || 'sem detalhe'}`);
          }
          let { error: erroDel } = await supabase.from('mensagens')
            .update({ apagada: true, texto: null, midia_url: null })
            .eq('id_uazapi', item.responder_id_uazapi);
          if (erroDel && /apagada/i.test(erroDel.message || '')) {
            console.log('Falta a coluna "apagada"? Rode sql/2026-08-apagar-mensagem.sql. Erro:', erroDel.message);
          } else if (erroDel) {
            console.log('Exclusão: não consegui marcar a mensagem:', erroDel.message);
          }
          await supabase.from('fila_envio')
            .update({ status: 'enviada', enviado_em: new Date().toISOString() }).eq('id', item.id);
          console.log(`Mensagem ${item.responder_id_uazapi} apagada para todos.`);
          continue;
        }

        // A EDIÇÃO PARA AQUI: ela reescreve uma bolha que já existe, em vez de
        // criar outra. Sem este desvio, editar criaria uma segunda mensagem com
        // o texto novo e a antiga continuaria na conversa — o oposto de editar.
        //
        // O WhatsApp gera um ID NOVO para a mensagem editada, e por isso o
        // `id_uazapi` é trocado junto: sem isso, uma edição seguinte apontaria
        // para um id que já não existe, e a segunda correção falharia.
        if (ehEdicao) {
          const novoTexto = item.texto || '';
          let idNovo = null;
          // 200 NÃO É SUCESSO AQUI. A Uazapi aceita o pedido e responde OK
          // mesmo quando o WhatsApp recusa a edição depois — foi o que
          // aconteceu ao editar uma mensagem de mais de uma hora: o contato
          // recebeu a notificação e o texto ficou como estava.
          //
          // Por isso o corpo é lido: se ele disser que não deu, o item vai
          // para 'erro' e o banco NÃO é reescrito, senão o Zorvin mostraria
          // uma correção que só existe aqui dentro.
          const dados = await resposta.json().catch(() => null);
          if (dados && (dados.success === false || dados.error)) {
            throw new Error(`Uazapi recusou a edição: ${dados.error || dados.message || 'sem detalhe'}`);
          }
          idNovo = dados?.messageid || dados?.id || dados?.message?.messageid || null;
          const campos = { texto: novoTexto, editada: true };
          if (idNovo) campos.id_uazapi = String(idNovo).split(':').pop();
          let { error: erroEd } = await supabase.from('mensagens')
            .update(campos).eq('id_uazapi', item.responder_id_uazapi);
          // Instalação sem a coluna `editada`: grava só o texto. Perder o selo
          // "editada" é aceitável; não gravar a correção, não.
          if (erroEd && /editada/i.test(erroEd.message || '')) {
            delete campos.editada;
            ({ error: erroEd } = await supabase.from('mensagens')
              .update(campos).eq('id_uazapi', item.responder_id_uazapi));
          }
          if (erroEd) console.log('Edição: não consegui gravar o texto novo:', erroEd.message);
          await supabase.from('fila_envio')
            .update({ status: 'enviada', enviado_em: new Date().toISOString() }).eq('id', item.id);
          console.log(`Mensagem ${item.responder_id_uazapi} editada.`);
          continue;
        }

        // A REAÇÃO PARA AQUI. Ela não vira linha no histórico: prende-se à
        // mensagem que já está lá, do mesmo jeito que a reação recebida. Sem
        // este desvio, reagir pelo Zorvin criaria a bolha solta que este
        // trabalho todo foi feito para eliminar.
        if (ehReacao) {
          await aplicarReacao({ alvo: item.responder_id_uazapi, emoji: item.texto || '' }, 'advogado');
          console.log(`Reação ${item.texto || '(retirada)'} enviada para ${numeroDestino}.`);
          continue;
        }

        const base = {
          conversa_id: item.conversa_id,
          origem: 'advogado',
          tipo: item.tipo || 'texto',
          texto: item.texto || null,
          midia_url: ehMidia ? item.midia_url : null,
          midia_mime: ehMidia ? (item.midia_mime || null) : null,
          id_uazapi: idUazapi,
          status: 'enviada'
        };
        // Campos "extras" (colunas que podem não existir ainda no banco): quem
        // enviou (atendente) e os dados de citação. Se alguma coluna faltar, o
        // salvarMensagem regrava só com o básico, sem quebrar.
        const extras = {};
        if (item.enviado_por) extras.enviado_por = item.enviado_por;
        if (item.enviado_por_foto) extras.enviado_por_foto = item.enviado_por_foto;
        // O NOME DO ARQUIVO TAMBÉM NO QUE SAI.
        //
        // O painel já grava `midia_nome` na FILA — é dele que sai o `docName`
        // mandado ao WhatsApp, logo acima. Mas a linha de `mensagens`, que é a
        // que a conversa desenha, nunca o recebia: o nome fazia a viagem
        // inteira até o cliente e não sobrava para o escritório. Toda bolha de
        // documento ENVIADO também aparecia escrita só "Documento".
        if (ehMidia && item.midia_nome) extras.midia_nome = item.midia_nome;
        // O ID de quem enviou viaja junto com o nome. O nome é o que a bolha
        // mostra (o nome de então); o id é o que o painel conta, porque ele não
        // muda quando alguém edita o próprio perfil. Entra como "extra" pelo
        // mesmo motivo dos outros: numa base sem o SQL rodado a coluna não
        // existe, e a mensagem não pode deixar de ser gravada por causa disso.
        if (item.enviado_por_id) extras.enviado_por_id = item.enviado_por_id;
        if (item.responder_id_uazapi) {
          extras.responder_id_uazapi = item.responder_id_uazapi;
          extras.resposta_previa = item.resposta_previa || null;
          extras.resposta_autor = item.resposta_autor || null;
        }
        // O RESULTADO DESTA GRAVAÇÃO NÃO PODE SER JOGADO FORA.
        //
        // Ele era. A mensagem saía para o WhatsApp, o contato recebia, e se o
        // banco recusasse a linha — coluna faltando, restrição no `tipo`,
        // política de RLS — ninguém ficava sabendo: nem a tela, que não
        // mostrava a bolha, nem o log, que não dizia nada. Era assim que uma
        // figurinha podia chegar ao cliente e não existir no Zorvin.
        //
        // O item continua 'enviada', porque enviada ele foi. O motivo fica
        // gravado em `erro_detalhe`, que é onde se procura quando algo não
        // aparece.
        const erroHist = await salvarMensagem(base, Object.keys(extras).length ? extras : null);
        if (erroHist) {
          console.error(`ENVIADA MAS NÃO GRAVADA (item ${item.id}, tipo ${item.tipo || 'texto'}):`, erroHist.message);
          await supabase.from('fila_envio')
            .update({ erro_detalhe: `enviada ao WhatsApp, mas não gravada no histórico: ${erroHist.message}` })
            .eq('id', item.id);
        }

        console.log(`Enviada (${item.tipo || 'texto'}) para ${numeroDestino}.`);
      } catch (envioErro) {
        // O CÓDIGO DA FALHA DE REDE VINHA E ERA JOGADO FORA. Quando a conexão
        // não abre, o Node lança "fetch failed" e guarda o motivo de verdade
        // (`ECONNREFUSED`, `ENOTFOUND`) em `cause` — que ninguém lia. Sem ele
        // não há como separar "não consegui nem falar com o servidor" de
        // "falei e a resposta se perdeu no meio", e essa é justamente a
        // diferença entre poder tentar de novo sozinho e não poder.
        const motivoCru = envioErro.cause && envioErro.cause.code
          ? `${envioErro.message} (${envioErro.cause.code})`
          : envioErro.message;

        // POR QUAL LINHA E PARA QUEM. O identificador do item é um código que
        // não diz nada a ninguém; em 19/08 o log trazia só ele, e para
        // descobrir qual telefone tinha caído era preciso ir ao banco.
        const linha = conv.advogado.numero || 'telefone desconhecido';
        const deQuem = conv.advogado.nome ? ` (${conv.advogado.nome})` : '';
        console.error(`Falha ao enviar pela linha ${linha}${deQuem} para ${numeroDestino} `
                    + `[item ${item.id}]:`, motivoCru);
        avisarQueALinhaCaiu(motivoCru, linha, conv.advogado.nome);

        // A FALHA PROVA QUE NADA CHEGOU AO CLIENTE, e ainda há tentativa? Então
        // ela volta para a fila com uma espera, em vez de virar bolha vermelha
        // que só sai se alguém estiver olhando a tela. Na dúvida — e a régua de
        // `daParaTentarDeNovoSozinho` é dura de propósito — segue como sempre.
        const aindaHaTentativa = (item.tentativas || 0) + 1 < MAX_TENTATIVAS;
        const podeInsistir =
          daParaTentarDeNovoSozinho(motivoCru)
          && aindaHaTentativa
          && await tentarDeNovoMaisTarde(item, motivoCru);
        if (podeInsistir) continue;

        // ESGOTADAS AS TENTATIVAS, A BOLHA DIZ QUE JÁ TENTAMOS. Sem esta linha
        // a tela mostrava só a última falha ("muitas mensagens de uma vez,
        // espere um minuto e toque em reenviar") — e quem lesse tocaria em
        // reenviar achando que era a primeira vez, sem saber que a ponte já
        // tinha tentado cinco vezes ao longo de vinte minutos. O motivo
        // técnico continua junto, para quem for investigar.
        const paraGravar = !aindaHaTentativa && daParaTentarDeNovoSozinho(motivoCru)
          ? `Falhou após ${MAX_TENTATIVAS} tentativas: ${motivoCru}`
          : motivoCru;

        // O aviso de audiência volta a aparecer como "Falhou" no Vantoro, com o
        // motivo — em vez de sumir e só dar as caras quando o cliente faltar.
        await marcarErroNaFila(item.id, paraGravar, item.aviso_vantoro_id);
      }
    }
  } catch (e) {
    console.error('Erro ao processar fila:', e.message);
  } finally {
    filaRodando = false;
    // Alguém tocou enquanto este ciclo rodava: vai mais um, agora. `setImmediate`
    // para o ciclo atual terminar de sair da pilha antes — chamar aqui dentro
    // faria a recursão crescer a cada toque, e um dia estourar.
    if (filaPedidaDeNovo) {
      filaPedidaDeNovo = false;
      setImmediate(() => { processarFilaDeEnvio().catch(() => {}); });
    }
  }
}

// ============================================================
//  VANTORO — ficha do cliente dentro do atendimento
//
//  O painel roda no NAVEGADOR, então ele não pode conhecer o token do
//  Vantoro (seria dar a base inteira de clientes para quem abrir o
//  inspecionar). Por isso a ponte funciona como intermediária:
//
//     painel  ->  (sessão do Supabase)  ->  ponte  ->  (token)  ->  Vantoro
//
//  A ponte confere se quem chamou está logado no Zorvin e só então
//  repassa a chamada, acrescentando o token no servidor.
//
//  Variáveis necessárias (Render do zorvin-bridge):
//     VANTORO_API_URL    ex.: https://SEU-VANTORO.onrender.com/cadastro/api/v1
//     VANTORO_API_TOKEN  o mesmo valor gerado no Render do Vantoro
// ============================================================

const VANTORO_URL = (process.env.VANTORO_API_URL || '').replace(/\/+$/, '');
const VANTORO_TOKEN = process.env.VANTORO_API_TOKEN || '';

// O painel fica em outro endereço, então o navegador exige estes cabeçalhos.
// A ORIGEM PERMITIDA, LIMPA — e o motivo de ela existir separada.
//
// `PAINEL_ORIGEM` é preenchida à mão num campo de site. Colar ali arrasta
// espaço, barra no fim e, sobretudo, QUEBRA DE LINHA. O Node recusa pôr um
// "\n" dentro de um cabeçalho e lança `ERR_INVALID_CHAR` — e como isso
// acontece DENTRO da rota, ela morre antes de responder. O navegador vê a
// conexão falhar e escreve "Load failed"; do lado de cá, o log só mostra uma
// pilha de erro que não menciona a variável.
//
// Foi assim que uma quebra de linha invisível derrubou a entrada de todo o
// escritório numa manhã de expediente. Uma variável mal colada pode fazer o
// sistema funcionar pior; não pode fazer ele parar.
//
// Então: o que dá para consertar sozinho é consertado (espaço, barra no fim),
// e o que não dá vira aviso e cai no `*`, que é o padrão de sempre. Degradar
// para permissivo com aviso é melhor do que derrubar tudo em silêncio.
let origemLembrada = null;
function origemPermitida() {
  if (origemLembrada) return origemLembrada;
  const cru = String(process.env.PAINEL_ORIGEM || '');
  const limpa = cru.replace(/[\r\n\t]/g, '').trim().replace(/\/+$/, '');

  if (!limpa) {
    origemLembrada = '*';
  } else if (!/^https?:\/\/[A-Za-z0-9.:-]+$/.test(limpa)) {
    console.log(`PAINEL_ORIGEM não parece um endereço (${JSON.stringify(cru)}). `
              + 'Aceitando qualquer origem, que é o padrão. Ela deve ser só o '
              + 'endereço do painel, assim: https://zorvin.exemplo.com.br');
    origemLembrada = '*';
  } else {
    if (limpa !== cru) {
      console.log(`PAINEL_ORIGEM tinha espaço, barra ou quebra de linha sobrando `
                + `(${JSON.stringify(cru)}). Usando "${limpa}".`);
    }
    origemLembrada = limpa;
  }
  return origemLembrada;
}

function liberarCors(res, req) {
  const permitida = origemPermitida();
  res.set('Access-Control-Allow-Origin', permitida);
  res.set('Access-Control-Allow-Headers', 'Authorization, Content-Type');
  res.set('Access-Control-Allow-Methods', 'GET, POST, PATCH, OPTIONS');

  // O ERRO MAIS INVISÍVEL QUE ESTA PONTE PODE DAR.
  //
  // `Access-Control-Allow-Origin` tem de casar com a origem do pedido LETRA
  // POR LETRA — uma barra a mais no fim, `www.` a mais, `http` no lugar de
  // `https`, e o navegador descarta a resposta. Do lado de cá parece que deu
  // tudo certo: a rota respondeu 200 e nada foi para o log. Do lado de lá, o
  // Safari escreve "Load failed" e o Chrome, "Failed to fetch".
  //
  // Este aviso existe para esse caso não ser mais invisível. Ele não muda o
  // comportamento — só conta o que está acontecendo, com os dois valores lado
  // a lado, que é o que falta para consertar em trinta segundos.
  const origem = req && req.headers && req.headers.origin;
  if (permitida !== '*' && origem && origem !== permitida) {
    console.log(`CORS: o painel pediu de "${origem}" mas PAINEL_ORIGEM está "${permitida}". `
              + 'O navegador vai descartar a resposta e dizer "Load failed". '
              + 'Ajuste a variável PAINEL_ORIGEM (sem barra no fim) ou deixe-a vazia.');
  }
}

// ============================================================
//  O BILHETE DE ENTRADA ASSINADO AQUI
//
//  Na manhã de 19/08 o escritório inteiro ficou de fora. O banco respondia em
//  168ms; quem não respondia era o `/auth/v1/*` do Supabase — o serviço que
//  cuida de conta e senha, que fica atrás do MESMO endereço do banco e cai
//  sozinho. O que voltava era uma página do Cloudflare com "Error 521".
//
//  A entrada dependia dele em dois pontos, e bastava um para ninguém entrar:
//  a ponte pedia um `generateLink` para abrir a sessão, e o painel trocava
//  esse bilhete por uma sessão com `verifyOtp`.
//
//  O QUE ESTE PEDAÇO FAZ. A sessão do Supabase é um bilhete assinado com um
//  segredo do projeto — o "JWT Secret". Quem tem o segredo pode assinar um. A
//  ponte já guarda a chave de serviço, que é mais poderosa do que isso (ela
//  própria é um bilhete assinado com o mesmo segredo, com poder de
//  administrador do banco). Então guardar o segredo aqui não abre porta
//  nenhuma que já não estivesse aberta — e fecha a que derrubou a manhã.
//
//  QUEM CONFERE O BILHETE DEPOIS. O banco, sozinho, com o mesmo segredo. É
//  por isso que isto funciona com o Auth no chão: quem estava logado naquela
//  manhã continuou conversando normalmente, porque mensagem, etiqueta e busca
//  vão direto ao banco. O que quebrava era só a PORTA DE ENTRADA.
//
//  O SEGREDO É OPCIONAL, DE PROPÓSITO. Sem `SUPABASE_JWT_SECRET`, tudo aqui
//  fica desligado e a entrada é exatamente a de antes. Assim esta mudança não
//  pode quebrar nada por si só: ela só entra em cena onde foi configurada.
// ============================================================
const crypto = require('crypto');

const JWT_SEGREDO = String(process.env.SUPABASE_JWT_SECRET || '').replace(/[\r\n\t]/g, '').trim();

// DOZE HORAS, e não os 60 minutos do Supabase.
//
// O bilhete do Supabase dura uma hora porque ele tem como se renovar sozinho:
// o navegador pede um novo com o "refresh token", e isso passa pelo Auth. O
// nosso não tem — é justamente o Auth que pode estar fora. Então ele precisa
// durar mais do que um expediente, senão quem entrou às 8h seria posto para
// fora às 9h no meio de um atendimento, sem ter como voltar.
//
// Doze horas cobrem o dia inteiro com folga e ainda são curtas o bastante para
// que uma conta desligada no Vantoro perca o acesso no mesmo dia.
const VALIDADE_S = 12 * 60 * 60;

function base64url(dado) {
  return Buffer.from(dado).toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function assinar(conteudo) {
  return crypto.createHmac('sha256', JWT_SEGREDO).update(conteudo).digest('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** Existe segredo configurado? É o interruptor de tudo neste arquivo. */
function souCapazDeAssinar() {
  return JWT_SEGREDO.length >= 20;
}

/** O bilhete de sessão, no mesmo formato que o Supabase emite.
 *
 *  As informações são as que o banco lê: `sub` é quem a pessoa é (é dele que
 *  sai `auth.uid()`, e é `auth.uid()` que decide quais conversas ela abre),
 *  `role` é o papel no banco, `exp` é até quando vale. O resto está aqui
 *  porque o Supabase põe — um bilhete que não se pareça com os outros é um
 *  bilhete que vai surpreender alguém um dia. */
function assinarSessao({ id, email, nome, login, foto }) {
  const agora = Math.floor(Date.now() / 1000);
  const exp = agora + VALIDADE_S;
  const cabecalho = base64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const corpo = base64url(JSON.stringify({
    iss: `${String(process.env.SUPABASE_URL || '').replace(/\/+$/, '')}/auth/v1`,
    sub: id,
    aud: 'authenticated',
    role: 'authenticated',
    email: email || '',
    phone: '',
    app_metadata: { provider: 'email', providers: ['email'] },
    user_metadata: { nome: nome || '', login: login || '', email: email || '',
                     foto_url: foto || null,
                     email_verified: true, phone_verified: false },
    // A "sessão" a que este bilhete pertence. O Supabase põe um id aqui e
    // algumas regras de banco olham para ele; um valor sorteado agora é o que
    // mais se parece com o que ele faria.
    session_id: crypto.randomUUID(),
    aal: 'aal1',
    amr: [{ method: 'password', timestamp: agora }],
    is_anonymous: false,
    iat: agora,
    exp,
  }));
  const assinatura = assinar(`${cabecalho}.${corpo}`);
  return { token: `${cabecalho}.${corpo}.${assinatura}`, expira_em: exp };
}

/** Confere um bilhete SEM sair da máquina, e devolve quem é a pessoa.
 *
 *  Devolve `null` quando não dá para dizer que o bilhete é bom — assinatura
 *  que não bate, prazo vencido, ou um bilhete assinado de outro jeito (um
 *  projeto que use chave assimétrica não é conferível assim). `null` aqui não
 *  quer dizer "recuse": quer dizer "não sei", e quem chamou volta a perguntar
 *  ao Supabase, que é o que se fazia antes. */
function conferirSessao(bilhete) {
  if (!souCapazDeAssinar()) return null;
  const partes = String(bilhete || '').split('.');
  if (partes.length !== 3) return null;
  const [cabecalho, corpo, assinatura] = partes;

  let cab = null;
  try { cab = JSON.parse(Buffer.from(cabecalho, 'base64url').toString('utf8')); } catch (_e) { return null; }
  // SÓ O QUE ESTE SEGREDO ASSINA. Um projeto migrado para chave assimétrica
  // emite `RS256`/`ES256`, e tentar conferir com o segredo simétrico daria
  // "assinatura ruim" para um bilhete perfeitamente bom.
  if (!cab || cab.alg !== 'HS256') return null;

  const esperada = assinar(`${cabecalho}.${corpo}`);
  // COMPARAÇÃO DE TEMPO CONSTANTE. Comparar com `===` vaza, pelo tempo que a
  // comparação leva, quantas letras do começo bateram — e com isso dá para
  // descobrir a assinatura certa uma letra por vez.
  const a = Buffer.from(assinatura), b = Buffer.from(esperada);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;

  let dados = null;
  try { dados = JSON.parse(Buffer.from(corpo, 'base64url').toString('utf8')); } catch (_e) { return null; }
  if (!dados || !dados.sub) return null;
  if (dados.aud !== 'authenticated' || dados.role !== 'authenticated') return null;
  if (!dados.exp || dados.exp * 1000 <= Date.now()) return null;

  // No formato que o resto da ponte já espera de `auth.getUser`.
  return { id: dados.sub, email: dados.email || '',
           user_metadata: dados.user_metadata || {},
           app_metadata: dados.app_metadata || {} };
}


// QUEM JÁ FOI CONFERIDO HÁ POUCO NÃO É CONFERIDO DE NOVO.
//
// `auth.getUser` é uma ida à API do Supabase — rede, ida e volta — e ela
// acontecia em TODA chamada do painel: abrir a ficha do cliente são duas (a
// ficha e o histórico), digitar na busca é mais uma a cada pausa. O tempo
// somava na cara da pessoa sem servir para nada: a mesma sessão, conferida
// cinco vezes em dez segundos, dá cinco vezes a mesma resposta.
//
// A lembrança dura 60 segundos. É o preço de sair: quem for desligado continua
// entrando por até um minuto. Para uma ferramenta interna, onde desligar
// alguém é um ato deliberado e acompanhado, um minuto é aceitável — e a conta
// no Vantoro, que é o que manda, já foi cortada.
const sessoesLembradas = new Map();   // jwt -> { usuario, ate }
const LEMBRAR_MS = 60 * 1000;

function limparLembradas() {
  const agora = Date.now();
  for (const [k, v] of sessoesLembradas) if (v.ate < agora) sessoesLembradas.delete(k);
}

// Só passa quem está logado no Zorvin (sessão válida do Supabase).
async function exigirLogin(req, res) {
  const cabecalho = String(req.headers.authorization || '');
  const jwt = cabecalho.toLowerCase().startsWith('bearer ')
    ? cabecalho.slice(7).trim() : '';
  if (!jwt) {
    res.status(401).json({ ok: false, erro: 'Faça login no Zorvin.' });
    return null;
  }
  const lembrada = sessoesLembradas.get(jwt);
  if (lembrada && lembrada.ate > Date.now()) return lembrada.usuario;

  // PRIMEIRO AQUI DENTRO, SEM SAIR DA MÁQUINA.
  //
  // Este era o segundo lugar em que a entrada dependia do Auth do Supabase, e
  // o menos óbvio: `auth.getUser` é uma ida à rede, e é ela que dizia se a
  // sessão vale. Com o Auth fora do ar, quem já estava logado ia perdendo o
  // acesso à Ficha e ao Histórico à medida que a lembrança de 60 segundos
  // vencia — sem entender por quê, porque as mensagens continuavam chegando.
  //
  // O bilhete é assinado com o segredo do projeto, e conferir uma assinatura
  // não precisa de ninguém: é uma conta. Vale para os bilhetes que a ponte
  // assina E para os que o Supabase emite, porque o segredo é o mesmo.
  //
  // Quando não dá para conferir aqui — sem segredo configurado, ou um projeto
  // que assine com chave assimétrica — a pergunta volta a ser feita ao
  // Supabase, exatamente como antes.
  const local = conferirSessao(jwt);
  if (local) {
    limparLembradas();
    sessoesLembradas.set(jwt, { usuario: local, ate: Date.now() + LEMBRAR_MS });
    return local;
  }

  const { data, error } = await supabase.auth.getUser(jwt);
  if (error || !data || !data.user) {
    // Sessão ruim NÃO é lembrada: senão um token expirado ficaria recusado por
    // um minuto depois de a pessoa entrar de novo.
    sessoesLembradas.delete(jwt);
    res.status(401).json({ ok: false, erro: 'Sessão expirada. Entre de novo.' });
    return null;
  }
  limparLembradas();
  sessoesLembradas.set(jwt, { usuario: data.user, ate: Date.now() + LEMBRAR_MS });
  return data.user;
}

// Repassa a chamada ao Vantoro colocando o token (que só existe aqui).
async function chamarVantoro(caminho, opcoes = {}) {
  if (!VANTORO_URL || !VANTORO_TOKEN) {
    return { status: 503, corpo: { ok: false, erro: 'Integração com o Vantoro não configurada (VANTORO_API_URL/VANTORO_API_TOKEN).' } };
  }
  const uma = () => fetchComTimeout(`${VANTORO_URL}${caminho}`, {
    ...opcoes,
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${VANTORO_TOKEN}`,
      ...(opcoes.headers || {}),
    },
  }, 20000);

  // ESPERAR O VANTORO ACORDAR, EM VEZ DE DESISTIR.
  //
  // No plano gratuito da Render o serviço hiberna, e a primeira chamada depois
  // disso NÃO ESPERA: a Render responde na hora, com uma página de erro, e só
  // então acorda o Django por baixo. Do lado de quem atende isso aparece como a
  // ficha do cliente falhando sem motivo e voltando sozinha minutos depois.
  //
  // A assinatura desse caso é específica: resposta RÁPIDA, código 5xx, e um
  // corpo que não é JSON. Nenhuma das três sozinha basta — um 500 do Django vem
  // em JSON, e uma resposta lenta é outra coisa (serviço no ar e sobrecarregado,
  // e insistir aí só piora).
  //
  // Só nesse caso vale esperar e tentar de novo: a segunda chamada cai num
  // serviço já de pé. Um envio (POST/PUT) NÃO é repetido — se o Vantoro chegou a
  // receber o cadastro antes de a Render cortar, repetir criaria dois.
  const comecou = Date.now();
  let r = await uma();
  const demorou = Date.now() - comecou;
  let texto0 = await r.text().catch(() => '');

  {
    const metodo = String(opcoes.method || 'GET').toUpperCase();
    const naoEhJson = (() => { try { JSON.parse(texto0); return false; } catch (_e) { return true; } })();
    // RÁPIDA é parte da assinatura. A Render corta na hora enquanto acorda o
    // serviço; uma resposta que DEMOROU é outra coisa — serviço no ar e
    // sobrecarregado —, e insistir nesse caso só piora.
    const parecendoSono = r.status >= 500 && naoEhJson && demorou < 5000
      && (metodo === 'GET' || metodo === 'HEAD');
    if (parecendoSono) {
      console.warn(`Vantoro respondeu ${r.status} sem JSON em ${demorou}ms — parece `
        + 'serviço hibernando na Render. Esperando 6s e tentando mais uma vez.');
      await new Promise((ok) => setTimeout(ok, 6000));
      try {
        const r2 = await uma();
        const texto2 = await r2.text().catch(() => '');
        r = r2; texto0 = texto2;
      } catch (_e) { /* fica com a primeira resposta, que já explica o que houve */ }
    }
  }

  // O CORPO SÓ PODE SER LIDO UMA VEZ. Chamar `r.json()` e, ao falhar, tentar
  // `r.text()` para saber o que tinha lá devolve VAZIO — o fluxo já foi
  // consumido pela primeira leitura. Era assim que a página de suspensão, que é
  // justamente a evidência que interessa, virava "uma resposta vazia".
  // Por isso o texto vem lido de cima, de uma vez só.
  const texto = texto0;
  let corpo = null;
  try {
    corpo = JSON.parse(texto);
  } catch (_e) {
    // NÃO VEIO JSON. Antes, tudo aqui virava a mesma frase — "Resposta inválida
    // do Vantoro." — e o painel emendava "verifique VANTORO_API_URL e
    // VANTORO_API_TOKEN".
    //
    // Essa dica está errada JUSTAMENTE NESTE PONTO: se as duas variáveis
    // faltassem, a função teria parado lá em cima, com outra mensagem. Chegar
    // aqui prova que as duas existem. Mandava-se a pessoa conferir exatamente o
    // que não era o problema — e foi o que aconteceu em 21/08, com o
    // atendimento parado e a configuração intacta.
    //
    // O corpo e o código já estão na mão; jogá-los fora é que tornava isto
    // indiagnosticável. Uma página HTML com 503, por exemplo, é o serviço fora
    // do ar ou suspenso, e não tem nada a ver com token.
    corpo = { ok: false, erro: explicarRespostaNaoJson(r.status, texto) };
  }
  return { status: r.status, corpo };
}

// Transforma uma resposta que não é JSON numa frase que diz o que houve.
function explicarRespostaNaoJson(status, cru) {
  const texto = String(cru || '').trim();
  const ehHtml = /^\s*<(!doctype|html|head|body)/i.test(texto);

  // O caso mais comum e o mais confundido: a hospedagem devolve uma página no
  // lugar do serviço. Serviço dormindo, fora do ar, suspenso por consumo, ou um
  // endereço que caiu numa rota que não existe.
  if (ehHtml || !texto) {
    const onde = ehHtml ? 'uma página HTML' : 'uma resposta vazia';
    if (status >= 500 || status === 402 || status === 403) {
      return `O Vantoro respondeu com erro ${status} e ${onde}, em vez dos dados. `
           + 'Isso é o serviço do Vantoro fora do ar, dormindo ou suspenso — '
           + 'não é a configuração da ponte. Confira o painel da hospedagem do Vantoro.';
    }
    if (status === 404) {
      return 'O endereço do Vantoro respondeu 404 (página não encontrada). '
           + 'O serviço está no ar, mas VANTORO_API_URL aponta para um caminho que não existe.';
    }
    if (status === 401 || status === 407) {
      return `O Vantoro recusou a chamada (${status}) sem explicar em JSON. `
           + 'Normalmente é VANTORO_API_TOKEN errado ou vencido.';
    }
    return `O Vantoro respondeu ${status} com ${onde}, em vez dos dados.`;
  }

  // Texto curto que não é JSON nem HTML: quase sempre é a mensagem de erro do
  // próprio servidor, e mostrá-la resolve mais do que qualquer frase minha.
  return `O Vantoro respondeu ${status} com algo que não é JSON: `
       + `"${texto.slice(0, 160)}${texto.length > 160 ? '…' : ''}"`;
}

// A CHAMADA QUE NEM CHEGOU A TER RESPOSTA — dita em português.
//
// `explicarRespostaNaoJson`, acima, traduz o que o Vantoro RESPONDEU. Mas há o
// caso em que não houve resposta nenhuma: o tempo estourou, o endereço não
// resolveu, a conexão caiu no meio. Aí a exceção era engolida e o painel
// mostrava sempre a mesma frase — "Não foi possível falar com o Vantoro agora."
//
// Relato do escritório, com a tela na mão: era isso que aparecia, e não havia
// como saber se o serviço estava dormindo, se o endereço estava errado ou se a
// internet do celular tinha oscilado. Três causas, três consertos, uma frase só.
//
// O motivo fica NA TELA, e não só no log da hospedagem: quem atende não tem
// acesso ao log, e é ele quem precisa decidir se insiste ou se chama alguém.
function explicarFalhaDaChamada(e) {
  const msg = String((e && e.message) || e || '');
  const nome = String((e && e.name) || '');
  const causa = String((e && e.cause && e.cause.code) || '');

  // O tempo estourou. No plano gratuito da Render o serviço hiberna e a
  // primeira chamada pode levar quase um minuto para acordá-lo.
  if (nome === 'AbortError' || /abort|timeout|timed out/i.test(msg)) {
    return 'O Vantoro não respondeu a tempo. Costuma ser o serviço dele acordando '
         + 'depois de um tempo parado — espere uns segundos e tente de novo.';
  }
  // O endereço não existe ou não resolve.
  if (causa === 'ENOTFOUND' || /getaddrinfo|ENOTFOUND|dns/i.test(msg)) {
    return 'Não achei o endereço do Vantoro na internet. O serviço pode ter mudado '
         + 'de endereço, ou VANTORO_API_URL está escrito errado.';
  }
  // A conexão foi recusada ou caiu.
  if (causa === 'ECONNREFUSED' || causa === 'ECONNRESET' || /refused|reset|socket/i.test(msg)) {
    return 'O endereço do Vantoro existe, mas recusou a conexão. Normalmente é o '
         + 'serviço parado ou suspenso na hospedagem.';
  }
  return `Não consegui falar com o Vantoro: ${msg.slice(0, 160) || 'motivo desconhecido'}.`;
}

// Envolve cada rota: CORS + login + tratamento de erro, sem repetir código.
function rotaVantoro(handler) {
  return async (req, res) => {
    liberarCors(res);
    try {
      const usuario = await exigirLogin(req, res);
      if (!usuario) return;
      const { status, corpo } = await handler(req, usuario);
      res.status(status).json(corpo);
    } catch (e) {
      const erro = explicarFalhaDaChamada(e);
      console.error('vantoro:', erro, '|', (e && e.message) || e);
      res.status(502).json({ ok: false, erro });
    }
  };
}

app.options('/vantoro/*', (req, res) => { liberarCors(res); res.sendStatus(204); });

// Acha o cliente pelo número do WhatsApp da conversa aberta.
app.get('/vantoro/cliente', rotaVantoro(async (req) => {
  const telefone = String(req.query.telefone || '').replace(/\D/g, '');
  const cpf = String(req.query.cpf || '').replace(/\D/g, '');
  if (!telefone && !cpf) {
    return { status: 400, corpo: { ok: false, erro: 'Informe telefone ou cpf.' } };
  }
  const busca = telefone ? `telefone=${telefone}` : `cpf=${cpf}`;
  return chamarVantoro(`/clientes/buscar?${busca}`);
}));

// ------------------------------------------------------------
//  DE QUEM É ESTE CPF — perguntado ENQUANTO a pessoa digita
//
//  Relato do escritório, em 08/09: "está sendo permitido cadastrar o mesmo
//  cliente com o mesmo CPF... o ideal é que ao digitar o CPF o sistema avise
//  que já existe o cadastro e se o usuário quer ver a ficha".
//
//  O Vantoro passou a RECUSAR o CPF de outro cadastro (vantoro#232). Recusar
//  no fim, porém, é tarde: a pessoa preencheu nome, nascimento, endereço e
//  profissão, e só então descobre que o cadastro já existia — o trabalho todo
//  refeito à toa, e o cadastro certo continuando sem o que ela digitou.
//
//  Esta rota é a pergunta feita ANTES. Repassa e mais nada: quem sabe de quem
//  é o CPF é o Vantoro, e uma segunda resposta aqui divergiria da dele no
//  primeiro caso que eu não tivesse previsto.
// ------------------------------------------------------------
app.get('/vantoro/cpf-existe', rotaVantoro(async (req) => {
  const cpf = String(req.query.cpf || '').replace(/\D/g, '');
  // MENOS DE ONZE DÍGITOS NEM SAI DAQUI. A tela chama a cada tecla; mandar
  // "398" ao Vantoro seria uma ida à rede por caractere digitado, num serviço
  // que hiberna, para uma pergunta que não tem resposta possível.
  if (cpf.length !== 11 && cpf.length !== 14) {
    return { status: 200, corpo: { ok: true, encontrado: false, incompleto: true } };
  }
  return chamarVantoro(`/clientes/cpf-existe?cpf=${encodeURIComponent(cpf)}`);
}));

// Busca livre no cadastro: nome, CPF ou número do processo. É o que permite ao
// atendente procurar no Zorvin do mesmo jeito que procuraria no Vantoro, em vez
// de depender de já ter o telefone da pessoa.
app.get('/vantoro/buscar', rotaVantoro(async (req) => {
  const termo = String(req.query.q || '').trim();
  if (termo.length < 3) {
    return { status: 400, corpo: { ok: false, erro: 'Digite ao menos 3 letras ou números.' } };
  }
  return chamarVantoro(`/clientes/buscar?q=${encodeURIComponent(termo)}`);
}));

// Ficha completa (dados, pendências da ordem de serviço e processos).
app.get('/vantoro/cliente/:id', rotaVantoro(async (req) =>
  chamarVantoro(`/clientes/${encodeURIComponent(req.params.id)}`)));

// Cria o pré-cadastro a partir do atendimento.
app.post('/vantoro/cliente', rotaVantoro(async (req) =>
  chamarVantoro('/clientes', { method: 'POST', body: JSON.stringify(req.body || {}) })));

/**
 * Guarda no histórico do Zorvin o que mudou no cadastro do cliente.
 *
 * AQUI, e não no navegador, porque é aqui que se sabe QUEM é quem: a ponte
 * confere o login antes de deixar passar. O painel poderia mandar um nome
 * qualquer no corpo do pedido, e um histórico em que o autor é o que o
 * navegador disse ser não serve para responder "quem mexeu nisto?".
 *
 * O valor ANTERIOR também é lido daqui, do próprio Vantoro, e não recebido
 * pronto: a tela pode estar aberta há meia hora e mostrar um "antes" que já
 * não era o de antes.
 *
 * Nada disto pode impedir a edição de acontecer. Se o histórico falhar, a
 * alteração vale do mesmo jeito e fica um aviso no log — o contrário seria
 * trocar um registro perdido por um atendente travado.
 */
async function registrarEdicaoDeCadastro(clienteId, mudou, anterior, usuario) {
  try {
    const campos = Object.keys(mudou || {});
    if (!campos.length) return;

    // De qual contato do Zorvin é este cliente. Sem ele a linha continua
    // valendo (o histórico geral a mostra), só não aparece na ficha daquela
    // conversa.
    let contatoId = null;
    const { data: cont } = await supabase
      .from('contatos').select('id').eq('vantoro_cliente_id', clienteId).limit(1);
    if (cont && cont[0]) contatoId = cont[0].id;

    const nome = (usuario && usuario.user_metadata && usuario.user_metadata.nome) || '';
    const linhas = campos
      // Campo que não mudou de verdade não vira linha: o painel manda o que
      // ele acha que mudou, e "  " para "" encheria o histórico de nada.
      .filter((c) => String((anterior || {})[c] ?? '').trim() !== String(mudou[c] ?? '').trim())
      .map((c) => ({
        contato_id: contatoId,
        tipo: 'cadastro',
        alvo: c,
        antes: String((anterior || {})[c] ?? ''),
        depois: String(mudou[c] ?? ''),
        autor: nome,
        autor_id: (usuario && usuario.id) || null,
      }));
    if (!linhas.length) return;

    const { error } = await supabase.from('alteracoes').insert(linhas);
    if (error) console.log(`histórico: não gravei a edição do cadastro (${error.message}).`);
  } catch (e) {
    console.log('histórico: não gravei a edição do cadastro —', (e && e.message) || e);
  }
}

// Atendente corrige/completa os dados sem sair da conversa.
app.patch('/vantoro/cliente/:id', rotaVantoro(async (req, usuario) => {
  const id = encodeURIComponent(req.params.id);
  const mudou = req.body || {};
  // O "antes", lido agora. Best-effort: se o Vantoro não responder a esta,
  // a edição segue e o histórico fica sem o valor anterior.
  let anterior = {};
  try {
    const atual = await chamarVantoro(`/clientes/${id}`);
    if (atual.status === 200 && atual.corpo && atual.corpo.cliente) anterior = atual.corpo.cliente;
  } catch (_) { /* segue sem o "antes" */ }

  const r = await chamarVantoro(`/clientes/${id}/editar`,
    { method: 'PATCH', body: JSON.stringify(mudou) });
  if (r.status === 200 && r.corpo && r.corpo.ok) {
    await registrarEdicaoDeCadastro(req.params.id, mudou, anterior, usuario);
  }
  return r;
}));

// ------------------------------------------------------------
//  OS TELEFONES DO CLIENTE
//
//  Três pedidos do escritório, em 04/09: o mesmo número em dois CPF tem de
//  ficar DITO na tela e com dono escolhível; o cadastro precisa de mais de
//  dois números; e a troca do WhatsApp passa a poder ser feita pelo Zorvin.
//
//  A ponte só repassa. A regra toda — quem é o principal, o que acontece com o
//  número velho na troca, o que não pode ser apagado — mora no Vantoro, que é
//  quem tem o cadastro. Duplicá-la aqui daria duas respostas para a mesma
//  pergunta, e a que o escritório veria dependeria de por onde ela passou.
//
//  O TOKEN NÃO ATRAVESSA. É o motivo de estas rotas existirem em vez de o
//  painel falar direto com o Vantoro: o `VANTORO_API_TOKEN` é de servidor e dá
//  acesso à base inteira. `rotaVantoro` exige a sessão do Zorvin.
// ------------------------------------------------------------
app.get('/vantoro/cliente/:id/telefones', rotaVantoro(async (req) =>
  chamarVantoro(`/clientes/${encodeURIComponent(req.params.id)}/telefones`)));

app.post('/vantoro/cliente/:id/telefones', rotaVantoro(async (req) =>
  chamarVantoro(`/clientes/${encodeURIComponent(req.params.id)}/telefones`,
    { method: 'POST', body: JSON.stringify(req.body || {}) })));

app.patch('/vantoro/cliente/:id/telefones/:tel', rotaVantoro(async (req) =>
  chamarVantoro(`/clientes/${encodeURIComponent(req.params.id)}`
                + `/telefones/${encodeURIComponent(req.params.tel)}`,
    { method: 'PATCH', body: JSON.stringify(req.body || {}) })));

app.delete('/vantoro/cliente/:id/telefones/:tel', rotaVantoro(async (req) =>
  chamarVantoro(`/clientes/${encodeURIComponent(req.params.id)}`
                + `/telefones/${encodeURIComponent(req.params.tel)}`,
    { method: 'DELETE' })));

// Manda para o cadastro um arquivo recebido no WhatsApp.
app.post('/vantoro/cliente/:id/documento', rotaVantoro(async (req) =>
  chamarVantoro(`/clientes/${encodeURIComponent(req.params.id)}/documentos`,
    { method: 'POST', body: JSON.stringify(req.body || {}) })));

// A NOTA INTERNA SOBE PARA O HISTÓRICO DO CLIENTE — e do processo, quando tem.
//
// A equipe escreve a nota dentro da conversa, que é onde ela está quando
// descobre o que precisa anotar. Mas quem for procurar aquilo meses depois vai
// à ficha do cliente, ou ao histórico do processo. Então a nota vive nos dois.
//
// O AUTOR É DECIDIDO AQUI, e não recebido do navegador. É a mesma regra do
// histórico de alterações logo abaixo: a ponte confere o login antes de deixar
// passar, então é aqui que se sabe QUEM é quem. Um histórico em que o autor é o
// que o navegador disse ser não responde "quem escreveu isto?" — e num
// escritório de advocacia essa é a pergunta que se faz.
//
// O `id` vai do painel de propósito: é o id da nota na tabela do Zorvin, e é
// por ele que uma edição encontra o que reescrever no Vantoro em vez de criar
// uma segunda. Sem ele as duas viram cópias, e cópias se separam no primeiro
// que alguém corrigir.
app.post('/vantoro/cliente/:id/nota', rotaVantoro(async (req, usuario) => {
  const corpo = req.body || {};
  const nome = (usuario && usuario.user_metadata && usuario.user_metadata.nome) || '';
  const resposta = await chamarVantoro(`/clientes/${encodeURIComponent(req.params.id)}/nota`, {
    method: 'POST',
    body: JSON.stringify({
      id: corpo.id,
      texto: corpo.texto,
      processo_id: corpo.processo_id ?? null,
      apagada: !!corpo.apagada,
      // Sobrescreve o que veio do navegador, e não completa: aceitar o nome
      // dele quando vier seria aceitar sempre, porque ele sempre pode mandar.
      autor: nome || (usuario && usuario.email) || 'Zorvin',
      // O CARIMBO DESTE LADO. É por ele que o Vantoro decide se esta versão é
      // mais nova do que a que ele tem — e agora ele PODE ter uma mais nova,
      // porque a nota passou a ser editável dos dois lados. Sem mandar, o
      // Vantoro não teria o que comparar e o comportamento antigo voltaria: o
      // Zorvin sobrescrevendo sempre, apagando correções feitas lá.
      atualizado_em: corpo.atualizado_em || new Date().toISOString(),
    }),
  });

  // A MARCA DE QUE SUBIU, que esta rota não gravava.
  //
  // O Vantoro devolve o id da atividade que a nota virou, e este caminho jogava
  // fora. Só o retroativo gravava — então TODA nota escrita pelo caminho normal
  // ficava com `vantoro_atividade_id` nulo para sempre, mesmo tendo chegado
  // perfeitamente.
  //
  // Isso não era só um campo vazio. Foi medido no escritório: o diagnóstico
  // mostrou "164 notas, NENHUMA subiu" e concluiu que a subida estava sendo
  // recusada — quando o que ele via era a marca que ninguém escrevia. Uma
  // ferramenta de diagnóstico afirmando o que não sabe é pior do que não ter
  // ferramenta: manda procurar defeito no lugar errado.
  //
  // E o retroativo depende desta marca para pular o que já subiu. Sem ela, ele
  // reenviaria tudo toda vez — o Vantoro deduplica pelo `id_externo`, então não
  // duplicaria, mas seriam centenas de chamadas à toa a cada rodada.
  const atividade = resposta && resposta.corpo && resposta.corpo.atividade
    && resposta.corpo.atividade.id;
  if (atividade && corpo.id) {
    // FALHAR AQUI NÃO DESFAZ NADA, e nem devolve erro: a nota JÁ chegou ao
    // Vantoro, que é o que importava. Perder a marca custa uma chamada repetida
    // no próximo retroativo; devolver erro faria o painel avisar que a nota não
    // subiu quando ela subiu.
    const { error } = await supabase.from('notas')
      .update({ vantoro_atividade_id: atividade }).eq('id', corpo.id);
    if (error) {
      console.warn(`Nota ${corpo.id} subiu, mas não consegui gravar a marca: ${error.message}`);
    }
  }
  return resposta;
}));

// ============================================================
//  O CAMINHO DE VOLTA — o Vantoro contando que a nota mudou lá
// ============================================================
//
//  Até agora a nota andava num sentido só. Quem corrigisse o texto pela tela do
//  Vantoro via a correção ficar lá: na conversa continuava o texto velho, e
//  quem lê a conversa durante o atendimento não tinha como saber que existia
//  versão mais nova. Nada dava erro.
//
//  ESTA PORTA FICA NA INTERNET ABERTA, sem sessão e sem token de usuário — como
//  as do LegalMail e da Uazapi no Vantoro. O que prova que o aviso veio de lá é
//  a ASSINATURA do corpo, com o segredo combinado entre os dois.
//
//  E ELA TRANCA SEM O SEGREDO, ao contrário do `/webhook` da Uazapi. A diferença
//  não é de gosto: aquele já estava no ar recebendo mensagem de cliente quando
//  ganhou trava, e exigir o segredo antes de a Uazapi ter o dele faria as
//  mensagens pararem de chegar em silêncio. Esta porta nasce agora, sem nenhum
//  tráfego legítimo para proteger — deixá-la aberta seria deixar qualquer um que
//  descubra o endereço reescrever nota no histórico do escritório.
function assinaturaDoVantoroConfere(req) {
  const segredo = String(process.env.VANTORO_WEBHOOK_SECRET || '').trim();
  if (!segredo) return { ok: false, motivo: 'sem-segredo' };

  const veio = String(req.headers['x-vantoro-assinatura'] || '').trim();
  if (!veio) return { ok: false, motivo: 'sem-assinatura' };

  // SOBRE OS BYTES QUE CHEGARAM. Ver o `verify` lá em cima: reserializar o
  // objeto já lido daria outros bytes e recusaria toda entrega legítima.
  const cru = req.corpoCru;
  if (!cru || !cru.length) return { ok: false, motivo: 'sem-corpo' };

  const esperada = crypto.createHmac('sha256', segredo).update(cru).digest('hex');
  // COMPARAÇÃO DE TEMPO CONSTANTE, como no resto da ponte. `===` para na
  // primeira letra diferente, e o tempo conta quantas bateram.
  const a = Buffer.from(veio), b = Buffer.from(esperada);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
    return { ok: false, motivo: 'assinatura-errada' };
  }
  return { ok: true };
}

app.post('/vantoro/nota-mudou', async (req, res) => {
  liberarCors(res);
  const conferencia = assinaturaDoVantoroConfere(req);
  if (!conferencia.ok) {
    // O MOTIVO VAI NO LOG, e não na resposta. Dizer para quem bateu na porta
    // QUAL das conferências falhou é ensinar a passar pela próxima; no log, é
    // a diferença entre "o segredo está diferente dos dois lados" e "a variável
    // não foi preenchida", que pedem coisas opostas.
    console.warn(`Aviso do Vantoro recusado: ${conferencia.motivo}.`
      + (conferencia.motivo === 'sem-segredo'
        ? ' VANTORO_WEBHOOK_SECRET não está preenchida na ponte — preencha com o'
          + ' MESMO valor de ZORVIN_WEBHOOK_SECRET no Vantoro.'
        : ''));
    return res.status(401).json({ ok: false, erro: 'Não autorizado.' });
  }

  const corpo = req.body || {};
  const notaId = String(corpo.nota_id || '').trim();
  if (!notaId) return res.status(400).json({ ok: false, erro: 'Falta o nota_id.' });

  const { data: nota, error } = await supabase
    .from('notas').select('id, texto, atualizado_em').eq('id', notaId).maybeSingle();
  if (error) return res.status(502).json({ ok: false, erro: error.message });
  if (!nota) {
    // NÃO É ERRO NOSSO. A nota pode ter sido apagada aqui, ou a atividade do
    // Vantoro pode ter nascido de outro lugar. Responder 404 faria o Vantoro
    // registrar falha e reclamar no log dele de uma coisa que está certa.
    return res.status(200).json({ ok: true, ignorada: true,
      motivo: 'Esta nota não existe mais no Zorvin.' });
  }

  // A ÚLTIMA EDIÇÃO VENCE — a MESMA regra que o Vantoro aplica ao receber.
  //
  // Ela precisa existir nos DOIS lados. Se só um comparasse, a nota ficaria
  // indo e voltando: o lado sem comparação aceitaria a versão velha e a
  // devolveria como se fosse novidade.
  const chegou = corpo.atualizado_em ? Date.parse(corpo.atualizado_em) : NaN;
  const daqui = nota.atualizado_em ? Date.parse(nota.atualizado_em) : NaN;
  if (Number.isFinite(chegou) && Number.isFinite(daqui) && daqui > chegou) {
    return res.status(200).json({ ok: true, ignorada: true,
      motivo: 'Há uma versão mais nova no Zorvin.' });
  }

  const mudanca = {
    texto: corpo.texto || '',
    // O CARIMBO QUE CHEGOU, e não `now()`. Gravar a hora de agora faria esta
    // linha parecer mais nova do que a versão do Vantoro que ela ACABOU de
    // copiar — e no próximo aviso ela ganharia dele, desfazendo a cópia.
    atualizado_em: corpo.atualizado_em || new Date().toISOString(),
  };
  if (corpo.atividade_id) mudanca.vantoro_atividade_id = corpo.atividade_id;
  if ('processo_id' in corpo) mudanca.processo_id = corpo.processo_id;

  const { error: erroAoGravar } = await supabase
    .from('notas').update(mudanca).eq('id', notaId);
  if (erroAoGravar) {
    return res.status(502).json({ ok: false, erro: erroAoGravar.message });
  }
  return res.status(200).json({ ok: true, atualizada: true });
});

// O CADASTRO MUDOU NO VANTORO: nome e telefone.
//
// Pedido do escritório: "quando eu altero alguma informação no Vantoro, não
// está atualizando no Zorvin". Não era um sincronismo quebrado — era a ausência
// de um. O que este lado guarda do Vantoro são dois campos do contato,
// `vantoro_nome` e `vantoro_cliente_id`, e os dois eram escritos PELO PAINEL,
// quando alguém abre a ficha. Uma correção feita lá só aparecia aqui na próxima
// abertura daquela conversa — e ninguém abre a ficha de um contato cujo nome já
// parece certo.
//
// DUAS COISAS DIFERENTES CHEGAM POR AQUI, e vale separar:
//
//   NOME — é cópia, e cópia velha se atualiza. Todo contato ligado a este
//   cliente passa a mostrar o nome novo na lista de conversas.
//
//   TELEFONE — NÃO é cópia. Aqui o número É o da conversa do WhatsApp, e não
//   pode ser sobrescrito por nada que venha do Vantoro: a conversa pertence
//   àquele número, e trocá-lo desligaria o histórico do aparelho que o mandou.
//
//   O que a mudança de telefone faz é outra coisa: ela pode ter tornado FALSO
//   um vínculo que existe aqui. Foi o caso relatado — mãe e filho no mesmo
//   número, o telefone da mãe corrigido no Vantoro. A conversa continuava
//   ligada a ela, e a nota escrita ali continuaria subindo para a ficha de quem
//   não atende mais por aquele número.
//
// POR ISSO O VÍNCULO QUE DEIXOU DE SER VERDADE É DESFEITO. É o oposto de
// destruir informação: o vínculo é derivado, o painel refaz na próxima abertura
// da ficha — e agora ele PERGUNTA quando há mais de um candidato. Deixá-lo de
// pé é que seria escolher, em silêncio, mandar a anotação para a ficha errada.
//
// E NÃO SE LIGA NINGUÉM AQUI. Ligar o cliente ao contato do número NOVO
// pareceria simétrico e não é: o número novo pode ter uma conversa que é de
// outra pessoa, e escolher por conta própria é exatamente o sorteio que o
// seletor do painel existe para não fazer.
app.post('/vantoro/cliente-mudou', async (req, res) => {
  liberarCors(res);
  const conferencia = assinaturaDoVantoroConfere(req);
  if (!conferencia.ok) {
    console.warn(`Aviso de cadastro do Vantoro recusado: ${conferencia.motivo}.`
      + (conferencia.motivo === 'sem-segredo'
        ? ' VANTORO_WEBHOOK_SECRET não está preenchida na ponte — preencha com o'
          + ' MESMO valor de ZORVIN_WEBHOOK_SECRET no Vantoro.'
        : ''));
    return res.status(401).json({ ok: false, erro: 'Não autorizado.' });
  }

  const corpo = req.body || {};
  const clienteId = String(corpo.cliente_id || '').trim();
  if (!clienteId) return res.status(400).json({ ok: false, erro: 'Falta o cliente_id.' });
  const nome = String(corpo.nome || '').trim();
  // AS CHAVES, e não os números. São os últimos 8 dígitos, que é como o Vantoro
  // casa telefone desde sempre — eles não mudam com DDD, com o dígito 9 extra
  // nem com o código do país. Mandá-las prontas evita a regra existir duas
  // vezes: quem sabe o que é um telefone brasileiro é o Vantoro; aqui se
  // compara conjunto.
  const chaves = Array.isArray(corpo.chaves_de_telefone)
    ? corpo.chaves_de_telefone.map((c) => String(c || '').trim()).filter(Boolean)
    : null;

  const { data: ligados, error } = await supabase
    .from('contatos').select('id, numero, vantoro_nome')
    .eq('vantoro_cliente_id', clienteId);
  if (error) return res.status(502).json({ ok: false, erro: error.message });
  if (!ligados || !ligados.length) {
    // NÃO É ERRO. O cliente pode não ter conversa nenhuma aqui, e isso é o
    // normal para a maior parte do cadastro do escritório.
    return res.status(200).json({ ok: true, ligados: 0 });
  }

  const miolo = (numero) => {
    const d = String(numero || '').replace(/\D/g, '');
    return d.length >= 8 ? d.slice(-8) : '';
  };

  let renomeados = 0, desligados = 0;
  for (const c of ligados) {
    // O VÍNCULO AINDA É VERDADE? Só quando as chaves vieram: sem elas não se
    // sabe nada sobre telefone, e "não sei" não pode virar "não é".
    const perdeuONumero = chaves !== null && !chaves.includes(miolo(c.numero));
    if (perdeuONumero) {
      const { error: e1 } = await supabase.from('contatos')
        .update({ vantoro_cliente_id: null, vantoro_nome: null }).eq('id', c.id);
      if (e1) { console.warn(`Não consegui desligar o contato ${c.id}: ${e1.message}`); continue; }
      desligados += 1;
      // EM VOZ ALTA. Desfazer um vínculo é mexer em para onde vão as anotações
      // daquela conversa; quem for procurar depois precisa achar o registro.
      console.log(`Contato ${c.id} (${c.numero}) foi DESLIGADO do cliente ${clienteId}: `
        + 'o telefone mudou no Vantoro e este número não é mais dele. '
        + 'A ficha do painel refaz o vínculo na próxima abertura.');
      continue;
    }
    if (nome && c.vantoro_nome !== nome) {
      const { error: e2 } = await supabase.from('contatos')
        .update({ vantoro_nome: nome }).eq('id', c.id);
      if (e2) { console.warn(`Não consegui renomear o contato ${c.id}: ${e2.message}`); continue; }
      renomeados += 1;
    }
  }

  return res.status(200).json({ ok: true, ligados: ligados.length, renomeados, desligados });
});

// ============================================================
//  AS NOTAS QUE JÁ EXISTEM SOBEM PARA O VANTORO
// ============================================================
//
//  Dois casos, uma máquina só — e é por isso que ela mora aqui em vez de estar
//  escrita duas vezes:
//
//    1. O CONTATO VIRA CLIENTE. Enquanto ele não tinha cadastro, as notas
//       ficaram só na conversa, que é o certo: não havia ficha para recebê-las.
//       Criado o cadastro, tudo o que a equipe já anotou sobre ele passa a ter
//       um lugar — e deixar para trás justamente o histórico anterior ao
//       cadastro é perder o que costuma ser o mais importante.
//
//    2. O RETROATIVO, uma vez. Todas as notas escritas antes desta função
//       existir. Sobem como NOTA GERAL, sem processo: é tudo passado, e
//       adivinhar de qual ação era cada uma poria nota no histórico do processo
//       errado. Daqui para frente quem escreve escolhe.
//
//  O AUTOR AQUI É O DA NOTA, e não quem mandou subir — ao contrário da rota de
//  nota nova, onde o autor vem da sessão. A regra não mudou, a situação é que é
//  outra: lá o risco é o navegador MENTIR sobre quem escreveu, e por isso não se
//  acredita nele; aqui o autor já está gravado na tabela do próprio Zorvin, que
//  é fonte confiável. Assinar com o nome de quem rodou o retroativo reescreveria
//  a autoria de meses de histórico numa tacada.

/** Sobe para o Vantoro as notas de um contato que ainda não subiram.
 *
 *  Devolve { subiram, falharam, jaEstavam }. Nunca levanta: é chamada em laço
 *  sobre muitos contatos, e um cliente com problema não pode parar os outros.
 */
async function subirNotasDoContato(contato, { simular = false } = {}) {
  const clienteId = contato && contato.vantoro_cliente_id;
  if (!clienteId) return { subiram: 0, falharam: 0, jaEstavam: 0 };

  const { data: conversas } = await supabase
    .from('conversas').select('id').eq('contato_id', contato.id);
  const ids = (conversas || []).map((c) => c.id);
  if (!ids.length) return { subiram: 0, falharam: 0, jaEstavam: 0 };

  // MAIS ANTIGA PRIMEIRO. O histórico do cliente é lido em ordem; subir
  // embaralhado deixaria a leitura sem sentido para quem for entender o caso.
  const { data: notas, error } = await supabase
    .from('notas').select('*').in('conversa_id', ids)
    .order('criado_em', { ascending: true });
  if (error) return { subiram: 0, falharam: 1, jaEstavam: 0, erro: error.message };

  return subirNotas(clienteId, notas || [], { simular });
}

/** O envio em si: uma lista de notas já lida, para um cliente do Vantoro.
 *
 *  Separado da leitura porque os dois caminhos que sobem nota leem de jeitos
 *  diferentes — um contato só lê o dele; o retroativo lê tudo em lote —, mas o
 *  que é feito com cada nota TEM de ser idêntico. Duas cópias desta regra se
 *  separariam na primeira correção feita só de um lado.
 */
async function subirNotas(clienteId, notas, { simular = false } = {}) {
  if (!clienteId) return { subiram: 0, falharam: 0, jaEstavam: 0 };
  let subiram = 0, falharam = 0, jaEstavam = 0;
  for (const n of (notas || [])) {
    // JÁ SUBIU: pula. O Vantoro também deduplica pelo `id_externo`, então isto
    // é a segunda trava, não a única — mas evita a chamada, que é o que custa.
    if (n.vantoro_atividade_id) { jaEstavam += 1; continue; }
    if (simular) { subiram += 1; continue; }

    try {
      const { status, corpo } = await chamarVantoro(`/clientes/${encodeURIComponent(clienteId)}/nota`, {
        method: 'POST',
        body: JSON.stringify({
          id: n.id,
          texto: n.texto || '',
          // SEM PROCESSO, e de propósito: é tudo passado, e adivinhar de qual
          // ação era cada nota poria informação no histórico do processo errado.
          processo_id: null,
          apagada: !!n.apagada_em,
          autor: n.autor || 'Zorvin',
        }),
      });
      if (status >= 200 && status < 300) {
        subiram += 1;
        const atividade = corpo && corpo.atividade && corpo.atividade.id;
        if (atividade) {
          // Marca de que subiu. Se esta gravação falhar, a nota sobe de novo na
          // próxima rodada e o Vantoro a reconhece pelo `id_externo` — repetir é
          // barato, perder não é.
          await supabase.from('notas')
            .update({ vantoro_atividade_id: atividade }).eq('id', n.id);
        }
      } else {
        falharam += 1;
      }
    } catch (_e) {
      falharam += 1;
    }
  }
  return { subiram, falharam, jaEstavam };
}

// UM CONTATO SÓ — chamado pelo painel quando o contato acabou de virar cliente.
app.post('/vantoro/contato/:id/subir-notas', rotaVantoro(async (req) => {
  const { data: contato } = await supabase
    .from('contatos').select('id, vantoro_cliente_id').eq('id', req.params.id).maybeSingle();
  if (!contato) return { status: 404, corpo: { ok: false, erro: 'Contato não encontrado.' } };
  if (!contato.vantoro_cliente_id) {
    return { status: 200, corpo: { ok: true, subiram: 0,
      detalhe: 'Este contato ainda não tem cadastro no Vantoro; as notas ficam na conversa.' } };
  }
  const r = await subirNotasDoContato(contato);
  return { status: 200, corpo: { ok: true, ...r } };
}));

// LER TUDO DE UMA TABELA, EM PÁGINAS.
//
// O PostgREST devolve no máximo 1000 linhas e NÃO AVISA: a resposta vem com cara
// de resposta inteira. Num escritório com milhares de contatos, quem confia num
// `select` solto pula todo mundo a partir do milésimo e diz "pronto" — que é o
// defeito que mais se repetiu neste projeto.
//
// `montar` recebe a página e devolve a consulta; o `range` é aplicado aqui, num
// lugar só, para não haver uma versão certa e outra esquecida.
const PAGINA_DE_LEITURA = 500;
async function lerEmPaginas(montar) {
  const tudo = [];
  for (let de = 0; ; de += PAGINA_DE_LEITURA) {
    const { data, error } = await montar().range(de, de + PAGINA_DE_LEITURA - 1);
    if (error) throw new Error(error.message);
    tudo.push(...(data || []));
    if (!data || data.length < PAGINA_DE_LEITURA) return tudo;
  }
}

// Quantos clientes uma chamada percorre quando ninguém diz o contrário.
//
// EXISTE PARA O RETROATIVO PODER SER UM BOTÃO. Rodando de ponta a ponta, ele
// sobe uma nota de cada vez para o Vantoro, que é outra hospedagem e que
// hiberna: com centenas de clientes, a chamada passa do tempo que a Render dá
// a uma requisição e MORRE NO MEIO — sem dizer onde parou, e sem ninguém
// conseguir apertar de novo com proveito.
//
// Em fatias, cada chamada termina depressa e o painel pede a próxima. Como
// subir é idempotente (a nota que já subiu é reconhecida e pulada), uma fatia
// repetida não faz mal — o pior caso é ela não fazer nada.
const FATIA_DE_CLIENTES = 50;

function inteiroDaConsulta(valor, padrao) {
  // Chave que não pode existir não é filtro. Uma URL editada à mão não pode
  // fazer o retroativo pular gente em silêncio — na dúvida, o padrão.
  const n = Number.parseInt(String(valor ?? ''), 10);
  return Number.isFinite(n) && n >= 0 ? n : padrao;
}

// TODOS — o retroativo. Só quem administra, e com simulação primeiro.
//
// `de` e `quantos` recortam a lista de clientes: é o que permite ao painel
// mostrar progresso em vez de uma tela parada, e é o que impede a chamada de
// estourar o tempo da hospedagem. Sem eles, percorre tudo.
app.post('/vantoro/notas/subir-tudo', soAdmin(async (req) => {
  const simular = String(req.query.simular || '') === '1';
  const de = inteiroDaConsulta(req.query.de, 0);
  const quantos = inteiroDaConsulta(req.query.quantos, 0) || FATIA_DE_CLIENTES;
  // `quantos=tudo` é a saída para quem quiser rodar de uma vez só — pela linha
  // de comando, onde não há tempo limite de requisição no caminho.
  const tudoDeUmaVez = String(req.query.quantos || '') === 'tudo';

  let todos;
  try {
    todos = await lerEmPaginas(() => supabase
      .from('contatos').select('id, numero, vantoro_cliente_id')
      .not('vantoro_cliente_id', 'is', null)
      // ORDEM ESTÁVEL, e é ela que faz a fatia significar alguma coisa: sem
      // uma ordem fixa, "os 50 seguintes" seriam 50 quaisquer, e o painel
      // repetiria uns e pularia outros achando que percorreu tudo.
      .order('id', { ascending: true }));
  } catch (e) {
    return { status: 502, corpo: { ok: false, erro: e.message } };
  }

  const contatos = tudoDeUmaVez ? todos.slice(de) : todos.slice(de, de + quantos);

  let subiram = 0, falharam = 0, jaEstavam = 0;
  const comProblema = [];

  // EM LOTES DE CONTATOS, E NÃO UM DE CADA VEZ.
  //
  // Antes isto perguntava as conversas e as notas de cada contato
  // separadamente: duas idas ao Supabase POR CONTATO. Com três mil clientes são
  // seis mil idas à rede em sequência — o retroativo levaria muito mais do que o
  // tempo que a hospedagem dá a uma requisição, e morreria no meio sem dizer
  // onde parou. E como cada ida abre uma conexão, a própria bancada ficou sem
  // soquetes e passou a derrubar provas que nada tinham a ver com isto.
  //
  // MAS TAMBÉM NÃO TUDO DE UMA VEZ. Um `.in(...)` com os ids de três mil
  // contatos vira uma URL de dezenas de quilobytes, que o servidor recusa antes
  // de olhar o conteúdo; e as notas do escritório inteiro na memória de um
  // processo que a Render mede é outro jeito de cair. O lote resolve os dois:
  // URL curta, memória limitada, e ~3 leituras por lote em vez de 400.
  const LOTE = 200;
  for (let i = 0; i < contatos.length; i += LOTE) {
    const lote = contatos.slice(i, i + LOTE);
    let conversas, notas;
    try {
      conversas = await lerEmPaginas(() => supabase
        .from('conversas').select('id, contato_id')
        .in('contato_id', lote.map((c) => c.id))
        .order('id', { ascending: true }));

      // MAIS ANTIGA PRIMEIRO. O histórico do cliente é lido em ordem; subir
      // embaralhado deixaria a leitura sem sentido para quem for entender o caso.
      notas = conversas.length ? await lerEmPaginas(() => supabase
        .from('notas').select('*')
        .in('conversa_id', conversas.map((c) => c.id))
        .order('criado_em', { ascending: true })) : [];
    } catch (e) {
      // O LOTE QUE FALHOU É CONTADO E NOMEADO, e os outros seguem. Parar tudo
      // por causa de um pedaço deixaria o resto do escritório sem retroativo
      // nenhum, e sem saber de quem foi o problema.
      falharam += lote.length;
      comProblema.push(...lote.map((c) => c.numero || c.id));
      continue;
    }

    const contatoDaConversa = new Map(conversas.map((c) => [String(c.id), String(c.contato_id)]));
    const notasPorContato = new Map();
    for (const n of notas) {
      const dono = contatoDaConversa.get(String(n.conversa_id));
      if (!dono) continue;   // conversa que não é de nenhum contato deste lote
      if (!notasPorContato.has(dono)) notasPorContato.set(dono, []);
      notasPorContato.get(dono).push(n);
    }

    for (const c of lote) {
      const r = await subirNotas(c.vantoro_cliente_id,
                                 notasPorContato.get(String(c.id)) || [], { simular });
      subiram += r.subiram; falharam += r.falharam; jaEstavam += r.jaEstavam;
      if (r.falharam) comProblema.push(c.numero || c.id);
    }
  }
  const ate = de + contatos.length;
  return { status: 200, corpo: {
    ok: true, simulacao: simular,
    clientes: contatos.length, subiram, falharam, jaEstavam,
    // ONDE ESTA FATIA COMEÇOU E ONDE PAROU, para o painel pedir a seguinte e
    // para quem lê saber que não viu o escritório inteiro.
    de, ate, total_clientes: todos.length,
    // `fim` é calculado AQUI, e não no painel. A conta é "passei do último?",
    // e ela depende de coisas que só este lado sabe — quantos clientes existem
    // e quantos couberam na fatia. Refeita do outro lado, ela erraria na
    // primeira vez que uma delas mudasse.
    fim: ate >= todos.length,
    // OS QUE FALHARAM, NOMEADOS. "3 falharam" no meio de um número grande é
    // um dado que ninguém consegue usar: sem saber quais, não há o que refazer.
    com_problema: comProblema.slice(0, 50),
    detalhe: (simular
      ? `Simulação: ${subiram} nota(s) SUBIRIAM. Nada foi enviado nem gravado.`
      : `${subiram} nota(s) subiram, ${jaEstavam} já estavam lá, ${falharam} falharam. `
        + 'Rodar de novo é seguro: o que já subiu é reconhecido e não duplica.')
      // FALTA GENTE, E ISSO PRECISA ESTAR ESCRITO. Quem chamar uma vez e ler
      // só o número vai embora achando que acabou — e o retroativo pela metade
      // é pior que o não feito, porque ninguém volta para conferir.
      + (ate >= todos.length ? ''
         : ` Esta é uma fatia: clientes ${de + 1} a ${ate} de ${todos.length}. `
           + `Chame de novo com de=${ate} para continuar.`),
  } };
}));

// Diagnóstico rápido: a integração está configurada?
app.get('/vantoro/status', (req, res) => {
  liberarCors(res);
  res.json({
    ok: true,
    configurado: Boolean(VANTORO_URL && VANTORO_TOKEN),
    url: VANTORO_URL ? VANTORO_URL.replace(/\/\/[^/]+/, '//…') : null,
  });
});

// ============================================================
//  POR QUE A NOTA NÃO CHEGOU NO VANTORO
// ============================================================
//
//  O escritório relatou que as notas internas não aparecem no histórico do
//  cliente. O caminho tem quatro pontos onde ela pode parar, e TRÊS DELES SÃO
//  MUDOS — não há erro em lugar nenhum, a nota simplesmente fica na conversa:
//
//    1. a coluna `contatos.vantoro_cliente_id` não existe. O painel pede a
//       coluna, o banco recusa a consulta inteira, e ele desce para o conjunto
//       de colunas antigo PELA SESSÃO INTEIRA. A partir daí `vantoro_cliente_id`
//       chega indefinido em toda conversa, e o `if` que decide subir nunca é
//       verdadeiro. Este é o mais silencioso dos quatro;
//    2. a coluna existe e está VAZIA no contato. É o certo: quem ainda não tem
//       cadastro no Vantoro não tem ficha para receber. Mas se estiver vazia em
//       TODO MUNDO, o vínculo nunca foi feito — e aí o problema é outro;
//    3. a subida foi tentada e falhou. Este ponto FALA: o painel avisa na tela;
//    4. a coluna `notas.vantoro_atividade_id` não existe, e aí a nota até sobe,
//       mas a marca de que subiu não é gravada.
//
//  ESTA ROTA RESPONDE QUAL DOS QUATRO É, em números. Um `console.log` no
//  navegador não serve: o defeito aparece em quem atende, não em quem
//  desenvolve, e pedir para alguém abrir o inspetor no meio do atendimento não
//  é caminho.
//
//  SÓ CONTAGENS, NENHUM DADO. Nome, telefone e texto de nota não passam por
//  aqui. É o que permite deixá-la aberta como as outras de diagnóstico — e a
//  pergunta que ela responde é justamente a que alguém precisa fazer quando não
//  consegue entrar em lugar nenhum.
app.get('/vantoro/diagnostico-notas', async (req, res) => {
  liberarCors(res);

  // A COLUNA EXISTE? A pergunta não é "quantos têm valor", é se a coluna está
  // lá — e a única forma honesta de saber é pedir e ver se o banco recusa.
  const existe = async (tabela, coluna) => {
    const { error } = await supabase.from(tabela).select(coluna).limit(1);
    if (!error) return true;
    if (/column|coluna|does not exist|não existe/i.test(error.message || '')) return false;
    return null;    // outro erro: não dá para afirmar nem uma coisa nem outra
  };

  const contar = async (tabela, ajustar = (q) => q) => {
    const { count, error } = await ajustar(
      supabase.from(tabela).select('id', { count: 'exact', head: true }));
    return error ? null : (count ?? 0);
  };

  const temClienteId = await existe('contatos', 'vantoro_cliente_id');
  const temAtividadeId = await existe('notas', 'vantoro_atividade_id');

  const contatos = await contar('contatos');
  const comCadastro = temClienteId
    ? await contar('contatos', (q) => q.not('vantoro_cliente_id', 'is', null))
    : null;
  const notas = await contar('notas');
  const notasQueSubiram = temAtividadeId
    ? await contar('notas', (q) => q.not('vantoro_atividade_id', 'is', null))
    : null;

  // O DIAGNÓSTICO EM UMA FRASE, e não só os números. Quem abre isto quer saber
  // o que fazer, não interpretar uma tabela.
  let diagnostico;
  if (temClienteId === false) {
    diagnostico = 'A coluna `contatos.vantoro_cliente_id` NÃO EXISTE no Supabase '
      + 'do Zorvin. Sem ela o painel nunca sabe para qual cliente subir, e a nota '
      + 'fica só na conversa — sem erro nenhum. É a causa mais provável. '
      + 'Rode o SQL que cria essa coluna.';
  } else if (temClienteId === null) {
    diagnostico = 'Não consegui perguntar ao banco se a coluna existe. Veja o log '
      + 'da ponte: pode ser SUPABASE_URL/SUPABASE_SERVICE_KEY errada.';
  } else if (comCadastro === 0) {
    diagnostico = 'A coluna existe, mas NENHUM contato está ligado a um cliente do '
      + 'Vantoro. Enquanto o contato não tem cadastro, a nota fica na conversa — '
      + 'isso é o certo. Abra a ficha de um cliente pelo painel para criar o '
      + 'vínculo, e as notas dele sobem na hora.';
  } else if (!notas) {
    diagnostico = 'Não há nota interna nenhuma gravada ainda. Nada para subir.';
  } else if (notasQueSubiram === 0) {
    // AQUI ELE NÃO SABE, E PASSOU A DIZER QUE NÃO SABE.
    //
    // Antes esta frase afirmava "a subida está sendo tentada e recusada". Era
    // conclusão, não medição — e estava errada: por muito tempo a rota normal
    // não gravava `vantoro_atividade_id`, então zero aqui era o esperado até
    // para nota que chegou perfeitamente. No escritório, essa frase mandou
    // procurar defeito no token do Vantoro, que estava certo.
    //
    // Ferramenta de diagnóstico que conclui além do que mediu é pior do que
    // ferramenta nenhuma: ela dá confiança para procurar no lugar errado.
    diagnostico = `Existem ${comCadastro} contato(s) com cadastro e ${notas} nota(s), `
      + 'e NENHUMA está marcada como subida. Duas causas possíveis, e daqui não dá '
      + 'para separar: (1) são notas ANTIGAS, escritas antes de a subida existir — '
      + 'nesse caso rode o retroativo; ou (2) a subida está sendo recusada. '
      + 'PARA SABER QUAL: escreva uma nota NOVA numa conversa de quem já tem ficha '
      + 'no Vantoro e olhe o histórico daquele cliente. Apareceu = caso 1. '
      + 'Não apareceu = caso 2, e aí veja o log da ponte por "Vantoro".';
  } else {
    diagnostico = `${notasQueSubiram} de ${notas} nota(s) já subiram. O caminho está `
      + 'funcionando; as que faltam são de contatos sem cadastro no Vantoro, ou '
      + 'são anteriores a esta função existir — nesse caso rode o retroativo.';
  }

  res.json({
    ok: true,
    coluna_contatos_vantoro_cliente_id: temClienteId,
    coluna_notas_vantoro_atividade_id: temAtividadeId,
    contatos,
    contatos_com_cadastro_no_vantoro: comCadastro,
    notas,
    notas_que_ja_subiram: notasQueSubiram,
    vantoro_configurado: Boolean(VANTORO_URL && VANTORO_TOKEN),
    diagnostico,
  });
});

// ============================================================
//  LOGIN ÚNICO — a senha mora no Vantoro
//
//  Antes: cada pessoa tinha uma conta criada à mão no Supabase, com uma senha
//  que não era a do Vantoro. Duas listas de gente para manter iguais à mão, e
//  ninguém lembra das duas.
//
//  Agora o painel manda login e senha para cá; a ponte pergunta ao Vantoro se
//  confere (é ela quem tem o token) e, se conferir, abre a sessão do Supabase
//  com a chave de serviço. A conta do Supabase passa a ser uma carcaça: ela
//  existe só para o `auth.uid()` das regras de visibilidade ter um valor. A
//  senha de verdade existe num lugar só.
//
//  A senha NUNCA é gravada nem repassada para o Supabase — ela só atravessa
//  esta função a caminho do Vantoro.
// ============================================================

// Freio contra tentativa de adivinhar senha. Em memória de propósito: a ponte
// é um processo só, e um freio simples que funciona vale mais do que um
// elaborado que depende de outra peça no ar.
const tentativas = new Map();
const TENTATIVAS_MAX = 8;
const TENTATIVAS_JANELA_MS = 5 * 60 * 1000;

function freioBateu(chave) {
  const agora = Date.now();
  const reg = tentativas.get(chave);
  if (!reg || agora - reg.desde > TENTATIVAS_JANELA_MS) {
    tentativas.set(chave, { n: 1, desde: agora });
    return false;
  }
  reg.n += 1;
  return reg.n > TENTATIVAS_MAX;
}

function freioLimpa(chave) { tentativas.delete(chave); }

// O mapa do freio só crescia: cada par (ip, login) que já tentou entrar ficava
// lá para sempre. Numa ponte que fica meses no ar, é memória que nunca volta.
// Uma varredura a cada 10 minutos custa nada e fecha o vazamento.
setInterval(() => {
  const agora = Date.now();
  for (const [k, v] of tentativas) if (agora - v.desde > TENTATIVAS_JANELA_MS) tentativas.delete(k);
}, 10 * 60 * 1000).unref();

// Acha (ou cria) a conta do Supabase daquele e-mail e devolve o id.
async function contaDoSupabase(email, nome) {
  // ------------------------------------------------------------
  //  PRIMEIRO O BANCO, QUE JÁ SABE A RESPOSTA
  //
  //  Isto aqui começava chamando `createUser` A CADA ENTRADA, contando com o
  //  erro "já registrado" para descobrir que a conta existe. Funcionava, e era
  //  uma ESCRITA na API de administração do Auth por login de cada pessoa —
  //  o caminho mais caro e mais frágil que havia para responder uma pergunta
  //  que o banco responde num piscar.
  //
  //  No dia em que essa API ficou lenta, o efeito foi este: entrada de 6
  //  minutos e meio, e depois nem isso. O escritório inteiro na porta, e o
  //  passo que travava era a criação de contas que já existiam há meses.
  //
  //  `usuarios` guarda o id e o e-mail de todo mundo que já entrou — a própria
  //  ponte grava isso ao fim de cada entrada. Para quem já entrou uma vez (que
  //  é todo mundo, todo dia), a resposta sai daí: uma leitura indexada, sem
  //  tocar no Auth.
  //
  //  O caminho antigo continua embaixo, para quem entra pela primeira vez —
  //  ou para quem foi apagado de `usuarios` e continua existindo no Auth.
  // ------------------------------------------------------------
  const { data: jaConhecido } = await supabase
    .from('usuarios').select('id').eq('email', email).maybeSingle();
  if (jaConhecido && jaConhecido.id) return jaConhecido.id;

  // `listUsers` não filtra por e-mail na API atual, então a criação vem
  // primeiro: se já existir, o erro diz isso e aí sim procuramos. Evita
  // varrer a lista inteira de usuários a cada login.
  const criada = await supabase.auth.admin.createUser({
    email,
    email_confirm: true,          // sem isto a conta nasce impedida de entrar
    user_metadata: { nome: nome || '' },
  });
  if (criada && criada.data && criada.data.user) return criada.data.user.id;

  const msg = String((criada && criada.error && criada.error.message) || '').toLowerCase();
  const jaExiste = msg.includes('already') || msg.includes('registered') || msg.includes('exists');
  if (!jaExiste) throw new Error((criada && criada.error && criada.error.message) || 'Falha ao criar a conta.');

  // Procura pelo e-mail, paginando. A base é de dezenas de pessoas, não de
  // milhares — mas o laço tem teto para não virar varredura infinita se a API
  // mudar de comportamento.
  for (let pagina = 1; pagina <= 20; pagina += 1) {
    const { data, error } = await supabase.auth.admin.listUsers({ page: pagina, perPage: 200 });
    if (error) throw new Error(error.message);
    const achada = (data.users || []).find(
      (u) => String(u.email || '').toLowerCase() === email.toLowerCase());
    if (achada) return achada.id;
    if (!data.users || data.users.length < 200) break;
  }
  throw new Error('A conta existe mas não foi encontrada.');
}

/**
 * Deixa o nome guardado no Supabase Auth igual ao do cadastro do Vantoro.
 *
 * O painel lê o nome de `user_metadata`, e ele só era escrito na criação da
 * conta. Trocar o nome no Vantoro não chegava aqui nunca.
 *
 * Não é uma escrita a cada login: só grava quando MUDOU. Login é caminho
 * quente e uma ida à API de admin por entrada, para reescrever a mesma coisa,
 * é desperdício puro.
 *
 * Falhar aqui não impede ninguém de entrar — a pessoa entra com o nome antigo
 * e a próxima entrada tenta de novo. Barrar o login porque o nome não alinhou
 * seria trocar um incômodo por um impedimento.
 */
async function alinharNomeDaConta(id, nomeDoVantoro) {
  const nome = String(nomeDoVantoro || '').trim();
  if (!id || !nome) return;
  try {
    const { data, error } = await supabase.auth.admin.getUserById(id);
    if (error || !data || !data.user) return;
    const meta = data.user.user_metadata || {};
    if (String(meta.nome || '').trim() === nome) return;
    const { error: erroGravar } = await supabase.auth.admin.updateUserById(id, {
      user_metadata: { ...meta, nome },
    });
    if (erroGravar) {
      console.log(`login: não alinhei o nome da conta (${erroGravar.message}).`);
      return;
    }
    console.log(`login: nome da conta atualizado para "${nome}" (era "${meta.nome || ''}").`);
  } catch (e) {
    console.log(`login: não alinhei o nome da conta (${e.message}).`);
  }
}

// ============================================================
//  PERMISSÕES — o Vantoro decide, a Ponte aplica
//
//  Quem pode ver quais conversas é decisão de CADASTRO DE PESSOA, e cadastro de
//  pessoa mora no Vantoro. Duas telas de permissão para a mesma pessoa é como o
//  escritório acaba com alguém que saiu da empresa ainda lendo conversa de
//  cliente: só metade dos acessos foi cortada.
//
//  Faltavam as duas pontas do caminho, e sem elas a tela do Vantoro guardava a
//  escolha sem que ela chegasse a lugar nenhum:
//
//    1. a lista de departamentos daqui nunca era enviada ao Vantoro, então a
//       tela de lá não tinha o que oferecer para marcar;
//    2. o que fosse marcado lá nunca era gravado em `permissoes` aqui.
//
//  O momento é o LOGIN: é quando a Ponte já está falando com o Vantoro sobre
//  esta pessoa, e é quando a permissão precisa valer — ela entra na tela em
//  seguida. Uma rotina de fundo chegaria depois de a pessoa já estar dentro.
// ============================================================

// A lista de departamentos muda quando alguém mexe na tela de departamentos —
// quase nunca. Sem o teto, todo login viria com duas idas ao banco e uma
// chamada ao Vantoro para reenviar exatamente a mesma coisa.
let departamentosEnviadosEm = 0;
const DEPARTAMENTOS_VALIDADE_MS = 10 * 60 * 1000;

async function mandarDepartamentosAoVantoro() {
  if (!VANTORO_URL || !VANTORO_TOKEN) return;
  if (Date.now() - departamentosEnviadosEm < DEPARTAMENTOS_VALIDADE_MS) return;

  const { data, error } = await supabase
    .from('departamentos').select('slug, nome').eq('ativo', true);
  if (error) {
    console.log(`Departamentos: não consegui ler (${error.message}). Falta rodar o SQL?`);
    return;
  }
  // Lista vazia não se envia: do lado do Vantoro, uma lista vazia não desativa
  // nada (ele trata isso), mas mandar "nenhum departamento existe" quando na
  // verdade não consegui ler seria afirmar uma coisa que não sei.
  if (!data || !data.length) return;

  const { status } = await chamarVantoro('/zorvin/departamentos', {
    method: 'POST',
    body: JSON.stringify({ departamentos: data }),
  });
  if (status === 200) {
    departamentosEnviadosEm = Date.now();
  } else {
    console.log(`Departamentos: o Vantoro respondeu ${status}.`);
  }
}

// ------------------------------------------------------------
//  LER A TABELA INTEIRA — E NÃO AS MIL PRIMEIRAS LINHAS
//
//  O PostgREST devolve no máximo 1000 linhas por consulta, e não avisa: a
//  resposta chega com mil linhas e cara de resposta inteira. Quem escreveu
//  `select(...)` sem paginar acredita que leu tudo, e o que passar de mil some
//  em silêncio — o pior tipo de falta, porque não há erro nenhum para procurar.
//
//  Nas rotinas de permissão isso tem uma consequência exata: a pessoa espelhada
//  depois da milésima linha de `usuarios` nunca é encontrada, e a permissão dela
//  nunca é reaplicada. A tela do Vantoro mostra tudo marcado, certinho, e ela
//  continua sem ver as conversas. Ninguém procuraria a causa num teto de leitura.
//
//  A ordem por `id` não é enfeite: sem `order`, o Postgres não promete a mesma
//  ordem entre uma página e a seguinte, e daria para pular e para repetir linha.
// ------------------------------------------------------------
const PAGINA_POSTGREST = 1000;

async function lerTudo(tabela, colunas, ajustar, ordem = 'id') {
  const tudo = [];
  for (let pagina = 0; pagina < 500; pagina++) {
    let consulta = supabase.from(tabela).select(colunas).order(ordem)
      .range(pagina * PAGINA_POSTGREST, (pagina + 1) * PAGINA_POSTGREST - 1);
    if (ajustar) consulta = ajustar(consulta);
    const { data, error } = await consulta;
    if (error) return { data: null, error };
    tudo.push(...(data || []));
    if (!data || data.length < PAGINA_POSTGREST) break;
  }
  return { data: tudo, error: null };
}

// O NÚMERO COMO O VANTORO GUARDA: só dígitos, sem o 55 na frente, últimos 11.
//
// É a mesma redução que o cadastro do Vantoro usa para casar telefone
// (`core.models.normalizar_telefone`), e ela precisa ser a mesma dos dois lados:
// a permissão por telefone é encontrada comparando esta chave. Aqui o número
// vem cru da instância ("5511934042997"); lá ele foi normalizado ao entrar.
function chaveDoNumero(bruto) {
  let d = String(bruto || '').replace(/\D/g, '');
  if (d.length > 11 && d.startsWith('55')) d = d.slice(2);
  return d.length > 11 ? d.slice(-11) : d;
}

// A lista de telefones muda quando alguém liga uma instância nova — quase nunca.
// O mesmo teto dos departamentos, pela mesma razão.
let telefonesEnviadosEm = 0;

async function mandarTelefonesAoVantoro() {
  if (!VANTORO_URL || !VANTORO_TOKEN) return;
  if (Date.now() - telefonesEnviadosEm < DEPARTAMENTOS_VALIDADE_MS) return;

  // `select('*')` e não a lista de colunas: o formato de `advogados` varia com o
  // que já foi rodado no banco, e pedir uma coluna que ainda não existe devolve
  // erro e mata a rotina inteira. Mesmo cuidado que a rotina do departamento.
  const { data: fones, error } = await lerTudo(
    'advogados', '*', (q) => q.eq('ativo', true));
  if (error) {
    console.log(`Telefones: não consegui ler (${error.message}).`);
    return;
  }
  if (!fones || !fones.length) return;

  const { data: deps } = await supabase.from('departamentos').select('id, slug');
  const slugPorId = new Map((deps || []).map((d) => [d.id, d.slug]));

  const lista = fones
    .map((f) => ({
      numero: chaveDoNumero(f.numero),
      nome: String(f.nome || f.numero || '').slice(0, 120),
      // O departamento vai junto para a tela de permissões poder dizer "este
      // número já está incluído no departamento X" — sem isso, marcar os dois
      // parece dobrar o acesso quando só repete.
      departamento: slugPorId.get(f.departamento_id) || String(f.setor || '').trim(),
    }))
    .filter((f) => f.numero);
  if (!lista.length) return;

  const { status } = await chamarVantoro('/zorvin/telefones', {
    method: 'POST',
    body: JSON.stringify({ telefones: lista }),
  });
  if (status === 200) {
    telefonesEnviadosEm = Date.now();
  } else {
    console.log(`Telefones: o Vantoro respondeu ${status}.`);
  }
}

// `emMaos` é a lista de telefones e a de departamentos já lidas por quem
// chamou. A rodada percorre o escritório inteiro, e essas duas listas são as
// MESMAS para todo mundo: relê-las por pessoa fazia dezenas de consultas
// idênticas a cada três minutos, para sempre. Quem chama por uma pessoa só
// (a entrada no sistema, a tela de permissões) não passa nada e a rotina lê
// como sempre leu.
//
// DEVOLVE `{ tirei, pus }` quando escreveu alguma coisa, e nada quando não
// escreveu — que é o caso de quase toda rodada. Quem chama por uma pessoa só
// ignora a resposta; quem percorre o escritório usa para não anunciar trabalho
// que não houve.
async function aplicarPermissoes(usuarioId, u, emMaos = null) {
  // `zorvin_definido` distingue "não pode ver nada" de "ninguém definiu ainda".
  // Sem essa distinção, o primeiro login depois desta mudança apagaria a
  // permissão de todo mundo que ainda não tem perfil no Vantoro — o sistema
  // inteiro ficaria cego de uma vez, e por causa de uma melhoria.
  if (!u || u.zorvin_definido !== true) return;
  // Admin vê tudo pelas regras de visibilidade; linha de permissão para ele
  // seria enfeite que confunde quem for conferir depois.
  if (u.admin) return;

  // DOIS CORTES, E O FINO GANHA DO GROSSO.
  //
  // O departamento é o corte certo na maioria dos casos. O que ele não resolve
  // aparece toda semana: a pessoa que atende UM número e só ele — uma estagiária
  // no número do cadastro, um parceiro no de vendas. Pelo departamento, liberar
  // esse número libera todos os números do departamento junto.
  //
  // Quando o Vantoro diz `zorvin_so_telefones`, ele já conferiu que há telefone
  // marcado (chave ligada com lista vazia não vira restrição lá, justamente para
  // não deixar ninguém sem ver nada no meio de uma edição). Aqui a lista de
  // telefones SUBSTITUI os departamentos: é o que a tela promete a quem marcou.
  const soTelefones = u.zorvin_so_telefones === true;
  const chaves = Array.isArray(u.zorvin) ? u.zorvin.filter(Boolean) : [];
  const numeros = Array.isArray(u.zorvin_telefones) ? u.zorvin_telefones.filter(Boolean) : [];

  const linhas = [];

  if (soTelefones) {
    // `select('*')` e não a lista de colunas, pelo mesmo motivo das outras
    // rotinas: o formato de `advogados` varia com o que já foi rodado no banco.
    let fones = emMaos && emMaos.fones;
    if (!fones) {
      const lido = await lerTudo('advogados', '*');
      if (lido.error) {
        console.log(`Permissões: não consegui ler os telefones (${lido.error.message}).`);
        return;
      }
      fones = lido.data;
    }
    const porChave = new Map((fones || []).map((f) => [chaveDoNumero(f.numero), f.id]));
    const perdidos = [];
    for (const n of numeros) {
      const id = porChave.get(chaveDoNumero(n));
      if (id) linhas.push({ usuario_id: usuarioId, telefone_id: id });
      else perdidos.push(n);
    }
    if (perdidos.length) {
      console.log(`Permissões de ${u.login}: o Zorvin não tem os telefones ${perdidos.join(', ')}.`);
    }
    // Nenhum telefone reconhecido: sair sem apagar nada. Substituir a permissão
    // por uma lista vazia deixaria a pessoa cega por causa de um número escrito
    // diferente dos dois lados — e o sintoma não apontaria para a causa.
    if (!linhas.length) return;
  } else if (chaves.length) {
    let data = null;
    if (emMaos && emMaos.deps) {
      data = emMaos.deps.filter((d) => chaves.includes(d.slug));
    } else {
      const lido = await supabase
        .from('departamentos').select('id, slug').in('slug', chaves);
      if (lido.error) {
        console.log(`Permissões: não consegui ler os departamentos (${lido.error.message}).`);
        return;
      }
      data = lido.data;
    }
    for (const d of data || []) linhas.push({ usuario_id: usuarioId, departamento_id: d.id });
    // Chave marcada no Vantoro que não existe aqui é erro de digitação lá. Fica
    // registrado: é o que explica "marquei e a pessoa continua sem ver".
    const achados = new Set((data || []).map((d) => d.slug));
    const perdidas = chaves.filter((s) => !achados.has(s));
    if (perdidas.length) {
      console.log(`Permissões de ${u.login}: o Zorvin não conhece ${perdidas.join(', ')}.`);
    }
  }

  // AGORA AS DUAS ESPÉCIES DE LINHA SÃO SUBSTITUÍDAS — antes, só as de
  // departamento eram. A regra mudou porque o lugar de decidir mudou: enquanto
  // o telefone só se liberava aqui, apagar essas linhas seria o sistema mais
  // grosseiro passando por cima do mais fino. Agora o Vantoro tem a tela dos
  // dois cortes, e quem tem perfil lá tem a resposta inteira lá. Deixar
  // sobrar linha de telefone dada em outro tempo faria a pessoa continuar vendo
  // o que a tela diz que ela não vê — e ninguém procuraria o resto da resposta
  // num segundo lugar.
  //
  // ------------------------------------------------------------
  //  MAS SUBSTITUIR NÃO É APAGAR TUDO E GRAVAR TUDO DE VOLTA
  //
  //  Era o que esta rotina fazia, e ela roda de três em três minutos para cada
  //  pessoa do escritório. Entre o `delete` e o `insert` — dois pedidos de
  //  rede, algumas dezenas de milissegundos — a pessoa não tem permissão
  //  nenhuma. Quem estivesse carregando a lista de conversas naquele instante
  //  não via nada, e ao recarregar via tudo de novo. Um sumiço curto, sem erro,
  //  que volta sozinho: exatamente o feitio de "às vezes aparece, às vezes não".
  //
  //  E quando a gravação falhava — a rede caiu, o banco recusou —, o apagar já
  //  tinha acontecido: a pessoa ficava cega até uma rodada seguinte dar certo.
  //  Se a causa fosse permanente, ficava cega para sempre, com a tela do
  //  Vantoro mostrando a permissão marcada, certinha.
  //
  //  A correção é comparar antes de escrever. Quase sempre nada mudou desde a
  //  rodada anterior, e então não se escreve NADA — a janela nem chega a abrir.
  //  Quando mudou, mexe-se só na diferença: tira o que não vale mais, depois
  //  acrescenta o que passou a valer. Nessa ordem de propósito. Se a segunda
  //  metade falhar, a pessoa fica vendo de menos por alguns minutos; na ordem
  //  inversa, ela ficaria vendo o que a tela já diz que ela não pode ver. Num
  //  escritório de advocacia, errar para menos é o único lado aceitável.
  //
  //  A consulta não cita `grupo_id` de propósito: a coluna ainda existe, mas os
  //  grupos saíram e ela está esperando o painel parar de mencioná-la para ser
  //  apagada. Amarrar esta rotina a ela faria a permissão parar de ser aplicada
  //  no dia em que a coluna sumir — e sem nada dizendo por quê. Linha herdada
  //  de grupo (sem departamento e sem telefone) entra como sobra e sai, que é o
  //  mesmo destino que tinha antes.
  // ------------------------------------------------------------
  const chaveDaLinha = (l) => (l.telefone_id ? `t:${l.telefone_id}`
                             : l.departamento_id ? `d:${l.departamento_id}` : null);

  const { data: atuais, error: erroLe } = await supabase
    .from('permissoes').select('id, departamento_id, telefone_id').eq('usuario_id', usuarioId);
  if (erroLe) {
    console.log(`Permissões: não consegui ler as atuais (${erroLe.message}).`);
    return;
  }

  const querido = new Map();
  for (const l of linhas) querido.set(chaveDaLinha(l), l);

  const jaTem = new Set();
  const sobrando = [];
  for (const p of atuais || []) {
    const chave = chaveDaLinha(p);
    // `jaTem.has` cobre a linha repetida: duas rodadas que se atropelaram no
    // passado podem ter deixado a mesma permissão duas vezes. A primeira fica,
    // a segunda sai.
    if (chave && querido.has(chave) && !jaTem.has(chave)) jaTem.add(chave);
    else sobrando.push(p.id);
  }
  const faltando = [];
  for (const [chave, linha] of querido) if (!jaTem.has(chave)) faltando.push(linha);

  // Nada mudou: não se escreve nada. É o caso de quase toda rodada — e é por
  // isso que a resposta é vazia aqui, para o log lá em cima não anunciar uma
  // reaplicação que não aconteceu.
  if (!sobrando.length && !faltando.length) return null;

  if (sobrando.length) {
    const { error } = await supabase.from('permissoes').delete().in('id', sobrando);
    if (error) {
      console.log(`Permissões: não consegui tirar as que não valem mais (${error.message}).`);
      return null;
    }
  }
  // `pus` conta o que ENTROU, e não o que se pretendia pôr: com a gravação
  // falhando, dizer que pôs seria o log inventando um trabalho que não houve —
  // que é justamente o defeito que esta mudança veio corrigir.
  let pus = 0;
  if (faltando.length) {
    const { error } = await supabase.from('permissoes').insert(faltando);
    if (error) console.log(`Permissões: não consegui gravar (${error.message}).`);
    else pus = faltando.length;
  }
  return { tirei: sobrando.length, pus };
}

// ------------------------------------------------------------
//  A PERMISSÃO NÃO PODE ESPERAR O PRÓXIMO LOGIN
//
//  Aplicar só na entrada tem um defeito que só aparece no uso: quem já está com
//  o painel aberto — que é o caso de todo mundo no meio do expediente —
//  continua com a permissão velha até sair e entrar de novo. Do lado de quem
//  administra, o sintoma é exatamente "liberei o departamento e a pessoa
//  continua sem ver as conversas", sem nada na tela explicando que falta um
//  logout.
//
//  Esta rotina reaplica a permissão de todo mundo de tempos em tempos, lendo a
//  mesma lista que o Vantoro já expõe em /usuarios. Quem estiver com a tela
//  aberta passa a enxergar sozinho, sem instrução nenhuma.
//
//  Só mexe em quem JÁ ENTROU alguma vez (está em `usuarios`): criar conta no
//  Supabase para quem nunca entrou encheria a base de contas que ninguém pediu,
//  e a permissão dessa pessoa é aplicada no primeiro login dela de todo jeito.
// ------------------------------------------------------------
const PERMISSOES_INTERVALO_MS = 3 * 60 * 1000;

async function sincronizarPermissoes() {
  if (!VANTORO_URL || !VANTORO_TOKEN) return;

  const { status, corpo } = await chamarVantoro('/usuarios');
  if (status !== 200 || !corpo || !Array.isArray(corpo.usuarios)) {
    console.log(`Permissões: o Vantoro respondeu ${status} ao listar usuários.`);
    return;
  }

  const { data: espelhados, error } = await lerTudo('usuarios', 'id, login, email');
  if (error) {
    console.log(`Permissões: não consegui ler os usuários (${error.message}).`);
    return;
  }

  // Casa pelo login E pelo e-mail. O login é a identidade no Vantoro; o e-mail
  // entra porque foi ele que abriu a conta aqui, e quem trocou de login lá
  // continuaria casando por ele.
  const porLogin = new Map();
  const porEmail = new Map();
  for (const u of espelhados || []) {
    if (u.login) porLogin.set(String(u.login).toLowerCase(), u.id);
    if (u.email) porEmail.set(String(u.email).toLowerCase(), u.id);
  }

  // Os telefones e os departamentos são os mesmos para todo mundo: lidos uma
  // vez aqui e emprestados a cada pessoa. Se a leitura falhar, `emMaos` fica
  // sem a lista e cada chamada lê por conta própria — a rodada fica mais cara,
  // mas não deixa de acontecer.
  const emMaos = {};
  const lidosFones = await lerTudo('advogados', '*');
  if (!lidosFones.error) emMaos.fones = lidosFones.data;
  const lidosDeps = await supabase.from('departamentos').select('id, slug');
  if (!lidosDeps.error) emMaos.deps = lidosDeps.data;

  // ------------------------------------------------------------
  //  ESTA RODADA ACONTECE DE TRÊS EM TRÊS MINUTOS, E QUASE SEMPRE NÃO FAZ NADA
  //
  //  O log dizia `Permissões: reaplicadas para 14 usuário(s).` a cada rodada.
  //  Duas coisas erradas na mesma linha:
  //
  //  A frase era falsa. `aplicadas` contava quem a rotina VISITOU, não quem
  //  teve permissão mexida — e a rotina foi consertada justamente para não
  //  escrever quando nada mudou. Ela anunciava uma reaplicação que não
  //  acontecia.
  //
  //  E, sendo a cada três minutos, ela enchia o log de linhas iguais: quase
  //  quinhentas por dia, todas sem notícia. Quem for procurar o que houve às
  //  quinze para as três — uma linha caída, um webhook recusado — precisa
  //  passar por elas. Um log que repete o que não mudou esconde o que mudou.
  //
  //  Agora só sai linha quando alguma permissão de fato mexeu, e ela diz DE
  //  QUEM. É a pergunta que quem administra faz depois: "a fulana parou de ver
  //  o departamento, quando isso mudou?".
  // ------------------------------------------------------------
  const mexidos = [];
  let conferidos = 0;
  for (const u of corpo.usuarios) {
    const id = porLogin.get(String(u.login || '').toLowerCase())
            || porEmail.get(String(u.email || '').toLowerCase());
    if (!id) continue;   // ainda não entrou no Zorvin nenhuma vez
    try {
      const mexeu = await aplicarPermissoes(id, u, emMaos);
      conferidos += 1;
      if (mexeu && (mexeu.tirei || mexeu.pus)) {
        const conta = [mexeu.pus ? `+${mexeu.pus}` : null,
                       mexeu.tirei ? `-${mexeu.tirei}` : null].filter(Boolean).join(' ');
        mexidos.push(`${u.login} (${conta})`);
      }
    } catch (e) {
      console.log(`Permissões de ${u.login}: ${(e && e.message) || e}`);
    }
  }
  if (mexidos.length) {
    // O TETO DE NOMES. Na primeira rodada depois de uma implantação — ou
    // depois de alguém mexer no perfil de meio escritório — todo mundo muda de
    // uma vez, e a linha inteira viraria um parágrafo. Oito nomes contam a
    // história; o resto vira número, que é o que interessa nesse caso.
    const TETO = 8;
    const lista = mexidos.length > TETO
      ? `${mexidos.slice(0, TETO).join(', ')} e mais ${mexidos.length - TETO}`
      : mexidos.join(', ');
    console.log(`Permissões: mudei ${lista} — de ${conferidos} conferido(s).`);
  }
}

// ------------------------------------------------------------
//  TELEFONE SEM DEPARTAMENTO É TELEFONE INVISÍVEL
//
//  A regra de visibilidade compara o departamento da permissão com o do
//  TELEFONE. Telefone sem departamento não bate com nada, então as conversas
//  dele somem para todo mundo que não é administrador — e somem em silêncio,
//  inclusive para quem tem a permissão certa. É a causa que mais engana, porque
//  a permissão está lá, marcada, correta.
//
//  O SQL que criou os departamentos já resolveu isso para os telefones daquele
//  dia (cada um foi para o departamento do seu `setor`, e quem não tinha setor
//  foi para `acordos`, que era o padrão de antes). Telefone cadastrado DEPOIS
//  nasce sem departamento e recria o problema. Esta rotina aplica a mesma regra
//  daquele SQL, continuamente — não é regra nova, é a mesma deixando de valer
//  só uma vez.
// ------------------------------------------------------------
async function garantirDepartamentoDosTelefones() {
  // `select('*')` e não a lista de colunas: o formato de `advogados` varia com
  // o que já foi rodado no banco, e pedir uma coluna que ainda não existe
  // devolve erro e mata a rotina inteira. É o mesmo cuidado que a busca do
  // advogado no webhook já toma, e pelo mesmo motivo.
  const { data: fones, error } = await lerTudo(
    'advogados', '*', (q) => q.is('departamento_id', null));
  if (error || !fones || !fones.length) return;

  const { data: deps } = await supabase.from('departamentos').select('id, slug');
  if (!deps || !deps.length) return;
  const porSlug = new Map(deps.map((d) => [d.slug, d.id]));
  const padrao = porSlug.get('acordos') || deps[0].id;

  for (const f of fones) {
    const destino = porSlug.get(String(f.setor || '').trim()) || padrao;
    const { error: erroGrava } = await supabase
      .from('advogados').update({ departamento_id: destino }).eq('id', f.id);
    if (erroGrava) {
      console.log(`Telefone ${f.nome || f.numero || f.id}: não consegui definir o departamento (${erroGrava.message}).`);
    } else {
      console.log(`Telefone ${f.nome || f.numero || f.id} estava sem departamento — suas conversas `
                + 'não apareciam para ninguém que não fosse administrador. Corrigido.');
    }
  }
}

// A primeira rodada sai logo depois de subir (dando tempo de o processo ficar
// de pé), e daí em diante no intervalo. `unref` para o temporizador não segurar
// o processo se ele for encerrado.
// UMA RODADA DE CADA VEZ.
//
// A rodada percorre todo mundo, e cada pessoa custa algumas idas ao banco. Com
// o escritório crescendo, ou com o Vantoro lento (a chamada espera até 20
// segundos), uma rodada pode passar dos três minutos do intervalo — e então a
// seguinte começa em cima dela. Duas rodadas mexendo na permissão da mesma
// pessoa ao mesmo tempo se atropelam: uma tira o que a outra acabou de pôr.
//
// É a mesma trava que a fila de envio já tem, pelo mesmo motivo.
let rodadaRodando = false;

async function rodada() {
  if (desligando) return;   // saindo do ar: a próxima ponte faz esta rodada
  if (rodadaRodando) {
    console.log('Rodada: a anterior ainda está correndo — esta fica para o próximo intervalo.');
    return;
  }
  rodadaRodando = true;
  try {
    await umaRodada();
  } finally {
    rodadaRodando = false;
  }
}

// UM TROPEÇO NÃO PARA A RODADA — MAS APARECE NO LOG.
//
// Eram quatro `.catch(() => {})`. A intenção estava certa: o departamento que
// falha não pode impedir a permissão de ser aplicada. O preço é que um erro
// INESPERADO dentro de qualquer uma das quatro — a rede caindo no meio da
// chamada ao Vantoro, por exemplo — sumia sem deixar rastro. As quatro tratam
// os erros que esperam e escrevem no log; só os que não esperam eram engolidos,
// e são justamente esses que a gente precisa ver.
//
// Foi assim que "a conexão com o Vantoro não está funcionando" chegou como
// relato de tela, e não como linha de log: o painel via a falha, a ponte
// tentava de três em três minutos, e o log não tinha uma palavra sobre o
// assunto para dizer de que lado estava o problema.
async function semDerrubarARodada(nome, tarefa) {
  try {
    await tarefa();
  } catch (e) {
    console.error(`Rodada: ${nome} tropeçou — ${e?.message || e}`);
  }
}

async function umaRodada() {
  // A ordem importa: o telefone precisa ter departamento ANTES de a permissão
  // ser conferida, senão a primeira rodada aplica permissão que ainda não
  // alcança conversa nenhuma.
  await semDerrubarARodada('departamento dos telefones', garantirDepartamentoDosTelefones);
  await semDerrubarARodada('departamentos para o Vantoro', mandarDepartamentosAoVantoro);
  // Os telefones vão DEPOIS dos departamentos: a tela de permissões mostra a que
  // departamento cada número pertence, e para isso o departamento já tem de
  // existir lá. Na ordem inversa, a primeira sincronização mostraria os números
  // soltos, e quem marcasse ali não veria que já estavam cobertos.
  await semDerrubarARodada('telefones para o Vantoro', mandarTelefonesAoVantoro);
  await semDerrubarARodada('permissões', sincronizarPermissoes);
}
setTimeout(() => { rodada().catch(() => {}); }, 20 * 1000).unref();
setInterval(() => { rodada().catch(() => {}); }, PERMISSOES_INTERVALO_MS).unref();

// ============================================================
//  A TELA DE ATENDENTES DO ZORVIN
//
//  Quem administra o escritório passa a dar e tirar acesso DENTRO do Zorvin, em
//  vez de abrir o admin do Django. É a mesma permissão — não uma segunda.
//
//  E é por isso que estas rotas escrevem no VANTORO, e não direto em
//  `permissoes` aqui. A Ponte reescreve as linhas de lá a partir do Vantoro a
//  cada poucos minutos: o que a tela gravasse direto no Supabase sumiria
//  sozinho na rodada seguinte, sem nada dizendo por quê. Uma resposta, um lugar.
//
//  Depois de gravar, a permissão é aplicada NA HORA (`aplicarPermissoes`), sem
//  esperar a rodada: quem acabou de marcar quer conferir na tela ao lado, e
//  "espere três minutos" é o tipo de coisa que faz a pessoa marcar de novo
//  achando que não salvou.
// ============================================================

// Só admin abre: as duas rotas contam e mudam quem enxerga o quê.
function soAdmin(handler) {
  return rotaVantoro(async (req, usuario) => {
    const { data: eu } = await supabase
      .from('usuarios').select('admin').eq('id', usuario.id).maybeSingle();
    if (!eu || !eu.admin) {
      return { status: 403, corpo: { ok: false, erro: 'Só quem administra pode mexer nas permissões.' } };
    }
    return handler(req, usuario);
  });
}

// Nomeadas, e não escritas dentro do `app.get`: assim dá para exercitá-las com
// um dublê do Supabase e do Vantoro, que é o único jeito de conferir quem pode
// mexer em quê sem depender de um banco de verdade.
async function listarAtendentes() {
  // A lista sai do Vantoro porque é lá que a permissão mora. Vem com o estado de
  // cada pessoa (departamentos, telefones e a chave), que é o que a tela desenha.
  const { status, corpo } = await chamarVantoro('/usuarios');
  if (status !== 200 || !corpo || !corpo.ok) {
    return { status: 502, corpo: { ok: false, erro: 'Não consegui ler os usuários do Vantoro.' } };
  }
  // Quem nunca entrou no Zorvin ainda não tem conta aqui — e a permissão dele só
  // vira linha no dia em que entrar. A tela precisa dizer isso, senão o
  // administrador marca, confere e não vê efeito nenhum.
  const { data: contas } = await lerTudo('usuarios', 'id, login, email');
  const conhecidos = new Set();
  for (const c of contas || []) {
    if (c.login) conhecidos.add(String(c.login).toLowerCase());
    if (c.email) conhecidos.add(String(c.email).toLowerCase());
  }
  const usuarios = (corpo.usuarios || []).map((u) => ({
    ...u,
    ja_entrou: conhecidos.has(String(u.login || '').toLowerCase())
            || conhecidos.has(String(u.email || '').toLowerCase()),
  }));
  return { status: 200, corpo: { ok: true, usuarios } };
}

async function gravarAtendente(req) {
  const corpoEnviado = req.body || {};
  if (!corpoEnviado.usuario) {
    return { status: 400, corpo: { ok: false, erro: 'Informe de quem é a permissão.' } };
  }
  const { status, corpo } = await chamarVantoro('/zorvin/permissoes', {
    method: 'POST',
    body: JSON.stringify(corpoEnviado),
  });
  if (status !== 200 || !corpo || !corpo.ok) {
    return { status, corpo: corpo || { ok: false, erro: 'O Vantoro não aceitou a mudança.' } };
  }

  // Aplicar agora, e não na próxima rodada. Se falhar, a gravação no Vantoro
  // continua valendo — a rodada seguinte aplica. Por isso o erro daqui não
  // desfaz nada: ele só avisa que o efeito vai demorar alguns minutos.
  let aplicada = false;
  try {
    const login = String(corpo.usuario.login || '').toLowerCase();
    const { data: contas } = await lerTudo('usuarios', 'id, login, email');
    const conta = (contas || []).find(
      (c) => String(c.login || '').toLowerCase() === login
          || String(c.email || '').toLowerCase() === login);
    if (conta) {
      await aplicarPermissoes(conta.id, { ...corpo.usuario, admin: false });
      aplicada = true;
    }
  } catch (e) {
    console.log('Permissões: gravei no Vantoro mas não apliquei agora —', (e && e.message) || e);
  }
  return { status: 200, corpo: { ok: true, usuario: corpo.usuario, aplicada } };
}

app.options('/permissoes/atendentes', (req, res) => { liberarCors(res); res.sendStatus(204); });
app.get('/permissoes/atendentes', soAdmin(listarAtendentes));
app.options('/permissoes/atendente', (req, res) => { liberarCors(res); res.sendStatus(204); });
app.post('/permissoes/atendente', soAdmin(gravarAtendente));


// ============================================================
//  JUNTAR DUAS CONVERSAS À MÃO
//
//  A junção automática dos grupos depende de reconhecer o rastro que o erro
//  deixou, e ela só roda quando chega uma mensagem nova daquele grupo. Duas
//  coisas que ela não alcança:
//
//    - grupo parado: ninguém escreve nele há dias, então nada dispara;
//    - rastro que não bate com nenhum dos padrões conhecidos — e aí o certo é
//      deixar quem OLHA a tela dizer "estas duas são a mesma", em vez de o
//      código adivinhar com mais uma regra.
//
//  Esta rota é isso: a pessoa aponta as duas, e nós movemos.
//
//  Ela mora AQUI e não no painel por causa do RLS: mover mensagem é UPDATE em
//  `mensagens`, e apagar conversa é DELETE em `conversas` — duas coisas que o
//  painel não pode fazer (e não deve). A ponte fala com o banco pelo papel de
//  serviço, e por isso é ela quem faz, com o admin conferido antes.
// ============================================================
async function juntarConversas(req) {
  const de = String((req.body && req.body.de) || '').trim();
  const para = String((req.body && req.body.para) || '').trim();
  if (!de || !para) return { status: 400, corpo: { ok: false, erro: 'Informe as duas conversas.' } };
  if (de === para) return { status: 400, corpo: { ok: false, erro: 'São a mesma conversa.' } };

  const { data: ambas, error } = await supabase
    .from('conversas').select('id, advogado_id, contato_id').in('id', [de, para]);
  if (error) return { status: 500, corpo: { ok: false, erro: error.message } };
  const origem = (ambas || []).find((c) => String(c.id) === de);
  const destino = (ambas || []).find((c) => String(c.id) === para);
  if (!origem || !destino) return { status: 404, corpo: { ok: false, erro: 'Não achei uma das conversas.' } };
  // Telefones diferentes não se juntam: a conversa pertence ao número por onde
  // ela aconteceu, e misturar dois números apagaria essa informação — além de
  // levar mensagem para um telefone que talvez outra equipe enxergue.
  if (String(origem.advogado_id) !== String(destino.advogado_id)) {
    return { status: 400, corpo: { ok: false,
      erro: 'As duas conversas são de telefones diferentes. Junte só conversas do mesmo número.' } };
  }

  const { movidas, erro: erroMove } = await mudarDeConversa(origem.id, destino.id);
  if (erroMove) return { status: 500, corpo: { ok: false, erro: erroMove } };

  await supabase.from('conversas').delete().eq('id', origem.id);

  // O contato da conversa que saiu só é apagado se não sobrou conversa nenhuma
  // nele — ele pode ter conversa em outro telefone do escritório, e aí não é
  // nosso para apagar.
  const { data: sobrou } = await supabase
    .from('conversas').select('id').eq('contato_id', origem.contato_id).limit(1);
  if (!sobrou || !sobrou.length) {
    await supabase.from('contatos').delete().eq('id', origem.contato_id);
  }
  console.log(`Conversas: juntei ${movidas} mensagem(ns) da conversa ${origem.id} na ${destino.id}.`);
  return { status: 200, corpo: { ok: true, movidas } };
}

app.options('/conversas/juntar', (req, res) => { liberarCors(res); res.sendStatus(204); });
app.post('/conversas/juntar', soAdmin(juntarConversas));


// ------------------------------------------------------------
//  HISTÓRICO DE ATENDIMENTO DE UM CLIENTE
//
//  Quem já falou com esta pessoa, quando, e por qual dos telefones do
//  escritório. O painel montava isso sozinho, direto do Supabase — e por isso
//  via só os telefones que a PESSOA LOGADA alcança: a regra de linha
//  (`pode_ver_conversa`) recorta a consulta dela. Uma lista recortada respondia
//  "ninguém falou com esse cliente" quando a resposta certa era "falaram, por
//  um telefone que você não abre".
//
//  Aqui a chave é a de serviço, que enxerga o escritório inteiro. É por isso
//  que esta rota existe em vez de uma política mais frouxa no banco: afrouxar
//  a leitura de `conversas` abriria TODAS as conversas para todo mundo dentro
//  do painel, e não é isso que se quer. O que sai daqui é só o RESUMO — nome
//  de quem escreveu, data e telefone. Nenhum texto de mensagem atravessa.
//
//  Basta estar logado no Zorvin: a informação é de organização do trabalho, e
//  guardá-la por permissão é justamente o que criava a resposta errada.
// ------------------------------------------------------------
// ------------------------------------------------------------
//  A ETIQUETA É DO CLIENTE, E NÃO DA CAIXA EM QUE ELE FALOU
//
//  Relato de quem usa: "a etiqueta que é incluída no contato deve aparecer nas
//  conversas com o contato em todos os telefones".
//
//  A tabela é `conversa_tags` — uma linha por (conversa, etiqueta). Como cada
//  telefone nosso tem a SUA conversa com o mesmo cliente, etiquetar "Urgente"
//  no telefone do Dr. Max não mudava nada no do Estratégico. E etiqueta serve
//  para achar e para priorizar: uma que só metade do escritório enxerga faz o
//  filtro devolver metade, sem dizer que devolveu metade.
//
//  ESPALHAR, E NÃO LER A CAIXA DO OUTRO. A outra saída era o painel ler as
//  etiquetas das conversas dos outros telefones — o que abriria exceção na
//  regra de acesso que o #124 acabou de fechar. Aqui cada conversa ganha a SUA
//  linha, e o painel continua lendo só o que já lia. É a mesma escolha do
//  #130, e pelo mesmo motivo.
//
//  PELA PONTE porque o navegador não alcança: as conversas dos outros
//  telefones são invisíveis para ele, e um espalhamento feito lá cobriria só
//  as que a pessoa já vê — deixando a etiqueta pela metade, que é o defeito de
//  origem com outra roupa.
//
//  O QUE ATRAVESSA É UM ID DE ETIQUETA. Nenhum texto de conversa sai daqui, e
//  quem chama precisa estar logado no Zorvin (`rotaVantoro` exige).
// ------------------------------------------------------------
app.options('/etiqueta/contato', (req, res) => { liberarCors(res); res.sendStatus(204); });
app.post('/etiqueta/contato', rotaVantoro(async (req) => {
  const contatoId = String((req.body && req.body.contato_id) || '').trim();
  const tagId = String((req.body && req.body.tag_id) || '').trim();
  const aplicar = (req.body && req.body.aplicar) !== false;
  if (!contatoId || !tagId) {
    return { status: 400, corpo: { ok: false, erro: 'Informe contato_id e tag_id.' } };
  }

  const { data: convs, error } = await supabase
    .from('conversas').select('id').eq('contato_id', contatoId);
  if (error) return { status: 502, corpo: { ok: false, erro: 'Não consegui achar as conversas do contato.' } };
  const ids = (convs || []).map((c) => c.id);
  // NENHUMA CONVERSA É UM ERRO, e não um sucesso silencioso: o painel acabou de
  // pintar a etiqueta na tela, e responder "ok, 0 conversas" deixaria a marca
  // no ecrã e nada no banco.
  if (!ids.length) {
    return { status: 404, corpo: { ok: false, erro: 'Este contato não tem conversa nenhuma.' } };
  }

  if (!aplicar) {
    const { error: erroApagar } = await supabase.from('conversa_tags')
      .delete().in('conversa_id', ids).eq('tag_id', tagId);
    if (erroApagar) return { status: 502, corpo: { ok: false, erro: 'Não consegui tirar a etiqueta.' } };
    return { status: 200, corpo: { ok: true, conversas: ids.length } };
  }

  // LÊ O QUE JÁ EXISTE E INSERE SÓ O QUE FALTA — e não um `upsert` com
  // `onConflict: 'conversa_id,tag_id'`.
  //
  // O upsert seria mais curto e depende de uma coisa que eu NÃO conferi: um
  // índice único nessas duas colunas. Se `conversa_tags` não o tiver, o
  // PostgREST recusa o pedido inteiro — e a etiqueta que a pessoa acabou de
  // ver acender na tela não teria sido gravada em lugar nenhum. Ler antes
  // custa uma consulta e funciona com ou sem o índice.
  const { data: jaTem, error: erroLer } = await supabase.from('conversa_tags')
    .select('conversa_id').eq('tag_id', tagId).in('conversa_id', ids);
  if (erroLer) return { status: 502, corpo: { ok: false, erro: 'Não consegui ler as etiquetas do contato.' } };
  const postas = new Set((jaTem || []).map((r) => String(r.conversa_id)));
  const faltando = ids.filter((id) => !postas.has(String(id)));
  if (!faltando.length) return { status: 200, corpo: { ok: true, conversas: ids.length, novas: 0 } };

  const { error: erroPor } = await supabase.from('conversa_tags')
    .insert(faltando.map((id) => ({ conversa_id: id, tag_id: tagId })));
  // CHAVE REPETIDA NÃO É FALHA. Duas pessoas etiquetando o mesmo cliente ao
  // mesmo tempo caem aqui, e o desfecho é o que as duas queriam: a etiqueta
  // está posta. Recusar seria inventar um erro para quem não errou.
  if (erroPor && erroPor.code !== '23505') {
    return { status: 502, corpo: { ok: false, erro: 'Não consegui aplicar a etiqueta.' } };
  }
  return { status: 200, corpo: { ok: true, conversas: ids.length, novas: faltando.length } };
}));


// ------------------------------------------------------------
//  QUANTAS CONVERSAS ESTE CONTATO TEM, E EM QUANTOS TELEFONES
//
//  O ícone de histórico no topo da conversa era mudo: só clicando dava para
//  saber que o mesmo cliente estava sendo atendido por outro telefone nosso —
//  e ninguém clica num ícone para descobrir que não há nada lá. O resultado é
//  que a informação existia e não era vista: duas pessoas do escritório
//  atendendo o mesmo cliente sem saber uma da outra.
//
//  Agora o ícone traz o número, e ele vem daqui.
//
//  POR QUE UMA ROTA SÓ PARA CONTAR, tendo `/historico/contato/:id` logo
//  abaixo: aquela faz DUAS consultas por conversa (a primeira e a última
//  mensagem de cada uma) para desenhar o painel inteiro. Chamá-la a cada
//  conversa ABERTA, só para pôr um número num ícone, seria pagar o painel
//  todo — em toda troca de conversa, o dia inteiro, num serviço que hiberna.
//  Esta faz uma consulta e devolve um número.
//
//  E PELA PONTE, e não do navegador, pelo mesmo motivo da outra: a regra de
//  linha do Supabase recorta as conversas pelos telefones que a PESSOA
//  alcança, e aí a resposta seria sempre "só esta" — que é justamente a
//  resposta errada que a tela existe para corrigir. Só o RESUMO atravessa:
//  quantas conversas e de quais telefones. Texto de mensagem nenhum.
// ------------------------------------------------------------
app.options('/historico/contato/:id/quantas', (req, res) => { liberarCors(res); res.sendStatus(204); });
app.get('/historico/contato/:id/quantas', rotaVantoro(async (req) => {
  const contatoId = String(req.params.id || '').trim();
  if (!contatoId) return { status: 400, corpo: { ok: false, erro: 'Informe o contato.' } };

  const { data: convs, error } = await supabase
    .from('conversas').select('id, advogado_id').eq('contato_id', contatoId);
  if (error) return { status: 502, corpo: { ok: false, erro: 'Não consegui contar as conversas.' } };

  // OS TELEFONES DISTINTOS, e não as conversas. São a mesma coisa hoje (uma
  // conversa por telefone e contato) e podem deixar de ser; contar o que a
  // frase promete é o que impede o número de mentir depois.
  const telefones = [...new Set((convs || []).map((c) => String(c.advogado_id)))];
  return { status: 200, corpo: { ok: true, conversas: (convs || []).length,
                                 telefones: telefones.length } };
}));

app.options('/historico/contato/:id', (req, res) => { liberarCors(res); res.sendStatus(204); });
app.get('/historico/contato/:id', rotaVantoro(async (req) => {
  const contatoId = String(req.params.id || '').trim();
  if (!contatoId) return { status: 400, corpo: { ok: false, erro: 'Informe o contato.' } };

  const { data: convs, error } = await supabase
    .from('conversas').select('id, advogado_id').eq('contato_id', contatoId);
  if (error) return { status: 502, corpo: { ok: false, erro: 'Não consegui ler o histórico.' } };

  const { data: advs } = await supabase.from('advogados').select('id, nome, numero');

  // PRIMEIRA e ÚLTIMA por conversa, com `limit(1)` em cada sentido — e não uma
  // leitura de tudo para depois escolher. Cliente antigo tem milhares de
  // mensagens, e seriam todas na memória da ponte para mostrar duas.
  const ponta = (convId, crescente) => supabase
    .from('mensagens')
    .select('enviado_por, enviado_por_foto, criado_em')
    .eq('conversa_id', convId).eq('origem', 'advogado')
    .order('criado_em', { ascending: crescente }).limit(1);

  const linhas = await Promise.all((convs || []).map(async (v) => {
    const [pri, ult] = await Promise.all([ponta(v.id, true), ponta(v.id, false)]);
    const adv = (advs || []).find((a) => String(a.id) === String(v.advogado_id)) || null;
    return {
      conversa_id: v.id,
      advogado_id: v.advogado_id,
      advogado_nome: adv ? adv.nome : null,
      advogado_numero: adv ? adv.numero : null,
      primeira: (pri.data || [])[0] || null,
      ultima: (ult.data || [])[0] || null,
    };
  }));

  return { status: 200, corpo: { ok: true, linhas } };
}));


// ------------------------------------------------------------
//  A FOTO DO CONTATO EM TAMANHO CHEIO
//
//  A foto de perfil chegava pelo webhook e ficava guardada. Só que o campo que
//  vinha na frente era `imagePreview` — a MINIATURA. Corrigida a ordem, as
//  novas passam a vir cheias; as que já estão guardadas, não: o webhook só
//  traz foto quando o contato manda mensagem, e um cliente que não escreve há
//  um mês fica com a miniatura de um mês atrás para sempre.
//
//  Esta rota vai buscar a foto DE NOVO, sob demanda. O painel só a oferece
//  quando a foto aberta é pequena de verdade — não adianta pedir de novo o que
//  já está bom.
//
//  A ROTA DA UAZAPI VARIA COM A VERSÃO, como já variava a de download de mídia.
//  Mesma solução, e pelo mesmo motivo: tenta as conhecidas, LEMBRA a que
//  serviu, e quando nenhuma serve diz isso em português em vez de falhar
//  calada. Se um dia o servidor mudar de rota, uma linha nesta lista resolve.
// ------------------------------------------------------------
//
//  `preview: false` NÃO É DETALHE — é o parâmetro inteiro. A documentação da
//  Uazapi diz, sobre `/chat/details`:
//
//    preview | true: imagem em tamanho preview (menor, otimizada para
//                    listagens)
//            | false (padrão): tamanho full (resolução original, maior
//                    qualidade)
//
//  Ou seja: é este endereço que resolve o "abre grande, porém embaçada".
//  Vai escrito mesmo sendo o padrão — um padrão que muda de versão em versão
//  vira defeito silencioso, e este em particular já custou uma rodada.
const ROTAS_DE_FOTO = [
  { rota: '/chat/details',            corpo: (n) => ({ number: n, preview: false }) },
  { rota: '/chat/GetNameAndImageURL', corpo: (n) => ({ number: n, preview: false }) },
  { rota: '/contact/picture',         corpo: (n) => ({ number: n, preview: false }) },
];
const rotaDeFotoQueServe = new Map();

/** Acha a maior foto dentro da resposta, seja qual for o formato.
 *
 *  Procurar por NOME de campo (`imgUrl`, `profilePicUrl`, …) obrigaria a
 *  conhecer de antemão o formato de cada versão, que é justamente o que não se
 *  sabe. Aqui a regra é a que vale para todas: um endereço http que pareça
 *  imagem, preferindo o que NÃO é miniatura. */
function acharFotoNaResposta(dados) {
  const achados = [];
  const andar = (v, caminho) => {
    if (!v) return;
    if (typeof v === 'string') {
      if (/^https?:\/\//.test(v) && /(img|image|pic|photo|foto|avatar)/i.test(caminho)) {
        achados.push({ url: v, miniatura: /(preview|thumb|small)/i.test(caminho) });
      }
      return;
    }
    if (typeof v !== 'object') return;
    for (const k of Object.keys(v)) andar(v[k], caminho + '.' + k);
  };
  andar(dados, '');
  const cheia = achados.find((a) => !a.miniatura);
  return (cheia || achados[0] || {}).url || null;
}

async function buscarFotoNaUazapi(servidor, token, numero) {
  const lembrada = rotaDeFotoQueServe.get(servidor);
  const ordem = lembrada
    ? [lembrada, ...ROTAS_DE_FOTO.filter((r) => r.rota !== lembrada.rota)]
    : ROTAS_DE_FOTO;

  const tentadas = [];
  for (const candidata of ordem) {
    try {
      const r = await fetchComTimeout(`${servidor}${candidata.rota}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', token },
        body: JSON.stringify(candidata.corpo(numero)),
      }, 15000);
      tentadas.push(`${candidata.rota} → ${r.status}`);
      if (!r.ok) {
        if (lembrada && candidata.rota === lembrada.rota) rotaDeFotoQueServe.delete(servidor);
        continue;
      }
      const dados = await r.json().catch(() => null);
      const url = acharFotoNaResposta(dados);
      if (!url) continue;
      if (!lembrada || lembrada.rota !== candidata.rota) {
        console.log(`foto do contato: este servidor atende por ${candidata.rota}.`);
        rotaDeFotoQueServe.set(servidor, candidata);
      }
      return { url };
    } catch (e) {
      tentadas.push(`${candidata.rota} → ${e.message}`);
      if (lembrada && candidata.rota === lembrada.rota) rotaDeFotoQueServe.delete(servidor);
    }
  }
  console.log('foto do contato: nenhuma rota serviu — ' + tentadas.join(' · '));
  return { url: null, tentadas };
}

app.options('/contato/foto', (req, res) => { liberarCors(res); res.sendStatus(204); });
// `rotaVantoro` é o embrulho de CORS + login + erro. O nome vem de onde ele
// nasceu; o que ele faz serve para qualquer rota que exija estar logado.
app.post('/contato/foto', rotaVantoro(async (req) => {
  const conversaId = String((req.body && req.body.conversa_id) || '').trim();
  if (!conversaId) return { status: 400, corpo: { ok: false, erro: 'Informe a conversa.' } };

  const { data: conv } = await supabase
    .from('conversas')
    .select('id, contato:contato_id (id, numero, foto_url), advogado:advogado_id (servidor, token)')
    .eq('id', conversaId).maybeSingle();
  if (!conv || !conv.contato || !conv.advogado) {
    return { status: 404, corpo: { ok: false, erro: 'Não achei essa conversa.' } };
  }
  if (!conv.advogado.token) {
    return { status: 503, corpo: { ok: false, erro: 'Este telefone não está conectado à Uazapi.' } };
  }
  // Grupo não tem foto de perfil de pessoa; pedir seria pedir o que não existe.
  const numero = String(conv.contato.numero || '');
  if (!numero || numero.startsWith('grupo:')) {
    return { status: 400, corpo: { ok: false, erro: 'Esta conversa não tem foto de perfil para buscar.' } };
  }

  const servidor = (conv.advogado.servidor || 'https://novaera.uazapi.com').replace(/\/$/, '');
  const { url } = await buscarFotoNaUazapi(servidor, conv.advogado.token, numero);
  if (!url) {
    return { status: 502, corpo: { ok: false,
      erro: 'Não consegui buscar a foto agora. Ela aparece maior sozinha na próxima mensagem deste contato.' } };
  }
  if (url === conv.contato.foto_url) {
    return { status: 200, corpo: { ok: true, foto_url: url, trocou: false } };
  }
  const { error } = await supabase.from('contatos').update({ foto_url: url }).eq('id', conv.contato.id);
  if (error) {
    return { status: 502, corpo: { ok: false, erro: 'Achei a foto, mas não consegui guardá-la.' } };
  }
  return { status: 200, corpo: { ok: true, foto_url: url, trocou: true } };
}));


// ------------------------------------------------------------
//  POR QUE FULANO NÃO VÊ AS CONVERSAS
//
//  A regra de visibilidade tem alguns elos, e quando um falha o sintoma é
//  sempre o mesmo: tela vazia. Sem esta rota, descobrir QUAL deles falhou exige
//  abrir o Supabase e escrever consulta — e quem administra o escritório não
//  faz isso. Aqui a resposta vem em português, com o passo que resolve.
//
//  Só admin abre: a resposta conta quem enxerga o quê.
// ------------------------------------------------------------
app.options('/permissoes/diagnostico', (req, res) => { liberarCors(res); res.sendStatus(204); });
app.get('/permissoes/diagnostico', rotaVantoro(async (req, usuario) => {
  const { data: eu } = await supabase
    .from('usuarios').select('admin').eq('id', usuario.id).maybeSingle();
  if (!eu || !eu.admin) {
    return { status: 403, corpo: { ok: false, erro: 'Só quem administra pode abrir este diagnóstico.' } };
  }

  const alvo = String(req.query.login || req.query.email || '').trim().toLowerCase();
  if (!alvo) return { status: 400, corpo: { ok: false, erro: 'Informe ?login=' } };

  const { data: pessoas } = await supabase
    .from('usuarios').select('id, login, nome, email, admin, ativo');
  const pessoa = (pessoas || []).find(
    (p) => String(p.login || '').toLowerCase() === alvo
        || String(p.email || '').toLowerCase() === alvo);

  if (!pessoa) {
    return { status: 200, corpo: { ok: true, problema:
      'Esta pessoa nunca entrou no Zorvin. A permissão é gravada aqui na primeira '
      + 'entrada dela — peça para ela fazer login uma vez.' } };
  }
  if (pessoa.admin) {
    return { status: 200, corpo: { ok: true, problema: null,
      resumo: 'É administradora: enxerga todas as conversas, independentemente de permissão.' } };
  }

  const { data: perms } = await supabase
    .from('permissoes').select('departamento_id, telefone_id').eq('usuario_id', pessoa.id);
  const { data: deps } = await supabase.from('departamentos').select('id, nome');
  const nomeDep = new Map((deps || []).map((d) => [d.id, d.nome]));

  // Telefone sem departamento é invisível para quem não é admin: a regra compara
  // o departamento da permissão com o do telefone, e comparar com vazio nunca dá
  // verdadeiro. É a causa que mais engana, porque a permissão ESTÁ lá.
  const { data: fones } = await supabase.from('advogados').select('*');
  const orfaos = (fones || []).filter((f) => !f.departamento_id);
  const nomeDoFone = (f) => f.nome || f.numero || f.id;

  const liberados = (perms || []).filter((p) => p.departamento_id)
    .map((p) => nomeDep.get(p.departamento_id) || `#${p.departamento_id}`);

  // Permissão por TELEFONE deixou de ser exceção: é o corte fino da tela do
  // Vantoro ("limitar a telefones específicos"), e quem está nele vê os números
  // marcados e mais nada. Antes esta rota tratava isso como defeito — dizia
  // "ela tem permissão só por telefone" como se faltasse alguma coisa, e quem
  // lia ia mexer numa configuração que estava certa.
  const nomeDoFone2 = new Map((fones || []).map((f) => [f.id, f.nome || f.numero || f.id]));
  const fonesLiberados = (perms || []).filter((p) => p.telefone_id)
    .map((p) => nomeDoFone2.get(p.telefone_id) || `#${p.telefone_id}`);

  let problema = null;
  if (!pessoa.ativo) {
    problema = 'O acesso dela está desativado aqui.';
  } else if (!perms || !perms.length) {
    problema = 'Não há permissão nenhuma gravada para esta pessoa. Confira se o '
             + 'departamento está marcado no cadastro dela no Vantoro — a Ponte '
             + 'reaplica a cada poucos minutos.';
  } else if (!liberados.length && !fonesLiberados.length) {
    problema = 'Há linhas de permissão, mas nenhuma aponta para departamento nem '
             + 'para telefone. É resto de uma versão antiga: salve o cadastro dela '
             + 'no Vantoro para a Ponte regravar.';
  } else if (orfaos.length && liberados.length) {
    problema = `Há ${orfaos.length} telefone(s) sem departamento definido `
             + `(${orfaos.slice(0, 5).map(nomeDoFone).join(', ')}). `
             + 'As conversas deles não aparecem para quem não é administrador — '
             + 'defina o departamento de cada telefone.';
  }

  return { status: 200, corpo: { ok: true, pessoa: pessoa.login, ativa: pessoa.ativo,
    departamentos_liberados: liberados,
    // Quando esta lista vem preenchida, a pessoa está no corte fino: ela vê
    // ESTES telefones e nada mais, e é por isso que os departamentos podem
    // aparecer vazios sem que haja nada errado.
    telefones_liberados: fonesLiberados,
    telefones_sem_departamento: orfaos.length, problema } };
}));

// ------------------------------------------------------------
//  CADA PASSO DA ENTRADA TEM PRAZO, E CADA PASSO APARECE NO LOG
//
//  A entrada é uma fila de cinco idas à rede: Vantoro, criar/achar a conta,
//  alinhar o nome, espelhar o usuário, gerar o bilhete. Só a primeira tinha
//  prazo. Qualquer uma das outras, travando, travava a entrada inteira — e o
//  log não dizia nada, porque nenhuma delas escreve ao começar.
//
//  Foi o que aconteceu numa manhã de expediente: "tentativa de rodrigo.sousa"
//  no log e depois silêncio; a tela esperou 75 segundos e desistiu, sem que
//  ninguém pudesse dizer QUAL passo estava pendurado.
//
//  Agora cada um tem prazo próprio e deixa no log quanto demorou. Uma entrada
//  que falha em cinco segundos dizendo onde falhou vale mais do que uma que
//  fica pendurada dando esperança.
// ------------------------------------------------------------
function comPrazo(promessa, ms, oQue) {
  return new Promise((resolve, reject) => {
    const relogio = setTimeout(
      () => reject(new Error(`o passo "${oQue}" não respondeu em ${Math.round(ms / 1000)}s`)), ms);
    Promise.resolve(promessa).then(
      (v) => { clearTimeout(relogio); resolve(v); },
      (e) => { clearTimeout(relogio); reject(e); });
  });
}

async function passoDaEntrada(oQue, ms, fazer) {
  const comecou = Date.now();
  try {
    const r = await comPrazo(fazer(), ms, oQue);
    console.log(`entrada · ${oQue}: ${Date.now() - comecou}ms`);
    return r;
  } catch (e) {
    console.error(`entrada · ${oQue}: FALHOU depois de ${Date.now() - comecou}ms — ${(e && e.message) || e}`);
    // O NOME DO PASSO VIAJA COM O ERRO, e não dentro do texto dele. O passo
    // falha de vários jeitos — prazo estourado aqui, prazo estourado lá dentro,
    // conexão recusada — e procurar o nome no meio da frase só acertaria o
    // primeiro. Numa propriedade, ele sobrevive a qualquer mensagem.
    const erro = (e instanceof Error) ? e : new Error(String(e));
    if (!erro.passo) erro.passo = oQue;
    throw erro;
  }
}

app.options('/auth/login', (req, res) => {
  liberarCors(res, req);
  // O PEDIDO DE PERMISSÃO, que vem ANTES do de verdade. Uma entrada com corpo
  // em JSON sempre manda este primeiro; se ele não passa, o pedido de verdade
  // nunca sai do navegador — e no log da ponte não aparece nada, porque nada
  // chegou. Registrado, ele separa "não chegou aqui" de "chegou e falhou".
  console.log(`entrada: pedido de permissão (OPTIONS) de "${req.headers.origin || 'sem origem'}"`);
  res.sendStatus(204);
});

app.post('/auth/login', async (req, res) => {
  liberarCors(res, req);
  const login = String((req.body && (req.body.login || req.body.email)) || '').trim();
  console.log(`entrada: tentativa de "${login || '(sem usuário)'}" de "${req.headers.origin || 'sem origem'}"`);
  const senha = String((req.body && req.body.senha) || '');
  if (!login || !senha) {
    return res.status(400).json({ ok: false, erro: 'Informe usuário e senha.' });
  }

  const chaveFreio = `${req.ip || 'sem-ip'}|${login.toLowerCase()}`;
  if (freioBateu(chaveFreio)) {
    return res.status(429).json({
      ok: false,
      erro: 'Muitas tentativas seguidas. Espere alguns minutos e tente de novo.',
    });
  }

  try {
    const { status, corpo } = await passoDaEntrada('perguntar ao Vantoro', 25000, () =>
      chamarVantoro('/auth/login', { method: 'POST', body: JSON.stringify({ login, senha }) }));
    if (status !== 200 || !corpo || !corpo.ok) {
      // Repassa 401/403 como vieram; qualquer outra coisa é problema nosso, e
      // dizer "usuário ou senha incorretos" quando o Vantoro está fora do ar
      // mandaria a equipe caçar um erro que não existe.
      if (status === 401 || status === 403) {
        return res.status(status).json({ ok: false, erro: (corpo && corpo.erro) || 'Login ou senha incorretos.' });
      }
      console.error('login: Vantoro respondeu', status, corpo && corpo.erro);
      return res.status(503).json({
        ok: false,
        erro: 'O Vantoro não respondeu agora — é ele quem confere a senha. Tente de novo em instantes.',
      });
    }

    const u = corpo.usuario;
    const email = String(u.email || '').toLowerCase();
    const id = await passoDaEntrada('conta no Supabase', 20000, () => contaDoSupabase(email, u.nome));

    // O NOME VEM DO CADASTRO DO VANTORO, SEMPRE.
    //
    // `contaDoSupabase` grava o nome só no dia em que a conta nasce. Quem
    // entrou antes de o Vantoro ter o nome completo ficou com o que havia na
    // hora — em geral o começo do e-mail ("rodrigo", "max") — e nada nunca
    // trocava aquilo. Era esse nome que assinava a bolha e que ia para o
    // Painel, e por isso a mesma pessoa aparecia duas vezes no relatório.
    //
    // Agora cada entrada realinha. É de propósito que a fonte seja o Vantoro:
    // é lá que o cadastro de pessoa mora e é lá que quem administra mexe. O
    // Zorvin não é dono do nome de ninguém.
    // ALINHAR O NOME SAI DO CAMINHO — sem `await` nenhum.
    //
    // Primeiro ele não tinha prazo e travava a entrada para sempre. Depois
    // ganhou prazo de 10 segundos, e aí passou a custar 10 segundos de espera
    // a CADA pessoa, todo dia, num serviço que estava lento — para escrever um
    // nome que ninguém está esperando.
    //
    // Ele fala com a mesma API de administração do Auth que hoje está doente.
    // E é a única coisa nesta rota que não precisa acontecer agora: a pessoa
    // entra com o nome de antes e a próxima entrada realinha.
    //
    // Mesmo tratamento que as permissões já recebiam duas linhas abaixo, e
    // pelo mesmo motivo: quem está digitando a senha não pode esperar por
    // sincronização.
    passoDaEntrada('alinhar o nome', 10000, () => alinharNomeDaConta(id, u.nome))
      .catch(() => {});

    // Espelha quem é a pessoa, para a tela de permissões mostrar nome em vez
    // de um código, e para as regras de visibilidade terem onde se apoiar.
    // `admin` do Vantoro manda: quem é superusuário lá administra aqui.
    const { error: erroUsuario } = await passoDaEntrada('espelhar o usuário', 15000, () =>
      supabase.from('usuarios').upsert({
        id, login: u.login, nome: u.nome || '', email,
        admin: Boolean(u.admin), ativo: true, visto_em: new Date().toISOString(),
      }, { onConflict: 'id' }));
    if (erroUsuario) {
      console.log(`login: não espelhei o usuário (${erroUsuario.message}). Falta rodar o SQL de departamentos?`);
    }

    // As duas metades que faltavam para a permissão do Vantoro valer aqui.
    // Rodam DEPOIS de espelhar o usuário (as permissões dependem da linha dele)
    // e sem `await` bloqueando a entrada: quem está digitando a senha não pode
    // esperar por sincronização. Se falharem, a pessoa entra com o que já
    // tinha, e a próxima entrada tenta de novo.
    mandarDepartamentosAoVantoro().catch(() => {});
    aplicarPermissoes(id, u).catch(() => {});

    // ------------------------------------------------------------
    //  ABRIR A SESSÃO — POR DOIS CAMINHOS, E O SEGUNDO NÃO DEPENDE DE NINGUÉM
    //
    //  O caminho de sempre é pedir um bilhete de uso único ao Auth do
    //  Supabase (`generateLink`); o painel troca por uma sessão na hora. É o
    //  caminho normal e continua sendo o primeiro, porque a sessão que sai
    //  dele se renova sozinha e dura o quanto a pessoa quiser ficar.
    //
    //  Só que era ele o ponto único de falha: em 19/08 o Auth ficou fora e
    //  ninguém entrou a manhã inteira. Então agora existe o segundo caminho —
    //  a própria ponte assina o bilhete, com o segredo do projeto — e a
    //  resposta leva os DOIS quando ambos estão disponíveis. O painel usa o
    //  primeiro que funcionar; se o Auth responder ao `generateLink` mas
    //  falhar no `verifyOtp`, ele ainda tem o outro no bolso.
    //
    //  O prazo caiu de 20 segundos (com uma segunda tentativa, 60 no total)
    //  para 8, e a segunda tentativa saiu. Ela existia porque desistir era
    //  não entrar; hoje desistir é entrar pelo outro caminho, e oito segundos
    //  esperando por um serviço doente já é tempo demais na cara de quem
    //  digitou a senha.
    // ------------------------------------------------------------
    const posso = souCapazDeAssinar();
    let hashDoBilhete = null;
    const bilhete = await passoDaEntrada('gerar o bilhete', posso ? 8000 : 20000, () =>
      supabase.auth.admin.generateLink({ type: 'magiclink', email })).catch(() => null);
    if (bilhete && bilhete.data && bilhete.data.properties && bilhete.data.properties.hashed_token) {
      hashDoBilhete = bilhete.data.properties.hashed_token;
    } else if (!posso) {
      // Sem segredo configurado não há segundo caminho: é aqui que a entrada
      // acaba, como acabava antes.
      console.error('login: generateLink falhou e não há SUPABASE_JWT_SECRET para assinar por conta própria.');
      return res.status(502).json({ ok: false, erro: 'Não consegui abrir a sessão. Tente de novo.' });
    } else {
      console.log('entrada: o Auth não deu o bilhete; assinando a sessão aqui mesmo.');
    }

    // A FOTO VAI JUNTO. O painel desenha o rostinho da pessoa no canto a
    // partir do que está na sessão; sem isto, quem entrasse pelo caminho
    // assinado veria as iniciais no lugar da foto e concluiria que o sistema
    // "perdeu" alguma coisa. É uma leitura de banco, que é a metade que fica
    // de pé — e se falhar, segue sem foto em vez de segurar a entrada.
    let fotoDaPessoa = null;
    if (posso) {
      try {
        const { data: eu } = await supabase.from('usuarios')
          .select('foto_url').eq('id', id).maybeSingle();
        fotoDaPessoa = (eu && eu.foto_url) || null;
      } catch (_e) { /* sem foto, e a entrada segue */ }
    }

    const sessao = posso
      ? assinarSessao({ id, email, nome: u.nome, login: u.login, foto: fotoDaPessoa })
      : null;

    freioLimpa(chaveFreio);
    // O FIM FELIZ TAMBÉM VAI PARA O LOG. Sem ele, "nenhuma linha de entrada no
    // log" tanto pode ser "ninguém tentou" quanto "todo mundo entrou" — e a
    // primeira vez que isso importou foi justamente numa manhã em que ninguém
    // conseguia entrar.
    console.log(`entrada: "${u.login}" entrou${hashDoBilhete ? '' : ' (pela sessão assinada aqui)'}.`);
    return res.json({
      ok: true,
      token_hash: hashDoBilhete,
      // A SESSÃO PRONTA. Vem SEM nada que sirva para renovar: o bilhete vale
      // doze horas e acabou. É de propósito — uma credencial de renovação
      // seria mais uma chave de longa vida circulando no navegador, e o que
      // ela compraria (não ter de entrar de novo no dia seguinte) não paga.
      sessao: sessao && {
        access_token: sessao.token,
        expira_em: sessao.expira_em,
        usuario_id: id,
      },
      email,
      usuario: { login: u.login, nome: u.nome, admin: Boolean(u.admin) },
    });
  } catch (e) {
    const motivo = (e && e.message) || String(e);
    console.error('entrada: FALHOU —', motivo);

    // O SUPABASE TEM DUAS METADES, E ELAS CAEM SEPARADAS.
    //
    // Banco e autenticação são serviços diferentes atrás do mesmo endereço. Em
    // 19/08 o banco respondeu em 168ms enquanto o `/auth/v1/*` devolvia erro
    // 521 do Cloudflare — "o servidor de origem não está respondendo". Metade
    // do projeto de pé, metade no chão.
    //
    // Sem isto, a tela mandava "tente de novo" para uma coisa que não vai dar
    // certo tentando de novo: o escritório inteiro repetindo a senha, achando
    // que errou. "Não é a sua senha" é a informação que falta.
    // SÓ SOBROU UM PASSO QUE O AUTH PODE DERRUBAR, e ele só acontece com
    // quem NUNCA entrou: é a criação da conta. "Alinhar o nome" e "gerar o
    // bilhete" também falam com o Auth, mas hoje os dois são contornados —
    // o primeiro sai do caminho sem `await`, o segundo tem a sessão assinada
    // aqui como saída. Nenhum dos dois chega até este ponto.
    const PASSOS_DO_AUTH = ['conta no Supabase'];
    if (e && e.passo && PASSOS_DO_AUTH.includes(e.passo)) {
      console.error('entrada: a AUTENTICAÇÃO do Supabase não está respondendo (o banco está). '
                  + 'Reinicie o projeto em Settings → General → Restart project, '
                  + 'e confira status.supabase.com.');
      return res.status(503).json({
        ok: false,
        erro: 'O serviço de autenticação está fora do ar — não é a sua senha. '
            + 'Isto só atrapalha quem está entrando no Zorvin pela primeira vez; '
            + 'quem já entrou alguma vez consegue. Avise quem administra.',
      });
    }
    // O PASSO VAI NA RESPOSTA. Quem está na porta não precisa do detalhe
    // técnico, mas precisa saber que não foi a senha dele — e quem administra
    // precisa saber ONDE. Sem isso o relato volta como "não entrou", que é
    // onde esta manhã começou.
    return res.status(502).json({
      ok: false,
      erro: e && e.passo
        ? `Não foi possível entrar agora: ${e.passo} não respondeu. Tente de novo.`
        : 'Não foi possível entrar agora. Tente de novo.',
    });
  }
});

// ============================================================
//  FRENTES — de quem é esta conversa?
//
//  O mesmo número de advogado atende duas coisas opostas: negociar acordo com
//  o escritório do réu e avisar/atender o próprio cliente. Separar pelo número
//  não funciona; quem define é quem está do outro lado, e isso o Vantoro sabe.
//
//    CLIENTE       — é um cliente nosso (SAC, audiências)
//    ACORDO        — é o advogado da parte contrária, ou a própria parte
//    LEAD          — não é conhecido e escreveu vindo de um anúncio
//    INTERNO       — chegou num número nosso de uso interno (RH, cadastro)
//    DESCONHECIDA  — ainda não deu para saber
//
//  A frente fica gravada no CONTATO (quem a pessoa é não muda de advogado para
//  advogado) e é copiada para a CONVERSA, que é onde o painel filtra.
// ============================================================

// Reclassifica um contato no máximo uma vez por semana. A resposta quase nunca
// muda, e perguntar ao Vantoro a cada mensagem só atrasaria o webhook.
const FRENTE_VALIDADE_MS = 7 * 24 * 60 * 60 * 1000;

// Marcas que a Uazapi manda quando a conversa começou por um anúncio de
// clique-para-WhatsApp. Não é lista fechada: por isso procuramos no JSON todo.
const MARCAS_DE_ANUNCIO = ['externaladreply', 'sourceurl', 'sourceid', 'ctwa', 'referral'];

function veioDeAnuncio(body) {
  try {
    const blob = JSON.stringify(body || {}).toLowerCase();
    return MARCAS_DE_ANUNCIO.some((marca) => blob.includes(marca));
  } catch (_e) {
    return false;
  }
}

// Grava colunas que talvez ainda não existam (o SQL das frentes pode não ter
// sido rodado). Isso nunca pode derrubar a entrada de mensagens: conversa sem
// etiqueta é um contratempo; mensagem perdida, não.
// Coluna que não existe é problema PERMANENTE — só passa quando alguém roda o
// SQL. Continuar tentando a cada mensagem não conserta nada e enche o log do
// Postgres de erro, que é onde um erro de verdade precisaria ser visto. Então a
// primeira recusa por coluna inexistente desliga aquela gravação até o próximo
// restart da ponte (que é quando o SQL novo teria sido rodado, de todo modo).
//
// Erro de rede NÃO entra nesta conta: esse passa sozinho, e desligar por causa
// dele deixaria a etiqueta parada por horas sem motivo.
const SEM_ESSA_COLUNA = ['42703', '42P01', 'PGRST204', 'PGRST200'];
const faltaColuna = (erro) => Boolean(erro) && (
  SEM_ESSA_COLUNA.includes(String(erro.code)) ||
  /does not exist|could not find|schema cache/i.test(String(erro.message || '')));

const GRAVACOES_DESLIGADAS = new Set();

async function gravarTolerante(tabela, campos, filtro, rotulo) {
  const chave = tabela + ':' + Object.keys(campos).sort().join(',');
  if (GRAVACOES_DESLIGADAS.has(chave)) return false;

  const { error } = await supabase.from(tabela).update(campos).match(filtro);
  if (!error) return true;

  if (faltaColuna(error)) {
    GRAVACOES_DESLIGADAS.add(chave);
    console.log(`${rotulo}: a coluna não existe (${error.message}). `
      + 'Parei de tentar até a ponte reiniciar — rode o SQL das frentes no Supabase.');
  } else {
    console.log(`${rotulo}: não gravei agora (${error.message}). Tento na próxima.`);
  }
  return false;
}

// ------------------------------------------------------------
//  O VANTORO MUDO NÃO É PERGUNTADO A CADA MENSAGEM
//
//  A classificação pergunta ao Vantoro quem é a pessoa do outro lado. Ele roda
//  no plano gratuito da Render e DORME; fora do horário de trabalho, e nos fins
//  de semana, está dormindo de propósito.
//
//  Cada pergunta a um serviço que não responde custa o tempo limite inteiro —
//  20 segundos, e mais 6 de espera com outra tentativa quando a resposta tem
//  cara de serviço acordando. Numa rajada de mensagens de sábado, isso é uma
//  fila de esperas de meio minuto, todas destinadas a falhar, todas contra o
//  mesmo serviço que já se sabe fora do ar.
//
//  Então a primeira falha cala o Vantoro por alguns minutos: nesse tempo a
//  classificação é simplesmente pulada, e a mensagem entra na conversa como
//  entra hoje. A etiqueta sai na próxima mensagem daquele contato, que é
//  exatamente o que já acontecia quando a chamada falhava.
//
//  CINCO MINUTOS porque é o bastante para uma rajada inteira passar sem
//  perguntar, e pouco para o serviço voltar a ser tentado no mesmo expediente.
//
//  E SÓ CALA QUEM NÃO RESPONDEU. Um 404 ou um 400 são respostas — o Vantoro
//  está de pé e disse alguma coisa. Calar por causa deles esconderia um erro de
//  configuração atrás de um silêncio de cinco minutos.
// ------------------------------------------------------------
const VANTORO_MUDO_MS = 5 * 60 * 1000;
let vantoroMudoAte = 0;
let avisadoVantoroMudo = 0;

// UMA PERGUNTA DE CADA VEZ — e é isto que faz o freio valer numa RAJADA.
//
// O freio acima só age depois que a primeira chamada VOLTA. Contra um serviço
// dormindo, ela demora 26 segundos (20 do tempo limite, mais 6 da espera com
// segunda tentativa) — e como a classificação agora corre por fora, as
// mensagens que chegarem nesse meio-tempo disparam a delas antes de o freio
// existir. Medido na bancada: três mensagens, três perguntas, com o Vantoro
// fora do ar desde a primeira.
//
// Com esta trava, a segunda mensagem da rajada não pergunta: ela vê que já há
// uma pergunta em voo e passa. A etiqueta dela sai na próxima mensagem daquele
// contato, que é o mesmo destino que ela teria se a chamada falhasse.
//
// O QUE ISSO CUSTA NO DIA NORMAL é quase nada: com o Vantoro de pé a resposta
// vem em milissegundos, e a janela em que duas mensagens se cruzam é dessa
// ordem. O que se ganha é a ponte deixando de martelar um serviço gratuito que
// já está no chão.
let classificacaoEmVoo = false;

function vantoroEstaMudo() { return Date.now() < vantoroMudoAte; }

function calarOVantoro(motivo) {
  vantoroMudoAte = Date.now() + VANTORO_MUDO_MS;
  // Uma linha por janela: repetir a cada mensagem afogaria o log justamente
  // quando ele é o único lugar onde dá para ver o que está acontecendo.
  if (Date.now() - avisadoVantoroMudo < VANTORO_MUDO_MS) return;
  avisadoVantoroMudo = Date.now();
  console.warn(`Frente: o Vantoro não respondeu (${motivo || 'sem detalhe'}). `
    + `Não vou perguntar a ele por ${Math.round(VANTORO_MUDO_MS / 60000)} minutos. `
    + 'As mensagens continuam entrando normalmente; o que fica sem etiqueta agora '
    + 'ganha a dela na próxima mensagem daquele contato.');
}

/** Pergunta a frente ao Vantoro.
 *
 *  Devolve `{ corpo }` quando ele respondeu, e `{ mudo: true }` quando não
 *  houve resposta — que são coisas diferentes e pedem reações diferentes. Antes
 *  as duas viravam `null`, e por isso não havia como saber se valia a pena
 *  perguntar de novo na mensagem seguinte. */
async function perguntarFrenteAoVantoro(numero) {
  try {
    const { status, corpo } = await chamarVantoro(
      `/contatos/classificar?telefone=${encodeURIComponent(numero)}`);
    if (status === 200 && corpo && corpo.ok) return { corpo };
    // 5xx é serviço com problema; 503 é também o que a própria ponte devolve
    // quando a integração não está configurada — nos dois casos, insistir a
    // cada mensagem não leva a lugar nenhum.
    return { corpo: null, mudo: status >= 500, motivo: `respondeu ${status}` };
  } catch (e) {
    // Tempo esgotado, conexão recusada, endereço que não resolve.
    return { corpo: null, mudo: true, motivo: (e && e.message) || String(e) };
  }
}

/**
 * Descobre e grava a frente desta conversa.
 *
 * Ordem de decisão, da mais forte para a mais fraca:
 *   1. o número NOSSO que recebeu é de uso interno  → a frente dele manda;
 *   2. o Vantoro reconhece a pessoa                 → CLIENTE ou ACORDO;
 *   3. veio de anúncio e ninguém conhece            → LEAD;
 *   4. nada disso                                   → DESCONHECIDA.
 */
async function definirFrente(contato, advogado, conversaId, body) {
  try {
    if (advogado.frente_fixa) {
      await gravarTolerante('conversas', { frente: advogado.frente_fixa },
        { id: conversaId }, 'frente da conversa');
      return advogado.frente_fixa;
    }

    const recente = contato.frente_em &&
      (Date.now() - new Date(contato.frente_em).getTime()) < FRENTE_VALIDADE_MS;
    let frente = contato.frente || null;

    if (!recente && !vantoroEstaMudo() && !classificacaoEmVoo) {
      classificacaoEmVoo = true;
      const { corpo: resposta, mudo, motivo } =
        await perguntarFrenteAoVantoro(contato.numero).finally(() => { classificacaoEmVoo = false; });
      if (mudo) calarOVantoro(motivo);
      if (resposta) {
        frente = resposta.frente;
        if (frente === 'DESCONHECIDA' && veioDeAnuncio(body)) frente = 'LEAD';
        await gravarTolerante('contatos', {
          frente,
          frente_em: new Date().toISOString(),
          vantoro_cliente_id: resposta.cliente ? resposta.cliente.id : null,
          vantoro_nome: resposta.cliente ? resposta.cliente.nome : null,
        }, { id: contato.id }, 'frente do contato');
      }
    }

    if (frente) {
      await gravarTolerante('conversas', { frente }, { id: conversaId }, 'frente da conversa');
    }
    return frente;
  } catch (e) {
    // Classificar é um extra. Se o Vantoro estiver fora do ar, a mensagem
    // continua entrando normalmente e a etiqueta sai na próxima.
    console.log('Frente: não consegui classificar agora —', (e && e.message) || e);
    return null;
  }
}

// ============================================================
//  GRUPOS DENTRO DO DEPARTAMENTO
//
//  O departamento diz de QUEM é o telefone (Advogados, SAC, Vendas). O grupo
//  diz que TIPO de conversa é aquela — e essa é a distinção que o telefone
//  sozinho nunca dá: no departamento Advogados, o mesmo número negocia acordo
//  com o réu e avisa o cliente da audiência.
//
//  Quem separa é quem está do outro lado, e isso a frente já respondeu. Aqui
//  só se traduz frente → grupo daquele departamento, com um balaio para o que
//  não se encaixar.
// ============================================================

// O GRUPO SAIU — e com ele a etiqueta que ninguém tinha criado.
//
// O grupo existia para um problema só: no departamento Advogados, os MESMOS
// telefones negociavam acordo com o réu e avisavam o cliente da audiência —
// duas conversas de natureza oposta no mesmo número. O aviso de audiência passou
// a sair de um telefone próprio, e aí o telefone voltou a responder a pergunta
// sozinho. O `sql/2026-07-sem-grupos.sql` já tinha tirado o grupo da permissão
// por isso; ficava só o carimbo na tela.
//
// E o carimbo era o pior pedaço: na lista, ele ficava idêntico às tags que a
// equipe cria à mão. "Sem identificar" — o balaio de quem ainda não tem ficha —
// caía em quase toda conversa, uma etiqueta dizendo "não sei" em cada linha.
//
// Gravar `conversas.grupo_id` a cada mensagem virou escrita que ninguém lê. Sai
// junto: é um UPDATE por mensagem recebida.

// O painel pergunta a frente de um número (para mostrar o selo na hora).
app.get('/vantoro/classificar', rotaVantoro(async (req) => {
  const telefone = String(req.query.telefone || '').replace(/\D/g, '');
  if (!telefone) return { status: 400, corpo: { ok: false, erro: 'Informe o telefone.' } };
  return chamarVantoro(`/contatos/classificar?telefone=${telefone}`);
}));

// ============================================================
//  AVISOS DE AUDIÊNCIA
//
//  O Vantoro monta a fila (quem avisar, o que dizer, de qual advogado sai) e a
//  ponte só executa: enfileira em fila_envio e, quando a Uazapi confirmar,
//  avisa o Vantoro de volta. Marcar como enviado na hora de enfileirar seria
//  mentira — a mensagem ainda não saiu.
// ============================================================

// A API de clientes fica em /cadastro/api/v1 e a de audiências em
// /audiencias/api/v1. Deriva uma da outra para não exigir mais uma variável;
// VANTORO_AUDIENCIAS_URL existe como escape se o endereço fugir do padrão.
const VANTORO_AUDIENCIAS = (process.env.VANTORO_AUDIENCIAS_URL ||
  VANTORO_URL.replace(/\/cadastro\/api\/v1$/, '/audiencias/api/v1')).replace(/\/+$/, '');

async function chamarAudiencias(caminho, opcoes = {}) {
  if (!VANTORO_AUDIENCIAS || !VANTORO_TOKEN) return { status: 503, corpo: null };
  const r = await fetchComTimeout(`${VANTORO_AUDIENCIAS}${caminho}`, {
    ...opcoes,
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${VANTORO_TOKEN}`,
      ...(opcoes.headers || {}),
    },
  }, 20000);
  let corpo = null;
  try { corpo = await r.json(); } catch (_e) { corpo = null; }
  return { status: r.status, corpo };
}

async function avisoDeuErro(id, motivo) {
  try {
    await chamarAudiencias(`/avisos/${id}/erro`,
      { method: 'POST', body: JSON.stringify({ motivo }) });
  } catch (_e) { /* segue pendente no Vantoro; tentamos de novo no próximo ciclo */ }
}

// O Vantoro manda o número sem o código do país; a Uazapi quer com ele.
function numeroComPais(digitos) {
  const d = String(digitos || '').replace(/\D/g, '');
  if (!d) return '';
  return d.startsWith('55') ? d : `55${d}`;
}

let avisosRodando = false;
async function buscarAvisosDeAudiencia() {
  if (desligando) return;   // saindo do ar: os avisos continuam pendentes no Vantoro
  if (avisosRodando) return;
  avisosRodando = true;
  try {
    const { status, corpo } = await chamarAudiencias('/avisos/pendentes');
    if (status !== 200 || !corpo || !corpo.ok) return;
    const avisos = corpo.avisos || [];
    if (!avisos.length) return;
    console.log(`Audiências: ${avisos.length} aviso(s) para enviar.`);

    for (const aviso of avisos) {
      const destino = numeroComPais(aviso.telefone);
      if (!destino) {
        await avisoDeuErro(aviso.id, 'Cliente sem número de WhatsApp no cadastro.');
        continue;
      }

      // DE QUAL WHATSAPP ESTA MENSAGEM SAI.
      //
      // O Vantoro manda o NÚMERO da linha de audiências — todos os avisos saem
      // por ela, para o histórico do cliente não ficar espalhado por um número
      // diferente a cada advogado. Casamos pela chave do número, que tolera as
      // formas com e sem o 55 e com e sem o nono dígito.
      //
      // O nome continua aceito, e por isso a busca antiga ficou como segunda
      // tentativa: avisos já enfileirados antes desta mudança trazem o nome do
      // advogado da ação, e recusá-los faria o cliente não ser avisado por
      // causa de uma troca que é nossa, não dele.
      const pedido = String(aviso.remetente || '').trim();
      let adv = null;
      if (/^[\d\s()+-]+$/.test(pedido) && pedido.replace(/\D/g, '').length >= 10) {
        const { data: todos } = await supabase.from('advogados').select('id, nome, numero');
        adv = (todos || []).find((a) => chaveDoNumero(a.numero) === chaveDoNumero(pedido)) || null;
      } else if (pedido) {
        const { data } = await supabase.from('advogados')
          .select('id, nome').ilike('nome', `%${pedido}%`).limit(1).maybeSingle();
        adv = data || null;
      }
      if (!adv) {
        await avisoDeuErro(aviso.id,
          `Telefone "${pedido || '(em branco)'}" não encontrado no Zorvin.`);
        continue;
      }

      const { data: contato } = await supabase.from('contatos')
        .upsert({ numero: destino }, { onConflict: 'numero' }).select('id').single();
      if (!contato) { await avisoDeuErro(aviso.id, 'Não consegui criar o contato.'); continue; }

      const { data: conversa } = await supabase.from('conversas')
        .upsert({ advogado_id: adv.id, contato_id: contato.id },
          { onConflict: 'advogado_id,contato_id' }).select('id').single();
      if (!conversa) { await avisoDeuErro(aviso.id, 'Não consegui abrir a conversa.'); continue; }

      // Já nasce etiquetada: é conversa com CLIENTE, não negociação de acordo.
      await gravarTolerante('conversas', { frente: aviso.finalidade || 'CLIENTE' },
        { id: conversa.id }, 'frente do aviso');

      // aviso_vantoro_id tem índice único: se este ciclo repetir antes de a fila
      // ser processada, o banco recusa a segunda cópia e o cliente não recebe a
      // mesma mensagem duas vezes.
      const { error: filaErro } = await supabase.from('fila_envio').insert({
        conversa_id: conversa.id, texto: aviso.texto,
        status: 'pendente', tipo: 'texto', aviso_vantoro_id: aviso.id,
      });
      if (filaErro) {
        console.log(`Aviso ${aviso.id}: não entrou na fila (${filaErro.message}).`);
        continue;
      }
      console.log(`Aviso ${aviso.id} enfileirado para ${destino} por ${adv.nome}.`);
    }
  } catch (e) {
    console.error('Avisos de audiência:', (e && e.message) || e);
  } finally {
    avisosRodando = false;
  }
}

// Roda a verificação da fila a cada 3 segundos.
setInterval(processarFilaDeEnvio, 3000);

// A caixa de entrada é varrida de meio em meio minuto. Não precisa ser rápida:
// o caminho normal trata o evento no instante em que ele chega, e esta rodada
// só existe para o que NÃO terminou. Meio minuto depois de uma publicação, o
// que ficou pela metade já está de volta na conversa.
const CAIXA_INTERVALO_MS = Number(process.env.CAIXA_INTERVALO_MS) || 30 * 1000;
setInterval(() => { terminarOsPendentes().catch(() => {}); }, CAIXA_INTERVALO_MS);
// E uma logo depois de subir: o caso mais comum de evento pela metade é
// exatamente a ponte ter sido derrubada no meio dele.
setTimeout(() => { terminarOsPendentes().catch(() => {}); }, 5000).unref();

// Os avisos de audiência mudam de hora em hora, não de segundo em segundo:
// 5 minutos é de sobra e não pesa no plano free.
setInterval(buscarAvisosDeAudiencia, 5 * 60 * 1000);

// ------------------------------------------------------------
//  MANTER O VANTORO ACORDADO — no horário de trabalho, e só nele
//
//  O plano gratuito da Render hiberna o serviço parado. A primeira chamada
//  depois disso recebe uma PÁGINA DE ERRO enquanto o Django acorda por baixo, e
//  do lado de cá isso vira "Resposta inválida do Vantoro": a ficha do cliente
//  falha sem motivo e volta sozinha minutos depois.
//
//  A ponte já é mantida acordada por um cronjob de fora. Ela aproveita o mesmo
//  ciclo para bater no /ping do Vantoro — sem serviço novo, sem custo novo.
//
//  POR QUE NÃO O DIA INTEIRO. O plano gratuito dá 750 horas de máquina por mês
//  para o workspace, e são DOIS serviços. Acordado 24 horas, cada um consome
//  ~730 h/mês: os dois juntos passam de 1400 e estouram a franquia — seria
//  trocar o problema do sono pelo problema da conta.
//
//  Numa janela de 13 horas em dia útil, o Vantoro fica em ~290 h/mês e sobra
//  espaço para a ponte. Fora do horário ele dorme, e quem entrar às 23h espera
//  o primeiro acesso acordar — que é exatamente o comportamento de hoje, só que
//  agora restrito às horas em que quase ninguém usa.
//
//  A janela é configurável porque quem sabe o horário do escritório não é quem
//  escreve isto.
const VANTORO_ACORDADO_DE = Number(process.env.VANTORO_ACORDADO_DE || 7);
const VANTORO_ACORDADO_ATE = Number(process.env.VANTORO_ACORDADO_ATE || 20);
const VANTORO_ACORDADO_SABADO = String(process.env.VANTORO_ACORDADO_SABADO || '1') === '1';

function dentroDoHorarioDeTrabalho(agora = new Date()) {
  // Em SÃO PAULO, não em UTC. A máquina da Render roda em UTC, e uma janela
  // calculada nela abriria às 4h da manhã e fecharia às 17h — justamente na
  // hora em que o escritório ainda está trabalhando.
  const partes = new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/Sao_Paulo', hour: 'numeric', hour12: false, weekday: 'short',
  }).formatToParts(agora);
  const hora = Number(partes.find((p) => p.type === 'hour').value);
  const dia = partes.find((p) => p.type === 'weekday').value;
  if (dia === 'Sun') return false;
  if (dia === 'Sat' && !VANTORO_ACORDADO_SABADO) return false;
  return hora >= VANTORO_ACORDADO_DE && hora < VANTORO_ACORDADO_ATE;
}

async function manterVantoroAcordado() {
  if (!VANTORO_URL || !dentroDoHorarioDeTrabalho()) return;
  try {
    // O /ping do Vantoro não pede token: responde 200 vazio, sem banco e sem
    // sessão. Mandar o token aqui seria expô-lo numa chamada que não precisa.
    await fetchComTimeout(`${VANTORO_URL.replace(/\/$/, '')}/ping`, {}, 15000);
  } catch (_e) {
    // Em silêncio de propósito: falhar em acordar não é problema para reportar,
    // é o estado normal enquanto o serviço sobe. O que interessa reclamar é a
    // chamada de verdade falhando — e essa já reclama, com o motivo.
  }
}

// A Render hiberna com ~15 minutos de inatividade. 10 minutos deixa margem para
// uma batida perdida sem o serviço chegar a dormir.
setInterval(manterVantoroAcordado, 10 * 60 * 1000).unref();
manterVantoroAcordado();

const port = process.env.PORT || 3000;
// ------------------------------------------------------------
//  AO SUBIR, A PONTE DIZ SE SABE ASSINAR A SESSÃO
//
//  A saída para o Auth fora do ar só aparece no dia em que o Auth cair. Até
//  lá, ligada ou desligada, a ponte se comporta igual — e quem configurou a
//  variável não tem como saber se acertou. Descobrir no dia seria descobrir
//  do pior jeito.
//
//  E MAIS UMA CONFERÊNCIA, que vale a ida à rede: se o projeto tiver migrado
//  para chave assimétrica (o Supabase oferece isso num botão chamado
//  "Migrate JWT secret"), o banco passa a recusar os bilhetes assinados aqui —
//  eles são HS256. A saída continuaria existindo no código e não funcionaria
//  mais, em silêncio, até o dia em que fosse precisa. Uma linha no log no dia
//  da migração é o aviso mais barato que existe.
//
//  A lista de chaves é pública de propósito (é assim que qualquer um confere
//  uma assinatura), então não há nada de sigiloso nesta chamada. Ela é
//  best-effort: falhando, não diz nada e não atrapalha nada.
// ------------------------------------------------------------
async function contarComoEstaAEntrada() {
  if (!souCapazDeAssinar()) {
    console.log('entrada: SUPABASE_JWT_SECRET não está configurada. A entrada '
              + 'funciona normalmente, mas se o Auth do Supabase cair de novo '
              + 'ninguém entra — foi o que houve em 19/08. O valor está em '
              + 'Settings → JWT Keys → Legacy JWT Secret.');
    return;
  }
  console.log('entrada: sei assinar a sessão por conta própria — se o Auth do '
            + 'Supabase cair, o escritório continua entrando.');

  const base = String(process.env.SUPABASE_URL || '').replace(/\/+$/, '');
  if (!base) return;
  try {
    const r = await fetchComTimeout(`${base}/auth/v1/.well-known/jwks.json`, {}, 8000);
    const corpo = await r.json();
    const chaves = (corpo && corpo.keys) || [];
    const assimetricas = chaves.filter((k) => k && k.kty && k.kty !== 'oct');
    if (assimetricas.length) {
      console.error('entrada: ATENÇÃO — este projeto do Supabase passou a assinar com chave '
                  + `assimétrica (${assimetricas.map((k) => k.alg || k.kty).join(', ')}). `
                  + 'Os bilhetes que a ponte assina são HS256 e o banco vai recusá-los, '
                  + 'então a saída para o Auth fora do ar deixou de funcionar. '
                  + 'Isso precisa ser refeito antes da próxima queda.');
    }
  } catch (_e) {
    // Sem resposta agora não quer dizer nada: pode ser justamente o Auth fora
    // do ar, que é o dia para o qual tudo isto existe.
  }
}

// ============================================================
//  QUAL VERSÃO ESTÁ NO AR
//
//  Em 20/08 uma correção ficou pronta, mesclada, e NÃO estava rodando. A
//  Render não publicou, e ninguém tinha como saber: o repositório dizia uma
//  coisa e o serviço fazia outra, sem nenhuma diferença visível.
//
//  Só descobrimos por acidente. Uma frase de log tinha mudado de "Permissões:
//  reaplicadas para N usuário(s)" para outra, e a antiga continuava aparecendo
//  no log de produção. Foi essa coincidência — uma frase que por acaso mudou —
//  que revelou o descompasso. Sem ela, a correção da lentidão do anexo teria
//  ficado meses parada, com todo mundo achando que estava no ar.
//
//  Não dá para depender de coincidência. Agora a ponte diz, ao subir, qual
//  versão ela é. Um deploy sempre reinicia o serviço, então esta linha aparece
//  toda vez que algo é publicado — e o commit ao lado dela responde, em um
//  segundo, à pergunta "o que está rodando agora?".
//
//  `RENDER_GIT_COMMIT` é dado pela própria Render. Fora dela a variável não
//  existe, e aí vale a data de escrita do arquivo — que não identifica o
//  commit, mas denuncia um deploy velho, que é o que se quer pegar.
// ============================================================
function comoMeChamo() {
  const commit = String(process.env.RENDER_GIT_COMMIT || '').trim();
  const ramo = String(process.env.RENDER_GIT_BRANCH || '').trim();
  const partes = [];
  if (commit) partes.push(`commit ${commit.slice(0, 8)}`);
  if (ramo) partes.push(`ramo ${ramo}`);
  try {
    const { mtime } = require('fs').statSync(__filename);
    partes.push(`arquivo de ${mtime.toISOString().slice(0, 16).replace('T', ' ')}`);
  } catch (_) { /* sem data: o resto já serve */ }
  return partes.length ? partes.join(' · ')
    : 'não sei dizer (sem RENDER_GIT_COMMIT e sem data de arquivo)';
}

const servidor = app.listen(port, () => {
  console.log('Ponte do Zorvin rodando na porta', port);
  console.log(`versão no ar: ${comoMeChamo()}`);
  contarComoEstaAEntrada().catch(() => {});
});

// ============================================================
//  SAIR COM CALMA — O QUE ESTÁ NO MEIO TERMINA ANTES
//
//  Toda publicação passa por aqui, e são várias por semana. Até agora a saída
//  era um tiro: a Render manda SIGTERM, o Node não trata, e o processo morre no
//  mesmo instante — com o que estivesse em andamento.
//
//  O QUE SE PERDIA, e não é hipótese: o webhook responde "OK" à Uazapi ANTES de
//  gravar (para ela não reenviar). Entre o "OK" e a linha no banco há algumas
//  idas à rede: achar o telefone, o contato, a conversa, classificar, gravar.
//  Morrer nesse intervalo é a mensagem do cliente sumindo — a Uazapi a
//  considera entregue, e aqui não fica rastro nenhum de que ela existiu.
//
//  Do outro lado, um envio que a Uazapi já aceitou e cuja marca de "enviada"
//  ainda não chegou ao banco fica preso em "enviando"; cinco minutos depois a
//  recuperação o devolve para a fila e o cliente recebe a mesma mensagem duas
//  vezes.
//
//  A ORDEM AQUI IMPORTA, e é ela que faz isto funcionar:
//
//    1. `desligando = true` — a partir daqui nenhum ciclo de fila, nenhuma
//       rodada de permissões e nenhum aviso de audiência COMEÇA. Só termina o
//       que já estava correndo;
//    2. a porta fecha para conexões novas. A ponte nova já está subindo, e é
//       ela que atende quem chegar agora;
//    3. espera-se o que está em voo: os webhooks sendo gravados e o ciclo da
//       fila. É a espera inteira do valor deste trecho;
//    4. sai com 0. Sair sozinho, e não esperar o SIGKILL, é o que faz a
//       publicação seguinte não levar nove segundos de carência à toa.
//
//  O PRAZO É UM TETO, não uma promessa: se algo estiver mesmo pendurado, a
//  ponte sai assim mesmo, dizendo no log o que ficou pela metade. Ficar
//  esperando para sempre daria no mesmo tiro, só que mais tarde e com a Render
//  puxando o gatilho.
//
//  25 segundos porque a Render dá 30 antes de matar à força. Sai da variável
//  para a bancada poder encurtá-lo: provar isto esperando 25 segundos de
//  verdade seria uma prova que ninguém roda — e prova que ninguém roda é o
//  defeito que a integração contínua acabou de vir resolver.
// ============================================================
const PRAZO_PARA_SAIR_MS = Number(process.env.DESLIGAR_PRAZO_MS) || 25000;

async function desligarComCalma(sinal) {
  // Dois sinais seguidos (a Render insiste) não podem reiniciar a contagem.
  if (desligando) return;
  desligando = true;
  const comecou = Date.now();
  console.log(`${sinal} recebido: a ponte vai sair. `
    + `Não começo nada novo; termino o que está no meio (até ${Math.round(PRAZO_PARA_SAIR_MS / 1000)}s).`);

  // Fecha a porta para conexões novas. As que já estão abertas seguem até o
  // fim — é o que `close` faz, e é o que se quer: recusar quem chega, sem
  // cortar quem está sendo atendido.
  try { servidor.close(); } catch (_e) { /* já fechada: segue */ }

  const limite = comecou + PRAZO_PARA_SAIR_MS;
  while ((webhooksEmVoo > 0 || filaRodando) && Date.now() < limite) {
    await new Promise((ok) => setTimeout(ok, 50));
  }

  const demorou = Date.now() - comecou;
  if (webhooksEmVoo > 0 || filaRodando) {
    // O QUE FICOU PELA METADE VAI DITO. Um desligamento que estoura o prazo em
    // silêncio é indistinguível de um que terminou tudo — e os dois pedem
    // coisas opostas de quem for investigar uma mensagem que sumiu.
    console.error(`Desligamento: o prazo de ${Math.round(PRAZO_PARA_SAIR_MS / 1000)}s acabou e ainda havia `
      + `${webhooksEmVoo} webhook(s) sendo gravado(s)${filaRodando ? ' e um ciclo da fila aberto' : ''}. `
      + 'Saindo assim mesmo. Se alguma mensagem faltar, foi aqui.');
  } else {
    console.log(`Desligamento: nada ficou no meio (${demorou}ms). Saindo.`);
  }
  process.exit(0);
}

// SIGTERM é o que a Render manda ao publicar; SIGINT é o Ctrl+C de quem roda a
// ponte na própria máquina. Os dois merecem o mesmo cuidado.
process.on('SIGTERM', () => { desligarComCalma('SIGTERM').catch(() => process.exit(0)); });
process.on('SIGINT', () => { desligarComCalma('SIGINT').catch(() => process.exit(0)); });
