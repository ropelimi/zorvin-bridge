-- ============================================================
--  A TRANSCRIÇÃO DO ÁUDIO
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido da equipe em 02/10: transcrever os áudios. Decidido com o Rodrigo:
--  pelo Groq (Whisper), AO CLICAR no botão "Transcrever" da bolha. Quem faz a
--  ida ao Groq é a PONTE, onde mora a chave (`GROQ_API_KEY`).
--
--  Estas duas colunas GUARDAM o texto na própria mensagem:
--
--    transcricao    o texto que o Groq devolveu
--    transcrita_em  quando
--
--  Guardado, o mesmo áudio não vai ao Groq duas vezes: a segunda pessoa que
--  clicar recebe o texto que já está aqui, e o painel o mostra direto na bolha
--  na próxima vez que a conversa abrir.
--
--  QUEM ESCREVE É SÓ A PONTE (chave de serviço), e por isso nenhuma política
--  nova: quem entrou continua lendo `mensagens` pela regra que já existe, e
--  não ganha permissão para escrever o texto de um áudio à mão.
--
--  ------------------------------------------------------------
--  ENQUANTO ESTE ARQUIVO NÃO FOR RODADO
--
--  A transcrição funciona assim mesmo — só não fica guardada, e cada clique
--  vai ao Groq de novo. A ponte avisa uma vez no log.
-- ============================================================

do $transcricao$
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_015;
  create temp table zorvin_conferencia_015 (item text, resposta text);

  if to_regclass('public.mensagens') is null then
    insert into zorvin_conferencia_015
      values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem a tabela de mensagens — script 015 não fez nada.';
    return;
  end if;

  execute 'alter table public.mensagens add column if not exists transcricao text';
  execute 'alter table public.mensagens add column if not exists transcrita_em timestamptz';

  execute $c$comment on column public.mensagens.transcricao is
    'O texto de um áudio, transcrito pelo Groq quando alguém clicou em '
    '"Transcrever". Escrito só pela ponte; guardado para não pagar duas vezes.'$c$;

  insert into zorvin_conferencia_015
  select 'a coluna da transcrição existe'::text,
         exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'mensagens'
                    and column_name = 'transcricao')::text
  union all
  select 'quem entrou consegue LER a transcrição',
         has_column_privilege('authenticated', 'public.mensagens', 'transcricao', 'SELECT')::text
  union all
  select 'áudios já transcritos',
         (select count(*) from public.mensagens where transcricao is not null)::text;
end $transcricao$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_015;
