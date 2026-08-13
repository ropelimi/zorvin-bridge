-- DE-PARA DE ATENDENTES — juntar o histórico à pessoa certa.
--
-- O problema: durante muito tempo o nome de quem enviou foi gravado como
-- TEXTO, e em vários casos esse texto era o começo do e-mail ("rodrigo",
-- "max", "isabelle"), porque era o único nome que o sistema tinha na hora.
-- No Painel, "rodrigo" e "Rodrigo Sousa" viram duas pessoas.
--
-- A saída NÃO é sair reescrevendo mensagem antiga. É dizer, numa tabela à
-- parte, que aquele nome antigo é aquela pessoa. Vantagens de fazer assim:
--
--   * é REVERSÍVEL. Errou o de-para? Apaga a linha e pronto. Um `update` em
--     `mensagens` não tem volta.
--   * o de-para vale para o histórico INTEIRO de uma vez, inclusive para o
--     que ainda vai ser importado com o nome velho.
--   * a bolha da conversa continua mostrando o que mostrava.
--
-- (Se você preferir arrumar também o que aparece nas bolhas antigas, tem um
--  script separado para isso no fim deste arquivo, comentado. Leia antes.)
--
-- Rodar no SQL Editor do Supabase. Pode rodar de novo à vontade.

create table if not exists atendentes_de_para (
  -- O nome como está gravado nas mensagens antigas. Sem diferenciar
  -- maiúscula de minúscula na hora de casar (ver a função): "Rodrigo" e
  -- "rodrigo" são a mesma coisa aqui.
  nome_antigo text primary key,
  -- Para quem ele aponta. O ideal é o id: aí a pessoa passa a ser contada
  -- junto com as mensagens novas dela, que já saem identificadas.
  usuario_id  uuid,
  -- E o nome para mostrar no relatório.
  nome_novo   text not null,
  criado_em   timestamptz default now()
);

alter table atendentes_de_para enable row level security;

-- Leitura para quem está dentro do Zorvin: a função do Painel roda com os
-- direitos de quem chamou, e sem poder ler esta tabela o de-para não valeria.
-- Escrita não passa por aqui — é pelo SQL Editor, com você olhando.
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
  'Nome antigo gravado em mensagens.enviado_por -> a pessoa de verdade. Só o Painel usa.';

-- ============================================================
--  PASSO 1 — VER QUAIS NOMES EXISTEM
-- ============================================================
-- Rode isto sozinho primeiro. Ele lista todo nome que já assinou uma mensagem
-- enviada, quantas mensagens tem, e se já está resolvido. Não adianta escrever
-- o de-para de memória: o que vale é o que está gravado.
--
--   select
--     coalesce(nullif(btrim(enviado_por), ''), '(sem nome)') as nome_gravado,
--     count(*) as mensagens,
--     count(enviado_por_id) as ja_tem_id,
--     min(criado_em)::date as desde,
--     max(criado_em)::date as ate
--   from mensagens
--   where origem = 'advogado'
--   group by 1
--   order by mensagens desc;
--
-- "WhatsApp" vai aparecer nessa lista. NÃO faça de-para dele: não é pessoa, é
-- mensagem enviada pelo aparelho, e o Painel já a separa sozinho.

-- ============================================================
--  PASSO 2 — ESCREVER O DE-PARA
-- ============================================================
-- Troque pelos nomes que apareceram no passo 1. O `usuario_id` sai da consulta
-- logo abaixo; se você não souber o id de alguém, pode deixar `null` e só o
-- nome já junta as linhas no relatório.
--
--   select id, nome, email from usuarios order by nome;
--
-- Estes três são os do exemplo que você me deu — confira os ids antes.

-- insert into atendentes_de_para (nome_antigo, usuario_id, nome_novo) values
--   ('rodrigo',  null, 'Rodrigo Sousa'),
--   ('max',      null, 'Max Canaverde'),
--   ('isabelle', null, 'Isabelle Alencar')
-- on conflict (nome_antigo) do update
--   set usuario_id = excluded.usuario_id, nome_novo = excluded.nome_novo;

-- Um jeito de preencher o `usuario_id` sem copiar id na mão, quando o nome
-- novo é igual ao que está em `usuarios`:
--
--   update atendentes_de_para d
--      set usuario_id = u.id
--     from usuarios u
--    where d.usuario_id is null
--      and lower(btrim(u.nome)) = lower(btrim(d.nome_novo));

-- ============================================================
--  PASSO 3 — A FUNÇÃO DO PAINEL PASSA A CONSULTAR O DE-PARA
-- ============================================================
-- Substitui a versão anterior. A única diferença é que agora, antes de
-- agrupar, cada mensagem passa pelo de-para: quem não tem id pode ganhar um, e
-- o nome mostrado passa a ser o novo.

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

  with msg as (
    select
      m.origem,
      m.criado_em,
      c.advogado_id,
      -- QUEM ENVIOU, já resolvido. O id gravado manda; na falta dele, o id que
      -- o de-para apontar; e o nome mostrado é o novo, quando houver.
      coalesce(m.enviado_por_id, dp.usuario_id) as quem_id,
      coalesce(nullif(btrim(dp.nome_novo), ''), nullif(btrim(m.enviado_por), '')) as quem_nome,
      -- O rótulo CRU, para reconhecer o "WhatsApp" mesmo que alguém tenha feito
      -- um de-para dele por engano.
      coalesce(btrim(m.enviado_por), '') as rotulo
    from mensagens m
    join conversas c on c.id = m.conversa_id
    left join atendentes_de_para dp
      on lower(btrim(m.enviado_por)) = lower(btrim(dp.nome_antigo))
    where p_desde is null or m.criado_em >= p_desde
  ),
  gente as (
    select
      case when quem_id is not null then 'id:' || quem_id::text
           else 'nome:' || coalesce(quem_nome, '(sem nome)') end as chave,
      (array_agg(quem_id order by criado_em desc))[1] as enviado_por_id,
      (array_agg(coalesce(quem_nome, '(sem nome)') order by criado_em desc))[1] as nome,
      count(*) as enviadas
    from msg
    where origem = 'advogado' and rotulo <> 'WhatsApp'
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
    'aparelho',  (select count(*) from msg where origem = 'advogado' and rotulo = 'WhatsApp'),
    -- Agora conta quem continua SEM id DEPOIS do de-para. Quem foi resolvido
    -- sai desta conta, e é assim que o aviso da tela vai encolhendo.
    'sem_id',    (select count(*) from msg
                   where origem = 'advogado' and rotulo <> 'WhatsApp' and quem_id is null),
    'notas',     v_notas,
    'por_telefone', coalesce((select jsonb_agg(to_jsonb(t)) from tel t), '[]'::jsonb),
    'por_pessoa',   coalesce((select jsonb_agg(to_jsonb(g)) from gente g), '[]'::jsonb)
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
--  OPCIONAL — arrumar também o nome nas BOLHAS antigas
-- ============================================================
-- O de-para acima resolve o RELATÓRIO. As bolhas da conversa continuam
-- mostrando o nome de então ("rodrigo"), porque é o que está gravado.
--
-- Se você quiser que as bolhas antigas passem a mostrar o nome novo, rode o
-- comando abaixo. PENSE ANTES: ele reescreve linha de mensagem, e não tem
-- desfazer. Faça um backup do Supabase primeiro (Database > Backups).
--
-- Vale a pena quando o nome velho é só um resto de e-mail, como "rodrigo" —
-- ninguém quer preservar isso. Não vale quando a pessoa mudou de nome de
-- verdade e a mensagem antiga deve continuar assinada como estava.
--
--   update mensagens m
--      set enviado_por = d.nome_novo,
--          enviado_por_id = coalesce(m.enviado_por_id, d.usuario_id)
--     from atendentes_de_para d
--    where m.origem = 'advogado'
--      and lower(btrim(m.enviado_por)) = lower(btrim(d.nome_antigo));
--
-- Para ver quantas linhas isso mexeria, sem mexer:
--
--   select d.nome_antigo, d.nome_novo, count(*) as mensagens
--     from mensagens m
--     join atendentes_de_para d
--       on lower(btrim(m.enviado_por)) = lower(btrim(d.nome_antigo))
--    where m.origem = 'advogado'
--    group by 1, 2 order by 3 desc;
