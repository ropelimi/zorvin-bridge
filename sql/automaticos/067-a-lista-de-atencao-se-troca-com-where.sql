-- ============================================================
--  067. A LISTA DE QUEM PEDE ATENÇÃO SE TROCA (25/11)
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  O 066 entrou no ar às 06h48 de 25/11 e a primeira lista do Vantoro, às
--  06h49, foi RECUSADA: o PostgREST respondeu 400, e o log do banco disse
--  "DELETE requires a WHERE clause". A Supabase carrega o `pg_safeupdate`
--  em todo pedido que passa pelo PostgREST, e ele recusa um DELETE (ou um
--  UPDATE) sem WHERE, também dentro de uma função `security definer`. A
--  função que troca a lista esvaziava a de antes com `delete from …;`.
--
--  O Postgres das provas não tem o `pg_safeupdate`, e por isso nenhuma
--  prova viu. A correção foi aplicada à mão às 06h55 (Brasília), pelo
--  conector, e este script a deixa escrita: o mesmo corpo do 066, com
--  `where true` nos dois DELETE. O 066 não foi editado (script aplicado não
--  se edita).
--
--  A VERSÃO DE REFERÊNCIA (regra 5) de zorvin_atencao_trocar passa a ser a
--  deste script.
--
--  DEPENDE DE JÁ TER RODADO: 066.
-- ============================================================

do $ate$
declare
  v_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_srv  boolean := exists (select 1 from pg_roles where rolname = 'service_role');
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_067;
  create temp table zorvin_conferencia_067 (item text, resposta text);

  if to_regclass('public.zorvin_atencao') is null or to_regclass('public.zorvin_atencao_chaves') is null
     or to_regclass('public.zorvin_atencao_marca') is null then
    insert into zorvin_conferencia_067 values ('sem a lista do 066', 'nada a fazer aqui');
    raise notice 'Zorvin: sem a lista do 066 — script 067 não fez nada.';
    return;
  end if;

  execute $x$
create or replace function public.zorvin_atencao_trocar(p_clientes jsonb, p_sem_vantoro boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare
  v_antes  integer;
  v_novos  integer;
  v_chaves integer;
begin
  if p_clientes is null or jsonb_typeof(p_clientes) <> 'array' then
    raise exception 'a lista do Vantoro tem de ser uma lista' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtext('zorvin_atencao_trocar'));
  select count(*) into v_antes from public.zorvin_atencao;
  select count(distinct e ->> 'id') into v_novos from jsonb_array_elements(p_clientes) e
   where (e ->> 'id') ~ '^\d+$';
  if not p_sem_vantoro and v_antes >= 20 and v_novos * 2 < v_antes then
    return jsonb_build_object('trocada', false, 'antes', v_antes, 'novos', v_novos,
      'motivo', 'a lista encolheu mais da metade de uma vez; a de antes continua valendo');
  end if;
  -- `where true`, e não um DELETE solto: o pg_safeupdate da Supabase recusa
  -- o DELETE sem WHERE em todo pedido que vem pelo PostgREST.
  delete from public.zorvin_atencao_chaves where true;
  delete from public.zorvin_atencao where true;
  insert into public.zorvin_atencao (cliente_id, ordem_servico, blindagem, telefones)
  select distinct on ((e ->> 'id')::bigint) (e ->> 'id')::bigint,
         case when jsonb_typeof(e -> 'ordem_servico') = 'object' then e -> 'ordem_servico' end,
         case when jsonb_typeof(e -> 'blindagem') = 'object' then e -> 'blindagem' end,
         coalesce(array(select regexp_replace(t, '\D', '', 'g')
                          from jsonb_array_elements_text(
                                 case when jsonb_typeof(e -> 'telefones') = 'array' then e -> 'telefones' else '[]'::jsonb end) t
                         where regexp_replace(t, '\D', '', 'g') <> ''), '{}')
    from jsonb_array_elements(p_clientes) e
   where (e ->> 'id') ~ '^\d+$'
   order by (e ->> 'id')::bigint;
  insert into public.zorvin_atencao_chaves (chave, cliente_id)
  select distinct public.zorvin_chave_do_telefone(t), a.cliente_id
    from public.zorvin_atencao a cross join unnest(a.telefones) t
   where public.zorvin_chave_do_telefone(t) is not null
  on conflict do nothing;
  get diagnostics v_chaves = row_count;
  insert into public.zorvin_atencao_marca (id, trocada_em, clientes, sem_vantoro)
  values (true, now(), v_novos, p_sem_vantoro)
  on conflict (id) do update set trocada_em = excluded.trocada_em, clientes = excluded.clientes,
                                 sem_vantoro = excluded.sem_vantoro;
  return jsonb_build_object('trocada', true, 'antes', v_antes, 'clientes', v_novos, 'chaves', v_chaves);
end
$f$$x$;

  -- SÓ A PONTE CHAMA (create or replace guarda as permissões; ditas de novo
  -- pela armadilha nº 5).
  execute 'revoke all on function public.zorvin_atencao_trocar(jsonb, boolean) from public';
  if v_anon then execute 'revoke all on function public.zorvin_atencao_trocar(jsonb, boolean) from anon'; end if;
  if v_auth then execute 'revoke all on function public.zorvin_atencao_trocar(jsonb, boolean) from authenticated'; end if;
  if v_srv then execute 'grant execute on function public.zorvin_atencao_trocar(jsonb, boolean) to service_role'; end if;

  -- A CONFERÊNCIA: o corpo não tem DELETE sem WHERE, e quem entrou não troca.
  insert into zorvin_conferencia_067
  select 'a troca da lista não tem DELETE sem WHERE (o pg_safeupdate da Supabase o recusa)',
         (pg_get_functiondef('public.zorvin_atencao_trocar(jsonb, boolean)'::regprocedure)
            !~* 'delete\s+from\s+[a-z_.]+\s*;')::text;
  insert into zorvin_conferencia_067
  select 'clientes na lista do Vantoro agora', (select count(*) from public.zorvin_atencao)::text;
  if v_auth then
    insert into zorvin_conferencia_067 values
      ('quem entrou não troca a lista',
       (not has_function_privilege('authenticated', 'public.zorvin_atencao_trocar(jsonb, boolean)', 'execute'))::text);
  end if;
end
$ate$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_067;
