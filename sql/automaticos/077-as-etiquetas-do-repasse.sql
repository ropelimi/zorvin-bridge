-- ============================================================
--  077. AS ETIQUETAS DO REPASSE (27/11)
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  ------------------------------------------------------------
--  O PEDIDO
--
--  O Rodrigo: "Todos os clientes que tiverem repasse precisa aparecer ao abrir
--  a conversa, informando que tem repasse pendente e o valor do repasse. Esse
--  repasse é a 'DESPESA EM ABERTO' que é puxada da aba 'Andon' dentro da ficha
--  do cliente no Vantoro. E para todos os clientes que possuem repasse,
--  precisa ter etiqueta automática também. As etiquetas podem ser algo como
--  'Repasse pago' e 'Repasse em aberto'."
--
--  O VANTORO diz o repasse de cada cliente em `GET /clientes/etiquetas`
--  (`repasse`: "aberto", "pago" ou nulo, pelo financeiro do Andon), e
--  `repasse_ok` diz se o Andon respondeu.
--
--  ------------------------------------------------------------
--  O QUE ESTE SCRIPT FAZ
--
--  Troca `zorvin_etiquetas_do_vantoro(jsonb)` por
--  `zorvin_etiquetas_do_vantoro(jsonb, boolean)`, a mesma do 075 com:
--    - duas etiquetas automáticas a mais, "Repasse em aberto" e "Repasse
--      pago", travadas como as outras (a equipe só filtra);
--    - `p_repasse_ok`: só com ele verdadeiro o repasse da lista vale. Falso ou
--      nulo (o Andon fora, ou um Vantoro de antes), as etiquetas do repasse
--      que já estão nas conversas FICAM, e nenhuma entra: não saber não é "não
--      tem repasse";
--    - a régua da lista que encolhe pela metade conta só a blindagem e o
--      subsídio, como no 075.
--  É a versão de referência da troca daqui para a frente (regra 5).
--
--  O valor do repasse não vai na etiqueta: ele muda, e mora na ficha (o aviso
--  ao abrir a conversa, no painel).
--
--  DEPENDE DE JÁ TER RODADO: 075.
-- ============================================================

do $repasse$
declare
  v_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_srv  boolean := exists (select 1 from pg_roles where rolname = 'service_role');
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_077;
  create temp table zorvin_conferencia_077 (item text, resposta text);

  if to_regclass('public.tags') is null or to_regclass('public.conversas') is null then
    insert into zorvin_conferencia_077 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 077 não fez nada.';
    return;
  end if;
  if to_regclass('public.zorvin_etiquetas_marca') is null
     or to_regprocedure('public.zorvin_chave_do_telefone(text)') is null
     or to_regprocedure('public.zorvin_chave_da_etiqueta(text)') is null then
    insert into zorvin_conferencia_077 values ('NÃO — falta o 075', 'rode-o antes');
    raise notice 'Zorvin: script 077 precisa do 075 (as etiquetas do Vantoro).';
    return;
  end if;

  -- Uma função só: a de um argumento sai (duas com o mesmo nome fariam a
  -- chamada de um argumento morrer com "is not unique").
  execute 'drop function if exists public.zorvin_etiquetas_do_vantoro(jsonb)';

  execute $x$
create or replace function public.zorvin_etiquetas_do_vantoro(p_clientes jsonb, p_repasse_ok boolean default null)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare
  v_antes    integer;
  v_novos    integer;
  v_tiradas  integer;
  v_postas   integer;
  v_criadas  integer := 0;
  v_somem    integer;
  v_et       record;
  v_tag      uuid;
begin
  if p_clientes is null or jsonb_typeof(p_clientes) <> 'array' then
    raise exception 'a lista do Vantoro tem de ser uma lista' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtext('zorvin_etiquetas_do_vantoro'));

  drop table if exists zorvin_etiquetas_cli;
  create temp table zorvin_etiquetas_cli (id bigint, blindagem text, subs jsonb, tels jsonb, repasse text) on commit drop;
  create temp table if not exists zorvin_etiquetas_rotulo (cliente bigint, rotulo text) on commit drop;
  create temp table if not exists zorvin_etiquetas_tipo (rotulo text, nome text) on commit drop;
  create temp table if not exists zorvin_etiquetas_alvo (conversa_id uuid, tag_id uuid) on commit drop;
  truncate zorvin_etiquetas_cli, zorvin_etiquetas_rotulo, zorvin_etiquetas_tipo, zorvin_etiquetas_alvo;

  insert into zorvin_etiquetas_cli
  select distinct on ((e ->> 'id')::bigint) (e ->> 'id')::bigint,
         case when e ->> 'blindagem' in ('completa', 'parcial', 'pendente') then e ->> 'blindagem' end,
         case when jsonb_typeof(e -> 'subsidios') = 'array' then e -> 'subsidios' else '[]'::jsonb end,
         case when jsonb_typeof(e -> 'telefones') = 'array' then e -> 'telefones' else '[]'::jsonb end,
         case when p_repasse_ok is true and e ->> 'repasse' in ('aberto', 'pago') then e ->> 'repasse' end
    from jsonb_array_elements(p_clientes) e
   where jsonb_typeof(e) = 'object' and (e ->> 'id') ~ '^\d{1,15}$'
   order by (e ->> 'id')::bigint;

  -- OS RÓTULOS de cada cliente: a blindagem e cada tipo de subsídio (pela
  -- chave, para "SUBSÍDIO EMENDA" e "Subsidio Emenda" serem o mesmo).
  insert into zorvin_etiquetas_rotulo
  select c.id, 'blindagem:' || c.blindagem from zorvin_etiquetas_cli c where c.blindagem is not null
  union
  select c.id, 'repasse:' || c.repasse from zorvin_etiquetas_cli c where c.repasse is not null
  union
  select c.id, 'subsidio:' || public.zorvin_chave_da_etiqueta(s)
    from zorvin_etiquetas_cli c cross join jsonb_array_elements(c.subs) j
    cross join lateral (select j #>> '{}' as s) x
   where jsonb_typeof(j) = 'string' and public.zorvin_chave_da_etiqueta(s) <> '' and length(btrim(s)) <= 120;

  -- A régua do encolher conta só a blindagem e o subsídio (a do 075): o repasse
  -- depende do Andon, e tem a sua guarda (`p_repasse_ok`).
  select count(distinct cliente) into v_novos from zorvin_etiquetas_rotulo where rotulo not like 'repasse:%';
  select coalesce((select m.clientes from public.zorvin_etiquetas_marca m), 0) into v_antes;
  if v_antes >= 20 and v_novos * 2 < v_antes then
    return jsonb_build_object('trocada', false, 'antes', v_antes, 'novos', v_novos,
      'motivo', 'a lista encolheu mais da metade de uma vez; as etiquetas de antes continuam');
  end if;

  -- O NOME de cada tipo de subsídio: como o Vantoro escreveu (o primeiro, se
  -- duas escritas dão a mesma chave).
  insert into zorvin_etiquetas_tipo
  select distinct on (k) 'subsidio:' || k, regexp_replace(btrim(s), '\s+', ' ', 'g')
    from (select j #>> '{}' as s, public.zorvin_chave_da_etiqueta(j #>> '{}') as k
            from zorvin_etiquetas_cli c cross join jsonb_array_elements(c.subs) j
           where jsonb_typeof(j) = 'string') x
   where k <> '' and length(btrim(s)) <= 120
   order by k, s;

  -- AS ETIQUETAS: a marcada, ou a da equipe com o mesmo nome (aproveitada e
  -- renomeada), ou uma nova.
  for v_et in select * from (values ('blindagem:completa', 'Blindagem completa', '#43a047'),
                                 ('blindagem:parcial', 'Blindagem parcial', '#f9a825'),
                                 ('blindagem:pendente', 'Blindagem pendente', '#e53935'),
                                 ('repasse:aberto', 'Repasse em aberto', '#fb8c00'),
                                 ('repasse:pago', 'Repasse pago', '#00897b')) v(chave, nome, cor)
           union all
           select t.rotulo, t.nome, '#8e24aa' from zorvin_etiquetas_tipo t loop
    v_tag := null;
    select t.id into v_tag from public.tags t where t.automatica = v_et.chave;
    if v_tag is not null then
      update public.tags set nome = v_et.nome where id = v_tag and nome is distinct from v_et.nome;
    else
      select t.id into v_tag from public.tags t
       where t.automatica is null and public.zorvin_chave_da_etiqueta(t.nome) = public.zorvin_chave_da_etiqueta(v_et.nome)
       order by t.criado_em, t.id limit 1;
      if v_tag is null then
        insert into public.tags (nome, cor, automatica) values (v_et.nome, v_et.cor, v_et.chave);
        v_criadas := v_criadas + 1;
      else
        update public.tags set automatica = v_et.chave, nome = v_et.nome where id = v_tag;
      end if;
    end if;
  end loop;

  -- O TIPO DE SUBSÍDIO QUE SUMIU do Vantoro leva a etiqueta junto.
  delete from public.tags t
   where t.automatica like 'subsidio:%'
     and not exists (select 1 from zorvin_etiquetas_tipo x where x.rotulo = t.automatica);
  get diagnostics v_somem = row_count;

  with fones as (
    select distinct public.zorvin_chave_do_telefone(t) as chave, c.id as cliente
      from zorvin_etiquetas_cli c cross join jsonb_array_elements_text(c.tels) t
     where public.zorvin_chave_do_telefone(t) is not null
       and exists (select 1 from zorvin_etiquetas_rotulo r where r.cliente = c.id)
  ), ct as (
    select c.id, (to_jsonb(c) ->> 'vantoro_cliente_id') as vinculo, public.zorvin_chave_do_telefone(c.numero) as chave
      from public.contatos c where c.numero not like 'grupo:%'
  ), pelo_fone as (
    select ct.id as contato, f.cliente from ct join fones f on f.chave = ct.chave
     where not (coalesce(ct.vinculo, '') ~ '^\d{1,15}$')
  ), rotulo_do_contato as (
    -- LIGADO: o cadastro do vínculo, e só ele.
    select ct.id as contato, r.rotulo from ct join zorvin_etiquetas_rotulo r
        on ct.vinculo ~ '^\d{1,15}$' and r.cliente = ct.vinculo::bigint
    union
    -- SEM VÍNCULO: pelo telefone, só o que todos os cadastros dele têm.
    select p.contato, r.rotulo from pelo_fone p join zorvin_etiquetas_rotulo r on r.cliente = p.cliente
     group by p.contato, r.rotulo
    having count(distinct p.cliente) = (select count(distinct p2.cliente) from pelo_fone p2 where p2.contato = p.contato)
  )
  insert into zorvin_etiquetas_alvo (conversa_id, tag_id)
  select distinct cv.id, t.id
    from rotulo_do_contato e
    join public.conversas cv on cv.contato_id = e.contato
    join public.tags t on t.automatica = e.rotulo;

  delete from public.conversa_tags x
   using public.tags t
   where t.id = x.tag_id and t.automatica is not null
     -- SEM O ANDON (p_repasse_ok não verdadeiro), o repasse de antes fica.
     and (p_repasse_ok is true or t.automatica not like 'repasse:%')
     and not exists (select 1 from zorvin_etiquetas_alvo a where a.conversa_id = x.conversa_id and a.tag_id = x.tag_id);
  get diagnostics v_tiradas = row_count;

  insert into public.conversa_tags (conversa_id, tag_id)
  select a.conversa_id, a.tag_id from zorvin_etiquetas_alvo a
  on conflict do nothing;
  get diagnostics v_postas = row_count;

  insert into public.zorvin_etiquetas_marca (id, trocada_em, clientes) values (true, now(), v_novos)
  on conflict (id) do update set trocada_em = excluded.trocada_em, clientes = excluded.clientes;

  return jsonb_build_object('trocada', true, 'antes', v_antes, 'repasse_ok', coalesce(p_repasse_ok, false), 'clientes', v_novos,
    'postas', v_postas, 'tiradas', v_tiradas, 'etiquetas_criadas', v_criadas, 'etiquetas_que_sumiram', v_somem,
    'conversas', (select count(distinct conversa_id) from zorvin_etiquetas_alvo),
    'por_etiqueta', coalesce((select jsonb_object_agg(t.nome, n) from
       (select a.tag_id, count(*) as n from zorvin_etiquetas_alvo a group by a.tag_id) q
       join public.tags t on t.id = q.tag_id), '{}'::jsonb));
end
$f$$x$;
  execute 'revoke all on function public.zorvin_etiquetas_do_vantoro(jsonb, boolean) from public';
  if v_anon then execute 'revoke all on function public.zorvin_etiquetas_do_vantoro(jsonb, boolean) from anon'; end if;
  if v_auth then execute 'revoke all on function public.zorvin_etiquetas_do_vantoro(jsonb, boolean) from authenticated'; end if;
  if v_srv then execute 'grant execute on function public.zorvin_etiquetas_do_vantoro(jsonb, boolean) to service_role'; end if;

  insert into zorvin_conferencia_077 values
    ('a troca aceita o repasse',
      (to_regprocedure('public.zorvin_etiquetas_do_vantoro(jsonb, boolean)') is not null)::text),
    ('a troca de um argumento saiu',
      (to_regprocedure('public.zorvin_etiquetas_do_vantoro(jsonb)') is null)::text),
    ('quem entrou não chama a troca',
      (not v_auth or not has_function_privilege('authenticated', 'public.zorvin_etiquetas_do_vantoro(jsonb, boolean)', 'execute'))::text),
    ('etiquetas do repasse hoje', (select count(*)::text from public.tags where automatica like 'repasse:%'));
end
$repasse$;

select * from zorvin_conferencia_077;
