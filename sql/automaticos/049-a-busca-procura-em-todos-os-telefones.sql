-- ============================================================
--  A BUSCA PROCURA EM TODOS OS TELEFONES (04/11)
--
--  A ponte aplica sozinha. Pode rodar de novo sem medo — com a pasta inteira,
--  na ordem (regra 5 do LEIA-ME).
--
--  ------------------------------------------------------------
--  POR QUE EXISTE
--
--  Pedido do Rodrigo, com duas fotos: um lead sem ficha no Vantoro tem
--  conversa só no telefone do SAC. Procurando o nome dele no SAC, a conversa
--  aparecia; procurando no telefone de Audiências, a lista dizia "Nada
--  encontrado para essa busca". Nas palavras dele: "não importa em qual
--  telefone o usuário esteja, a busca deve encontrar todas as conversas, com
--  ou sem ficha do Vantoro."
--
--  A busca da lista (`buscar_conversas`) recortava no telefone aberto
--  (`c.advogado_id = p_advogado`) nas quatro perguntas que faz: o nome, o
--  número, o que foi escrito e o que foi dito nos áudios.
--
--  ------------------------------------------------------------
--  O QUE ESTE SCRIPT FAZ
--
--    1. `p_todos_os_telefones` (padrão falso). Verdadeiro, a busca não recorta
--       no telefone. Cada pessoa continua achando só as conversas que a regra
--       de acesso de `conversas` deixa ver: a função é `security invoker`, e a
--       regra vale aqui dentro como numa leitura qualquer.
--    2. A resposta ganha `advogado_id`: a tela precisa saber de qual telefone
--       é cada conversa achada, para dizer qual é e para abri-la nele.
--    3. O TELEFONE ABERTO PRIMEIRO. A resposta tem teto (`p_limite`, 80 no
--       painel), e com os telefones todos uma palavra comum o enche. O teto
--       corta primeiro as conversas dos OUTROS telefones: as do telefone que a
--       pessoa está olhando não podem sumir por causa de um que ela nem abriu.
--    4. O resto é a busca do 040, palavra por palavra (o nome vence o trecho
--       de mensagem; vale a mensagem mais recente da conversa, escrita ou
--       falada; sem acento).
--
--  POR QUE UM ARGUMENTO, E NÃO `p_advogado` NULO. Com a função de antes, um
--  telefone nulo não acha nada e não dá erro — a tela leria "nada encontrado"
--  num banco que só não sabe procurar em todos os telefones (a armadilha nº 2
--  do painel). Com o argumento novo, a função de antes não é achada
--  (PGRST202), e a tela sabe que tem de procurar só no telefone aberto.
--
--  A RESPOSTA MUDA DE FORMA, e por isso a função é apagada e criada de novo.
--  `create or replace` não aceita outra lista de colunas. A ponte aplica cada
--  script numa transação só: ninguém vê o instante sem a função. E a chamada
--  do painel de antes (os três argumentos de sempre) continua valendo, porque
--  o argumento novo tem padrão; a coluna a mais ele não lê.
--
--  UMA FUNÇÃO SÓ, e não uma segunda ao lado da de antes: duas buscas
--  divergiriam no primeiro conserto. E as duas com o mesmo nome fariam a
--  chamada de três argumentos morrer com "could not choose the best candidate
--  function".
--
--  SÓ TROCA A BUSCA QUE EXISTE, como o 040: ela nasceu num script colado à mão
--  (a pasta `sql/` de cima), junto com `zorvin_sem_acento` e a coluna `busca`
--  de `contatos`. Num banco sem ela, criá-la aqui seria escrever a busca
--  inteira de novo, e o painel já sabe viver sem a função.
--
--  ESTA É A VERSÃO DE REFERÊNCIA de `buscar_conversas` daqui para a frente
--  (regra 5 do LEIA-ME). O 040, rodado de novo depois deste, não acha a
--  função de três argumentos e não a recria ao lado desta.
-- ============================================================

do $busca_em_todos$
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_049;
  create temp table zorvin_conferencia_049 (item text, resposta text);

  if to_regclass('public.mensagens') is null or to_regclass('public.conversas') is null
     or to_regclass('public.contatos') is null then
    insert into zorvin_conferencia_049 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 049 não fez nada.';
    return;
  end if;

  if to_regprocedure('public.buscar_conversas(uuid,text,integer)') is null
     and to_regprocedure('public.buscar_conversas(uuid,text,integer,boolean)') is null then
    insert into zorvin_conferencia_049
    values ('a busca da lista', 'ainda não existe neste banco: nada a trocar (o painel usa o caminho antigo)');
    return;
  end if;

  -- O CORPO É `language sql`, e o Postgres confere as colunas ao criar: sem
  -- as do 015, a criação estouraria e pararia os scripts seguintes.
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'mensagens'
         and column_name in ('transcricao', 'transcrita_em')) < 2 then
    insert into zorvin_conferencia_049 values ('as colunas da transcrição', 'rode o script 015 antes');
    return;
  end if;

  execute 'drop function if exists public.buscar_conversas(uuid, text, integer)';

  execute $funcao$
create or replace function public.buscar_conversas(
  p_advogado           uuid,
  p_termo              text,
  p_limite             int     default 80,
  p_todos_os_telefones boolean default false
)
returns table (
  id               uuid,
  motivo           text,        -- 'nome' | 'numero' | 'mensagem' | 'audio'
  trecho           text,        -- o que foi escrito, ou dito no áudio, que casou
  ultima_atividade timestamptz,
  mensagem_id      text,        -- QUAL mensagem casou
  mensagem_em      timestamptz, -- e quando ela foi escrita
  advogado_id      uuid         -- DE QUAL TELEFONE é a conversa (049)
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
           null::text as mensagem_id, null::timestamptz as mensagem_em, c.advogado_id
      from conversas c
      join contatos ct on ct.id = c.contato_id
     cross join alvo a
     where (p_todos_os_telefones or c.advogado_id = p_advogado)
       and length(a.termo) >= 3
       and ct.busca like '%' || a.termo || '%'
  ),
  por_numero as (
    select c.id, 'numero'::text, null::text, c.ultima_atividade,
           null::text, null::timestamptz, c.advogado_id
      from conversas c
      join contatos ct on ct.id = c.contato_id
     cross join alvo a
     where (p_todos_os_telefones or c.advogado_id = p_advogado)
       and length(a.digitos) >= 4
       and ct.numero like '%' || a.digitos || '%'
  ),
  -- O teto é de MENSAGENS: uma palavra comum enche estas cinco mil. Com os
  -- telefones todos, ele vale para todos juntos.
  casadas as (
    select m.id as msg_id, m.conversa_id, m.texto, m.criado_em, 'mensagem'::text as motivo
      from mensagens m
      join conversas c on c.id = m.conversa_id
     cross join alvo a
     where (p_todos_os_telefones or c.advogado_id = p_advogado)
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
     where (p_todos_os_telefones or c.advogado_id = p_advogado)
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
           c.ultima_atividade, k.msg_id::text as mensagem_id, k.criado_em as mensagem_em, c.advogado_id
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
    select id, motivo, trecho, ultima_atividade, mensagem_id, mensagem_em, advogado_id,
           row_number() over (
             partition by id
             order by case motivo when 'nome' then 1 when 'numero' then 2 else 3 end
           ) as posicao
      from tudo
  )
  select id, motivo, trecho, ultima_atividade, mensagem_id, mensagem_em, advogado_id
    from melhor
   where posicao = 1
   -- O TELEFONE ABERTO PRIMEIRO: o teto corta antes as conversas dos outros.
   order by (advogado_id is not distinct from p_advogado) desc, ultima_atividade desc nulls last
   limit greatest(p_limite, 1);
$corpo$
$funcao$;

  execute $comentario$comment on function public.buscar_conversas(uuid, text, int, boolean) is
    'A busca da lista de conversas: por nome (sem acento), por número, pelo que '
    'foi escrito e pelo que foi dito nos áudios. Com p_todos_os_telefones, em '
    'todos os telefones que quem chama alcança (script 049), com as do telefone '
    'aberto primeiro. Devolve QUAL mensagem casou e de qual telefone é cada '
    'conversa.'$comentario$;

  -- QUEM ATENDE USA; QUEM NÃO ENTROU, NÃO. A função nova nasce pela herança do
  -- banco, e ela é dita aqui em vez de suposta (a armadilha nº 5).
  execute 'revoke all on function public.buscar_conversas(uuid, text, int, boolean) from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.buscar_conversas(uuid, text, int, boolean) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.buscar_conversas(uuid, text, int, boolean) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.buscar_conversas(uuid, text, int, boolean) to service_role';
  end if;
end
$busca_em_todos$;

-- ----------------------------------------------------------
--  A CONFERÊNCIA — a última linha, que é a que o editor mostra e a que a ponte
--  guarda. E ela CHAMA a busca como quem atende (`authenticated`), e não como
--  dona do banco (regra 4 do LEIA-ME), nos dois jeitos: num telefone e em
--  todos.
-- ----------------------------------------------------------
do $conf$
declare
  v_resposta text;
begin
  if to_regprocedure('public.buscar_conversas(uuid,text,integer,boolean)') is null then return; end if;

  insert into zorvin_conferencia_049
  select 'a busca da lista procura em todos os telefones',
         (pg_get_functiondef('public.buscar_conversas(uuid,text,integer,boolean)'::regprocedure)
            like '%p_todos_os_telefones or c.advogado_id = p_advogado%')::text;

  insert into zorvin_conferencia_049
  select 'e diz de qual telefone é cada conversa',
         (pg_get_function_result('public.buscar_conversas(uuid,text,integer,boolean)'::regprocedure)
            like '%advogado_id uuid%')::text;

  insert into zorvin_conferencia_049
  select 'a busca de antes saiu (sem duas com o mesmo nome)',
         (to_regprocedure('public.buscar_conversas(uuid,text,integer)') is null)::text;

  if not exists (select 1 from pg_roles where rolname = 'authenticated') then return; end if;

  insert into zorvin_conferencia_049
  select 'quem entrou pode usá-la',
         has_function_privilege('authenticated', 'public.buscar_conversas(uuid,text,integer,boolean)', 'execute')::text;

  if exists (select 1 from pg_roles where rolname = 'anon') then
    insert into zorvin_conferencia_049
    select 'quem não entrou não pode',
           (not has_function_privilege('anon', 'public.buscar_conversas(uuid,text,integer,boolean)', 'execute'))::text;
  end if;

  begin
    perform set_config('role', 'authenticated', true);
    -- Os três argumentos de sempre (o painel de antes) e os quatro (o de agora).
    perform * from public.buscar_conversas('00000000-0000-0000-0000-000000000000'::uuid, 'comprovante', 1);
    perform * from public.buscar_conversas('00000000-0000-0000-0000-000000000000'::uuid, 'comprovante', 1, true);
    v_resposta := 'sim';
    execute 'reset role';
  exception when others then
    -- A troca de papel é desfeita junto com o bloco que falhou.
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;

  insert into zorvin_conferencia_049
  values ('a busca responde para quem atende, num telefone e em todos', v_resposta);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_049;
