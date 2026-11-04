-- ============================================================
--  A LISTA DA EQUIPE DIZ QUEM ESTÁ DESATIVADO
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 04/11, com a foto do menu "Passar para": "A Gabriely
--  Mota está desativada, ela já foi desligada da empresa e não deve mais
--  aparecer no Zorvin. Ela já não está mais ativa no Vantoro, precisa ter
--  essa comunicação entre ambos sistemas."
--
--  A COMUNICAÇÃO JÁ EXISTIA, e funcionou: a ponte desliga no Zorvin quem sai
--  do Vantoro (`desligarQuemSaiuDoVantoro`, auditoria de 27/10). Medido em
--  04/11: a Gabriely estava com `usuarios.ativo = false`, sem nenhuma
--  permissão e com a entrada bloqueada no Auth. O que faltava era a TELA
--  saber disso. Ela monta as listas de pessoas ("Passar para", o seletor de
--  responsáveis, o "para quem" da tarefa) pela vista `equipe`, que só tinha
--  id, nome e foto — e `usuarios` continua fechada para quem atende (cada um
--  lê a própria linha).
--
--  A VISTA GANHA `ativo`, NO FIM. `create or replace view` só aceita coluna
--  nova depois das que já existem, e as três de antes continuam iguais: o
--  painel de antes, que pede `id, nome, foto_url`, não percebe nada.
--
--  QUEM SAIU CONTINUA NA VISTA, de propósito (o comentário dela, desde
--  agosto, diz por quê: as mensagens antigas dele seguem nas conversas e
--  precisam de nome). É o painel que decide não oferecê-lo para escolher.
--
--  `security_invoker = false`, como no script de agosto: é o que faz a vista
--  responder pelo dono dela, e não pela regra de quem pergunta. As permissões
--  não mudam: `create or replace` não mexe nelas (só leitura para quem
--  entrou; quem não entrou não alcança, desde 09/2026 e o 032).
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    a vista `equipe` (sql/2026-08-nome-e-foto-de-hoje.sql, colado à mão) e
--    a coluna `usuarios.ativo`. Sem uma das duas, não faz nada e diz. Com a
--    vista num formato que não é o de agosto, também não mexe, e diz.
-- ============================================================

do $equipe$
declare
  v_anon  boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_auth  boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_colunas text;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007:
  -- criada depois, o `select` da última linha estouraria num banco limpo.
  drop table if exists zorvin_conferencia_047;
  create temp table zorvin_conferencia_047 (item text, resposta text);

  if to_regclass('public.equipe') is null
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'usuarios'
                       and column_name = 'ativo') then
    insert into zorvin_conferencia_047
      values ('sem a vista equipe ou sem usuarios.ativo', 'nada a fazer aqui');
    raise notice 'Zorvin: sem a vista equipe ou sem usuarios.ativo — script 047 não fez nada.';
    return;
  end if;

  -- O FORMATO DE AGOSTO, e só ele. `create or replace view` exige as colunas
  -- de antes, na mesma ordem e com o mesmo nome; numa vista mexida à mão ele
  -- estouraria, e o script inteiro voltaria atrás sem dizer o que viu. Aqui
  -- ele não mexe, e diz.
  select string_agg(column_name, ',' order by ordinal_position) into v_colunas
    from information_schema.columns
   where table_schema = 'public' and table_name = 'equipe';
  if v_colunas not in ('id,nome,foto_url', 'id,nome,foto_url,ativo') then
    insert into zorvin_conferencia_047
      values ('a vista equipe está no formato de agosto (id, nome, foto_url)',
              'NÃO — ela tem ' || coalesce(v_colunas, 'nenhuma coluna') || '; não mexi');
    return;
  end if;

  execute $x$
    create or replace view public.equipe with (security_invoker = false) as
      select id, nome, foto_url, ativo from public.usuarios
  $x$;

  execute $x$
    comment on view public.equipe is
      'Nome, foto e se está ativa — de cada pessoa do escritório, e SÓ isso. É o que '
      'a tela usa para assinar as mensagens, desenhar os avatares e montar as listas '
      'de quem escolher. Quem sai do escritório continua aqui (com ativo = false): as '
      'mensagens dele seguem na conversa e precisam de nome. Quem decide não o '
      'oferecer para escolher é o painel.'
  $x$;

  -- A CONFERÊNCIA.
  insert into zorvin_conferencia_047 values
    ('a lista da equipe diz quem está ativo',
     exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'equipe' and column_name = 'ativo')::text),
    ('quem saiu continua na lista (as mensagens antigas precisam de nome)',
     ((select count(*) from public.equipe) = (select count(*) from public.usuarios))::text),
    ('pessoas desativadas na lista da equipe',
     (select count(*) from public.equipe where ativo is false)::text),
    ('a vista responde pelo dono dela, e não pela regra de quem pergunta',
     (not coalesce((select 'security_invoker=true' = any (c.reloptions)
                      from pg_class c where c.oid = 'public.equipe'::regclass), false))::text);

  if v_auth then
    insert into zorvin_conferencia_047 values
      ('quem entrou lê a lista, e não escreve nela',
       (has_table_privilege('authenticated', 'public.equipe', 'select')
        and not has_table_privilege('authenticated', 'public.equipe', 'insert')
        and not has_table_privilege('authenticated', 'public.equipe', 'update')
        and not has_table_privilege('authenticated', 'public.equipe', 'delete'))::text);
  end if;
  if v_anon then
    insert into zorvin_conferencia_047 values
      ('quem não entrou não alcança a lista',
       (not has_table_privilege('anon', 'public.equipe', 'select'))::text);
  end if;
end
$equipe$;

-- ----------------------------------------------------------
--  E A CONFERÊNCIA NO PAPEL DE QUEM ATENDE — a régua 4 do LEIA-ME: o painel
--  lê a vista como `authenticated`, e é a coluna nova que ele pede. A troca
--  de papel volta atrás sozinha se falhar.
-- ----------------------------------------------------------
do $conf$
declare
  v_resposta text;
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'equipe' and column_name = 'ativo')
     or not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  begin
    perform set_config('role', 'authenticated', true);
    execute 'select count(*) from public.equipe where ativo is false';
    v_resposta := 'true';
    execute 'reset role';
  exception when others then
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  insert into zorvin_conferencia_047 values
    ('quem atende lê quem está ativo', v_resposta);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_047;
