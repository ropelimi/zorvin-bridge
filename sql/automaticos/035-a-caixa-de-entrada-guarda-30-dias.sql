-- ============================================================
--  A CAIXA DE ENTRADA GUARDA A CÓPIA POR 30 DIAS (e não 7)
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Quem roda é a PONTE, sozinha, na publicação que vem com o merge.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO MUDA
--
--  Decidido pelo Rodrigo em 27/10. A ponte grava em `eventos_recebidos` o
--  evento cru de cada mensagem que chega, antes de responder "OK" à Uazapi, e
--  `limpar_eventos_recebidos()` apaga, de hora em hora, os já processados há
--  mais de 7 dias. Passa a apagar os de mais de 30.
--
--  Essa cópia é o único jeito de devolver às conversas uma mensagem que a
--  ponte não soube ler. Em 26/10 apareceram 27 assim, desde setembro
--  (mensagens com botões, respostas a modelo, um convite de grupo), e o
--  defeito foi achado semanas depois: com 7 dias de cópia, só deu para
--  devolver 2. Com 30, um defeito achado um mês depois ainda tem conserto.
--
--  O QUE CUSTA, medido em 27/10: a tabela passa de uns 10 mil para uns 40 mil
--  eventos. Ela já ocupa 108 MB no disco (o espaço da limpeza de 26/10 fica
--  com ela, para ser reaproveitado), e o banco inteiro tem 208 MB. E uma
--  segunda cópia do que os clientes escrevem fica guardada mais tempo — a
--  primeira, a conversa, já fica para sempre.
--
--  O QUE NÃO MUDA:
--
--    - os PENDENTES continuam ficando: um evento que nunca foi processado é
--      uma mensagem que talvez não tenha entrado, e apagá-lo seria apagar a
--      única pista dela;
--    - a conta continua sendo pelo `processado_em`;
--    - a função continua rodando com poder de dono e SÓ para a ponte (a
--      armadilha nº 5 do CLAUDE.md, e o 032): quem entrou no painel não a
--      chama;
--    - a ponte continua chamando do mesmo jeito, sem argumento. O `index.js`
--      não muda.
--
--  ------------------------------------------------------------
--  ENQUANTO ESTE ARQUIVO NÃO FOR RODADO
--
--  A limpeza continua apagando o que passou de 7 dias.
-- ============================================================

do $caixa$
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_035;
  create temp table zorvin_conferencia_035 (item text, resposta text);

  -- A função é `language sql`, e o Postgres confere o corpo dela ao criar:
  -- num banco sem a caixa de entrada, o `create` estouraria.
  if to_regclass('public.eventos_recebidos') is null then
    insert into zorvin_conferencia_035
      values ('sem a caixa de entrada do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem a tabela eventos_recebidos — script 035 não fez nada.';
    return;
  end if;

  execute $f$
    create or replace function public.limpar_eventos_recebidos()
    returns integer
    language sql
    security definer
    set search_path = public
    as $corpo$
      with apagados as (
        delete from public.eventos_recebidos
         where processado_em is not null
           and processado_em < now() - interval '30 days'
        returning 1
      )
      select count(*)::int from apagados;
    $corpo$
  $f$;

  execute $c$comment on function public.limpar_eventos_recebidos() is
    'Apaga os eventos já processados com mais de 30 dias (eram 7 até 27/10). '
    'Os PENDENTES ficam: um evento que nunca foi processado é uma mensagem que '
    'talvez não tenha entrado, e apagá-lo seria apagar a única pista dela.'$c$;

  -- SÓ A PONTE. `create or replace` guarda as permissões de uma função que já
  -- existe; uma que faltasse nasceria com as da herança. Ditas de novo aqui,
  -- valem nos dois casos.
  execute 'revoke all on function public.limpar_eventos_recebidos() from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.limpar_eventos_recebidos() from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.limpar_eventos_recebidos() from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.limpar_eventos_recebidos() to service_role';
  end if;

  insert into zorvin_conferencia_035
  select 'a limpeza guarda os eventos processados por 30 dias'::text,
         (p.prosrc like '%interval ''30 days''%'
          and p.prosrc like '%processado_em < now()%')::text
    from pg_proc p where p.oid = 'public.limpar_eventos_recebidos()'::regprocedure
  union all
  select 'os pendentes continuam ficando',
         (p.prosrc like '%processado_em is not null%')::text
    from pg_proc p where p.oid = 'public.limpar_eventos_recebidos()'::regprocedure
  union all
  select 'a limpeza roda com poder de dono, no esquema public',
         (p.prosecdef and coalesce('search_path=public' = any(p.proconfig), false))::text
    from pg_proc p where p.oid = 'public.limpar_eventos_recebidos()'::regprocedure
  union all
  select 'quem não entrou não chama a limpeza',
         (not exists (select 1 from pg_roles where rolname = 'anon')
          or not has_function_privilege('anon', 'public.limpar_eventos_recebidos()', 'EXECUTE'))::text
  union all
  select 'quem entrou no painel não chama a limpeza',
         (not exists (select 1 from pg_roles where rolname = 'authenticated')
          or not has_function_privilege('authenticated', 'public.limpar_eventos_recebidos()', 'EXECUTE'))::text
  union all
  select 'a ponte chama a limpeza',
         (not exists (select 1 from pg_roles where rolname = 'service_role')
          or has_function_privilege('service_role', 'public.limpar_eventos_recebidos()', 'EXECUTE'))::text
  union all
  select 'eventos guardados na caixa agora',
         (select count(*) from public.eventos_recebidos)::text
  union all
  select 'o mais antigo deles',
         coalesce((select min(recebido_em) from public.eventos_recebidos)::text, 'nenhum');
end $caixa$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_035;
