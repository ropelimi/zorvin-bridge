-- ============================================================
--  076. O NOME DO CLIENTE SEMPRE EM MAIÚSCULAS (27/11)
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  ------------------------------------------------------------
--  O PEDIDO
--
--  "Nome do cliente sempre deve ser com todas as letras maiúsculas, isso deve
--  ser padrão dentro do Zorvin e Vantoro. Mesmo se algum usuário salvar com
--  letras minúsculas, os sistemas devem alterar para maiúsculas." (Rodrigo,
--  27/11). No Vantoro, o Cliente.save() passou a gravar o nome em maiúsculas
--  (a migração 0156 converte os de antes).
--
--  ------------------------------------------------------------
--  O QUE ESTE SCRIPT FAZ
--
--  No Zorvin, o nome do cliente é o que a tela mostra no alto da conversa
--  (nomeDoContato, no painel): o do cadastro do Vantoro (vantoro_nome) e, sem
--  ele, o que a equipe deu (nome_zorvin, o lápis de renomear). Os dois passam a
--  ser gravados em maiúsculas, por quem quer que os grave (o painel, a ponte,
--  o conector), por um gatilho:
--
--    zorvin_nome_em_maiusculas()   o gatilho: tira os espaços das pontas e
--                                  passa para maiúsculas. Vazio vira nulo.
--
--  E os nomes que já existem são convertidos, uma vez a cada rodada (só os que
--  não estão em maiúsculas: rodar de novo não regrava ninguém).
--
--  O nome do WhatsApp (contatos.nome) NÃO muda, e é decisão: é o nome que o
--  próprio cliente pôs no perfil, e a ponte o regrava a cada mensagem. Ninguém
--  da equipe o salva.
--
--  As duas colunas nasceram à mão, fora dos scripts: cada uma é conferida.
--
--  DEPENDE DE: nada além das tabelas do Zorvin.
-- ============================================================

do $maiusc$
declare
  v_tem_zorvin boolean;
  v_tem_vantoro boolean;
  v_n integer := 0;
  v_m integer := 0;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_076;
  create temp table zorvin_conferencia_076 (item text, resposta text);

  if to_regclass('public.contatos') is null then
    insert into zorvin_conferencia_076 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 076 não fez nada.';
    return;
  end if;

  v_tem_zorvin := exists (select 1 from information_schema.columns where table_schema = 'public'
                           and table_name = 'contatos' and column_name = 'nome_zorvin');
  v_tem_vantoro := exists (select 1 from information_schema.columns where table_schema = 'public'
                            and table_name = 'contatos' and column_name = 'vantoro_nome');

  if not v_tem_zorvin and not v_tem_vantoro then
    insert into zorvin_conferencia_076 values ('sem nome_zorvin nem vantoro_nome', 'nada a fazer aqui');
    return;
  end if;

  -- O gatilho lê as colunas por to_jsonb: uma base com só uma das duas não
  -- quebra a gravação do contato.
  create or replace function public.zorvin_nome_em_maiusculas()
  returns trigger language plpgsql set search_path = public as $f$
  declare
    j jsonb := to_jsonb(new);
    v text;
  begin
    if j ? 'nome_zorvin' then
      v := nullif(upper(btrim(j ->> 'nome_zorvin')), '');
      if v is distinct from (j ->> 'nome_zorvin') then
        new := jsonb_populate_record(new, jsonb_build_object('nome_zorvin', v));
      end if;
    end if;
    if j ? 'vantoro_nome' then
      v := nullif(upper(btrim(j ->> 'vantoro_nome')), '');
      if v is distinct from (j ->> 'vantoro_nome') then
        new := jsonb_populate_record(new, jsonb_build_object('vantoro_nome', v));
      end if;
    end if;
    return new;
  exception when others then
    -- Gravar o contato vale mais do que a caixa do nome.
    raise warning 'Zorvin: o nome em maiúsculas não foi aplicado (%).', sqlerrm;
    return new;
  end $f$;

  revoke all on function public.zorvin_nome_em_maiusculas() from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_nome_em_maiusculas() from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.zorvin_nome_em_maiusculas() from authenticated';
  end if;

  drop trigger if exists zorvin_nome_em_maiusculas on public.contatos;
  create trigger zorvin_nome_em_maiusculas
    before insert or update on public.contatos
    for each row execute function public.zorvin_nome_em_maiusculas();

  if v_tem_zorvin then
    update public.contatos set nome_zorvin = nome_zorvin
     where nome_zorvin is not null and nome_zorvin is distinct from nullif(upper(btrim(nome_zorvin)), '');
    get diagnostics v_n = row_count;
  end if;
  if v_tem_vantoro then
    update public.contatos set vantoro_nome = vantoro_nome
     where vantoro_nome is not null and vantoro_nome is distinct from nullif(upper(btrim(vantoro_nome)), '');
    get diagnostics v_m = row_count;
  end if;

  insert into zorvin_conferencia_076 values
    ('nomes dados pela equipe convertidos nesta rodada', v_n::text),
    ('nomes do cadastro convertidos nesta rodada', v_m::text);
end $maiusc$;

-- O gatilho existe, e quem ficou de fora das maiúsculas (tem de ser 0).
do $conf$
begin
  if to_regclass('public.contatos') is null then return; end if;
  insert into zorvin_conferencia_076
  select 'o gatilho existe',
         (exists (select 1 from pg_trigger where tgname = 'zorvin_nome_em_maiusculas'
                   and tgrelid = 'public.contatos'::regclass))::text;
  if exists (select 1 from information_schema.columns where table_schema = 'public'
              and table_name = 'contatos' and column_name = 'nome_zorvin') then
    execute $q$ insert into zorvin_conferencia_076
      select 'nomes da equipe fora das maiúsculas (tem de ser 0)', count(*)::text
        from public.contatos where nome_zorvin <> upper(nome_zorvin) $q$;
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public'
              and table_name = 'contatos' and column_name = 'vantoro_nome') then
    execute $q$ insert into zorvin_conferencia_076
      select 'nomes do cadastro fora das maiúsculas (tem de ser 0)', count(*)::text
        from public.contatos where vantoro_nome <> upper(vantoro_nome) $q$;
  end if;
end $conf$;

select * from zorvin_conferencia_076;
