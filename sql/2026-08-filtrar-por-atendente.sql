-- ============================================================
--  DE QUAIS CONVERSAS EU PARTICIPEI
--
--  "Participei" quer dizer: em algum momento eu escrevi alguma coisa ali. Não
--  é a conversa que está comigo agora, nem a que abri para ler — é onde eu
--  falei. Quem atende dividindo os mesmos telefones com o escritório inteiro
--  não tem hoje nenhum jeito de achar de volta as suas.
--
--  DOIS MODOS, e a diferença entre eles é o ponto todo do recurso:
--
--    QUALQUER UM   Rodrigo ou Jenifer → toda conversa em que pelo menos um
--                  dos dois falou. Serve para "me mostra o que essas pessoas
--                  atenderam".
--
--    TODOS JUNTOS  Rodrigo e Jenifer → só as conversas em que os DOIS falaram,
--                  na mesma conversa. Serve para "onde nós dois nos cruzamos",
--                  que é o que se procura quando alguém passou um atendimento
--                  para outro e é preciso reconstituir o que aconteceu.
--
--  A PERGUNTA VAI AO BANCO, e não à lista que está na tela. Filtrar no
--  navegador só enxergaria as conversas já carregadas — foi exatamente assim
--  que o filtro por etiqueta mostrava três conversas quando havia trinta.
--
--  Seguro rodar de novo.
-- ============================================================

set search_path = public;


-- ------------------------------------------------------------
--  1. O ÍNDICE
--
--  A pergunta é sempre "quais conversas têm mensagem desta pessoa". Sem índice
--  isso é ler `mensagens` inteira, que é a maior tabela do sistema.
--
--  Parcial: mensagem sem autor identificado (a que o cliente mandou, ou a que
--  saiu pelo aparelho) nunca é resposta desta pergunta, e indexá-la seria
--  pagar espaço por linhas que nunca serão lidas por aqui.
-- ------------------------------------------------------------
create index if not exists mensagens_quem_conversa
  on mensagens (enviado_por_id, conversa_id) where enviado_por_id is not null;

-- E o mesmo pelo NOME, para o histórico antigo — ver o comentário da função.
--
-- Indexa a forma COMPARADA (sem acento, minúscula), e não o texto cru: a
-- comparação é feita assim, e um índice sobre o texto cru não serviria para
-- ela. `zorvin_sem_acento` vem do SQL da busca e é `immutable` justamente para
-- poder ser indexada.
create index if not exists mensagens_quem_conversa_nome
  on mensagens (zorvin_sem_acento(enviado_por), conversa_id)
  where enviado_por_id is null and enviado_por is not null;


-- ------------------------------------------------------------
--  2. QUEM JÁ ESCREVEU POR ESTE TELEFONE
--
--  A lista que a tela oferece para escolher. Sai de quem REALMENTE falou por
--  este número — não de `usuarios` inteiro. Oferecer o escritório todo faria
--  uma lista longa em que a maioria dos nomes devolveria zero conversa, e
--  procurar numa lista assim é pior do que não ter lista.
--
--  Vem com a contagem de conversas de cada um, que é o que responde "quanto
--  vou ver se marcar este?" antes de marcar.
-- ------------------------------------------------------------
create or replace function atendentes_do_telefone(p_advogado uuid)
returns table (id uuid, nome text, conversas bigint)
language sql
stable
security invoker
set search_path = public
as $$
  select m.enviado_por_id                                as id,
         coalesce(max(u.nome), max(m.enviado_por), '(sem nome)') as nome,
         count(distinct m.conversa_id)                   as conversas
    from mensagens m
    join conversas c on c.id = m.conversa_id
    left join usuarios u on u.id = m.enviado_por_id
   where c.advogado_id = p_advogado
     and m.enviado_por_id is not null
   group by m.enviado_por_id
   order by 3 desc, 2;
$$;

comment on function atendentes_do_telefone(uuid) is
  'Quem já escreveu alguma mensagem por este telefone, com quantas conversas '
  'cada um participou. É a lista que o filtro de atendentes oferece.';


-- ------------------------------------------------------------
--  3. AS CONVERSAS DESSAS PESSOAS
--
--  O NOME ENTRA JUNTO COM O ID, e não é preciosismo. A coluna
--  `mensagens.enviado_por_id` é recente: o histórico anterior a ela tem só o
--  NOME de quem escreveu. Procurando apenas pelo id, "as conversas em que eu
--  participei" começaria no dia em que a coluna foi criada — e o recurso
--  serviria justamente para achar coisa antiga.
--
--  Então a mensagem conta se o id bate OU se, não havendo id, o nome bate. O
--  nome é comparado sem acento e sem maiúscula, porque ele foi gravado do jeito
--  que estava na conta de cada um na época, e isso variou.
-- ------------------------------------------------------------
create or replace function conversas_por_atendente(
  p_advogado  uuid,
  p_usuarios  uuid[],
  p_todos     boolean default false,
  p_limite    int     default 500
)
returns table (id uuid, ultima_atividade timestamptz)
language sql
stable
security invoker
set search_path = public
as $$
  with quem as (
    select u.id,
           -- `zorvin_sem_acento` vem do SQL da busca. Se ele ainda não tiver
           -- sido rodado nesta base, esta função não é criada e a tela cai no
           -- comportamento de antes — sem filtro, e não com filtro errado.
           zorvin_sem_acento(u.nome) as nome
      from usuarios u
     where u.id = any(p_usuarios)
  ),
  -- AS DUAS METADES SEPARADAS, e isso não é estilo: é o que faz a consulta
  -- usar índice. Escritas como um `left join` só, com o casamento por nome na
  -- condição, o Postgres não tinha como usar índice nenhum e lia `mensagens`
  -- INTEIRA — medido: 692 ms com 264 mil mensagens, e crescendo com a tabela.
  -- Separadas, cada metade entra pelo seu próprio índice.
  participacao as (
    select m.conversa_id, m.enviado_por_id as quem_id
      from mensagens m
     where m.enviado_por_id = any(p_usuarios)
    union all
    -- `enviado_por is not null` repete a condição do índice parcial DE
    -- PROPÓSITO. Sem essa linha o Postgres não consegue provar que as linhas
    -- procuradas cabem dentro do índice, e volta a ler a tabela inteira — o
    -- resultado sai igual, e a consulta custa cinquenta vezes mais.
    select m.conversa_id, q.id
      from quem q
      join mensagens m
        on m.enviado_por_id is null
       and m.enviado_por is not null
       and zorvin_sem_acento(m.enviado_por) = q.nome
  ),
  casadas as (
    select p.conversa_id
      from participacao p
     group by p.conversa_id
    having (not p_todos)
        or count(distinct p.quem_id) = cardinality(p_usuarios)
  )
  select c.id, c.ultima_atividade
    from casadas k
    join conversas c on c.id = k.conversa_id
   where c.advogado_id = p_advogado
   order by c.ultima_atividade desc nulls last
   limit greatest(p_limite, 1);
$$;

comment on function conversas_por_atendente(uuid, uuid[], boolean, int) is
  'As conversas deste telefone em que as pessoas indicadas escreveram. '
  'p_todos = false: qualquer uma delas. p_todos = true: todas, na mesma conversa. '
  'Casa por id e, no histórico antigo que não tem id, pelo nome.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function atendentes_do_telefone(uuid) to authenticated';
    execute 'grant execute on function conversas_por_atendente(uuid, uuid[], boolean, int) to authenticated';
  end if;
end $$;


-- ------------------------------------------------------------
--  CONFERÊNCIA — rode e leia
-- ------------------------------------------------------------
select 'índice por id'   as item, exists(select 1 from pg_indexes where indexname='mensagens_quem_conversa') as ok
union all
select 'índice por nome',        exists(select 1 from pg_indexes where indexname='mensagens_quem_conversa_nome')
union all
select 'lista de atendentes',    to_regprocedure('public.atendentes_do_telefone(uuid)') is not null
union all
select 'filtro de conversas',    to_regprocedure('public.conversas_por_atendente(uuid,uuid[],boolean,int)') is not null;
