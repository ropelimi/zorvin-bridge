-- ============================================================
--  O RELATÓRIO DO "JÁ TRATEI"
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 30/09: *"preciso de algum lugar para metrificar essas
--  informações, do que foi tratado, por quem"*. O "Já tratei" grava desde 25/09
--  (script 005) e o texto do OUTROS desde o 009 — e não havia onde LER nada
--  disso. Esta função é essa leitura, e a tela é uma seção nova do Painel de
--  números, embaixo dos mesmos filtros.
--
--  ------------------------------------------------------------
--  A CONTA É FEITA AQUI, e não no navegador
--
--  Pelo mesmo motivo de `painel_dashboard`: a API do Supabase devolve no
--  máximo 1000 linhas por consulta e NÃO AVISA que cortou. Um mês de "Já
--  tratei" do escritório passa disso, e somar no navegador daria um número
--  menor com cara de número certo.
--
--  UM "JÁ TRATEI" É UM CLIQUE, e não uma linha. Cada clique grava uma linha
--  por assunto marcado (ACORDOS + VENDA LN = duas linhas), todas com a mesma
--  conversa, a mesma pessoa e o mesmo instante (`now()` é o mesmo dentro de um
--  `insert`). Contar linhas diria "a equipe tratou 2" quando tratou 1. Então:
--
--    tratamentos   cliques           — "quantas vezes alguém disse já tratei"
--    conversas     conversas únicas  — "quantos clientes saíram da fila"
--    marcacoes     linhas            — a soma do "por assunto"
--
--  O DESFEITO NÃO CONTA, e aparece à parte. Marcar por engano e desfazer não é
--  trabalho feito; esconder o número também não serve — muitos desfeitos são,
--  eles mesmos, a notícia.
--
--  ------------------------------------------------------------
--  CADA UM VÊ O QUE É SEU — a régua do Painel
--
--  Quem não administra recebe só os próprios tratamentos, e o recorte é FEITO
--  AQUI (`auth.uid()`), e não no navegador: recorte que o navegador pode
--  desligar é sugestão. A exceção é o "por pessoa", que mostra todo mundo pela
--  mesma razão do Painel: comparação com uma linha só não é comparação.
--
--  E A FUNÇÃO É `security invoker` (o padrão): ela enxerga só as conversas que
--  quem chama já enxerga pelas regras de `conversas`. Um relatório não pode ser
--  a porta dos fundos para os clientes de um telefone que a pessoa não atende.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    005 — o "Já tratei"      009 — o OUTROS (o texto; sem ele vem nulo)
-- ============================================================

-- Apaga qualquer versão anterior ANTES de criar. `create or replace` com outra
-- lista de argumentos não substitui: cria uma segunda função de mesmo nome, e
-- a chamada do navegador morreria com "could not choose the best candidate".
do $limpa$
declare r record;
begin
  for r in select oid::regprocedure as f from pg_proc
            where proname = 'zorvin_relatorio_tratados'
              and pronamespace = 'public'::regnamespace
  loop execute 'drop function ' || r.f; end loop;
end
$limpa$;

-- A FUNÇÃO É CRIADA SEMPRE, mesmo num banco sem as tabelas: é `plpgsql`, e os
-- nomes de dentro só são resolvidos quando ela roda. Assim a prova 51l-bis (que
-- aplica esta pasta num banco LIMPO) passa, e num banco de verdade ela serve.
create function public.zorvin_relatorio_tratados(
  p_desde        timestamptz default null,
  p_ate          timestamptz default null,
  p_quem         uuid        default null,
  p_fuso         text        default 'America/Campo_Grande',
  p_telefone     uuid        default null,
  p_departamento bigint      default null,
  -- QUANTOS REGISTROS, no máximo, vêm na lista de baixo. As somas de cima são
  -- sempre do período inteiro; só a lista é aparada — e ela diz de quantos.
  p_limite       integer     default 500
)
returns jsonb
language plpgsql
stable
as $fn$
declare
  v_ate   timestamptz := coalesce(p_ate, now());
  v_desde timestamptz := coalesce(p_desde, '-infinity'::timestamptz);
  v_quem  uuid := p_quem;
  v_fuso  text := coalesce(p_fuso, 'America/Campo_Grande');
  v_lim   integer := least(greatest(coalesce(p_limite, 500), 1), 2000);
  v_saida jsonb;
begin
  -- QUEM NÃO ADMINISTRA NÃO ESCOLHE. Aqui, e não no navegador.
  if to_regprocedure('public.zorvin_admin()') is not null then
    if not public.zorvin_admin() then v_quem := auth.uid(); end if;
  end if;

  -- Fuso inválido derrubaria a tela com "time zone not recognized".
  if not exists (select 1 from pg_timezone_names where name = v_fuso) then
    v_fuso := 'America/Campo_Grande';
  end if;

  with base as (
    -- UMA LINHA POR ASSUNTO MARCADO, já recortada por período e lugar. O texto
    -- vem por `to_jsonb` para a função não quebrar num banco sem o script 009:
    -- pedir `t.observacao` por nome ali seria "column does not exist".
    select t.id, t.conversa_id, t.assunto_id, t.quem, t.quando,
           t.esperava_desde, t.desfeito_em,
           to_jsonb(t) ->> 'observacao' as observacao,
           c.advogado_id, c.contato_id
      from public.zorvin_tratamentos t
      join public.conversas c on c.id = t.conversa_id
      left join public.advogados a on a.id = c.advogado_id
     where t.quando >= v_desde and t.quando <= v_ate
       and (p_telefone is null or c.advogado_id = p_telefone)
       and (p_departamento is null or a.departamento_id = p_departamento)
  ),
  eventos as (
    -- UM CLIQUE: mesma conversa, mesma pessoa, mesmo instante.
    select conversa_id, quem, quando, advogado_id, contato_id,
           bool_or(desfeito_em is not null)                         as desfeito,
           max(desfeito_em)                                         as desfeito_em,
           min(esperava_desde)                                      as esperava_desde,
           array_agg(distinct assunto_id)                           as assuntos,
           string_agg(observacao, ' · ') filter (where observacao is not null) as observacao
      from base
     group by conversa_id, quem, quando, advogado_id, contato_id
  ),
  meus as (
    select * from eventos where v_quem is null or quem = v_quem
  ),
  valendo as (
    select * from meus where not desfeito
  ),
  nomes as (
    -- OS NOMES DE HOJE, pela vista `equipe` (id, nome, foto) — a mesma que as
    -- bolhas usam. `usuarios` direto não serve: a regra dela mostra a quem não
    -- administra só a própria linha, e o "por pessoa" viraria "alguém".
    select id, nome from public.equipe
  )
  select jsonb_build_object(
    'so_meu', v_quem is not null,
    'total', jsonb_build_object(
      'tratamentos', (select count(*) from valendo),
      'conversas',   (select count(distinct conversa_id) from valendo),
      'marcacoes',   (select count(*) from base b
                       where b.desfeito_em is null and (v_quem is null or b.quem = v_quem)),
      'desfeitos',   (select count(*) from meus where desfeito),
      -- QUANTO O CLIENTE ESPERAVA quando alguém disse "já tratei", em dias. É
      -- o que separa limpar a fila de ontem de fazer um mutirão no esquecido.
      'espera_mediana_dias', (select percentile_cont(0.5) within group (
                                 order by extract(epoch from (quando - esperava_desde)) / 86400.0)
                                from valendo where esperava_desde is not null),
      'com_espera', (select count(*) from valendo where esperava_desde is not null)
    ),
    'por_assunto', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.assunto_id, 'nome', x.nome,
                                          'ativo', x.ativo, 'vezes', x.vezes)
                       order by x.vezes desc, x.nome)
        from (select b.assunto_id, s.nome, s.ativo, count(*) as vezes
                from base b
                join public.zorvin_assuntos s on s.id = b.assunto_id
               where b.desfeito_em is null and (v_quem is null or b.quem = v_quem)
               group by b.assunto_id, s.nome, s.ativo) x), '[]'::jsonb),
    -- TODO MUNDO, mesmo quando o resto está recortado numa pessoa: é para
    -- comparar, como o "por atendente" do Painel.
    'por_pessoa', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.quem, 'nome', x.nome, 'tratamentos', x.n)
                       order by x.n desc, x.nome)
        from (select e.quem, coalesce(n.nome, '(sem nome)') as nome, count(*) as n
                from eventos e left join nomes n on n.id = e.quem
               where not e.desfeito
               group by e.quem, n.nome) x), '[]'::jsonb),
    'por_dia', coalesce((
      select jsonb_agg(jsonb_build_object('quando', x.dia, 'tratamentos', x.n) order by x.dia)
        from (select (quando at time zone v_fuso)::date as dia, count(*) as n
                from valendo group by 1) x), '[]'::jsonb),
    'total_registros', (select count(*) from meus),
    'registros', coalesce((
      select jsonb_agg(r order by r ->> 'quando' desc)
        from (select jsonb_build_object(
                       'quando', e.quando,
                       'quem', e.quem,
                       'quem_nome', n.nome,
                       'conversa_id', e.conversa_id,
                       'advogado_id', e.advogado_id,
                       'contato', jsonb_build_object(
                          'nome', ct.nome, 'numero', ct.numero,
                          'nome_zorvin', to_jsonb(ct) ->> 'nome_zorvin',
                          'vantoro_nome', to_jsonb(ct) ->> 'vantoro_nome'),
                       'assuntos', (select jsonb_agg(s.nome order by s.ordem, s.nome)
                                      from public.zorvin_assuntos s
                                     where s.id = any(e.assuntos)),
                       'observacao', e.observacao,
                       'esperava_desde', e.esperava_desde,
                       'desfeito', e.desfeito,
                       'desfeito_em', e.desfeito_em) as r
                from meus e
                left join nomes n on n.id = e.quem
                left join public.contatos ct on ct.id = e.contato_id
               order by e.quando desc
               limit v_lim) y), '[]'::jsonb)
  ) into v_saida;

  return v_saida;
end
$fn$;

comment on function public.zorvin_relatorio_tratados(timestamptz, timestamptz, uuid, text, uuid, bigint, integer) is
  'O relatório do "Já tratei": somas do período (um clique = um tratamento), '
  'por assunto, por pessoa (todos), por dia e os registros. Quem não administra '
  'recebe só os próprios. security invoker: enxerga só as conversas de quem chama.';

-- `public` inclui quem não entrou (`anon`). Tira dele e devolve a quem entrou,
-- na mesma passada — a régua de 2026-09-as-quatro-funcoes-que-rodam-com-poder-de-dono.
revoke all on function public.zorvin_relatorio_tratados(timestamptz, timestamptz, uuid, text, uuid, bigint, integer) from public;
do $grant$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.zorvin_relatorio_tratados(timestamptz, timestamptz, uuid, text, uuid, bigint, integer) to authenticated';
  end if;
end
$grant$;

-- ----------------------------------------------------------
--  A CONFERÊNCIA VAI DENTRO DO SCRIPT, e é a última linha dele: o editor do
--  Supabase só mostra o resultado do último comando. Tabela temporária criada
--  ANTES da guarda — a lição do 006 e do 007.
-- ----------------------------------------------------------
do $conf$
begin
  drop table if exists zorvin_conferencia_010;
  create temp table zorvin_conferencia_010 (item text, resposta text);

  insert into zorvin_conferencia_010
  select 'a função do relatório existe',
         (to_regprocedure('public.zorvin_relatorio_tratados(timestamptz, timestamptz, uuid, text, uuid, bigint, integer)') is not null)::text;

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    insert into zorvin_conferencia_010
    select 'quem entrou pode usá-la',
           has_function_privilege('authenticated',
             'public.zorvin_relatorio_tratados(timestamptz, timestamptz, uuid, text, uuid, bigint, integer)',
             'execute')::text;
  end if;

  if to_regclass('public.zorvin_tratamentos') is null then
    insert into zorvin_conferencia_010 values ('sem a tabela do "Já tratei"', 'rode o script 005 antes');
    return;
  end if;

  execute $q$
    insert into zorvin_conferencia_010
    select '"já tratei" registrados até hoje',
           count(*)::text
      from (select distinct conversa_id, quem, quando from public.zorvin_tratamentos
             where desfeito_em is null) x
  $q$;
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_010;
