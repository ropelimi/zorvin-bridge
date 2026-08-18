-- ============================================================
--  A BUSCA QUE ACHA — por nome com acento e pelo que foi dito
--
--  Dois relatos, uma causa em comum: a busca perguntava ao banco de um jeito
--  que o banco não sabe responder rápido nem responder direito.
--
--  1. "PESQUISO O CLIENTE PELO NOME E ELE NÃO APARECE, MESMO CADASTRADO."
--
--     O `ilike` do Postgres compara letra por letra: "ç" não é "c", "ã" não é
--     "a". Ninguém digita "MARIA DAS GRAÇAS" com cedilha numa caixa de busca —
--     digita "gracas", e o teclado do celular nem oferece o resto. O cliente
--     com acento no nome (que é a maioria dos nomes brasileiros) não aparecia;
--     o de nome sem acento aparecia. Daí "em alguns casos".
--
--  2. "PROCURO UMA PALAVRA DA CONVERSA E A CONVERSA NÃO APARECE."
--
--     `ilike '%teste%'` não usa índice nenhum: o `%` na frente obriga a ler a
--     tabela linha por linha. Em `mensagens`, que é a maior tabela do sistema,
--     isso é uma varredura completa — e a API corta a consulta em 8 segundos.
--     O que voltava era um erro; a tela mostrava lista vazia. Uma lista vazia é
--     uma RESPOSTA ("esse cliente não existe aqui"), e quem lê isso para de
--     procurar.
--
--  A resposta às duas é a mesma: comparar sem acento e ter índice para isso.
--
--  Seguro rodar de novo: tudo é `if not exists` ou `create or replace`.
-- ============================================================

-- As extensões ficam no esquema `extensions` no Supabase; o `search_path`
-- abaixo faz o resto do arquivo enxergar as duas sem precisar qualificar nada.
set search_path = public, extensions;


-- ------------------------------------------------------------
--  1. AS DUAS EXTENSÕES
--
--  `unaccent` tira o acento. `pg_trgm` é o que torna `%palavra%` rápido: ele
--  quebra o texto em trigramas ("tes", "est", "ste") e indexa esses pedaços,
--  que é o único jeito de indexar uma busca com `%` na frente.
-- ------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'unaccent') then
    begin execute 'create extension unaccent with schema extensions';
    exception when others then execute 'create extension unaccent';
    end;
  end if;
  if not exists (select 1 from pg_extension where extname = 'pg_trgm') then
    begin execute 'create extension pg_trgm with schema extensions';
    exception when others then execute 'create extension pg_trgm';
    end;
  end if;
end $$;


-- ------------------------------------------------------------
--  2. SEM ACENTO E EM MINÚSCULA, SEMPRE DO MESMO JEITO
--
--  Um lugar só faz essa redução, e é ele que o índice guarda e a consulta
--  pergunta. Se fossem dois lugares, bastaria um deles mudar para o índice
--  parar de servir — e ninguém notaria, porque a busca continuaria certa,
--  só que lenta outra vez.
--
--  `immutable` é uma promessa: "para a mesma entrada, sempre a mesma saída".
--  O `unaccent` do Postgres é declarado `stable`, e não `immutable`, porque em
--  tese o dicionário de acentos poderia ser trocado. Aqui ele não é, e sem
--  essa promessa não dá para criar índice nenhum em cima disto. É a solução
--  que a própria documentação do Postgres recomenda para este caso — e está
--  escrito aqui para quem vier depois saber que foi decisão, e não descuido.
-- ------------------------------------------------------------
create or replace function zorvin_sem_acento(t text)
returns text
language sql
immutable
parallel safe
set search_path = public, extensions, pg_catalog
as $$ select lower(unaccent(coalesce(t, ''))) $$;

comment on function zorvin_sem_acento(text) is
  'Reduz um texto ao que se compara numa busca: sem acento e em minúscula. '
  'É esta mesma função que os índices guardam.';


-- ------------------------------------------------------------
--  3. O NOME DO CONTATO, PRONTO PARA COMPARAR
--
--  Uma pessoa tem até três nomes aqui: o que ela deixou no WhatsApp (`nome`),
--  o que está no cadastro do Vantoro (`vantoro_nome`) e o que a equipe deu
--  aqui dentro (`nome_zorvin`). A tela mostra um deles conforme o que existe,
--  e quem procura digita o que está lendo na tela. Então os três — mais o
--  número — viram um campo só, já sem acento.
--
--  `generated always ... stored` quer dizer que o banco mantém o campo
--  sozinho: nenhuma parte do sistema precisa lembrar de atualizá-lo quando o
--  nome muda, e não há como ele ficar desatualizado.
--
--  As colunas são conferidas antes: instalação que ainda não rodou o SQL dos
--  nomes tem só `nome` e `numero`, e pedir uma coluna que não existe faria o
--  arquivo inteiro parar aqui.
--
--  ATENÇÃO: acrescentar uma coluna `stored` reescreve a tabela, e enquanto
--  isso `contatos` fica travada para gravação. São dezenas de milhares de
--  linhas — questão de segundos —, mas se cair uma mensagem de um número novo
--  exatamente nesse instante, a ponte não conseguirá criar o contato. Rode
--  fora do horário de pico, por segurança. (O índice de `mensagens`, que é o
--  demorado de verdade, está na parte 2 e não trava nada.)
-- ------------------------------------------------------------
do $$
declare
  tem_vantoro boolean;
  tem_zorvin  boolean;
  expressao   text;
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'contatos'
                and column_name = 'busca') then
    return;   -- já existe: nada a fazer
  end if;

  select count(*) > 0 into tem_vantoro from information_schema.columns
   where table_schema = 'public' and table_name = 'contatos' and column_name = 'vantoro_nome';
  select count(*) > 0 into tem_zorvin from information_schema.columns
   where table_schema = 'public' and table_name = 'contatos' and column_name = 'nome_zorvin';

  expressao := 'coalesce(nome, '''')';
  if tem_vantoro then expressao := expressao || ' || '' '' || coalesce(vantoro_nome, '''')'; end if;
  if tem_zorvin  then expressao := expressao || ' || '' '' || coalesce(nome_zorvin, '''')';  end if;
  expressao := expressao || ' || '' '' || coalesce(numero, '''')';

  execute format(
    'alter table contatos add column busca text generated always as (zorvin_sem_acento(%s)) stored',
    expressao);
  raise notice 'Coluna contatos.busca criada.';
end $$;

comment on column contatos.busca is
  'Os nomes e o número do contato reunidos e sem acento, mantidos pelo próprio '
  'banco. É por esta coluna que a busca por nome pergunta.';

create index if not exists contatos_busca_idx
  on contatos using gin (busca gin_trgm_ops);


-- ------------------------------------------------------------
--  4. A BUSCA, COMO UMA PERGUNTA SÓ
--
--  Antes eram quatro idas ao banco a cada pausa na digitação: os contatos, as
--  conversas desses contatos, as mensagens do escritório inteiro e as
--  conversas que faltavam. A das mensagens era a que estourava o tempo.
--
--  Aqui é uma ida. E, principalmente, a parte das mensagens já nasce RECORTADA
--  NO TELEFONE: a versão anterior pedia as mil mensagens mais recentes de TODO
--  o escritório e só depois jogava fora as dos outros telefones — uma palavra
--  comum enchia as mil vagas com conversa alheia, e a conversa certa, mais
--  antiga, ficava de fora. Sem erro nenhum na tela.
--
--  `security invoker` (o padrão, dito aqui de propósito) é o que garante que
--  as regras de visibilidade continuam valendo: ninguém acha pela busca uma
--  conversa que não poderia abrir pela lista.
-- ------------------------------------------------------------
create or replace function buscar_conversas(
  p_advogado uuid,
  p_termo    text,
  p_limite   int default 80
)
returns table (
  id               uuid,
  motivo           text,   -- 'nome' | 'numero' | 'mensagem'
  trecho           text,   -- a mensagem que casou, quando foi por mensagem
  ultima_atividade timestamptz
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with alvo as (
    select zorvin_sem_acento(p_termo) as termo,
           -- Só os dígitos: quem procura "(67) 99111-0001" está procurando um
           -- número, e o que está guardado é "5567991110001".
           regexp_replace(coalesce(p_termo, ''), '\D', '', 'g') as digitos
  ),
  por_nome as (
    select c.id, 'nome'::text as motivo, null::text as trecho, c.ultima_atividade
      from conversas c
      join contatos ct on ct.id = c.contato_id
     cross join alvo a
     where c.advogado_id = p_advogado
       and length(a.termo) >= 3
       and ct.busca like '%' || a.termo || '%'
  ),
  por_numero as (
    select c.id, 'numero'::text, null::text, c.ultima_atividade
      from conversas c
      join contatos ct on ct.id = c.contato_id
     cross join alvo a
     where c.advogado_id = p_advogado
       and length(a.digitos) >= 4
       and ct.numero like '%' || a.digitos || '%'
  ),
  -- O teto é de MENSAGENS deste telefone, e não do escritório: uma palavra
  -- comum enche estas cinco mil com conversa DAQUI, que é o que se procurava.
  -- Cinco mil mensagens dão muito mais conversas distintas do que as oitenta
  -- que a tela mostra.
  casadas as (
    select m.conversa_id, m.texto, m.criado_em
      from mensagens m
      join conversas c on c.id = m.conversa_id
     cross join alvo a
     where c.advogado_id = p_advogado
       and length(a.termo) >= 3
       and zorvin_sem_acento(m.texto) like '%' || a.termo || '%'
     limit 5000
  ),
  por_mensagem as (
    select distinct on (k.conversa_id)
           k.conversa_id as id, 'mensagem'::text as motivo, k.texto as trecho,
           c.ultima_atividade
      from casadas k
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
    select id, motivo, trecho, ultima_atividade,
           row_number() over (
             partition by id
             order by case motivo when 'nome' then 1 when 'numero' then 2 else 3 end
           ) as posicao
      from tudo
  )
  select id, motivo, trecho, ultima_atividade
    from melhor
   where posicao = 1
   order by ultima_atividade desc nulls last
   limit greatest(p_limite, 1);
$$;

comment on function buscar_conversas(uuid, text, int) is
  'A busca da lista de conversas: por nome (sem acento), por número e pelo que '
  'foi dito dentro da conversa. Recortada no telefone e nas regras de '
  'visibilidade de quem chama.';

-- O papel `authenticated` é do Supabase; numa base comum ele não existe, e o
-- `grant` derrubaria o arquivo inteiro na última linha.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function buscar_conversas(uuid, text, int) to authenticated';
  end if;
end $$;


-- ------------------------------------------------------------
--  5. CONFERÊNCIA — rode e leia
-- ------------------------------------------------------------
select 'unaccent instalada'        as item, exists(select 1 from pg_extension where extname='unaccent')  as ok
union all
select 'pg_trgm instalada',              exists(select 1 from pg_extension where extname='pg_trgm')
union all
select 'coluna contatos.busca',          exists(select 1 from information_schema.columns
                                                 where table_name='contatos' and column_name='busca')
union all
select 'índice do nome',                 exists(select 1 from pg_indexes where indexname='contatos_busca_idx')
union all
select 'função buscar_conversas',        to_regprocedure('public.buscar_conversas(uuid,text,int)') is not null
union all
select 'índice das mensagens (parte 2)', exists(select 1 from pg_indexes where indexname='mensagens_busca_idx');
