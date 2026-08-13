-- O PAINEL PASSA A CONTAR NO BANCO.
--
-- A primeira versão da tela baixava as mensagens e contava no navegador. Não
-- funciona, por um motivo que não aparece em base pequena: a API do Supabase
-- devolve no máximo 1000 linhas por consulta e NÃO AVISA. Não vem erro, não
-- vem aviso — vem uma lista curta com cara de lista inteira. O resultado era
-- um painel que parava de crescer em 1000, escondia os telefones que não
-- couberam na fatia, e fazia "7 dias" e "Tudo" darem o mesmo número.
--
-- Contando aqui, o total é o total. Uma ida ao banco em vez de milhares de
-- linhas trafegadas, e o Postgres soma o que ele já tem em índice.
--
-- SEGURANÇA: a função é SECURITY INVOKER (o padrão). Ela enxerga exatamente
-- o que quem chamou enxergaria — as regras de RLS das tabelas continuam
-- valendo linha a linha. Não é um atalho para ler o que não se pode ler.
--
-- Rodar no SQL Editor do Supabase. Pode rodar de novo à vontade.

create or replace function painel_numeros(p_desde timestamptz default null)
returns jsonb
language plpgsql
stable
as $$
declare
  v_notas bigint := 0;
  v_saida jsonb;
begin
  -- `notas` é tabela separada e nasceu depois; em base que ainda não a tenha,
  -- a contagem é zero em vez de a tela inteira falhar.
  if to_regclass('public.notas') is not null then
    execute 'select count(*) from notas where $1 is null or criado_em >= $1'
      into v_notas using p_desde;
  end if;

  with msg as (
    select m.origem, m.enviado_por, m.enviado_por_id, m.criado_em, c.advogado_id
    from mensagens m
    join conversas c on c.id = m.conversa_id
    where p_desde is null or m.criado_em >= p_desde
  ),
  -- "WhatsApp" é o rótulo que a própria ponte grava quando a mensagem saiu
  -- pelo aparelho, fora do Zorvin. Não é atendente, e deixá-lo na lista de
  -- gente — quase sempre no topo — é um número errado com cara de certo.
  gente as (
    select
      case when enviado_por_id is not null then 'id:' || enviado_por_id::text
           else 'nome:' || coalesce(nullif(btrim(enviado_por), ''), '(sem nome)') end as chave,
      (array_agg(enviado_por_id order by criado_em desc))[1] as enviado_por_id,
      (array_agg(coalesce(nullif(btrim(enviado_por), ''), '(sem nome)')
                 order by criado_em desc))[1] as nome,
      count(*) as enviadas
    from msg
    where origem = 'advogado' and coalesce(btrim(enviado_por), '') <> 'WhatsApp'
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
    -- Qualquer `origem` que não seja uma das duas conhecidas fica À PARTE, e
    -- não somada às recebidas. Se um dia aparecer um valor novo, o painel
    -- mostra que apareceu em vez de engordar uma coluna em silêncio.
    'outras',    (select count(*) from msg where origem not in ('contato', 'advogado')),
    'aparelho',  (select count(*) from msg
                   where origem = 'advogado' and coalesce(btrim(enviado_por), '') = 'WhatsApp'),
    -- Enviadas por gente, mas sem id: histórico anterior a ago/2026. Contam
    -- pelo nome, com a imprecisão que o nome tem.
    'sem_id',    (select count(*) from msg
                   where origem = 'advogado' and enviado_por_id is null
                     and coalesce(btrim(enviado_por), '') <> 'WhatsApp'),
    'notas',     v_notas,
    'por_telefone', coalesce((select jsonb_agg(to_jsonb(t)) from tel t), '[]'::jsonb),
    'por_pessoa',   coalesce((select jsonb_agg(to_jsonb(g)) from gente g), '[]'::jsonb)
  ) into v_saida;

  return v_saida;
end;
$$;

-- No Supabase o papel `authenticated` sempre existe; o `if` é para este mesmo
-- arquivo poder rodar num Postgres comum, que é onde eu testo a função antes
-- de te mandar.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function painel_numeros(timestamptz) to authenticated';
  end if;
end;
$$;

comment on function painel_numeros(timestamptz) is
  'Contagens do Painel do Zorvin. p_desde nulo = desde sempre. Respeita RLS.';
