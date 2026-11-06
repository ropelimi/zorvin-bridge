-- ============================================================
--  O QUAZAR APRENDE COM A EQUIPE (os exemplos de verdade, e as notas de novo)
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Quem roda é a PONTE, sozinha, na publicação que vem com o merge.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O PEDIDO
--
--  Rodrigo, em 06/11: "O Quazar tem que usar nossos dados para aprender o
--  jeito que conversamos. O jeito que conversamos com o cliente é o jeito
--  certo!!! Ele é quem aprende com a gente [...] para parecer um dos nossos
--  operadores humanos. Use e abuse dos dados das conversas do telefone do
--  SAC. Lá é onde tem o ouro!" E: "O SAC é a fonte principal para o
--  departamento Sucesso do Cliente. Já para o departamento Acordos, todas as
--  conversas em todos os telefones do departamento Acordos devem ser a fonte
--  principal."
--
--  O QUE ESTAVA ERRADO: as notas que o Quazar escreveu lendo as conversas
--  (050) viraram uma lista de proibições — "levar ao responsável" em quase
--  toda linha, "não pedir senha nem código do gov.br" — e chegaram a dizer que
--  as conversas da própria equipe "não são modelo". Ele lia a equipe para
--  CORRIGI-LA. E a sugestão não via nenhuma resposta de verdade: só regras.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  1. `zorvin_copiloto_exemplos(conversa, texto, limite)` — as respostas de
--     verdade da equipe para mensagens PARECIDAS com a do cliente de agora.
--     A ponte chama a cada sugestão, e o Quazar imita o jeito.
--      - parecida é pelo trigrama (pg_trgm, o mesmo índice da busca), sem
--        acento, nos últimos 365 dias;
--      - o par é a mensagem do cliente (e as que ele mandou em seguida, até
--        três) e a resposta da equipe que veio depois, em até 24 horas (e as
--        que ela mandou em seguida, até três, sem o cliente no meio);
--      - não entram: a conversa de agora, grupo, aviso automático (037);
--      - uma por conversa, e a mesma resposta não se repete;
--      - completam a lista as trocas mais recentes da fonte principal (30
--        dias), para o jeito de escrever valer mesmo sem pergunta parecida;
--      - SECURITY INVOKER: a ponte chama como quem pediu, e cada pessoa só
--        recebe exemplos dos telefones que ela já vê.
--
--  2. `zorvin_copiloto_fontes` — de quais telefones vêm os exemplos de cada
--     departamento. Departamento SEM linha aqui: todos os telefones dele
--     (é o Acordos, como o Rodrigo pediu). Departamento COM linhas: esses
--     telefones são a fonte principal, e os outros do departamento entram com
--     menos peso. Nasce com o SAC como a fonte do Sucesso do Cliente, uma vez
--     só (a semente `copiloto:fonte-sac-054`). Quem entrou lê; quem
--     administra muda.
--
--  3. AS NOTAS COMEÇAM DE NOVO, uma vez (a semente
--     `copiloto:notas-de-novo-054`): a ponte passou a pedir notas do jeito de
--     escrever da equipe, e as de antes partiriam das proibições. O texto de
--     cada linha fica guardado em `zorvin_copiloto_aprendido_antes_054` antes
--     de apagar — inclusive a correção que o Rodrigo fez à mão nas do SAC.
--     A ponte relê primeiro o SAC, o Sucesso do Cliente e o Acordos: as outras
--     linhas ganham `aprendido_em` agora, e entram na fila depois delas.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    as tabelas do Zorvin, `zorvin_sem_acento`, o aviso automático (037), a
--    transcrição (015) e o copiloto que aprende (050). Sem as tabelas, não
--    faz nada; sem o resto, diz o que falta. Sem o pg_trgm, a função nasce
--    só com as trocas recentes, e a conferência diz.
-- ============================================================

do $exemplos$
declare
  v_anon   boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_auth   boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_srv    boolean := exists (select 1 from pg_roles where rolname = 'service_role');
  v_trgm   text;
  v_corpo  text;
  v_sim    text;
  v_filtro text;
  v_dep    bigint;
  v_sac    uuid;
  v_n      integer;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_054;
  create temp table zorvin_conferencia_054 (item text, resposta text);

  if to_regclass('public.conversas') is null or to_regclass('public.mensagens') is null
     or to_regclass('public.contatos') is null or to_regclass('public.advogados') is null
     or to_regclass('public.departamentos') is null or to_regprocedure('public.zorvin_admin()') is null then
    insert into zorvin_conferencia_054 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 054 não fez nada.';
    return;
  end if;
  if to_regprocedure('public.zorvin_sem_acento(text)') is null
     or not exists (select 1 from information_schema.columns where table_schema = 'public'
                     and table_name = 'mensagens' and column_name = 'automatica')
     or not exists (select 1 from information_schema.columns where table_schema = 'public'
                     and table_name = 'mensagens' and column_name = 'transcricao') then
    insert into zorvin_conferencia_054 values
      ('NÃO — falta zorvin_sem_acento, ou mensagens.automatica (037), ou mensagens.transcricao (015)', 'rode os scripts antes');
    raise notice 'Zorvin: script 054 precisa de zorvin_sem_acento, do 015 e do 037.';
    return;
  end if;

  -- ------------------------------------------------------------
  -- 1. AS FONTES DE CADA DEPARTAMENTO
  -- ------------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_copiloto_fontes (
      departamento_id  bigint not null references public.departamentos(id) on delete cascade,
      advogado_id      uuid   not null references public.advogados(id) on delete cascade,
      criada_em        timestamptz not null default now(),
      primary key (departamento_id, advogado_id)
    )
  $x$;
  execute $x$
    comment on table public.zorvin_copiloto_fontes is
      'De quais telefones o Quazar tira os exemplos de verdade de cada departamento. '
      'Departamento sem linha: todos os telefones dele.'
  $x$;
  -- A HERANÇA DA SUPABASE dá tudo a quem entrou e a quem não entrou (a
  -- armadilha nº 5): sai tudo, e volta só o que serve.
  execute 'alter table public.zorvin_copiloto_fontes enable row level security';
  if v_anon then execute 'revoke all on public.zorvin_copiloto_fontes from anon'; end if;
  if v_auth then
    execute 'revoke all on public.zorvin_copiloto_fontes from authenticated';
    execute 'grant select, insert, delete on public.zorvin_copiloto_fontes to authenticated';
    execute 'drop policy if exists zorvin_copiloto_fontes_leitura on public.zorvin_copiloto_fontes';
    execute 'create policy zorvin_copiloto_fontes_leitura on public.zorvin_copiloto_fontes
               for select to authenticated using (true)';
    execute 'drop policy if exists zorvin_copiloto_fontes_admin_cria on public.zorvin_copiloto_fontes';
    execute 'create policy zorvin_copiloto_fontes_admin_cria on public.zorvin_copiloto_fontes
               for insert to authenticated with check ((select public.zorvin_admin()))';
    execute 'drop policy if exists zorvin_copiloto_fontes_admin_apaga on public.zorvin_copiloto_fontes';
    execute 'create policy zorvin_copiloto_fontes_admin_apaga on public.zorvin_copiloto_fontes
               for delete to authenticated using ((select public.zorvin_admin()))';
  end if;
  if v_srv then execute 'grant all on public.zorvin_copiloto_fontes to service_role'; end if;

  -- AS SEMENTES (o 027). Sem a tabela, cria — ela é pequena e só da ponte.
  execute 'create table if not exists public.zorvin_sementes (
             chave text primary key, plantada_em timestamptz not null default now())';
  execute 'alter table public.zorvin_sementes enable row level security';
  if v_anon then execute 'revoke all on public.zorvin_sementes from anon'; end if;
  if v_auth then execute 'revoke all on public.zorvin_sementes from authenticated'; end if;

  -- O SAC COMO A FONTE DO SUCESSO DO CLIENTE, uma vez. Pelo nome: é o que o
  -- escritório chama assim. Num banco sem eles, a semente fica plantada e
  -- nada entra — quem administra escolhe a fonte depois.
  if not exists (select 1 from public.zorvin_sementes where chave = 'copiloto:fonte-sac-054') then
    select d.id into v_dep from public.departamentos d
     where public.zorvin_sem_acento(d.nome) = 'sucesso do cliente' order by d.id limit 1;
    if v_dep is not null then
      select a.id into v_sac from public.advogados a
       where a.departamento_id = v_dep and public.zorvin_sem_acento(btrim(a.nome)) = 'sac'
       order by a.id limit 1;
      if v_sac is not null then
        insert into public.zorvin_copiloto_fontes (departamento_id, advogado_id)
          values (v_dep, v_sac) on conflict do nothing;
      end if;
    end if;
    insert into public.zorvin_sementes (chave) values ('copiloto:fonte-sac-054') on conflict do nothing;
  end if;

  -- ------------------------------------------------------------
  -- 2. OS EXEMPLOS DE VERDADE
  --
  -- O trigrama mora numa extensão (o esquema é lido, como no 040). Sem ela,
  -- nada é "parecido", e ficam as trocas recentes.
  -- ------------------------------------------------------------
  select n.nspname into v_trgm
    from pg_operator o join pg_namespace n on n.oid = o.oprnamespace
   where o.oprname = '%' and o.oprleft = 'text'::regtype and o.oprright = 'text'::regtype
     and exists (select 1 from pg_proc p where p.proname = 'similarity' and p.pronamespace = n.oid)
   limit 1;
  if v_trgm is not null then
    v_sim := format('%I.similarity(public.zorvin_sem_acento(m.texto), alvo.t)', v_trgm);
    v_filtro := format('public.zorvin_sem_acento(m.texto) operator(%I.%%) alvo.t', v_trgm);
  else
    v_sim := '0::real';
    v_filtro := 'false';
  end if;

  v_corpo := $corpo$
create or replace function public.zorvin_copiloto_exemplos(p_conversa uuid, p_texto text, p_limite integer default 8)
  returns table (cliente text, equipe text, quando timestamptz, telefone text, nomes text, atendente text,
                 parecida real, principal boolean)
  language sql stable security invoker set search_path = public as $f$
  with conv as (
    select c.advogado_id, a.departamento_id
      from public.conversas c join public.advogados a on a.id = c.advogado_id
     where c.id = p_conversa
  ),
  -- AS FONTES: o telefone da conversa e os do departamento dele. Principal é
  -- o que `zorvin_copiloto_fontes` diz; sem linha, o departamento inteiro.
  fontes as (
    select a.id, a.nome,
           case when exists (select 1 from public.zorvin_copiloto_fontes f where f.departamento_id = conv.departamento_id)
                then exists (select 1 from public.zorvin_copiloto_fontes f
                              where f.departamento_id = conv.departamento_id and f.advogado_id = a.id)
                else true end as principal
      from public.advogados a, conv
     where a.id = conv.advogado_id
        or (conv.departamento_id is not null and a.departamento_id = conv.departamento_id and a.ativo is not false)
  ),
  alvo as (select public.zorvin_sem_acento(left(coalesce(p_texto, ''), 400)) as t),
  parecidas as (
    select m.id, m.conversa_id, m.criado_em, f.principal, (@SIM@)::real as sim, 0 as grupo
      from alvo, public.mensagens m
      join public.conversas c on c.id = m.conversa_id
      join public.contatos k on k.id = c.contato_id and k.numero not like 'grupo:%'
      join fontes f on f.id = c.advogado_id
     where length(alvo.t) >= 6 and @FILTRO@
       and m.origem = 'contato' and m.tipo = 'texto' and length(m.texto) between 4 and 1500
       and m.conversa_id <> p_conversa and m.criado_em > now() - interval '365 days'
     order by (@SIM@) + case when f.principal then 0.15 else 0 end desc
     limit 200
  ),
  recentes as (
    select m.id, m.conversa_id, m.criado_em, f.principal, 0::real as sim, 1 as grupo
      from public.mensagens m
      join public.conversas c on c.id = m.conversa_id
      join public.contatos k on k.id = c.contato_id and k.numero not like 'grupo:%'
      join fontes f on f.id = c.advogado_id and f.principal
     where m.origem = 'contato' and m.tipo = 'texto' and length(m.texto) between 4 and 1500
       and m.conversa_id <> p_conversa and m.criado_em > now() - interval '30 days'
     order by m.criado_em desc
     limit 200
  ),
  -- O PAR: a primeira resposta da equipe depois da mensagem do cliente, em
  -- até 24 horas, escrita por gente (o aviso automático não é a equipe).
  pares as (
    select a.*, r.id as resp_id, r.criado_em as resp_em, r.enviado_por_id
      from (select * from parecidas union all select * from recentes) a
      cross join lateral (
        select x.id, x.criado_em, x.enviado_por_id from public.mensagens x
         where x.conversa_id = a.conversa_id and x.criado_em > a.criado_em
           and x.criado_em < a.criado_em + interval '24 hours'
           and x.origem = 'advogado' and x.tipo = 'texto' and x.automatica is not true
           and btrim(coalesce(x.texto, '')) <> ''
         order by x.criado_em, x.id limit 1) r
  ),
  um_por_conversa as (
    select distinct on (p.conversa_id) p.*
      from pares p
     order by p.conversa_id, p.grupo, p.sim + case when p.principal then 0.15 else 0 end desc, p.criado_em desc
  ),
  com_texto as (
    select u.*,
           -- O CLIENTE: a mensagem e as que ele mandou até a resposta (até três).
           (select string_agg(y.t, E'\n' order by y.criado_em, y.id) from (
              select case when x.tipo = 'audio' then '[áudio] ' || x.transcricao else x.texto end as t, x.criado_em, x.id
                from public.mensagens x
               where x.conversa_id = u.conversa_id and x.origem = 'contato'
                 and x.criado_em >= u.criado_em and x.criado_em < u.resp_em
                 and ((x.tipo = 'texto' and btrim(coalesce(x.texto, '')) <> '')
                      or (x.tipo = 'audio' and btrim(coalesce(x.transcricao, '')) <> ''))
               order by x.criado_em, x.id limit 3) y) as cliente,
           -- A EQUIPE: a resposta e as que ela mandou em seguida, sem o cliente
           -- no meio, em até 15 minutos (até três).
           (select string_agg(y.texto, E'\n' order by y.criado_em, y.id) from (
              select x.texto, x.criado_em, x.id
                from public.mensagens x
               where x.conversa_id = u.conversa_id and x.origem = 'advogado' and x.tipo = 'texto'
                 and x.automatica is not true and btrim(coalesce(x.texto, '')) <> ''
                 and x.criado_em >= u.resp_em and x.criado_em < u.resp_em + interval '15 minutes'
                 and not exists (select 1 from public.mensagens z
                                  where z.conversa_id = u.conversa_id and z.origem = 'contato'
                                    and z.criado_em > u.resp_em and z.criado_em < x.criado_em)
               order by x.criado_em, x.id limit 3) y) as equipe
      from um_por_conversa u
  ),
  sem_repetir as (
    select distinct on (left(public.zorvin_sem_acento(t.equipe), 160)) t.*
      from com_texto t
     where t.cliente is not null and t.equipe is not null
     order by left(public.zorvin_sem_acento(t.equipe), 160), t.grupo,
              t.sim + case when t.principal then 0.15 else 0 end desc, t.criado_em desc
  )
  select s.cliente, s.equipe, s.criado_em,
         (select f.nome from public.conversas c join fontes f on f.id = c.advogado_id where c.id = s.conversa_id),
         (select concat_ws(' ', to_jsonb(k) ->> 'nome', to_jsonb(k) ->> 'nome_zorvin', to_jsonb(k) ->> 'vantoro_nome')
            from public.conversas c join public.contatos k on k.id = c.contato_id where c.id = s.conversa_id),
         (select e.nome from public.equipe e where e.id = s.enviado_por_id),
         s.sim, s.principal
    from sem_repetir s
   order by s.grupo, s.sim + case when s.principal then 0.15 else 0 end desc, s.criado_em desc
   limit greatest(1, least(coalesce(p_limite, 8), 20))
$f$
$corpo$;
  v_corpo := replace(replace(v_corpo, '@SIM@', v_sim), '@FILTRO@', v_filtro);
  execute v_corpo;

  execute 'revoke all on function public.zorvin_copiloto_exemplos(uuid, text, integer) from public';
  if v_anon then execute 'revoke all on function public.zorvin_copiloto_exemplos(uuid, text, integer) from anon'; end if;
  if v_auth then execute 'grant execute on function public.zorvin_copiloto_exemplos(uuid, text, integer) to authenticated'; end if;
  if v_srv then execute 'grant execute on function public.zorvin_copiloto_exemplos(uuid, text, integer) to service_role'; end if;

  -- ------------------------------------------------------------
  -- 3. AS NOTAS COMEÇAM DE NOVO, uma vez, guardadas antes
  -- ------------------------------------------------------------
  if to_regclass('public.zorvin_copiloto_aprendido') is not null then
    execute $x$
      create table if not exists public.zorvin_copiloto_aprendido_antes_054 (
        aprendido_id     uuid primary key,
        escopo           text,
        advogado_id      uuid,
        departamento_id  bigint,
        texto            text,
        mensagens_lidas  integer,
        leu_ate          timestamptz,
        editado_por      uuid,
        editado_em       timestamptz,
        guardado_em      timestamptz not null default now()
      )
    $x$;
    execute 'alter table public.zorvin_copiloto_aprendido_antes_054 enable row level security';
    if v_anon then execute 'revoke all on public.zorvin_copiloto_aprendido_antes_054 from anon'; end if;
    if v_auth then execute 'revoke all on public.zorvin_copiloto_aprendido_antes_054 from authenticated'; end if;

    if not exists (select 1 from public.zorvin_sementes where chave = 'copiloto:notas-de-novo-054') then
      insert into public.zorvin_copiloto_aprendido_antes_054
             (aprendido_id, escopo, advogado_id, departamento_id, texto, mensagens_lidas, leu_ate, editado_por, editado_em)
        select x.id, x.escopo, x.advogado_id, x.departamento_id, x.texto, x.mensagens_lidas, x.leu_ate,
               x.editado_por, x.editado_em
          from public.zorvin_copiloto_aprendido x
      on conflict (aprendido_id) do nothing;

      -- PRIMEIRO A FONTE PRINCIPAL: as linhas do SAC (e de toda fonte), do
      -- Sucesso do Cliente e do Acordos ficam sem `aprendido_em`, e a fila
      -- (050) começa por elas; as outras entram logo depois.
      update public.zorvin_copiloto_aprendido x
         set texto = '', leu_ate = null, leu_ate_id = null, mensagens_lidas = 0,
             editado_por = null, editado_em = null,
             aprendido_em = case
               when (x.escopo = 'telefone' and exists (select 1 from public.zorvin_copiloto_fontes f where f.advogado_id = x.advogado_id))
                 or (x.escopo = 'departamento' and exists (
                       select 1 from public.departamentos d where d.id = x.departamento_id
                          and public.zorvin_sem_acento(d.nome) in ('sucesso do cliente', 'acordos')))
               then null else now() end;
      get diagnostics v_n = row_count;
      insert into public.zorvin_sementes (chave) values ('copiloto:notas-de-novo-054') on conflict do nothing;
      insert into zorvin_conferencia_054 values ('linhas de notas que começaram de novo nesta rodada', v_n::text);
    end if;
  end if;

  -- ------------------------------------------------------------
  -- A CONFERÊNCIA
  -- ------------------------------------------------------------
  insert into zorvin_conferencia_054 values
    ('os exemplos de verdade procuram mensagens parecidas (pg_trgm)',
     case when v_trgm is null then 'NÃO — sem o pg_trgm: só as trocas recentes' else 'true' end),
    ('a fonte principal do Sucesso do Cliente',
     coalesce((select string_agg(a.nome, ', ' order by a.nome) from public.zorvin_copiloto_fontes f
                 join public.advogados a on a.id = f.advogado_id), '(nenhuma: todos os telefones de cada departamento)')),
    ('notas guardadas antes de começar de novo',
     case when to_regclass('public.zorvin_copiloto_aprendido_antes_054') is null then '(sem o 050)'
          else (select count(*) from public.zorvin_copiloto_aprendido_antes_054)::text end);
  if v_auth then
    insert into zorvin_conferencia_054 values
      ('quem entrou chama os exemplos (a ponte chama como quem pediu)',
       has_function_privilege('authenticated', 'public.zorvin_copiloto_exemplos(uuid, text, integer)', 'execute')::text),
      ('quem entrou lê as fontes, e não as notas guardadas',
       (has_table_privilege('authenticated', 'public.zorvin_copiloto_fontes', 'select')
        and not has_table_privilege('authenticated', 'public.zorvin_copiloto_fontes', 'update')
        and (to_regclass('public.zorvin_copiloto_aprendido_antes_054') is null
             or not has_table_privilege('authenticated', 'public.zorvin_copiloto_aprendido_antes_054', 'select')))::text);
  end if;
  if v_anon then
    insert into zorvin_conferencia_054 values
      ('quem não entrou não alcança nada disto',
       (not has_function_privilege('anon', 'public.zorvin_copiloto_exemplos(uuid, text, integer)', 'execute')
        and not has_table_privilege('anon', 'public.zorvin_copiloto_fontes', 'select'))::text);
  end if;
end
$exemplos$;

-- ----------------------------------------------------------
--  E A CONFERÊNCIA NO PAPEL DE QUEM ATENDE — a régua 4 do LEIA-ME: os
--  exemplos são chamados como `authenticated`, numa conversa de verdade da
--  fonte principal, por alguém que administra. Só a contagem sai daqui. A
--  troca de papel volta atrás sozinha (o `true` do set_config).
-- ----------------------------------------------------------
do $conf$
declare
  v_admin    uuid;
  v_conversa uuid;
  v_n        integer;
begin
  if to_regprocedure('public.zorvin_copiloto_exemplos(uuid, text, integer)') is null
     or not exists (select 1 from pg_roles where rolname = 'authenticated')
     or to_regclass('public.usuarios') is null then
    return;
  end if;
  select u.id into v_admin from public.usuarios u where u.admin is true and u.ativo is not false order by u.id limit 1;
  select c.id into v_conversa
    from public.conversas c
   where exists (select 1 from public.zorvin_copiloto_fontes f where f.advogado_id = c.advogado_id)
   order by c.ultima_atividade desc nulls last limit 1;
  if v_admin is null or v_conversa is null then
    insert into zorvin_conferencia_054 values ('exemplos chamados no papel de quem atende', '(sem quem administra ou sem conversa na fonte)');
    return;
  end if;
  begin
    perform set_config('request.jwt.claim.sub', v_admin::text, true);
    perform set_config('role', 'authenticated', true);
    execute 'select count(*) from public.zorvin_copiloto_exemplos($1, $2, 8)'
      into v_n using v_conversa, 'bom dia, como está o andamento do meu processo?';
    execute 'reset role';
    perform set_config('request.jwt.claim.sub', '', true);
    insert into zorvin_conferencia_054 values ('exemplos chamados no papel de quem atende (de 8)', v_n::text);
  exception when others then
    insert into zorvin_conferencia_054 values
      ('exemplos chamados no papel de quem atende', 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')');
  end;
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_054;
