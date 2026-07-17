// ============================================================
//  ZORVIN by Ropelimi — Ponte (middleware)
//  Recebe as mensagens do WhatsApp (via Uazapi) e guarda no
//  banco de dados do Zorvin (Supabase).
//
//  Esta é a versão 1: cuida de RECEBER mensagens (texto e o
//  registro de mídias). O ENVIO de respostas e a decodificação
//  completa das mídias entram numa próxima versão.
// ============================================================

const express = require('express');
const { createClient } = require('@supabase/supabase-js');

const app = express();
// As mensagens da Uazapi podem trazer miniaturas embutidas, então
// aumentamos um pouco o limite de tamanho do corpo da requisição.
app.use(express.json({ limit: '15mb' }));

// Conexão com o banco do Zorvin. Os dois valores abaixo vêm das
// "variáveis de ambiente" que você configura no Render (não ficam
// escritos aqui, por segurança).
const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
);

// ------------------------------------------------------------
//  Verificação de saúde: usada pelo cronjob para manter a ponte
//  acordada no plano gratuito do Render. Ao acessar a URL raiz,
//  responde uma mensagem simples.
// ------------------------------------------------------------
app.get('/', (req, res) => {
  res.status(200).send('Zorvin bridge online');
});

// ------------------------------------------------------------
//  O coração da ponte: recebe cada mensagem que a Uazapi envia.
// ------------------------------------------------------------
app.post('/webhook', async (req, res) => {
  // Responde 200 imediatamente para a Uazapi não ficar reenviando.
  res.status(200).send('OK');

  try {
    const body = req.body;

    // Só nos interessam eventos de mensagem que tenham conteúdo.
    if (body.EventType !== 'messages' || !body.message) return;

    const m = body.message;

    // 1) Descobrir de qual ADVOGADO é esta conversa.
    //    Na Uazapi, "owner" é o número do dono da instância (o advogado).
    const advogadoNumero = body.owner || m.owner;
    const { data: adv, error: advErro } = await supabase
      .from('advogados')
      .select('id')
      .eq('numero', advogadoNumero)
      .maybeSingle();

    if (advErro) { console.error('Erro ao buscar advogado:', advErro.message); return; }
    if (!adv) {
      console.log('Mensagem de um número não cadastrado em "advogados":', advogadoNumero);
      return;
    }

    // 2) Identificar o CONTATO (a pessoa que está do outro lado).
    //    Usamos o telefone real (chat.phone / sender_pn), não o "@lid".
    const contatoNumero =
      (body.chat && body.chat.phone) ||
      (m.sender_pn || '').split('@')[0];
    const contatoNome =
      (body.chat && body.chat.wa_name) ||
      m.senderName ||
      null;

    if (!contatoNumero) { console.log('Sem número de contato; ignorando.'); return; }

    // Cria o contato se ainda não existir; se já existir, mantém.
    const { data: contato, error: contErro } = await supabase
      .from('contatos')
      .upsert({ numero: contatoNumero, nome: contatoNome }, { onConflict: 'numero' })
      .select('id')
      .single();
    if (contErro) { console.error('Erro no contato:', contErro.message); return; }

    // 3) Encontrar (ou criar) a CONVERSA entre este advogado e este contato.
    const { data: conversa, error: convErro } = await supabase
      .from('conversas')
      .upsert(
        { advogado_id: adv.id, contato_id: contato.id },
        { onConflict: 'advogado_id,contato_id' }
      )
      .select('id')
      .single();
    if (convErro) { console.error('Erro na conversa:', convErro.message); return; }

    // 4) Descobrir o TIPO da mensagem (texto, imagem, áudio, etc.).
    let tipo = 'texto';
    if (m.type === 'media') {
      if (m.mediaType === 'image') tipo = 'imagem';
      else if (m.mediaType === 'ptt' || m.mediaType === 'audio') tipo = 'audio';
      else if (m.mediaType === 'video') tipo = 'video';
      else tipo = 'documento';
    }

    // De quem partiu: se "fromMe" é falso, veio do contato (recebida);
    // se verdadeiro, foi o próprio advogado que enviou (pelo celular dele).
    const origem = m.fromMe ? 'advogado' : 'contato';

    // Texto da mensagem (ou legenda de uma mídia).
    const texto =
      m.text ||
      (typeof m.content === 'string' ? m.content : '') ||
      null;

    // Para imagens, a Uazapi manda uma miniatura embutida (JPEGThumbnail).
    // Guardamos como prévia para o painel já mostrar algo, enquanto a
    // versão em alta resolução fica para a próxima etapa (decodificação).
    let midiaUrl = null;
    if (tipo === 'imagem' && m.content && m.content.JPEGThumbnail) {
      midiaUrl = 'data:image/jpeg;base64,' + m.content.JPEGThumbnail;
    }

    const midiaMime = (m.content && m.content.mimetype) || null;

    // 5) Guardar a MENSAGEM. Se já existir (mesmo id da Uazapi), ignora
    //    para não duplicar.
    const { error: msgErro } = await supabase
      .from('mensagens')
      .upsert(
        {
          conversa_id: conversa.id,
          origem,
          tipo,
          texto,
          midia_url: midiaUrl,
          midia_mime: midiaMime,
          id_uazapi: m.messageid,
          status: origem === 'contato' ? 'recebida' : 'enviada'
        },
        { onConflict: 'id_uazapi', ignoreDuplicates: true }
      );
    if (msgErro) { console.error('Erro ao salvar mensagem:', msgErro.message); return; }

    console.log(`Mensagem (${tipo}) de ${contatoNumero} para o advogado ${advogadoNumero} salva.`);
  } catch (e) {
    console.error('Erro inesperado no webhook:', e.message);
  }
});

const port = process.env.PORT || 3000;
app.listen(port, () => {
  console.log('Ponte do Zorvin rodando na porta', port);
});
