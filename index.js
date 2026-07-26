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
app.use(express.json({ limit: '15mb' }));

// Rede de segurança: um erro assíncrono não tratado NÃO pode derrubar a ponte
// (é um único processo no plano free do Render). Registra e segue vivo.
process.on('unhandledRejection', (err) => {
  console.error('unhandledRejection:', (err && err.message) || err);
});
process.on('uncaughtException', (err) => {
  console.error('uncaughtException:', (err && err.message) || err);
});

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
);

// fetch com timeout: evita que uma chamada à Uazapi fique pendurada e
// segure a fila. Aborta após `ms` milissegundos.
async function fetchComTimeout(url, opts = {}, ms = 15000) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), ms);
  try {
    return await fetch(url, { ...opts, signal: ctrl.signal });
  } finally {
    clearTimeout(t);
  }
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
function tipoDaMidiaHist(m) {
  const mt = String(m.mediaType || m.messageType || m.type || '').toLowerCase();
  if (mt.includes('image')) return 'imagem';
  if (mt === 'ptt' || mt.includes('audio')) return 'audio';
  if (mt.includes('video')) return 'video';
  if (mt.includes('document') || mt.includes('file')) return 'documento';
  return 'texto';
}
function previaMidiaHist(tipo) {
  if (tipo === 'imagem') return '📷 Foto';
  if (tipo === 'audio') return '🎤 Mensagem de voz';
  if (tipo === 'video') return '🎬 Vídeo';
  if (tipo === 'documento') return '📄 Documento';
  return '';
}
// Converte uma mensagem do /message/find no formato da nossa tabela "mensagens".
function mapearMensagemHistorico(m, conversaId) {
  const idUazapi = m.messageid || m.id || (m.key && m.key.id) || null;
  if (!idUazapi) return null;
  const fromMe = m.fromMe === true || (m.key && m.key.fromMe === true);
  const tipo = tipoDaMidiaHist(m);
  const texto = m.text || (typeof m.content === 'string' ? m.content : '') || m.caption || null;
  const midiaUrl = m.fileURL || m.mediaUrl || m.url || null;
  const midiaMime = m.mimetype || (m.content && m.content.mimetype) || null;
  // Horário original: pode vir em segundos ou milissegundos.
  let ts = m.messageTimestamp || m.timestamp || m.momment || m.t || null;
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
  if (ts) {
    ts = Number(ts);
    if (ts > 0) {
      if (ts < 1e12) ts = ts * 1000; // segundos -> ms
      linha.criado_em = new Date(ts).toISOString();
    }
  }
  return linha;
}

app.get('/importar-historico', async (req, res) => {
  try {
    const senha = process.env.IMPORT_TOKEN;
    if (!senha || req.query.token !== senha) {
      return res.status(403).send('Acesso negado. Configure IMPORT_TOKEN e informe ?token= correto.');
    }
    const advogadoNumero = String(req.query.advogado || '').replace(/\D/g, '');
    const contatoNumero = String(req.query.contato || '').replace(/\D/g, '');
    const limiteTotal = Math.min(parseInt(req.query.limite || '500', 10) || 500, 5000);
    if (!advogadoNumero || !contatoNumero) {
      return res.status(400).send('Informe advogado e contato (só números).');
    }

    const { data: adv } = await supabase.from('advogados')
      .select('id, token, servidor').eq('numero', advogadoNumero).maybeSingle();
    if (!adv || !adv.token) return res.status(404).send('Advogado não encontrado (ou sem token) no banco.');

    // Garante contato e conversa.
    const { data: contUp } = await supabase.from('contatos')
      .upsert({ numero: contatoNumero }, { onConflict: 'numero' }).select('id').single();
    const { data: conv } = await supabase.from('conversas')
      .upsert({ advogado_id: adv.id, contato_id: contUp.id }, { onConflict: 'advogado_id,contato_id' })
      .select('id').single();

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

    // Descobre qual sufixo de chatid a Uazapi aceita (varia por versão).
    let chatid = `${contatoNumero}@s.whatsapp.net`;
    let primeira = await buscarPagina(chatid, 0);
    if (!primeira || primeira.length === 0) {
      const alt = `${contatoNumero}@c.us`;
      const tent = await buscarPagina(alt, 0);
      if (tent && tent.length) { chatid = alt; primeira = tent; }
    }

    let importadas = 0, vistas = 0, offset = 0;
    let pagina = primeira || [];
    while (pagina && pagina.length && vistas < limiteTotal) {
      for (const m of pagina) {
        const linha = mapearMensagemHistorico(m, conv.id);
        if (!linha) continue;
        const erro = await salvarMensagem(linha, null);
        if (!erro) importadas++;
      }
      vistas += pagina.length;
      offset += pagina.length;
      if (pagina.length < PAG) break; // última página
      pagina = await buscarPagina(chatid, offset);
    }

    // Conserta a conversa: ordena pela mensagem mais recente e zera "não lidas"
    // (histórico importado não é mensagem nova).
    const { data: ult } = await supabase.from('mensagens')
      .select('texto, tipo, criado_em').eq('conversa_id', conv.id)
      .order('criado_em', { ascending: false }).limit(1);
    const u = ult && ult[0];
    if (u) {
      await supabase.from('conversas').update({
        ultima_mensagem: u.texto || previaMidiaHist(u.tipo) || '[mídia]',
        ultima_atividade: u.criado_em,
        nao_lidas: 0,
      }).eq('id', conv.id);
    }

    console.log(`Histórico: ${importadas} importadas de ${vistas} vistas (contato ${contatoNumero}).`);
    return res.status(200).send(
      `Pronto! Importei ${importadas} mensagem(ns) do contato ${contatoNumero} ` +
      `(vistas ${vistas}). Abra o painel para conferir.`
    );
  } catch (e) {
    console.error('Erro ao importar histórico:', e.message);
    return res.status(500).send('Erro ao importar: ' + e.message);
  }
});

// ============================================================
//  PARTE 1 — RECEBER mensagens
// ============================================================
app.post('/webhook', async (req, res) => {
  res.status(200).send('OK'); // responde rápido para a Uazapi não reenviar

  try {
    const body = req.body;
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
    const { data: adv, error: advErro } = await supabase
      .from('advogados')
      .select('id, token, servidor')
      .eq('numero', advogadoNumero)
      .maybeSingle();
    if (advErro) { console.error('Erro ao buscar advogado:', advErro.message); return; }
    if (!adv) { console.log('Número não cadastrado em advogados:', advogadoNumero); return; }

    // Quem é o CONTATO — SEMPRE o telefone real, ignorando o identificador de
    // privacidade "@lid" que a WhatsApp passou a enviar (ele criava um segundo
    // contato/conversa para a MESMA pessoa).
    const contatoNumero = numeroRealDoContato(body, m);
    if (!contatoNumero) {
      console.log('Sem número de contato; ignorando.', JSON.stringify(body).slice(0, 250));
      return;
    }
    console.log(`Contato ${contatoNumero} | chat.phone=${body.chat && body.chat.phone} | sender_pn=${m.sender_pn} | fromMe=${m.fromMe}`);

    // Foto de perfil do contato (vem no próprio webhook, no chat).
    const fotoContato =
      (body.chat && (body.chat.imagePreview || body.chat.imgUrl || body.chat.image || body.chat.profilePicUrl || body.chat.profilePictureUrl)) || null;

    // NOME do contato: só confiamos em mensagens RECEBIDAS. Numa mensagem fromMe
    // (o advogado escrevendo pelo próprio WhatsApp), os campos de nome trazem o
    // nome do ADVOGADO (ex.: "Acordos Yunes Kaled"), então NÃO tocamos no nome
    // do contato para não sobrescrever com o dado errado.
    const contatoNome = m.fromMe
      ? null
      : ((body.chat && body.chat.wa_name) || m.senderName || null);

    // Só inclui foto_url/nome quando temos valor, para não apagar o que já existe.
    const contatoUpsert = { numero: contatoNumero };
    if (contatoNome) contatoUpsert.nome = contatoNome;
    if (fotoContato) contatoUpsert.foto_url = fotoContato;

    const { data: contato, error: contErro } = await supabase
      .from('contatos')
      .upsert(contatoUpsert, { onConflict: 'numero' })
      .select('id')
      .single();
    if (contErro) { console.error('Erro no contato:', contErro.message); return; }

    // A CONVERSA entre este advogado e este contato.
    const { data: conversa, error: convErro } = await supabase
      .from('conversas')
      .upsert(
        { advogado_id: adv.id, contato_id: contato.id },
        { onConflict: 'advogado_id,contato_id' }
      )
      .select('id')
      .single();
    if (convErro) { console.error('Erro na conversa:', convErro.message); return; }

    // TIPO da mensagem.
    let tipo = 'texto';
    if (m.type === 'media') {
      if (m.mediaType === 'image') tipo = 'imagem';
      else if (m.mediaType === 'ptt' || m.mediaType === 'audio') tipo = 'audio';
      else if (m.mediaType === 'video') tipo = 'video';
      else tipo = 'documento';
    }

    const origem = m.fromMe ? 'advogado' : 'contato';
    const texto =
      m.text || (typeof m.content === 'string' ? m.content : '') || null;

    // Miniatura embutida da imagem (prévia imediata, baixa resolução).
    let midiaUrl = null;
    if (tipo === 'imagem' && m.content && m.content.JPEGThumbnail) {
      midiaUrl = 'data:image/jpeg;base64,' + m.content.JPEGThumbnail;
    }
    const midiaMime = (m.content && m.content.mimetype) || null;

    // Mídia em ALTA RESOLUÇÃO: tenta baixar o arquivo real pela Uazapi e
    // salvar no Storage. Se conseguir, usa essa URL; se não, fica a miniatura
    // (ou nada, no caso de áudio) — comportamento de antes, sem quebrar.
    if (m.type === 'media') {
      const servidorAdv = (adv.servidor || 'https://novaera.uazapi.com').replace(/\/$/, '');
      const urlReal = await baixarMidiaRecebida(servidorAdv, adv.token, m, midiaMime);
      if (urlReal) midiaUrl = urlReal;
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
    // Mensagem "fromMe" que chega pelo webhook (e não é eco de envio pela API,
    // que já foi ignorado acima) = foi enviada DIRETO pelo WhatsApp (app do
    // celular ou desktop), fora do Zorvin. Não sabemos qual atendente foi, então
    // marca com um rótulo de sistema para a equipe distinguir na bolha.
    if (origem === 'advogado') base.enviado_por = 'WhatsApp';
    // Se a mensagem recebida é uma RESPOSTA a outra, guarda a citação.
    const extras = extrairResposta(m);
    const msgErro = await salvarMensagem(base, extras);
    if (msgErro) { console.error('Erro ao salvar mensagem:', msgErro.message); return; }

    console.log(`Recebida (${tipo}) de ${contatoNumero} p/ advogado ${advogadoNumero}.`);
    // A ponte está acordada agora: aproveita para despachar qualquer mensagem
    // que estava esperando na fila (não espera o próximo ciclo do setInterval).
    processarFilaDeEnvio().catch(() => {});
  } catch (e) {
    console.error('Erro inesperado no webhook:', e.message);
  }
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
    const alvo = body.message || body.update || body.data || body;
    const id =
      alvo.messageid || alvo.id || (alvo.key && alvo.key.id) || body.messageid || null;
    const bruto = alvo.status ?? alvo.ack ?? body.status ?? body.ack;

    // Se não achamos id ou status, registramos para referência e saímos.
    if (!id || bruto === undefined || bruto === null) {
      console.log('Evento não tratado (p/ referência):', evento, JSON.stringify(body).slice(0, 300));
      return;
    }

    const s = String(bruto).toLowerCase();
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
async function baixarMidiaRecebida(servidor, token, m, mimeInformado) {
  try {
    try { console.log('Mídia recebida (content):', JSON.stringify(m.content).slice(0, 600)); } catch (_) { /* ignora */ }
    if (!token || !m.messageid) return null;

    let dados = null;
    for (const rota of ['/message/downloadmedia', '/message/download', '/downloadmedia']) {
      try {
        const r = await fetchComTimeout(`${servidor}${rota}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'token': token },
          body: JSON.stringify({ id: m.messageid })
        }, 20000);
        if (r.ok) {
          dados = await r.json().catch(() => null);
          if (dados) { console.log(`downloadmedia OK via ${rota}`); break; }
        } else {
          console.log(`downloadmedia ${rota} -> ${r.status}`);
        }
      } catch (e) { console.log(`downloadmedia ${rota} erro: ${e.message}`); }
    }
    if (!dados) return null;

    const mime = dados.mimetype || dados.mime || mimeInformado || 'application/octet-stream';
    let bytes = null;
    const b64 = dados.file || dados.data || dados.base64 || dados.media || dados.buffer;
    const urlBaixavel = dados.url || dados.fileURL || dados.fileUrl || dados.link || dados.mediaUrl;
    if (typeof b64 === 'string' && b64.length > 100) {
      bytes = Buffer.from(b64.replace(/^data:[^;]+;base64,/, ''), 'base64');
    } else if (urlBaixavel) {
      const arq = await fetchComTimeout(urlBaixavel, {}, 20000);
      if (arq.ok) bytes = Buffer.from(await arq.arrayBuffer());
    }
    if (!bytes || !bytes.length) {
      console.log('downloadmedia sem arquivo reconhecível:', JSON.stringify(dados).slice(0, 300));
      return null;
    }

    const ext = (String(mime).split('/')[1] || 'bin').split(';')[0];
    const caminho = `recebidos/${m.messageid}.${ext}`;
    const { error: upErr } = await supabase.storage.from('anexos').upload(caminho, bytes, { contentType: mime, upsert: true });
    if (upErr) { console.error('Erro ao salvar mídia recebida no Storage:', upErr.message); return null; }
    const { data: pub } = supabase.storage.from('anexos').getPublicUrl(caminho);
    return pub?.publicUrl || null;
  } catch (e) {
    console.error('Erro em baixarMidiaRecebida:', e.message);
    return null;
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
async function salvarMensagem(base, extras) {
  const temExtras = extras && Object.keys(extras).length > 0;
  const payload = temExtras ? { ...base, ...extras } : base;
  let { error } = await supabase
    .from('mensagens')
    .upsert(payload, { onConflict: 'id_uazapi', ignoreDuplicates: true });
  if (error && temExtras) {
    // Provável coluna inexistente: grava sem os campos de citação.
    console.log('Regravando mensagem sem campos de citação:', error.message);
    ({ error } = await supabase
      .from('mensagens')
      .upsert(base, { onConflict: 'id_uazapi', ignoreDuplicates: true }));
  }
  return error;
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

// ============================================================
//  PARTE 2 — ENVIAR respostas (processa a fila_envio)
// ============================================================
//  A cada poucos segundos, a ponte olha a fila de mensagens que o
//  painel quer enviar, e manda cada uma pela Uazapi.
// ------------------------------------------------------------
let filaRodando = false; // impede que dois ciclos processem a fila ao mesmo tempo
async function processarFilaDeEnvio() {
  if (filaRodando) return; // o ciclo anterior ainda não terminou
  filaRodando = true;
  try {
    // Recuperação: se um item ficou preso em 'enviando' por mais de 5 min
    // (ex.: o Render reiniciou/dormiu no meio de um envio), volta para
    // 'pendente' para ser reprocessado — senão a mensagem some sem aviso.
    const limiteTravado = new Date(Date.now() - 5 * 60 * 1000).toISOString();
    const { data: destravadas } = await supabase
      .from('fila_envio')
      .update({ status: 'pendente' })
      .eq('status', 'enviando')
      .lt('criado_em', limiteTravado)
      .select('id');
    if (destravadas && destravadas.length) console.log(`Fila: ${destravadas.length} item(ns) preso(s) em 'enviando' devolvido(s) para 'pendente'.`);

    // Pega até 10 mensagens pendentes de cada vez.
    const { data: pendentes, error } = await supabase
      .from('fila_envio')
      .select('*')
      .eq('status', 'pendente')
      .order('criado_em', { ascending: true })
      .limit(10);

    if (error) { console.error('Erro ao ler fila:', error.message); return; }
    if (!pendentes || pendentes.length === 0) return;

    const MAX_TENTATIVAS = 5;
    for (const item of pendentes) {
      // Trava de segurança: se o item já tentou demais (ex.: ficou preso e foi
      // devolvido para 'pendente' várias vezes), para de reenviar e marca erro.
      // Evita um laço infinito que reentregaria a mesma mensagem sem parar.
      if ((item.tentativas || 0) >= MAX_TENTATIVAS) {
        await supabase.from('fila_envio')
          .update({ status: 'erro', erro_detalhe: `Falhou após ${MAX_TENTATIVAS} tentativas` })
          .eq('id', item.id);
        console.error(`Fila: item ${item.id} excedeu ${MAX_TENTATIVAS} tentativas; marcado como erro.`);
        continue;
      }
      // Reivindica o item de forma ATÔMICA: só processa se ainda estava
      // 'pendente'. Evita envio duplicado se dois ciclos se cruzarem.
      const { data: claim, error: claimErr } = await supabase.from('fila_envio')
        .update({ status: 'enviando', tentativas: (item.tentativas || 0) + 1 })
        .eq('id', item.id)
        .eq('status', 'pendente')
        .select('id');
      if (claimErr) { console.error('Erro ao reivindicar item da fila:', claimErr.message); continue; }
      if (!claim || claim.length === 0) continue; // outro ciclo já pegou este item

      // Descobre para qual número enviar e por qual advogado (token/servidor).
      const { data: conv } = await supabase
        .from('conversas')
        .select('id, contato:contato_id (numero), advogado:advogado_id (token, servidor)')
        .eq('id', item.conversa_id)
        .single();

      if (!conv || !conv.advogado || !conv.contato) {
        await supabase.from('fila_envio')
          .update({ status: 'erro', erro_detalhe: 'Conversa/advogado/contato não encontrado' })
          .eq('id', item.id);
        continue;
      }

      const servidor = (conv.advogado.servidor || 'https://novaera.uazapi.com').replace(/\/$/, '');
      const token = conv.advogado.token;
      const numeroDestino = conv.contato.numero;

      try {
        // Esta mensagem é um ANEXO (imagem/documento/áudio/vídeo) ou texto?
        const ehMidia = item.tipo && item.tipo !== 'texto' && item.midia_url;

        let resposta;
        if (ehMidia) {
          const tipoUaz =
            item.tipo === 'imagem' ? 'image' :
            item.tipo === 'video' ? 'video' :
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
        if (item.responder_id_uazapi) {
          extras.responder_id_uazapi = item.responder_id_uazapi;
          extras.resposta_previa = item.resposta_previa || null;
          extras.resposta_autor = item.resposta_autor || null;
        }
        await salvarMensagem(base, Object.keys(extras).length ? extras : null);

        console.log(`Enviada (${item.tipo || 'texto'}) para ${numeroDestino}.`);
      } catch (envioErro) {
        await supabase.from('fila_envio')
          .update({ status: 'erro', erro_detalhe: envioErro.message })
          .eq('id', item.id);
        console.error(`Falha ao enviar (${item.id}):`, envioErro.message);
      }
    }
  } catch (e) {
    console.error('Erro ao processar fila:', e.message);
  } finally {
    filaRodando = false;
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
function liberarCors(res) {
  res.set('Access-Control-Allow-Origin', process.env.PAINEL_ORIGEM || '*');
  res.set('Access-Control-Allow-Headers', 'Authorization, Content-Type');
  res.set('Access-Control-Allow-Methods', 'GET, POST, PATCH, OPTIONS');
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
  const { data, error } = await supabase.auth.getUser(jwt);
  if (error || !data || !data.user) {
    res.status(401).json({ ok: false, erro: 'Sessão expirada. Entre de novo.' });
    return null;
  }
  return data.user;
}

// Repassa a chamada ao Vantoro colocando o token (que só existe aqui).
async function chamarVantoro(caminho, opcoes = {}) {
  if (!VANTORO_URL || !VANTORO_TOKEN) {
    return { status: 503, corpo: { ok: false, erro: 'Integração com o Vantoro não configurada (VANTORO_API_URL/VANTORO_API_TOKEN).' } };
  }
  const r = await fetchComTimeout(`${VANTORO_URL}${caminho}`, {
    ...opcoes,
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${VANTORO_TOKEN}`,
      ...(opcoes.headers || {}),
    },
  }, 20000);
  let corpo = null;
  try { corpo = await r.json(); } catch (_e) { corpo = { ok: false, erro: 'Resposta inválida do Vantoro.' }; }
  return { status: r.status, corpo };
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
      console.error('vantoro:', (e && e.message) || e);
      res.status(502).json({ ok: false, erro: 'Não foi possível falar com o Vantoro agora.' });
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

// Ficha completa (dados, pendências da ordem de serviço e processos).
app.get('/vantoro/cliente/:id', rotaVantoro(async (req) =>
  chamarVantoro(`/clientes/${encodeURIComponent(req.params.id)}`)));

// Cria o pré-cadastro a partir do atendimento.
app.post('/vantoro/cliente', rotaVantoro(async (req) =>
  chamarVantoro('/clientes', { method: 'POST', body: JSON.stringify(req.body || {}) })));

// Atendente corrige/completa os dados sem sair da conversa.
app.patch('/vantoro/cliente/:id', rotaVantoro(async (req) =>
  chamarVantoro(`/clientes/${encodeURIComponent(req.params.id)}/editar`,
    { method: 'PATCH', body: JSON.stringify(req.body || {}) })));

// Manda para o cadastro um arquivo recebido no WhatsApp.
app.post('/vantoro/cliente/:id/documento', rotaVantoro(async (req) =>
  chamarVantoro(`/clientes/${encodeURIComponent(req.params.id)}/documentos`,
    { method: 'POST', body: JSON.stringify(req.body || {}) })));

// Diagnóstico rápido: a integração está configurada?
app.get('/vantoro/status', (req, res) => {
  liberarCors(res);
  res.json({
    ok: true,
    configurado: Boolean(VANTORO_URL && VANTORO_TOKEN),
    url: VANTORO_URL ? VANTORO_URL.replace(/\/\/[^/]+/, '//…') : null,
  });
});

// Roda a verificação da fila a cada 3 segundos.
setInterval(processarFilaDeEnvio, 3000);

const port = process.env.PORT || 3000;
app.listen(port, () => {
  console.log('Ponte do Zorvin rodando na porta', port);
});
