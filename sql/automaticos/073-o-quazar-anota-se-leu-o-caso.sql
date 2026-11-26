-- ============================================================
--  073. O QUAZAR ANOTA SE LEU O CASO, TAMBÉM EM QUEM ESPERA (26/11)
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  ------------------------------------------------------------
--  O PEDIDO
--
--  "Faça as 3 melhorias." (Rodrigo, 26/11). A terceira: cada resposta do
--  Quazar diz se ele leu o caso do cliente no Vantoro, e o que leu (quantos
--  processos, intimações e tarefas), ou por que não leu. O Quazar de dia e o
--  da noite já guardam isso em zorvin_quazar_noturno.contexto (061). Faltava
--  a resposta a quem espera (069), que mora em zorvin_quazar_faxina.
--
--  ------------------------------------------------------------
--  O QUE ESTE SCRIPT FAZ
--
--    zorvin_quazar_faxina.resposta_contexto   o que o Quazar leu ao responder
--                                             quem espera: só contagens ("Leu
--                                             o caso no Vantoro: 2 processo(s),
--                                             …") ou o motivo de não ter lido.
--                                             Nunca o que está no caso. Quem
--                                             grava é a ponte.
--
--  A tabela continua só da ponte (RLS ligada, sem política, 064): a coluna
--  nova não abre nada a ninguém.
--
--  SEM ESTE SCRIPT, a ponte responde do mesmo jeito: tenta gravar a coluna, o
--  banco a recusa, e ela grava sem ela, dizendo no log qual script falta.
--
--  DEPENDE DE JÁ TER RODADO: 064 e 069.
-- ============================================================

do $leu$
declare
  v_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_073;
  create temp table zorvin_conferencia_073 (item text, resposta text);

  if to_regclass('public.conversas') is null or to_regclass('public.mensagens') is null then
    insert into zorvin_conferencia_073 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 073 não fez nada.';
    return;
  end if;

  if to_regclass('public.zorvin_quazar_faxina') is null
     or not exists (select 1 from information_schema.columns where table_schema = 'public'
                     and table_name = 'zorvin_quazar_faxina' and column_name = 'resposta') then
    insert into zorvin_conferencia_073 values ('NÃO — falta o 064 ou o 069', 'rode-os antes');
    raise notice 'Zorvin: script 073 precisa do 064 e do 069.';
    return;
  end if;

  alter table public.zorvin_quazar_faxina add column if not exists resposta_contexto text;

  -- ------------------------------------------------------------
  -- A CONFERÊNCIA
  -- ------------------------------------------------------------
  insert into zorvin_conferencia_073
  select 'a anotação do que o Quazar leu, em quem espera, existe',
         exists (select 1 from information_schema.columns where table_schema = 'public'
                  and table_name = 'zorvin_quazar_faxina' and column_name = 'resposta_contexto')::text;
  insert into zorvin_conferencia_073
  select 'respostas a quem espera com a anotação', count(*)::text
    from public.zorvin_quazar_faxina where resposta_contexto is not null;
  insert into zorvin_conferencia_073
  select 'a tabela continua fechada (RLS ligada)',
         coalesce((select relrowsecurity from pg_class where oid = 'public.zorvin_quazar_faxina'::regclass), false)::text;
  if v_auth then
    insert into zorvin_conferencia_073 values
      ('quem entrou não lê a anotação',
       (not has_column_privilege('authenticated', 'public.zorvin_quazar_faxina', 'resposta_contexto', 'select'))::text);
  end if;
  if v_anon then
    insert into zorvin_conferencia_073 values
      ('quem não entrou não lê a anotação',
       (not has_column_privilege('anon', 'public.zorvin_quazar_faxina', 'resposta_contexto', 'select'))::text);
  end if;
end
$leu$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_073;
