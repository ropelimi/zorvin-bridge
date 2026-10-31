-- ============================================================
--  O QUE FOI DITO NOS ÁUDIOS ENTRA NA BUSCA (31/10)
--
--  A ponte aplica sozinha. Pode rodar de novo sem medo — com a pasta inteira,
--  na ordem (regra 5 do LEIA-ME).
--
--  ------------------------------------------------------------
--  POR QUE EXISTE
--
--  Desde 31/10 a ponte transcreve sozinha todo áudio que chega (ver
--  "Transcrever um áudio" no CLAUDE.md da ponte). O texto mora em
--  `mensagens.transcricao` (script 015), e a busca da lista não o via: ela
--  procura em `mensagens.texto`, e o texto de um áudio é nulo (medido em
--  31/10: 2.807 dos 2.808 áudios). Quem procurasse "comprovante" não achava o
--  cliente que disse "mandei o comprovante" num áudio.
--
--  ------------------------------------------------------------
--  O QUE ESTE SCRIPT FAZ
--
--    1. `buscar_conversas` procura também nas transcrições. A conversa achada
--       por um áudio volta com o motivo 'audio', e o trecho é o que foi dito
--       nele: o painel mostra o 🎤 no lugar do 💬 e abre a conversa no áudio.
--       A assinatura e as colunas da resposta são as MESMAS — por isso é
--       `create or replace`, sem um instante em que a função não existe —, e
--       o resto da busca é o de `sql/2026-08-busca-ir-para-a-mensagem.sql`.
--    2. O índice da busca nas transcrições: o mesmo trigrama do índice do
--       texto (`mensagens_busca_idx`), só nas linhas que têm transcrição.
--       Começa pequeno (uns 300 áudios) e cresce junto com elas.
--    3. O índice da rodada automática: os áudios sem transcrição e ainda não
--       tentados, pela hora. A ponte pergunta por eles de 15 em 15 segundos, e
--       sem o índice cada pergunta leria os sete dias de mensagens (uns 5 mil
--       linhas em 31/10).
--
--  SÓ TROCA A BUSCA QUE EXISTE. Ela nasceu num script colado à mão (a pasta
--  `sql/` de cima), junto com `zorvin_sem_acento` e a coluna `busca` de
--  `contatos`. Num banco sem ela, criá-la aqui seria escrever a busca inteira
--  de novo, e o painel já sabe viver sem a função (volta ao caminho antigo).
--
--  OS ÍNDICES NÃO SÃO `concurrently`, e é decisão: o parcial da busca lê a
--  tabela uma vez para achar as poucas linhas com transcrição (60 mil
--  mensagens em 31/10, menos de um segundo), e durante isso só a gravação de
--  mensagens espera. `concurrently` não roda dentro da transação que deixa o
--  script inteiro valer ou nada valer.
-- ============================================================

do $busca_nos_audios$
declare
  v_trgm text;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_040;
  create temp table zorvin_conferencia_040 (item text, resposta text);

  if to_regclass('public.mensagens') is null then
    insert into zorvin_conferencia_040 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem a tabela de mensagens — script 040 não fez nada.';
    return;
  end if;

  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'mensagens'
         and column_name in ('transcricao', 'transcrita_em')) < 2 then
    insert into zorvin_conferencia_040 values ('as colunas da transcrição', 'rode o script 015 antes');
    return;
  end if;

  -- ------------------------------------------------------------
  --  3. O ÍNDICE DA RODADA AUTOMÁTICA
  --
  --  O predicado é a pergunta da ponte, palavra por palavra (`tipo`, as duas
  --  colunas nulas): é só assim que o banco aceita usar um índice parcial. Um
  --  áudio sai dele quando ganha o texto, ou quando a ponte o marca como "sem
  --  fala" ou "grande demais" (`transcrita_em`).
  -- ------------------------------------------------------------
  execute 'create index if not exists mensagens_audio_por_transcrever
             on public.mensagens (criado_em desc)
             where tipo = ''audio'' and transcricao is null and transcrita_em is null';

  -- ------------------------------------------------------------
  --  2. O ÍNDICE DA BUSCA NAS TRANSCRIÇÕES
  --
  --  O trigrama mora numa extensão (`pg_trgm`), no esquema `extensions` na
  --  Supabase. O nome do esquema é lido, e não escrito: num banco em que ela
  --  foi instalada noutro lugar, o índice nasce assim mesmo.
  -- ------------------------------------------------------------
  select n.nspname into v_trgm
    from pg_opclass o
    join pg_namespace n on n.oid = o.opcnamespace
    join pg_am a on a.oid = o.opcmethod
   where o.opcname = 'gin_trgm_ops' and a.amname = 'gin'
   limit 1;
  if v_trgm is not null and to_regprocedure('public.zorvin_sem_acento(text)') is not null then
    execute format('create index if not exists mensagens_transcricao_busca_idx
                      on public.mensagens using gin (public.zorvin_sem_acento(transcricao) %I.gin_trgm_ops)
                      where transcricao is not null', v_trgm);
  end if;

  -- ------------------------------------------------------------
  --  1. A BUSCA
  -- ------------------------------------------------------------
  if to_regprocedure('public.buscar_conversas(uuid,text,integer)') is not null then
    execute $funcao$
create or replace function public.buscar_conversas(
  p_advogado uuid,
  p_termo    text,
  p_limite   int default 80
)
returns table (
  id               uuid,
  motivo           text,        -- 'nome' | 'numero' | 'mensagem' | 'audio'
  trecho           text,        -- o que foi escrito, ou dito no áudio, que casou
  ultima_atividade timestamptz,
  mensagem_id      text,        -- QUAL mensagem casou
  mensagem_em      timestamptz  -- e quando ela foi escrita
)
language sql
stable
security invoker
set search_path = public, extensions
as $corpo$
  with alvo as (
    select zorvin_sem_acento(p_termo) as termo,
           regexp_replace(coalesce(p_termo, ''), '\D', '', 'g') as digitos
  ),
  por_nome as (
    select c.id, 'nome'::text as motivo, null::text as trecho, c.ultima_atividade,
           null::text as mensagem_id, null::timestamptz as mensagem_em
      from conversas c
      join contatos ct on ct.id = c.contato_id
     cross join alvo a
     where c.advogado_id = p_advogado
       and length(a.termo) >= 3
       and ct.busca like '%' || a.termo || '%'
  ),
  por_numero as (
    select c.id, 'numero'::text, null::text, c.ultima_atividade,
           null::text, null::timestamptz
      from conversas c
      join contatos ct on ct.id = c.contato_id
     cross join alvo a
     where c.advogado_id = p_advogado
       and length(a.digitos) >= 4
       and ct.numero like '%' || a.digitos || '%'
  ),
  -- O teto é de MENSAGENS deste telefone, e não do escritório: uma palavra
  -- comum enche estas cinco mil com conversa DAQUI, que é o que se procurava.
  casadas as (
    select m.id as msg_id, m.conversa_id, m.texto, m.criado_em, 'mensagem'::text as motivo
      from mensagens m
      join conversas c on c.id = m.conversa_id
     cross join alvo a
     where c.advogado_id = p_advogado
       and length(a.termo) >= 3
       and zorvin_sem_acento(m.texto) like '%' || a.termo || '%'
     limit 5000
  ),
  -- O QUE FOI DITO NUM ÁUDIO (script 040), pelo índice das transcrições.
  -- Uma pergunta à parte, e não um `or` na de cima: com `or`, o banco não
  -- usaria nenhum dos dois índices. E o `transcricao is not null` escrito à
  -- parte é o que o deixa usar o índice parcial.
  casadas_no_audio as (
    select m.id as msg_id, m.conversa_id, m.transcricao as texto, m.criado_em, 'audio'::text as motivo
      from mensagens m
      join conversas c on c.id = m.conversa_id
     cross join alvo a
     where c.advogado_id = p_advogado
       and length(a.termo) >= 3
       and m.transcricao is not null
       and zorvin_sem_acento(m.transcricao) like '%' || a.termo || '%'
     limit 5000
  ),
  -- A MAIS RECENTE de cada conversa, escrita ou falada. É a que a pessoa
  -- provavelmente procura: quem lembra de uma palavra dita numa conversa está
  -- pensando na última vez em que ela foi dita.
  por_mensagem as (
    select distinct on (k.conversa_id)
           k.conversa_id as id, k.motivo, k.texto as trecho,
           c.ultima_atividade, k.msg_id::text as mensagem_id, k.criado_em as mensagem_em
      from (select * from casadas union all select * from casadas_no_audio) k
      join conversas c on c.id = k.conversa_id
     order by k.conversa_id, k.criado_em desc
  ),
  tudo as (
    select * from por_nome
    union all select * from por_numero
    union all select * from por_mensagem
  ),
  -- Uma conversa pode casar de dois jeitos. Vale o motivo mais direto: o nome
  -- explica melhor do que um trecho de mensagem por que ela apareceu.
  melhor as (
    select id, motivo, trecho, ultima_atividade, mensagem_id, mensagem_em,
           row_number() over (
             partition by id
             order by case motivo when 'nome' then 1 when 'numero' then 2 else 3 end
           ) as posicao
      from tudo
  )
  select id, motivo, trecho, ultima_atividade, mensagem_id, mensagem_em
    from melhor
   where posicao = 1
   order by ultima_atividade desc nulls last
   limit greatest(p_limite, 1);
$corpo$
$funcao$;

    execute $comentario$comment on function public.buscar_conversas(uuid, text, int) is
      'A busca da lista de conversas: por nome (sem acento), por número, pelo que '
      'foi escrito e pelo que foi dito nos áudios (a transcrição, script 040). '
      'Devolve QUAL mensagem casou, para a tela abrir a conversa nela. Recortada '
      'no telefone e nas regras de visibilidade de quem chama.'$comentario$;
  end if;
end
$busca_nos_audios$;

-- ----------------------------------------------------------
--  A CONFERÊNCIA — a última linha, que é a que o editor mostra e a que a ponte
--  guarda. E ela CHAMA a busca como quem atende (`authenticated`), e não como
--  dona do banco (regra 4 do LEIA-ME).
-- ----------------------------------------------------------
do $conf$
declare
  v_resposta text;
begin
  if to_regclass('public.mensagens') is null then return; end if;
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'mensagens'
         and column_name in ('transcricao', 'transcrita_em')) < 2 then return; end if;

  insert into zorvin_conferencia_040
  select 'o índice da rodada automática existe',
         exists (select 1 from pg_indexes where schemaname = 'public'
                    and indexname = 'mensagens_audio_por_transcrever')::text;

  insert into zorvin_conferencia_040
  select 'o índice da busca nas transcrições',
         case when exists (select 1 from pg_indexes where schemaname = 'public'
                              and indexname = 'mensagens_transcricao_busca_idx') then 'true'
              when not exists (select 1 from pg_opclass where opcname = 'gin_trgm_ops')
                then 'sem a extensão pg_trgm neste banco: a busca nas transcrições lê a tabela'
              else 'false' end;

  insert into zorvin_conferencia_040
  select 'áudios esperando a transcrição automática (últimos 7 dias)',
         (select count(*) from public.mensagens
           where tipo = 'audio' and transcricao is null and transcrita_em is null
             and midia_url is not null and criado_em >= now() - interval '7 days')::text;

  if to_regprocedure('public.buscar_conversas(uuid,text,integer)') is null then
    insert into zorvin_conferencia_040
    values ('a busca da lista', 'ainda não existe neste banco: nada a trocar (o painel usa o caminho antigo)');
    return;
  end if;

  insert into zorvin_conferencia_040
  select 'a busca da lista procura nas transcrições',
         (pg_get_functiondef('public.buscar_conversas(uuid,text,integer)'::regprocedure)
            like '%casadas_no_audio%')::text;

  if not exists (select 1 from pg_roles where rolname = 'authenticated') then return; end if;

  insert into zorvin_conferencia_040
  select 'quem entrou pode usá-la',
         has_function_privilege('authenticated', 'public.buscar_conversas(uuid,text,integer)', 'execute')::text;

  begin
    perform set_config('role', 'authenticated', true);
    perform * from public.buscar_conversas('00000000-0000-0000-0000-000000000000'::uuid, 'comprovante', 1);
    v_resposta := 'sim';
    execute 'reset role';
  exception when others then
    -- A troca de papel é desfeita junto com o bloco que falhou.
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;

  insert into zorvin_conferencia_040
  values ('a busca responde para quem atende', v_resposta);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_040;
