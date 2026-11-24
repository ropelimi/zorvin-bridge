-- ============================================================
--  O QUAZAR MELHORA O TEXTO — A MARCA E O RELATÓRIO
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  A ponte aplica sozinha ao subir (sql/automaticos). Pode rodar de novo sem
--  medo — na ordem da pasta, como diz a regra 5 do LEIA-ME.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 24/11: "uma atualização onde após digitar um texto na
--  conversa, a opção do Quazar estar disponível para melhorar o texto."
--
--  O texto melhorado pelo Quazar também vai ao cliente, e o escritório pediu
--  em 18/11 para saber quando o Quazar foi usado. Então:
--
--    fila_envio.sugestao_quazar   aceita 'melhorada': a mensagem que a pessoa
--    mensagens.sugestao_quazar    escreveu e o Quazar melhorou (com ou sem
--                                 mudança depois). 'igual' e 'editada'
--                                 continuam sendo as do "Sugerir resposta"
--    zorvin_sugestoes.tipo        aceita 'melhorar': o pedido que deu certo
--    zorvin_relatorio_sugestoes   conta à parte as melhorias pedidas
--                                 (`melhorias`) e as mensagens que saíram
--                                 melhoradas (`melhoradas`), no total, por
--                                 pessoa, por dia e no período anterior.
--                                 `usadas` continua sendo só a sugestão usada
--                                 (sem mudança e editada): somar as melhoradas
--                                 ali faria a parte das pedidas passar de 100%
--
--  O 063 é a VERSÃO DE REFERÊNCIA do relatório daqui para a frente (regra 5):
--  rodar o 060 sozinho depois dele põe de volta a conta sem as melhorias.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    o 060 (a marca, os pedidos e o relatório). Sem ele, não faz nada e diz.
-- ============================================================

do $mel$
declare
  v_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_srv  boolean := exists (select 1 from pg_roles where rolname = 'service_role');
  v_regra record;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA (a lição do 006).
  drop table if exists zorvin_conferencia_063;
  create temp table zorvin_conferencia_063 (item text, resposta text);

  if to_regclass('public.conversas') is null or to_regclass('public.mensagens') is null
     or to_regclass('public.fila_envio') is null or to_regclass('public.usuarios') is null
     or to_regclass('public.advogados') is null
     or to_regprocedure('public.zorvin_admin()') is null then
    insert into zorvin_conferencia_063 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 063 não fez nada.';
    return;
  end if;
  if to_regclass('public.zorvin_sugestoes') is null
     or (select count(*) from information_schema.columns where table_schema = 'public'
          and column_name = 'sugestao_quazar' and table_name in ('fila_envio', 'mensagens')) < 2 then
    insert into zorvin_conferencia_063 values ('falta o 060 (a marca da sugestão)', 'NÃO — rode o 060 antes');
    return;
  end if;

  -- ------------------------------------------------------------
  -- 1. A MARCA ACEITA 'melhorada'
  -- ------------------------------------------------------------
  -- Refeita na mesma transação: não há instante sem a regra.
  execute 'alter table public.fila_envio drop constraint if exists fila_envio_sugestao_quazar_valida';
  execute $x$alter table public.fila_envio add constraint fila_envio_sugestao_quazar_valida
             check (sugestao_quazar is null or sugestao_quazar in ('igual', 'editada', 'melhorada'))$x$;
  execute 'alter table public.mensagens drop constraint if exists mensagens_sugestao_quazar_valida';
  execute $x$alter table public.mensagens add constraint mensagens_sugestao_quazar_valida
             check (sugestao_quazar is null or sugestao_quazar in ('igual', 'editada', 'melhorada'))$x$;

  -- ------------------------------------------------------------
  -- 2. O PEDIDO ACEITA 'melhorar'
  -- ------------------------------------------------------------
  -- A regra do tipo nasceu sem nome no 060 (o Postgres a chama
  -- "zorvin_sugestoes_tipo_check"): sai TODA regra da tabela que fala do
  -- tipo, e entra uma, com nome.
  for v_regra in
    select conname from pg_constraint
     where conrelid = 'public.zorvin_sugestoes'::regclass and contype = 'c'
       and pg_get_constraintdef(oid) ilike '%tipo%'
  loop
    execute format('alter table public.zorvin_sugestoes drop constraint %I', v_regra.conname);
  end loop;
  execute $x$alter table public.zorvin_sugestoes add constraint zorvin_sugestoes_tipo_valido
             check (tipo in ('sugerir', 'ajustar', 'melhorar'))$x$;
  execute $x$
    comment on table public.zorvin_sugestoes is
      'Um "Sugerir resposta", "Pedir uma mudança" ou "Melhorar o texto" do Quazar que deu certo: '
      'quem pediu, em qual conversa e quando. Só a ponte escreve.'
  $x$;

  -- ------------------------------------------------------------
  -- 3. O RELATÓRIO, COM AS MELHORIAS À PARTE
  -- ------------------------------------------------------------
  -- A mesma assinatura do 060: `create or replace` guarda as permissões, e o
  -- painel de antes, que não lê as chaves novas, continua lendo as de sempre.
  execute $x$
create or replace function public.zorvin_relatorio_sugestoes(
  p_desde        timestamptz default null,
  p_ate          timestamptz default null,
  p_quem         uuid        default null,
  p_fuso         text        default 'America/Sao_Paulo',
  p_telefone     uuid        default null,
  p_departamento bigint      default null
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $fn$
declare
  v_ate   timestamptz := coalesce(p_ate, now());
  v_desde timestamptz := coalesce(p_desde, now() - interval '30 days');
  v_antes timestamptz;
  v_quem  uuid := p_quem;
  v_so_meu boolean := false;
  v_fuso  text := coalesce(p_fuso, 'America/Sao_Paulo');
  v_saida jsonb;
begin
  if not public.zorvin_admin() then v_quem := auth.uid(); v_so_meu := true; end if;
  if not exists (select 1 from pg_timezone_names where name = v_fuso) then v_fuso := 'America/Sao_Paulo'; end if;
  v_antes := v_desde - (v_ate - v_desde);

  with msgs as (
    select m.enviado_por_id as quem, m.criado_em as quando, m.sugestao_quazar as marca
      from public.mensagens m
      join public.conversas c on c.id = m.conversa_id
      left join public.advogados a on a.id = c.advogado_id
     where m.criado_em >= v_antes and m.criado_em <= v_ate
       and m.origem = 'advogado' and m.tipo = 'texto'
       and m.enviado_por_id is not null and not coalesce(m.automatica, false)
       and not coalesce(c.arquivada, false)
       and (p_telefone is null or c.advogado_id = p_telefone)
       and (p_departamento is null or a.departamento_id = p_departamento)
       and (v_quem is null or m.enviado_por_id = v_quem)
  ),
  peds as (
    select s.quem, s.quando, s.tipo
      from public.zorvin_sugestoes s
      join public.conversas c on c.id = s.conversa_id
      left join public.advogados a on a.id = c.advogado_id
     where s.quando >= v_antes and s.quando <= v_ate
       and not coalesce(c.arquivada, false)
       and (p_telefone is null or c.advogado_id = p_telefone)
       and (p_departamento is null or a.departamento_id = p_departamento)
       and (v_quem is null or s.quem = v_quem)
  ),
  agora_m as (select * from msgs where quando >= v_desde),
  agora_p as (select * from peds where quando >= v_desde),
  pessoas as (
    select quem from agora_m where marca is not null
    union select quem from agora_p where quem is not null
  )
  select jsonb_build_object(
    'so_meu', v_so_meu,
    'total', jsonb_build_object(
      'pedidas',    (select count(*) from agora_p where tipo = 'sugerir'),
      'ajustes',    (select count(*) from agora_p where tipo = 'ajustar'),
      'melhorias',  (select count(*) from agora_p where tipo = 'melhorar'),
      'usadas',     (select count(*) from agora_m where marca in ('igual', 'editada')),
      'iguais',     (select count(*) from agora_m where marca = 'igual'),
      'editadas',   (select count(*) from agora_m where marca = 'editada'),
      'melhoradas', (select count(*) from agora_m where marca = 'melhorada'),
      'escritas',   (select count(*) from agora_m)),
    'antes', case when p_desde is null then null else jsonb_build_object(
      'pedidas',    (select count(*) from peds where quando < v_desde and tipo = 'sugerir'),
      'usadas',     (select count(*) from msgs where quando < v_desde and marca in ('igual', 'editada')),
      'melhoradas', (select count(*) from msgs where quando < v_desde and marca = 'melhorada')) end,
    'por_pessoa', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.quem, 'nome', coalesce(u.nome, '(sem nome)'),
               'pedidas',    (select count(*) from agora_p x where x.quem = p.quem and x.tipo = 'sugerir'),
               'ajustes',    (select count(*) from agora_p x where x.quem = p.quem and x.tipo = 'ajustar'),
               'melhorias',  (select count(*) from agora_p x where x.quem = p.quem and x.tipo = 'melhorar'),
               'usadas',     (select count(*) from agora_m x where x.quem = p.quem and x.marca in ('igual', 'editada')),
               'iguais',     (select count(*) from agora_m x where x.quem = p.quem and x.marca = 'igual'),
               'editadas',   (select count(*) from agora_m x where x.quem = p.quem and x.marca = 'editada'),
               'melhoradas', (select count(*) from agora_m x where x.quem = p.quem and x.marca = 'melhorada'),
               'escritas',   (select count(*) from agora_m x where x.quem = p.quem))
             order by (select count(*) from agora_m x where x.quem = p.quem and x.marca is not null) desc,
                      coalesce(u.nome, ''))
        from pessoas p left join public.usuarios u on u.id = p.quem), '[]'::jsonb),
    'por_dia', coalesce((
      select jsonb_agg(jsonb_build_object('dia', d.dia, 'pedidas', d.pedidas, 'iguais', d.iguais,
                                          'editadas', d.editadas, 'melhoradas', d.melhoradas) order by d.dia)
        from (select dia, sum(pedidas)::int as pedidas, sum(iguais)::int as iguais, sum(editadas)::int as editadas,
                     sum(melhoradas)::int as melhoradas
                from (select (quando at time zone v_fuso)::date as dia, 0 as pedidas,
                             (marca = 'igual')::int as iguais, (marca = 'editada')::int as editadas,
                             (marca = 'melhorada')::int as melhoradas
                        from agora_m where marca is not null
                      union all
                      select (quando at time zone v_fuso)::date, 1, 0, 0, 0 from agora_p where tipo = 'sugerir') z
               group by dia) d), '[]'::jsonb)
  ) into v_saida;
  return v_saida;
end
$fn$
  $x$;
  execute 'revoke all on function public.zorvin_relatorio_sugestoes(timestamptz, timestamptz, uuid, text, uuid, bigint) from public';
  if v_anon then execute 'revoke all on function public.zorvin_relatorio_sugestoes(timestamptz, timestamptz, uuid, text, uuid, bigint) from anon'; end if;
  if v_auth then execute 'grant execute on function public.zorvin_relatorio_sugestoes(timestamptz, timestamptz, uuid, text, uuid, bigint) to authenticated'; end if;
  if v_srv then execute 'grant execute on function public.zorvin_relatorio_sugestoes(timestamptz, timestamptz, uuid, text, uuid, bigint) to service_role'; end if;

  -- ------------------------------------------------------------
  -- 4. A CONFERÊNCIA
  -- ------------------------------------------------------------
  insert into zorvin_conferencia_063 values
    ('a fila e as mensagens aceitam a marca "melhorada"',
     (select count(*) = 2 from pg_constraint
       where conname in ('fila_envio_sugestao_quazar_valida', 'mensagens_sugestao_quazar_valida')
         and pg_get_constraintdef(oid) like '%melhorada%')::text);
  insert into zorvin_conferencia_063 values
    ('os pedidos aceitam "melhorar"',
     (select count(*) = 1 from pg_constraint
       where conrelid = 'public.zorvin_sugestoes'::regclass and contype = 'c'
         and pg_get_constraintdef(oid) ilike '%tipo%' and pg_get_constraintdef(oid) like '%melhorar%')::text);
  insert into zorvin_conferencia_063
  select 'mensagens melhoradas nos últimos 30 dias', count(*)::text
    from public.mensagens where sugestao_quazar = 'melhorada' and criado_em >= now() - interval '30 days';
end
$mel$;

-- ----------------------------------------------------------
--  O RELATÓRIO NO PAPEL DE QUEM ATENDE — a régua 4 do LEIA-ME: a função tem
--  de rodar para quem entrou, e não só para a dona do banco.
-- ----------------------------------------------------------
do $conf$
declare
  v_quem uuid;
  v_r    jsonb;
  v_resposta text;
begin
  if to_regclass('pg_temp.zorvin_conferencia_063') is null
     or to_regprocedure('public.zorvin_relatorio_sugestoes(timestamptz, timestamptz, uuid, text, uuid, bigint)') is null
     or not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  if to_regclass('public.zorvin_sugestoes') is null then return; end if;
  select id into v_quem from public.usuarios where not admin and coalesce(ativo, true) limit 1;
  begin
    perform set_config('request.jwt.claim.sub', coalesce(v_quem::text, ''), true);
    perform set_config('role', 'authenticated', true);
    execute 'select public.zorvin_relatorio_sugestoes(now() - interval ''7 days'', now(), null, ''America/Sao_Paulo'', null, null)' into v_r;
    execute 'reset role';
    perform set_config('request.jwt.claim.sub', '', true);
    v_resposta := case when (v_r ->> 'so_meu')::boolean and (v_r -> 'total') ? 'melhoradas' then 'true'
                       else 'NÃO — a resposta não veio recortada, ou sem as melhoradas: ' || left(v_r::text, 120) end;
  exception when others then
    execute 'reset role';
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  insert into zorvin_conferencia_063 values ('quem atende abre o relatório, com as melhoradas e só com o que é dela', v_resposta);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_063;
