-- ============================================================
--  DUAS CONTAS PARA A MESMA PESSOA
--
--  A conferência das fotos revelou 21 linhas em `usuarios` para 19 pessoas:
--  "Danilo Ferro" e "Max Canaverde" apareciam duas vezes. Olhando de perto, a
--  segunda conta de cada um é a antiga — o login curto, criado antes de o
--  escritório padronizar `nome.sobrenome`:
--
--    danilo.ferro   6 mensagens · entrou em 17/08      ← esta fica
--    danilo         0 mensagens · NUNCA entrou
--    max.canaverde  13 mensagens · entrou em 19/08     ← esta fica
--    max            0 mensagens · NUNCA entrou
--
--  ONDE ISSO MORDE. Nem toda parte do sistema tropeça nisso, e vale separar:
--
--    • O filtro "quem participou" casa o histórico ANTIGO pelo NOME (é a
--      metade que existe para as mensagens anteriores à coluna
--      `enviado_por_id`). Com duas linhas de mesmo nome, esse casamento
--      devolve as DUAS — e a pessoa aparece duas vezes no menu, cada uma com
--      a mesma contagem.
--    • A tela sabe juntar pelo nome antes de desenhar a lista de participantes
--      da conversa, então ali não aparece dobrado. Foi por isso que ninguém
--      notou até a conferência das fotos.
--    • O Painel conta por id, e as contas mortas têm zero mensagem — então
--      hoje ele não está partindo número de ninguém. Mas partiria no dia em
--      que alguém entrasse pela conta velha.
--
--  Rodar no SQL Editor do Supabase. O passo 1 não altera nada.
-- ============================================================

set search_path = public;


-- ------------------------------------------------------------
--  PASSO 1 — O QUE APONTA PARA AS CONTAS MORTAS. Rode e leia.
--
--  As colunas são DESCOBERTAS, e não listadas à mão: qualquer coluna `uuid`
--  chamada `usuario_id`, `autor_id` ou terminada em `_por_id`, mais tudo o que
--  tenha chave estrangeira para `usuarios`. Uma tabela criada depois deste
--  arquivo entra sozinha na conta — uma lista fixa envelheceria em silêncio, e
--  o que ela esquecesse sumiria junto com a linha apagada.
-- ------------------------------------------------------------
do $$
declare
  r record;
  n bigint;
  achou boolean := false;
begin
  for r in
    select c.table_name as tabela, c.column_name as coluna
      from information_schema.columns c
     where c.table_schema = 'public'
       and c.data_type = 'uuid'
       and (c.column_name in ('usuario_id', 'autor_id') or c.column_name like '%\_por\_id')
     union
    select cl.relname, a.attname
      from pg_constraint co
      join pg_class cl on cl.oid = co.conrelid
      join pg_attribute a on a.attrelid = co.conrelid and a.attnum = any(co.conkey)
     where co.contype = 'f' and co.confrelid = 'usuarios'::regclass
     order by 1, 2
  loop
    execute format(
      'select count(*) from %I where %I in (%L, %L)',
      r.tabela, r.coluna,
      '8611d289-8bbc-41e1-b0ef-96731d7b558f',   -- danilo (a morta)
      '148527e0-ed16-4e88-a5b8-17e52fe4962f')   -- max (a morta)
      into n;
    if n > 0 then
      achou := true;
      raise notice '% . %  →  % linha(s) apontando para uma conta morta', r.tabela, r.coluna, n;
    end if;
  end loop;
  if not achou then
    raise notice 'nada aponta para as contas mortas — a junção é só apagar as duas linhas';
  end if;
end $$;


-- ------------------------------------------------------------
--  PASSO 2 — A JUNÇÃO
--
--  Tudo o que aponta para a conta morta passa a apontar para a que fica; a
--  linha morta é apagada no fim. Um bloco só: falhou, o banco volta como
--  estava.
--
--  `permissoes` é a exceção, e de propósito: permissão é de CONTA, não de
--  pessoa. A conta que fica já tem as suas, vindas dos logins dela; mover as
--  da conta morta por cima daria acesso que ninguém concedeu. As dela são
--  apagadas — e cairiam sozinhas de qualquer forma, porque a chave é
--  `on delete cascade`.
-- ------------------------------------------------------------
do $$
declare
  juntar constant text[][] := array[
    -- morta                                    fica
    ['8611d289-8bbc-41e1-b0ef-96731d7b558f', '73759e46-7cae-4de7-90a0-1ac5aedaffe6'],  -- Danilo Ferro
    ['148527e0-ed16-4e88-a5b8-17e52fe4962f', '57afb06e-9ee3-484d-bea2-f3c75271c67c']   -- Max Canaverde
  ];
  par text[];
  r record;
  n bigint;
begin
  foreach par slice 1 in array juntar loop
    -- Confere que as duas existem e são a mesma pessoa, antes de mexer em
    -- qualquer coisa. Ids trocados de posição apagariam a conta viva.
    perform 1 from usuarios a, usuarios b
      where a.id = par[1]::uuid and b.id = par[2]::uuid
        and zorvin_sem_acento(a.nome) = zorvin_sem_acento(b.nome);
    if not found then
      -- Já juntadas numa rodada anterior, ou ids que não casam: não é erro,
      -- é o script sendo seguro de rodar de novo.
      raise notice 'pulei % → %: uma das duas não existe (ou os nomes não batem)', par[1], par[2];
      continue;
    end if;

    for r in
      select c.table_name as tabela, c.column_name as coluna
        from information_schema.columns c
       where c.table_schema = 'public'
         and c.data_type = 'uuid'
         and (c.column_name in ('usuario_id', 'autor_id') or c.column_name like '%\_por\_id')
       union
      select cl.relname, a.attname
        from pg_constraint co
        join pg_class cl on cl.oid = co.conrelid
        join pg_attribute a on a.attrelid = co.conrelid and a.attnum = any(co.conkey)
       where co.contype = 'f' and co.confrelid = 'usuarios'::regclass
       order by 1, 2
    loop
      if r.tabela = 'permissoes' then
        execute format('delete from permissoes where %I = %L', r.coluna, par[1]);
      else
        execute format('update %I set %I = %L where %I = %L',
                       r.tabela, r.coluna, par[2], r.coluna, par[1]);
      end if;
      get diagnostics n = row_count;
      if n > 0 then
        raise notice '  % . %: % linha(s)', r.tabela, r.coluna, n;
      end if;
    end loop;

    delete from usuarios where id = par[1]::uuid;
    raise notice 'juntado: a conta % foi apagada, o histórico dela ficou com %', par[1], par[2];
  end loop;
end $$;


-- ------------------------------------------------------------
--  CONFERÊNCIA — rode e leia
--
--  A primeira consulta tem de vir VAZIA: nenhum nome repetido.
-- ------------------------------------------------------------
select nome, count(*) as contas, string_agg(login, ' + ' order by login) as logins
  from usuarios
 group by nome
having count(*) > 1;

select u.nome, u.login, u.admin,
       (select count(*) from mensagens m where m.enviado_por_id = u.id) as mensagens
  from usuarios u
 where u.login in ('danilo.ferro', 'max.canaverde')
 order by u.nome;


-- ------------------------------------------------------------
--  E FALTA UMA COISA, QUE NÃO É AQUI
--
--  Apagar a linha de `usuarios` NÃO apaga a conta. Ela existe no Vantoro, que
--  é o dono do cadastro, e existe no Supabase Auth. Se alguém entrar com
--  `danilo@…` ou `max@…`, a ponte recria a linha no login seguinte e a
--  duplicata volta — desta vez com mensagens dentro, que é o caso difícil.
--
--  Então, para valer de vez: desative (ou apague) esses dois logins NO
--  VANTORO. É de lá que o Zorvin copia quem é quem.
--
--  Repare também que as contas mortas são as que estão com `admin = true`, e
--  as que ficam, não. Ou seja: hoje o Danilo e o Max NÃO administram o Zorvin,
--  porque entram pela outra conta. Se eles devem administrar, marque-os como
--  superusuário no Vantoro nas contas `danilo.ferro` e `max.canaverde` — a
--  ponte traz isso no próximo login deles.
-- ------------------------------------------------------------
