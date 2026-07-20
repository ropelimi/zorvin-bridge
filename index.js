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
  const fontes = (m && m.fromMe)
    ? [chatPhone, chatId, m && m.sender_pn, m && m.sender]
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

    if (body.EventType !== 'messages' || !body.message) return;

    const m = body.message;

    // Se a mensagem foi enviada pelo próprio Zorvin (pela API), a ponte já
    // registrou ela no banco na hora do envio. Este aviso é só um "eco" —
    // ignoramos para não duplicar.
    if (m.wasSentByApi === true) {
      console.log('Eco de mensagem enviada pelo Zorvin; ignorado.');
      return;
    }

    // De qual ADVOGADO é esta conversa (owner = número do dono da instância).
    const advogadoNumero = body.owner || m.owner;
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
    const contatoNome =
      (body.chat && body.chat.wa_name) || m.senderName || null;
    if (!contatoNumero) {
      console.log('Sem número de contato; ignorando.', JSON.stringify(body).slice(0, 250));
      return;
    }
    console.log(`Contato ${contatoNumero} | chat.phone=${body.chat && body.chat.phone} | sender_pn=${m.sender_pn} | fromMe=${m.fromMe}`);

    // Foto de perfil do contato (vem no próprio webhook, no chat).
    const fotoContato =
      (body.chat && (body.chat.imagePreview || body.chat.imgUrl || body.chat.image || body.chat.profilePicUrl || body.chat.profilePictureUrl)) || null;

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
    // Se a mensagem recebida é uma RESPOSTA a outra, guarda a citação.
    const extras = extrairResposta(m);
    const msgErro = await salvarMensagem(base, extras);
    if (msgErro) { console.error('Erro ao salvar mensagem:', msgErro.message); return; }

    console.log(`Recebida (${tipo}) de ${contatoNumero} p/ advogado ${advogadoNumero}.`);
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
    if (s === '3' || s === '4' || s.includes('read') || s.includes('play') || s.includes('lid')) {
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
        const r = await fetch(`${servidor}${rota}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'token': token },
          body: JSON.stringify({ id: m.messageid })
        });
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
      const arq = await fetch(urlBaixavel);
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
    // Pega até 10 mensagens pendentes de cada vez.
    const { data: pendentes, error } = await supabase
      .from('fila_envio')
      .select('*')
      .eq('status', 'pendente')
      .order('criado_em', { ascending: true })
      .limit(10);

    if (error) { console.error('Erro ao ler fila:', error.message); return; }
    if (!pendentes || pendentes.length === 0) return;

    for (const item of pendentes) {
      // Reivindica o item de forma ATÔMICA: só processa se ainda estava
      // 'pendente'. Evita envio duplicado se dois ciclos se cruzarem.
      const { data: claim } = await supabase.from('fila_envio')
        .update({ status: 'enviando', tentativas: 1 })
        .eq('id', item.id)
        .eq('status', 'pendente')
        .select('id');
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
            });
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
          });
        }

        if (!resposta.ok) {
          const detalhe = await resposta.text();
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
        await supabase.from('fila_envio')
          .update({ status: 'enviada', enviado_em: new Date().toISOString() })
          .eq('id', item.id);

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
        const extras = item.responder_id_uazapi
          ? {
              responder_id_uazapi: item.responder_id_uazapi,
              resposta_previa: item.resposta_previa || null,
              resposta_autor: item.resposta_autor || null
            }
          : null;
        await salvarMensagem(base, extras);

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

// Roda a verificação da fila a cada 3 segundos.
setInterval(processarFilaDeEnvio, 3000);

const port = process.env.PORT || 3000;
app.listen(port, () => {
  console.log('Ponte do Zorvin rodando na porta', port);
});
