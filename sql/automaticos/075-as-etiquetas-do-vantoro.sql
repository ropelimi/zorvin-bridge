-- ============================================================
--  075. AS ETIQUETAS QUE VÊM DO VANTORO: A BLINDAGEM E O SUBSÍDIO (27/11)
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  ------------------------------------------------------------
--  O PEDIDO
--
--  O Rodrigo: "Da para fazer um vínculo com o Vantoro para termos as
--  etiquetas 'Blindagem completa', 'Blindagem parcial' e 'Blindagem
--  pendente'?" E: "não pode ser possível a equipe editar essas etiquetas, não
--  deve ser permitido excluir ou incluir. As etiquetas devem aparecer apenas
--  para serem filtradas." E: "As etiquetas devem ser atualizadas com base na
--  atualização do Vantoro, que poderá incluir ou excluir." E: "Faça isso
--  também para os clientes que tiverem tarefas de subsídio pendentes", com o
--  nome da tarefa ("SUBSÍDIO EMENDA", "SUBSÍDIO CCR"...).
--
--  Quem sabe é o VANTORO (`GET /api/v1/clientes/etiquetas`: de cada cliente,
--  a blindagem, os tipos das tarefas de subsídio abertas e os telefones). A
--  ponte pergunta de tempos em tempos e chama `zorvin_etiquetas_do_vantoro`,
--  que troca as etiquetas das conversas de uma vez.
--
--  ------------------------------------------------------------
--  O QUE ESTE SCRIPT ACRESCENTA
--
--    tags.automatica                  a marca da etiqueta que o Zorvin mantém
--                                     sozinho ('blindagem:completa',
--                                     'subsidio:SUBSIDIO EMENDA'). Nula nas
--                                     etiquetas da equipe
--    zorvin_chave_da_etiqueta(text)   o nome sem acento, em maiúsculas e sem
--                                     espaço de sobra: é por ela que a
--                                     etiqueta da equipe é reconhecida
--    zorvin_etiquetas_marca           quando a lista foi trocada, e quantos
--                                     clientes ela tinha
--    zorvin_etiquetas_do_vantoro()    a troca (só a ponte)
--    a TRAVA                          dois gatilhos: quem entrou no painel
--                                     não renomeia, não muda a cor, não apaga
--                                     e não cria etiqueta automática, e não a
--                                     põe nem a tira de conversa nenhuma
--                                     (42501)
--
--  AS ETIQUETAS:
--    - da blindagem, três, sempre: "Blindagem completa", "Blindagem parcial" e
--      "Blindagem pendente";
--    - do subsídio, uma por TIPO de tarefa aberta no Vantoro, com o nome da
--      tarefa como o Vantoro escreve (sem a tentativa). O tipo que deixa de
--      existir no Vantoro (nenhum cliente com aquela tarefa aberta) leva a
--      etiqueta junto; ela volta quando a tarefa voltar.
--
--  A ETIQUETA DA EQUIPE COM O MESMO NOME (sem olhar acento nem maiúscula) é
--  APROVEITADA (decidido pelo Rodrigo em 27/11): passa a ser automática, ganha
--  o nome do Vantoro ("Subsidio Emenda" vira "SUBSÍDIO EMENDA"), e as
--  conversas dela são trocadas pelas da lista.
--
--  AS ETIQUETAS MANUAIS "Blindagem" E "Blindagem Concluida" SÃO APAGADAS, uma
--  vez (decidido pelo Rodrigo em 27/11: as três novas dizem o mesmo, e já
--  discordavam do Vantoro). A semente 'etiquetas:apagar-blindagem-manual-075'
--  em `zorvin_sementes` impede que rodar a pasta de novo apague uma que a
--  equipe criar depois.
--
--  QUAL ETIQUETA CADA CONVERSA RECEBE. As do cliente dela:
--    - o contato LIGADO a um cadastro do Vantoro (`vantoro_cliente_id`) segue
--      aquele cadastro, e só ele: o vínculo é a palavra final. Ligado a um
--      cadastro que não está na lista, não recebe nenhuma;
--    - sem vínculo, vale o TELEFONE (o DDD e os 8 últimos dígitos, a chave do
--      066): a etiqueta entra só se TODOS os cadastros com aquele telefone a
--      têm. Telefone de dois cadastros (a mãe e o filho) recebe só o que os
--      dois têm: dizer o de um dos dois seria chutar;
--    - grupo nunca recebe.
--
--  A LISTA QUE ENCOLHE PELA METADE DE UMA VEZ (de 20 ou mais) É RECUSADA, e
--  as etiquetas de antes ficam: é o Vantoro respondendo errado, e não metade
--  dos clientes resolvidos no mesmo minuto (a régua do 066).
--
--  DEPENDE DE JÁ TER RODADO: 066 (a chave do telefone).
-- ============================================================

do $ate$
declare
  v_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_srv  boolean := exists (select 1 from pg_roles where rolname = 'service_role');
  v_semente text := 'etiquetas:apagar-blindagem-manual-075';
  v_apagadas integer := 0;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_075;
  create temp table zorvin_conferencia_075 (item text, resposta text);

  if to_regclass('public.conversas') is null or to_regclass('public.contatos') is null
     or to_regclass('public.tags') is null or to_regclass('public.conversa_tags') is null then
    insert into zorvin_conferencia_075 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 075 não fez nada.';
    return;
  end if;
  if to_regprocedure('public.zorvin_chave_do_telefone(text)') is null then
    insert into zorvin_conferencia_075 values ('NÃO — falta o 066', 'rode-o antes');
    raise notice 'Zorvin: script 075 precisa do 066 (a chave do telefone).';
    return;
  end if;

  -- ------------------------------------------------------------
  -- 1. A MARCA DA ETIQUETA AUTOMÁTICA, e uma etiqueta por marca.
  -- ------------------------------------------------------------
  execute 'alter table public.tags add column if not exists automatica text';
  execute 'create unique index if not exists tags_automatica_uma on public.tags (automatica) where automatica is not null';

  execute $x$
create or replace function public.zorvin_chave_da_etiqueta(p_nome text)
returns text language sql immutable set search_path = public as $f$
  select upper(btrim(regexp_replace(translate(coalesce(p_nome, ''),
           'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
           'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN'), '\s+', ' ', 'g')))
$f$$x$;

  execute $x$
    create table if not exists public.zorvin_etiquetas_marca (
      id          boolean primary key default true check (id),
      trocada_em  timestamptz not null default now(),
      clientes    integer not null default 0
    )$x$;
  execute 'alter table public.zorvin_etiquetas_marca enable row level security';
  if v_anon then execute 'revoke all on public.zorvin_etiquetas_marca from anon'; end if;
  if v_auth then execute 'revoke all on public.zorvin_etiquetas_marca from authenticated'; end if;
  if v_srv then execute 'grant all on public.zorvin_etiquetas_marca to service_role'; end if;

  -- ------------------------------------------------------------
  -- 2. A TRAVA. Quem entrou no painel tem `auth.uid()`; a ponte (a chave de
  --    serviço) e o editor do banco não. A apagada em cascata (a conversa ou
  --    a etiqueta que some) vem de dentro de outro gatilho e passa.
  -- ------------------------------------------------------------
  execute $x$
create or replace function public.zorvin_etiqueta_automatica_travada()
returns trigger language plpgsql set search_path = public, auth as $f$
begin
  if auth.uid() is null or pg_trigger_depth() > 1 then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if (tg_op <> 'INSERT' and old.automatica is not null)
     or (tg_op <> 'DELETE' and new.automatica is not null) then
    raise exception 'Esta etiqueta vem do Vantoro e é mantida sozinha pelo Zorvin: não se renomeia, não se apaga e não se cria aqui.'
      using errcode = '42501';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end
$f$$x$;
  execute 'drop trigger if exists zorvin_etiqueta_automatica_travada on public.tags';
  execute 'create trigger zorvin_etiqueta_automatica_travada before insert or update or delete on public.tags
             for each row execute function public.zorvin_etiqueta_automatica_travada()';

  execute $x$
create or replace function public.zorvin_conversa_tag_automatica_travada()
returns trigger language plpgsql security definer set search_path = public, auth as $f$
declare
  v_tag uuid := case when tg_op = 'DELETE' then old.tag_id else new.tag_id end;
begin
  if auth.uid() is null or pg_trigger_depth() > 1 then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if exists (select 1 from public.tags t where t.id = v_tag and t.automatica is not null)
     or (tg_op = 'UPDATE' and exists (select 1 from public.tags t where t.id = old.tag_id and t.automatica is not null)) then
    raise exception 'Esta etiqueta vem do Vantoro: o Zorvin a põe e a tira sozinho. Use-a só para filtrar.'
      using errcode = '42501';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end
$f$$x$;
  execute 'drop trigger if exists zorvin_conversa_tag_automatica_travada on public.conversa_tags';
  execute 'create trigger zorvin_conversa_tag_automatica_travada before insert or update or delete on public.conversa_tags
             for each row execute function public.zorvin_conversa_tag_automatica_travada()';
  execute 'revoke all on function public.zorvin_etiqueta_automatica_travada() from public';
  execute 'revoke all on function public.zorvin_conversa_tag_automatica_travada() from public';
  if v_anon then
    execute 'revoke all on function public.zorvin_etiqueta_automatica_travada() from anon';
    execute 'revoke all on function public.zorvin_conversa_tag_automatica_travada() from anon';
  end if;
  if v_auth then
    execute 'revoke all on function public.zorvin_etiqueta_automatica_travada() from authenticated';
    execute 'revoke all on function public.zorvin_conversa_tag_automatica_travada() from authenticated';
  end if;

  -- ------------------------------------------------------------
  -- 3. A TROCA. `p_clientes` é a lista do Vantoro como veio:
  --    [{id, blindagem, subsidios[], telefones[]}]. Devolve o que fez.
  -- ------------------------------------------------------------
  execute $x$
create or replace function public.zorvin_etiquetas_do_vantoro(p_clientes jsonb)
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

  create temp table if not exists zorvin_etiquetas_cli (id bigint, blindagem text, subs jsonb, tels jsonb) on commit drop;
  create temp table if not exists zorvin_etiquetas_rotulo (cliente bigint, rotulo text) on commit drop;
  create temp table if not exists zorvin_etiquetas_tipo (rotulo text, nome text) on commit drop;
  create temp table if not exists zorvin_etiquetas_alvo (conversa_id uuid, tag_id uuid) on commit drop;
  truncate zorvin_etiquetas_cli, zorvin_etiquetas_rotulo, zorvin_etiquetas_tipo, zorvin_etiquetas_alvo;

  insert into zorvin_etiquetas_cli
  select distinct on ((e ->> 'id')::bigint) (e ->> 'id')::bigint,
         case when e ->> 'blindagem' in ('completa', 'parcial', 'pendente') then e ->> 'blindagem' end,
         case when jsonb_typeof(e -> 'subsidios') = 'array' then e -> 'subsidios' else '[]'::jsonb end,
         case when jsonb_typeof(e -> 'telefones') = 'array' then e -> 'telefones' else '[]'::jsonb end
    from jsonb_array_elements(p_clientes) e
   where jsonb_typeof(e) = 'object' and (e ->> 'id') ~ '^\d{1,15}$'
   order by (e ->> 'id')::bigint;

  -- OS RÓTULOS de cada cliente: a blindagem e cada tipo de subsídio (pela
  -- chave, para "SUBSÍDIO EMENDA" e "Subsidio Emenda" serem o mesmo).
  insert into zorvin_etiquetas_rotulo
  select c.id, 'blindagem:' || c.blindagem from zorvin_etiquetas_cli c where c.blindagem is not null
  union
  select c.id, 'subsidio:' || public.zorvin_chave_da_etiqueta(s)
    from zorvin_etiquetas_cli c cross join jsonb_array_elements(c.subs) j
    cross join lateral (select j #>> '{}' as s) x
   where jsonb_typeof(j) = 'string' and public.zorvin_chave_da_etiqueta(s) <> '' and length(btrim(s)) <= 120;

  select count(distinct cliente) into v_novos from zorvin_etiquetas_rotulo;
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
                                 ('blindagem:pendente', 'Blindagem pendente', '#e53935')) v(chave, nome, cor)
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
     and not exists (select 1 from zorvin_etiquetas_alvo a where a.conversa_id = x.conversa_id and a.tag_id = x.tag_id);
  get diagnostics v_tiradas = row_count;

  insert into public.conversa_tags (conversa_id, tag_id)
  select a.conversa_id, a.tag_id from zorvin_etiquetas_alvo a
  on conflict do nothing;
  get diagnostics v_postas = row_count;

  insert into public.zorvin_etiquetas_marca (id, trocada_em, clientes) values (true, now(), v_novos)
  on conflict (id) do update set trocada_em = excluded.trocada_em, clientes = excluded.clientes;

  return jsonb_build_object('trocada', true, 'antes', v_antes, 'clientes', v_novos,
    'postas', v_postas, 'tiradas', v_tiradas, 'etiquetas_criadas', v_criadas, 'etiquetas_que_sumiram', v_somem,
    'conversas', (select count(distinct conversa_id) from zorvin_etiquetas_alvo),
    'por_etiqueta', coalesce((select jsonb_object_agg(t.nome, n) from
       (select a.tag_id, count(*) as n from zorvin_etiquetas_alvo a group by a.tag_id) q
       join public.tags t on t.id = q.tag_id), '{}'::jsonb));
end
$f$$x$;
  execute 'revoke all on function public.zorvin_etiquetas_do_vantoro(jsonb) from public';
  if v_anon then execute 'revoke all on function public.zorvin_etiquetas_do_vantoro(jsonb) from anon'; end if;
  if v_auth then execute 'revoke all on function public.zorvin_etiquetas_do_vantoro(jsonb) from authenticated'; end if;
  if v_srv then execute 'grant execute on function public.zorvin_etiquetas_do_vantoro(jsonb) to service_role'; end if;

  -- ------------------------------------------------------------
  -- 4. AS MANUAIS "Blindagem" E "Blindagem Concluida" SAEM, uma vez.
  -- ------------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_sementes (
      chave        text primary key,
      plantada_em  timestamptz not null default now()
    )$x$;
  execute 'alter table public.zorvin_sementes enable row level security';
  if v_anon then execute 'revoke all on public.zorvin_sementes from anon'; end if;
  if v_auth then execute 'revoke all on public.zorvin_sementes from authenticated'; end if;

  if not exists (select 1 from public.zorvin_sementes where chave = v_semente) then
    delete from public.tags t
     where t.automatica is null
       and public.zorvin_chave_da_etiqueta(t.nome) in ('BLINDAGEM', 'BLINDAGEM CONCLUIDA');
    get diagnostics v_apagadas = row_count;
    insert into public.zorvin_sementes (chave) values (v_semente);
  end if;

  -- ------------------------------------------------------------
  -- 5. A CONFERÊNCIA.
  -- ------------------------------------------------------------
  insert into zorvin_conferencia_075 values
    ('a marca da etiqueta automática existe',
      (exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'tags' and column_name = 'automatica'))::text),
    ('a trava das etiquetas está ligada',
      (exists (select 1 from pg_trigger where tgname = 'zorvin_etiqueta_automatica_travada')
       and exists (select 1 from pg_trigger where tgname = 'zorvin_conversa_tag_automatica_travada'))::text),
    ('quem entrou não chama a troca',
      (not v_auth or not has_function_privilege('authenticated', 'public.zorvin_etiquetas_do_vantoro(jsonb)', 'execute'))::text),
    ('etiquetas manuais da blindagem apagadas agora', v_apagadas::text),
    ('etiquetas automáticas hoje', (select count(*)::text from public.tags where automatica is not null));
end
$ate$;

select * from zorvin_conferencia_075;
