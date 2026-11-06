-- ============================================================
--  O ADVOGADO NA AUDIÊNCIA RESPONDE PELA CONVERSA DO AVISO
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Quem roda é a PONTE, sozinha, na publicação que vem com o merge.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O PEDIDO (06/11)
--
--  "Na tela de Audiências quando o usuário cadastra uma nova audiência, ele
--  também informa quem será o advogado na audiência. Esse advogado na
--  audiência, após ser enviada a mensagem de aviso pelo Zorvin, essa
--  conversa no Zorvin deve ter o advogado na audiência como responsável da
--  conversa." E: "O usuário do Vantoro é o mesmo usuário do Zorvin" — o
--  login é o mesmo nos dois (ex.: willian.jones).
--
--  ------------------------------------------------------------
--  COMO
--
--  O Vantoro manda, em cada aviso, o LOGIN de quem vai à audiência
--  (`responsavel_da_conversa.login`). A ponte guarda o login no item da fila
--  (`fila_envio.responsavel_login`) e, quando a mensagem SAI de verdade — no
--  mesmo ponto em que confirma o aviso no Vantoro —, chama a função abaixo.
--  Antes de sair não muda nada: o aviso recusado pela Uazapi não passa a
--  conversa para ninguém.
--
--  `zorvin_aviso_passa_ao_advogado(conversa, login)` acha a pessoa pelo login
--  (sem olhar caixa) e a põe como responsável. Devolve `{passou, motivo}` ou
--  `{passou: true, para, nome, antes}`, para o log da ponte. NÃO passa:
--
--    - sem login (audiência sem advogado, o Correspondente, nome sem conta);
--    - login que o Zorvin não tem, ou que duas contas têm;
--    - pessoa desativada;
--    - pessoa que NÃO VÊ A LINHA da conversa (`zorvin_ve_o_telefone`, a regra
--      de acesso do 023): dar a conversa a quem não consegue abri-la seria o
--      cliente sem ninguém, com cara de ter dono. Quem administra dá a
--      permissão da linha das audiências, e o próximo aviso passa;
--    - a conversa que já é dela (nada a mudar).
--
--  QUEM ESTAVA COM A CONVERSA DEIXA DE ESTAR: o pedido é que o advogado da
--  audiência seja o responsável. `responsavel_por` fica nulo — foi o sistema,
--  como na distribuição (023) — e `responsavel_em` é agora. A cada aviso que
--  sai, a conversa volta para o advogado da audiência daquele aviso.
--
--  SÓ A PONTE CHAMA (service_role). Quem atende não alcança a função: ela
--  muda o dono sem perguntar quem pediu.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    008 (o responsável) e 023 (`zorvin_ve_o_telefone`)
-- ============================================================

do $s055$
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA (a lição do 006 e do 007).
  drop table if exists zorvin_conferencia_055;
  create temp table zorvin_conferencia_055 (item text, resposta text);

  if to_regclass('public.conversas') is null
     or to_regclass('public.usuarios') is null
     or to_regclass('public.fila_envio') is null then
    insert into zorvin_conferencia_055
      values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas de conversas — script 055 não fez nada.';
    return;
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'conversas'
                    and column_name = 'responsavel_id')
     or to_regprocedure('public.zorvin_ve_o_telefone(uuid, uuid)') is null then
    insert into zorvin_conferencia_055
      values ('o responsável (008) e a regra de acesso (023)', 'NÃO — rode o script 008 e o 023 antes');
    raise notice 'Zorvin: sem o 008 ou o 023 — script 055 não fez nada.';
    return;
  end if;

  execute 'alter table public.fila_envio add column if not exists responsavel_login text';
  execute $c$comment on column public.fila_envio.responsavel_login is
    'Aviso de audiência: o login do advogado na audiência. Quando a mensagem sai, '
    'ele passa a responder pela conversa (zorvin_aviso_passa_ao_advogado).'$c$;

  execute $x$
    create or replace function public.zorvin_aviso_passa_ao_advogado(p_conversa uuid, p_login text)
    returns jsonb language plpgsql security definer set search_path = public as $f$
    declare
      v_login   text := lower(btrim(coalesce(p_login, '')));
      v_conv    record;
      v_pessoa  record;
      v_quantas integer;
    begin
      if v_login = '' then
        return jsonb_build_object('passou', false, 'motivo', 'sem_login');
      end if;
      select c.id, c.advogado_id, c.responsavel_id into v_conv
        from public.conversas c where c.id = p_conversa;
      if not found then
        return jsonb_build_object('passou', false, 'motivo', 'conversa_nao_achada');
      end if;

      select count(*) into v_quantas from public.usuarios u where lower(btrim(u.login)) = v_login;
      if v_quantas = 0 then
        return jsonb_build_object('passou', false, 'motivo', 'login_nao_achado');
      end if;
      if v_quantas > 1 then
        return jsonb_build_object('passou', false, 'motivo', 'login_repetido');
      end if;
      select u.id, u.nome, u.ativo into v_pessoa
        from public.usuarios u where lower(btrim(u.login)) = v_login;
      if v_pessoa.ativo is false then
        return jsonb_build_object('passou', false, 'motivo', 'desativado', 'nome', v_pessoa.nome);
      end if;
      if not public.zorvin_ve_o_telefone(v_pessoa.id, v_conv.advogado_id) then
        return jsonb_build_object('passou', false, 'motivo', 'nao_ve_a_linha', 'nome', v_pessoa.nome);
      end if;
      if v_conv.responsavel_id = v_pessoa.id then
        return jsonb_build_object('passou', false, 'motivo', 'ja_era_dele', 'nome', v_pessoa.nome);
      end if;

      update public.conversas
         set responsavel_id = v_pessoa.id, responsavel_em = now(), responsavel_por = null
       where id = p_conversa;
      return jsonb_build_object('passou', true, 'para', v_pessoa.id, 'nome', v_pessoa.nome,
                                'antes', v_conv.responsavel_id);
    end
    $f$
  $x$;
  execute 'revoke all on function public.zorvin_aviso_passa_ao_advogado(uuid, text) from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_aviso_passa_ao_advogado(uuid, text) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.zorvin_aviso_passa_ao_advogado(uuid, text) from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.zorvin_aviso_passa_ao_advogado(uuid, text) to service_role';
  end if;

  -- ----------------------------------------------------------
  --  A CONFERÊNCIA, na última linha (regra 6 do LEIA-ME).
  -- ----------------------------------------------------------
  insert into zorvin_conferencia_055
  select 'a fila guarda o login do advogado da audiência',
         exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fila_envio'
                    and column_name = 'responsavel_login')::text
  union all
  select 'a ponte alcança a função',
         (not exists (select 1 from pg_roles where rolname = 'service_role')
          or has_function_privilege('service_role',
               'public.zorvin_aviso_passa_ao_advogado(uuid, text)', 'execute'))::text
  union all
  select 'quem atende não alcança a função',
         (not exists (select 1 from pg_roles where rolname = 'authenticated')
          or not has_function_privilege('authenticated',
               'public.zorvin_aviso_passa_ao_advogado(uuid, text)', 'execute'))::text;
end $s055$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_055;
