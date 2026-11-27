-- ============================================================
--  078. O NOME DAS ETIQUETAS SÓ COM A PRIMEIRA LETRA MAIÚSCULA (27/11)
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  ------------------------------------------------------------
--  O PEDIDO
--
--  "Notei que existem etiquetas com o nome tudo em maiúsculo como por exemplo
--  SUBSÍDIO EMENDA. Quero que todas as etiquetas sigam um padrão onde apenas a
--  primeira letra é maiúscula e as demais são minúsculas. Faça isso em todas
--  as existentes e as futuras que forem criadas." (Rodrigo, 27/11)
--
--  ------------------------------------------------------------
--  O QUE ESTE SCRIPT FAZ
--
--    zorvin_nome_da_etiqueta(texto)   a regra: sem os espaços das pontas, a
--                                     primeira letra maiúscula e o resto
--                                     minúsculo ("SUBSÍDIO EMENDA" vira
--                                     "Subsídio emenda").
--    zorvin_etiqueta_nome_padrao()    o gatilho em `tags`: vale para quem
--                                     grava (o painel, a ponte, o conector),
--                                     as manuais e as automáticas.
--
--  E os nomes que já existem são convertidos (só os que estão fora da regra:
--  rodar de novo não regrava ninguém).
--
--  A rodada das etiquetas do Vantoro (075/077) grava o nome que o Vantoro
--  manda ("SUBSÍDIO EMENDA") sempre que ele difere do guardado, e com o
--  gatilho ele sempre difere: o gatilho deixa essa gravação sem efeito quando
--  nada muda de verdade, para a rodada de 30 em 30 minutos não regravar as
--  etiquetas (cada gravação vira aviso do tempo real para cada aba aberta).
--  Só para quem não entrou pelo painel (a ponte, o editor): pelo painel, a
--  gravação sem efeito diria "o banco não deixou" na tela.
--
--  O gatilho nasce com um nome que vem ANTES da trava do 075 na ordem
--  alfabética ("nome" < "trava"): os gatilhos BEFORE do Postgres rodam nessa
--  ordem, e a gravação sem efeito não precisa passar pela trava.
--
--  DEPENDE DE: a tabela `tags`.
-- ============================================================

do $etq$
declare
  v_n integer := 0;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_078;
  create temp table zorvin_conferencia_078 (item text, resposta text);

  if to_regclass('public.tags') is null then
    insert into zorvin_conferencia_078 values ('sem a tabela das etiquetas', 'nada a fazer aqui');
    raise notice 'Zorvin: sem a tabela tags — script 078 não fez nada.';
    return;
  end if;

  create or replace function public.zorvin_nome_da_etiqueta(p_nome text)
  returns text language sql immutable set search_path = public as $f$
    select case when p_nome is null then null
                else upper(left(btrim(p_nome), 1)) || lower(substr(btrim(p_nome), 2)) end
  $f$;

  create or replace function public.zorvin_etiqueta_nome_padrao()
  returns trigger language plpgsql set search_path = public, auth as $f$
  begin
    new.nome := public.zorvin_nome_da_etiqueta(new.nome);
    if tg_op = 'UPDATE' and new is not distinct from old and auth.uid() is null then
      return null;  -- nada mudou: a gravação da ponte fica sem efeito
    end if;
    return new;
  end $f$;

  revoke all on function public.zorvin_etiqueta_nome_padrao() from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_etiqueta_nome_padrao() from anon';
    execute 'revoke all on function public.zorvin_nome_da_etiqueta(text) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.zorvin_etiqueta_nome_padrao() from authenticated';
  end if;

  drop trigger if exists zorvin_etiqueta_nome_padrao on public.tags;
  create trigger zorvin_etiqueta_nome_padrao
    before insert or update on public.tags
    for each row execute function public.zorvin_etiqueta_nome_padrao();

  update public.tags set nome = public.zorvin_nome_da_etiqueta(nome)
   where nome is distinct from public.zorvin_nome_da_etiqueta(nome);
  get diagnostics v_n = row_count;

  insert into zorvin_conferencia_078 values ('etiquetas convertidas nesta rodada', v_n::text);
end $etq$;

-- O gatilho existe, e quem ficou fora da regra (tem de ser 0).
do $conf$
begin
  if to_regclass('public.tags') is null then return; end if;
  insert into zorvin_conferencia_078
  select 'o gatilho existe',
         (exists (select 1 from pg_trigger where tgname = 'zorvin_etiqueta_nome_padrao'
                   and tgrelid = 'public.tags'::regclass))::text;
  insert into zorvin_conferencia_078
  select 'etiquetas fora da regra (tem de ser 0)', count(*)::text
    from public.tags where nome is distinct from public.zorvin_nome_da_etiqueta(nome);
end $conf$;

select * from zorvin_conferencia_078;
