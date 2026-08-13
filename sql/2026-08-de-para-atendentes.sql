-- DE-PARA DE ATENDENTES — juntar o histórico à pessoa certa,
-- e tirar da lista de gente o que não é gente.
--
-- Rodar no SQL Editor do Supabase. Idempotente: pode rodar de novo à vontade.
-- Substitui a versão anterior deste arquivo.
--
-- ------------------------------------------------------------------
-- DOIS PROBLEMAS, A MESMA TABELA
-- ------------------------------------------------------------------
--
-- 1. A MESMA PESSOA COM DOIS NOMES. Durante muito tempo o nome de quem enviou
--    foi gravado como TEXTO, e às vezes esse texto era o começo do e-mail
--    ("rodrigo", "max", "anderson.andrade"). No Painel, "rodrigo" e
--    "Rodrigo Sousa" viram duas pessoas.
--
-- 2. RÓTULO QUE NÃO É PESSOA. O importador de histórico assina as mensagens
--    enviadas com o nome que você escolheu no menu "qual desses nomes é você"
--    — que é o nome da LINHA como estava salvo no celular de quem exportou
--    ("Cadastro - C&A", "Atendimento Estratégico"). Isso entra na lista de
--    atendentes como se fosse um colega, e em geral no topo.
--
-- A saída para os dois é a mesma: uma tabela que diz o que cada rótulo é. Não
-- se sai reescrevendo mensagem antiga, porque:
--
--   * é REVERSÍVEL. Errou? Apaga a linha. Um `update` em `mensagens` não tem
--     volta.
--   * vale para o histórico inteiro de uma vez, inclusive para o que ainda
--     for importado com o nome velho.
--   * a bolha da conversa continua mostrando o que mostrava.

create table if not exists atendentes_de_para (
  -- O rótulo como está gravado em `mensagens.enviado_por`. O casamento ignora
  -- maiúscula e espaço em volta. Mensagem sem nenhum nome entra aqui como o
  -- texto literal '(sem nome)'.
  nome_antigo text primary key,
  -- Para quem ele aponta. O ideal é o id: aí o histórico passa a ser contado
  -- junto com as mensagens novas da pessoa, que já saem identificadas.
  usuario_id  uuid,
  -- O nome para mostrar no relatório. Pode ficar nulo quando não for pessoa.
  nome_novo   text,
  -- FALSE = isto não é um atendente. Sai da lista de gente e vai para um
  -- bloco à parte, sem sumir da conta do telefone: a mensagem existiu.
  e_pessoa    boolean not null default true,
  criado_em   timestamptz default now()
);

-- Para quem já tinha a versão anterior da tabela.
alter table atendentes_de_para add column if not exists e_pessoa boolean not null default true;
alter table atendentes_de_para alter column nome_novo drop not null;

alter table atendentes_de_para enable row level security;

-- (o `if` sobre o papel é só para este arquivo poder rodar num Postgres comum,
--  que é onde eu testo antes de te mandar; no Supabase ele sempre existe)
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'drop policy if exists de_para_leitura on atendentes_de_para';
    execute 'create policy de_para_leitura on atendentes_de_para for select to authenticated using (true)';
  end if;
end;
$$;

comment on table atendentes_de_para is
  'O que cada rótulo de mensagens.enviado_por é: qual pessoa, ou que não é pessoa.';

-- ============================================================
--  A FUNÇÃO DO PAINEL, JÁ CONSULTANDO O DE-PARA
-- ============================================================

create or replace function painel_numeros(p_desde timestamptz default null)
returns jsonb
language plpgsql
stable
as $$
declare
  v_notas bigint := 0;
  v_saida jsonb;
begin
  if to_regclass('public.notas') is not null then
    execute 'select count(*) from notas where $1 is null or criado_em >= $1'
      into v_notas using p_desde;
  end if;

  with cru as (
    select
      m.origem, m.criado_em, m.enviado_por, m.enviado_por_id, c.advogado_id,
      -- O rótulo NORMALIZADO. Sem nome nenhum vira '(sem nome)', que assim
      -- pode ser classificado no de-para como qualquer outro.
      coalesce(nullif(btrim(m.enviado_por), ''), '(sem nome)') as rotulo
    from mensagens m
    join conversas c on c.id = m.conversa_id
    where p_desde is null or m.criado_em >= p_desde
  ),
  -- QUEM JÁ ESTÁ CADASTRADO É RECONHECIDO PELO NOME, SEM DE-PARA NENHUM.
  --
  -- Sem isto, o de-para consertava pela metade: "rodrigo" ganhava o id da
  -- pessoa, mas as mensagens já assinadas "Rodrigo Sousa" continuavam sem id
  -- e viravam UMA SEGUNDA LINHA com o mesmo nome. Duas Rodrigo Sousa na
  -- tela — exatamente o que o de-para existe para evitar.
  --
  -- `having count(*) = 1` porque dois cadastros com o mesmo nome não dá para
  -- desempatar. Nesse caso ninguém é escolhido e as mensagens continuam
  -- contadas pelo nome, como antes: melhor impreciso do que atribuído à
  -- pessoa errada.
  -- (`array_agg` e não `min`: o Postgres não sabe comparar uuid com `min`.
  --  Como o `having` garante uma linha só, qualquer uma serve.)
  pessoa_por_nome as (
    select lower(btrim(nome)) as chave, (array_agg(id))[1] as id
    from usuarios
    where coalesce(btrim(nome), '') <> ''
    group by 1
    having count(*) = 1
  ),
  -- O MESMO RÓTULO É A MESMA PESSOA.
  --
  -- Se alguma mensagem assinada "Max Canaverde" já traz um id, então TODAS as
  -- mensagens com esse rótulo são daquela pessoa. É a evidência mais forte que
  -- existe aqui dentro — mais forte do que casar nome com cadastro — e não
  -- depende de o cadastro estar limpo.
  --
  -- É o que conserta o caso que apareceu na base: a mesma pessoa com DOIS
  -- cadastros de mesmo nome. Dois cadastros desligam o desempate lá de cima
  -- (`having count(*) = 1`), as mensagens sem id não achavam id nenhum, e
  -- "Max Canaverde" aparecia duas vezes no ranking — 30 num grupo, 9 no outro.
  --
  -- Sem o corte por data de propósito: o vínculo entre rótulo e pessoa vale
  -- para sempre, e não só para o período que está na tela. Se o corte
  -- entrasse aqui, um mês sem nenhuma mensagem identificada quebraria o
  -- vínculo e o defeito voltaria só naquele mês.
  --
  -- `count(distinct) = 1` porque um rótulo usado por duas pessoas diferentes
  -- não dá para desempatar — e chutar ali seria pôr o trabalho de alguém na
  -- conta de outro.
  id_pelo_rotulo as (
    select lower(btrim(enviado_por)) as chave, (array_agg(enviado_por_id))[1] as id
    from mensagens
    where origem = 'advogado'
      and enviado_por_id is not null
      and coalesce(btrim(enviado_por), '') <> ''
    group by 1
    having count(distinct enviado_por_id) = 1
  ),
  msg as (
    select
      cru.origem, cru.criado_em, cru.advogado_id, cru.rotulo,
      -- A ORDEM É A ORDEM DA EVIDÊNCIA, da mais forte para a mais fraca:
      -- o id gravado na própria mensagem; o id já visto nesse mesmo rótulo; o
      -- id já visto no nome para o qual o de-para aponta; o que o de-para
      -- aponta; e, por último, o casamento com o cadastro pelo nome.
      --
      -- O rótulo vem ANTES do de-para de propósito. O `usuario_id` do de-para
      -- costuma ser preenchido casando nome com cadastro, e quando há dois
      -- cadastros de mesmo nome esse casamento escolhe um dos dois sem
      -- critério — o que dava dois grupos para a mesma pessoa, dependendo de
      -- qual tivesse sido sorteado.
      coalesce(cru.enviado_por_id, ir.id, irn.id, dp.usuario_id, pn.id) as quem_id,
      coalesce(nullif(btrim(dp.nome_novo), ''), nullif(btrim(cru.enviado_por), '')) as quem_nome,
      -- "WhatsApp" é o rótulo que a ponte grava quando a mensagem saiu pelo
      -- aparelho. Não depende do de-para: é sempre aparelho.
      (cru.rotulo = 'WhatsApp') as e_aparelho,
      -- Marcado como "não é pessoa" no de-para. Só vale quando a mensagem não
      -- traz id: se ela traz, alguém de verdade a enviou pelo Zorvin, e o
      -- rótulo antigo não manda mais nada.
      (dp.e_pessoa is not null and dp.e_pessoa = false and cru.enviado_por_id is null) as e_rotulo
    from cru
    left join atendentes_de_para dp
      on lower(btrim(dp.nome_antigo)) = lower(cru.rotulo)
    left join id_pelo_rotulo ir
      on ir.chave = lower(cru.rotulo)
    left join id_pelo_rotulo irn
      on irn.chave = lower(btrim(dp.nome_novo))
    left join pessoa_por_nome pn
      on pn.chave = lower(btrim(coalesce(nullif(btrim(dp.nome_novo), ''), cru.rotulo)))
  ),
  gente as (
    select
      case when quem_id is not null then 'id:' || quem_id::text
           else 'nome:' || coalesce(quem_nome, '(sem nome)') end as chave,
      (array_agg(quem_id   order by criado_em desc))[1] as enviado_por_id,
      (array_agg(coalesce(quem_nome, '(sem nome)') order by criado_em desc))[1] as nome,
      count(*) as enviadas
    from msg
    where origem = 'advogado' and not e_aparelho and not e_rotulo
    group by 1
  ),
  rotulos as (
    select rotulo as nome, count(*) as enviadas
    from msg
    where origem = 'advogado' and e_rotulo
    group by 1
  ),
  tel as (
    select advogado_id,
           count(*) filter (where origem = 'contato')  as recebidas,
           count(*) filter (where origem = 'advogado') as enviadas
    from msg
    group by advogado_id
  )
  select jsonb_build_object(
    'recebidas', (select count(*) from msg where origem = 'contato'),
    'enviadas',  (select count(*) from msg where origem = 'advogado'),
    'outras',    (select count(*) from msg where origem not in ('contato', 'advogado')),
    'aparelho',  (select count(*) from msg where origem = 'advogado' and e_aparelho),
    -- Enviadas por gente, mas ainda sem id: histórico que o de-para não
    -- alcançou. Contam pelo nome, com a imprecisão que o nome tem.
    'sem_id',    (select count(*) from msg
                   where origem = 'advogado' and not e_aparelho and not e_rotulo
                     and quem_id is null),
    'notas',     v_notas,
    'por_telefone', coalesce((select jsonb_agg(to_jsonb(t)) from tel t), '[]'::jsonb),
    'por_pessoa',   coalesce((select jsonb_agg(to_jsonb(g)) from gente g), '[]'::jsonb),
    -- O que foi tirado da lista de gente, discriminado. Some da tabela de
    -- atendentes; não some da tela.
    'por_rotulo',   coalesce((select jsonb_agg(to_jsonb(r)) from rotulos r), '[]'::jsonb)
  ) into v_saida;

  return v_saida;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function painel_numeros(timestamptz) to authenticated';
  end if;
end;
$$;

-- ============================================================
--  COMO PREENCHER
-- ============================================================
--
-- PASSO 1 — ver o que existe, e o que já bate com uma pessoa cadastrada:
--
--   with rotulos as (
--     select coalesce(nullif(btrim(enviado_por), ''), '(sem nome)') as rotulo,
--            count(*) as mensagens
--     from mensagens where origem = 'advogado' group by 1
--   )
--   select r.rotulo, r.mensagens,
--     exists (select 1 from usuarios u where lower(btrim(u.nome)) = lower(r.rotulo)) as e_uma_pessoa
--   from rotulos r order by r.mensagens desc;
--
-- PASSO 2 — ver os nomes das pessoas cadastradas, para acertar o `nome_novo`:
--
--   select id, nome, email, admin from usuarios order by nome;
--
-- PASSO 3 — escrever. Duas formas na mesma tabela:
--
--   -- (a) é a mesma pessoa, com outro nome
--   insert into atendentes_de_para (nome_antigo, nome_novo, e_pessoa) values
--     ('rodrigo',          'Rodrigo Sousa',    true),
--     ('max',              'Max Canaverde',    true),
--     ('anderson.andrade', 'Anderson Andrade', true),
--     ('Isabelle',         'Isabelle Alencar', true)
--   on conflict (nome_antigo) do update
--     set nome_novo = excluded.nome_novo, e_pessoa = excluded.e_pessoa;
--
--   -- (b) não é pessoa: é nome de linha, ou mensagem sem autor
--   insert into atendentes_de_para (nome_antigo, e_pessoa) values
--     ('Cadastro - C&A',          false),
--     ('Atendimento Estratégico', false),
--     ('(sem nome)',              false)
--   on conflict (nome_antigo) do update set e_pessoa = excluded.e_pessoa;
--
-- PASSO 4 — ligar cada de-para de pessoa ao id dela, quando o nome bater:
--
--   update atendentes_de_para d
--      set usuario_id = u.id
--     from usuarios u
--    where d.e_pessoa and d.usuario_id is null
--      and lower(btrim(u.nome)) = lower(btrim(d.nome_novo));
--
-- Para desfazer qualquer linha:  delete from atendentes_de_para where nome_antigo = '...';

-- ============================================================
--  OPCIONAL — arrumar também o nome nas BOLHAS antigas
-- ============================================================
-- O de-para acima resolve o RELATÓRIO. As bolhas da conversa continuam
-- mostrando o nome de então ("rodrigo"), porque é o que está gravado.
--
-- O comando abaixo reescreve linha de mensagem, e NÃO TEM DESFAZER. Faça um
-- backup antes (Database > Backups). Vale a pena quando o nome velho é só um
-- resto de e-mail; não vale quando a pessoa mudou de nome de verdade e a
-- mensagem antiga deve continuar assinada como estava.
--
-- Antes, para ver quantas linhas seriam mexidas:
--
--   select d.nome_antigo, d.nome_novo, count(*) as mensagens
--     from mensagens m
--     join atendentes_de_para d
--       on lower(btrim(m.enviado_por)) = lower(btrim(d.nome_antigo))
--    where m.origem = 'advogado' and d.e_pessoa and d.nome_novo is not null
--    group by 1, 2 order by 3 desc;
--
--   update mensagens m
--      set enviado_por = d.nome_novo,
--          enviado_por_id = coalesce(m.enviado_por_id, d.usuario_id)
--     from atendentes_de_para d
--    where m.origem = 'advogado' and d.e_pessoa and d.nome_novo is not null
--      and lower(btrim(m.enviado_por)) = lower(btrim(d.nome_antigo));
