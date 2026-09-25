-- ============================================================
--  "JÁ TRATEI" — tirar da fila o que foi resolvido sem mandar mensagem
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  POR QUE ELE EXISTE, MEDIDO EM 25/09
--
--  A fila da espera (script 004) nasceu com **813 conversas**. Perguntando ao
--  banco o que elas são:
--
--    601  nós respondemos e o cliente escreveu de volta
--    214  nunca respondemos nada
--
--  E, entre as 601, o que o cliente escreveu por último:
--
--    369  até 15 letras
--     99  `[anexo]`   ← o MAIOR grupo, e é documento de cliente sem confirmação
--     42  "ok"
--     22  "boa tarde"      12  "bom dia"       7  "oi"
--      9  "obrigada"        7  "sim"           5  "certo"
--
--  A conta que isso fecha: ~140 são espera DE VERDADE (o anexo e as
--  saudações), e ~94 são despedida — "ok", "obrigada", o joinha. Despedida não
--  pede resposta, e a conversa fica na fila para sempre porque o banco não tem
--  como saber a diferença.
--
--  **Quem sabe a diferença é a pessoa que leu a conversa.** É só isso que este
--  script cria: um jeito de ela dizer.
--
--  ------------------------------------------------------------
--  `conversas.tratada_em` É "A NOSSA ÚLTIMA AÇÃO", E NÃO UMA SEGUNDA FILA
--
--  Esta é a decisão principal, e ela é pequena de propósito.
--
--  O script 004 define a espera como *"a primeira mensagem do cliente depois
--  da NOSSA ÚLTIMA RESPOSTA"*. "Já tratei" é exatamente isto: nós agimos —
--  só que sem mandar mensagem. Então ele não ganha coluna própria na conta:
--  ele entra como mais um candidato ao "o que fizemos por último", ao lado da
--  última mensagem nossa, por um `greatest`.
--
--  A alternativa seria a tela apagar `esperando_desde` e pronto. **Não
--  funciona**, e o motivo é concreto: `zorvin_recontar_espera()` recalcula do
--  zero — depois de uma importação de histórico ela devolveria à fila tudo o
--  que a equipe tratou, porque continua não havendo resposta nossa. Trabalho
--  de semanas desfeito por uma importação, sem nada na tela dizendo por quê.
--
--  ------------------------------------------------------------
--  DÁ PARA DESFAZER, E ISSO NÃO É LUXO
--
--  Marcar "já tratei" por engano faz um cliente sumir da fila em silêncio —
--  que é o pior desfecho deste sistema, com outra roupa. Então:
--
--  - a tela exige a checklist antes de confirmar (atrito contra o clique
--    errado);
--  - e o registro pode ser DESFEITO: `tratada_em` volta a nulo, a recontagem
--    recoloca a conversa na fila com a espera ORIGINAL, e a linha do
--    tratamento ganha `desfeito_em` em vez de sumir.
--
--  **O registro não é apagado**, e é decisão: quem desfez e quando é
--  justamente a informação que interessa quando alguém pergunta "por que este
--  cliente sumiu da fila em agosto".
--
--  ------------------------------------------------------------
--  OS ASSUNTOS SÃO TABELA, E NÃO LISTA NO CÓDIGO
--
--  Os oito de hoje (BLINDAGEM, SUBSÍDIO EMENDA, …) são os do escritório. Quem
--  compra o programa tem outros, e não publica nada — abre a tela e escreve.
--  É a mesma razão do script 003.
--
--  **Assunto não se APAGA, se DESATIVA** (`ativo = false`). Apagar deixaria os
--  tratamentos antigos apontando para o nada, e um relatório com buraco é pior
--  do que um relatório com uma linha a mais. Por isso não há política de
--  DELETE aqui — e não é esquecimento.
--
--  **E o tratamento guarda o `assunto_id`, não o nome copiado.** Assim,
--  corrigir "Subisídio Emenda" para "Subsídio Emenda" conserta o passado
--  inteiro de uma vez. O preço é que renomear um assunto para OUTRA COISA
--  reescreve a história — e a saída certa para isso é desativar o velho e
--  criar um novo, que é o que a tela oferece.
--
--  ------------------------------------------------------------
--  ENQUANTO ISTO NÃO FOR RODADO, NADA MUDA
--
--  O painel descobre sozinho que a coluna e a tabela não existem, e o botão
--  "Já tratei" simplesmente não aparece.
--
--  ------------------------------------------------------------
--  CONFERÊNCIA (depois de aplicado)
--
--    select nome, ordem, ativo from public.zorvin_assuntos order by ordem;
--    -- deve devolver os oito
--
--    select count(*) from public.conversas where tratada_em is not null;
--    -- zero, por enquanto
-- ============================================================

-- ------------------------------------------------------------
--  1. OS ASSUNTOS
--
--  FORA DO BLOCO GUARDADO de propósito: esta tabela não depende de
--  `conversas`, então ela nasce igual num banco zerado de cliente novo. Só o
--  que encosta em `conversas`/`mensagens` precisa da guarda (ver o script
--  004, e a prova 51l-bis que a exigiu).
-- ------------------------------------------------------------
create table if not exists public.zorvin_assuntos (
  id         uuid primary key default gen_random_uuid(),
  nome       text not null,
  ordem      integer not null default 0,
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);

comment on table public.zorvin_assuntos is
  'O que a equipe marca ao dizer "já tratei". Editável na tela de '
  'administração. Não se apaga assunto: desativa-se (ativo = false), senão os '
  'tratamentos antigos ficam apontando para o nada.';

-- O NOME É ÚNICO ENTRE OS ATIVOS, e não entre todos: desativado "ACORDOS" e
-- criado outro com o mesmo nome anos depois é situação legítima, e o índice
-- total a proibiria sem explicar por quê.
create unique index if not exists zorvin_assuntos_nome_ativo
  on public.zorvin_assuntos (lower(nome)) where ativo;

-- OS OITO DO ESCRITÓRIO, e só na primeira vez. O `where not exists` olha a
-- tabela INTEIRA: rodando de novo depois de o escritório ter desativado um
-- deles, um `on conflict` o ressuscitaria — e assunto que volta sozinho é o
-- mesmo defeito da chave que volta sozinha, descrito no CLAUDE.md do painel.
insert into public.zorvin_assuntos (nome, ordem)
select v.nome, v.ordem
  from (values
          ('BLINDAGEM',            1),
          ('SUBSÍDIO EMENDA',      2),
          ('SUBSÍDIO CONDENAÇÃO',  3),
          ('SUBSÍDIO CCR',         4),
          ('DOCUMENTOS JG',        5),
          ('ACORDOS',              6),
          ('VENDA CCS',            7),
          ('VENDA LN',             8)
       ) as v(nome, ordem)
 where not exists (select 1 from public.zorvin_assuntos);

alter table public.zorvin_assuntos enable row level security;

-- LÊ QUEM ENTROU: a checklist aparece para toda atendente.
drop policy if exists zorvin_assuntos_leitura on public.zorvin_assuntos;
create policy zorvin_assuntos_leitura on public.zorvin_assuntos
  for select to authenticated using (true);

-- ESCREVE QUEM ADMINISTRA, e em DUAS políticas separadas — `for all` daria
-- DELETE junto, que é exatamente o que não pode existir aqui.
drop policy if exists zorvin_assuntos_criar on public.zorvin_assuntos;
create policy zorvin_assuntos_criar on public.zorvin_assuntos
  for insert to authenticated with check (public.zorvin_admin());

drop policy if exists zorvin_assuntos_editar on public.zorvin_assuntos;
create policy zorvin_assuntos_editar on public.zorvin_assuntos
  for update to authenticated
  using (public.zorvin_admin()) with check (public.zorvin_admin());

grant select, insert, update on public.zorvin_assuntos to authenticated;

-- ------------------------------------------------------------
--  2. O RESTO — encosta em `conversas`, então vai na guarda
-- ------------------------------------------------------------
do $tratei$
begin
  if to_regclass('public.conversas') is null or to_regclass('public.mensagens') is null then
    raise notice 'Zorvin: banco sem `conversas`/`mensagens` — só os assuntos foram criados.';
    return;
  end if;

  execute 'alter table public.conversas add column if not exists tratada_em timestamptz';

  execute $x$
    comment on column public.conversas.tratada_em is
      'Quando alguém disse "já tratei" nesta conversa. Entra na conta da espera '
      'como se fosse uma resposta nossa: é a NOSSA ÚLTIMA AÇÃO, só que sem '
      'mensagem. Nulo = ninguém tratou (ou o tratamento foi desfeito).'
  $x$;

  -- ------------------------------------------------------------
  --  O REGISTRO DO QUE FOI TRATADO
  --
  --  UMA LINHA POR ASSUNTO, e não uma linha com uma lista de assuntos dentro.
  --  A pergunta que este registro existe para responder é "quanto de BLINDAGEM
  --  a equipe fez em setembro", e ela é uma contagem — com a lista guardada
  --  num campo só, toda contagem viraria uma varredura de texto.
  -- ------------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_tratamentos (
      id             uuid primary key default gen_random_uuid(),
      conversa_id    uuid not null references public.conversas(id) on delete cascade,
      assunto_id     uuid not null references public.zorvin_assuntos(id),
      quem           uuid,
      quando         timestamptz not null default now(),
      -- A ESPERA QUE ESTAVA CORRENDO na hora de tratar. Guardo a DATA, e não
      -- o número de dias: o número é derivado dela e envelheceria escrito,
      -- passando a dizer uma coisa diferente a cada relatório.
      esperava_desde timestamptz,
      desfeito_em    timestamptz,
      desfeito_por   uuid
    )
  $x$;

  execute $x$
    comment on table public.zorvin_tratamentos is
      'Uma linha por assunto marcado em cada "já tratei". Nada é apagado: '
      'desfazer preenche desfeito_em, porque quem desfez e quando é a '
      'informação que interessa quando se pergunta por que um cliente sumiu '
      'da fila.'
  $x$;

  -- OS DOIS ÍNDICES SÃO AS DUAS PERGUNTAS QUE A TELA FAZ: "esta conversa já
  -- foi tratada?" (ao abrir) e "o que a equipe tratou no mês?" (relatório).
  execute 'create index if not exists zorvin_tratamentos_conversa
             on public.zorvin_tratamentos (conversa_id, quando desc)';
  execute 'create index if not exists zorvin_tratamentos_quando
             on public.zorvin_tratamentos (quando desc)';

  execute 'alter table public.zorvin_tratamentos enable row level security';

  execute $x$
    drop policy if exists zorvin_tratamentos_leitura on public.zorvin_tratamentos
  $x$;
  execute $x$
    create policy zorvin_tratamentos_leitura on public.zorvin_tratamentos
      for select to authenticated using (true)
  $x$;

  execute $x$
    drop policy if exists zorvin_tratamentos_criar on public.zorvin_tratamentos
  $x$;
  execute $x$
    create policy zorvin_tratamentos_criar on public.zorvin_tratamentos
      for insert to authenticated with check (true)
  $x$;

  -- DESFAZER É UM UPDATE, e a permissão vai POR COLUNA: `grant update
  -- (desfeito_em, desfeito_por)` é o que impede alguém de reescrever o assunto
  -- ou a data de um tratamento antigo. A política sozinha não faria isso — ela
  -- libera a LINHA, e não o que se pode mexer dentro dela.
  execute $x$
    drop policy if exists zorvin_tratamentos_desfazer on public.zorvin_tratamentos
  $x$;
  execute $x$
    create policy zorvin_tratamentos_desfazer on public.zorvin_tratamentos
      for update to authenticated using (true) with check (true)
  $x$;

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select, insert on public.zorvin_tratamentos to authenticated';
    execute 'grant update (desfeito_em, desfeito_por) on public.zorvin_tratamentos to authenticated';
  end if;

  -- ------------------------------------------------------------
  --  3. A CONTA DA ESPERA PASSA A ENXERGAR `tratada_em`
  --
  --  As duas funções do script 004 são REESCRITAS aqui, e não remendadas: a
  --  regra "o que fizemos por último" tem de ser a mesma nas duas, e deixar
  --  uma delas para trás é a fila dizer uma coisa ao vivo e outra depois da
  --  recontagem.
  --
  --  `greatest` IGNORA NULOS no Postgres, e é disso que esta conta vive: uma
  --  conversa nunca respondida tem `max(mensagem nossa)` nulo, uma nunca
  --  tratada tem `tratada_em` nulo, e o `greatest` devolve o que existir.
  --  Com os dois nulos ele devolve nulo, e o `coalesce` cai no `-infinity` —
  --  que é o certo: o cliente espera desde a primeira mensagem da vida dele.
  -- ------------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_recontar_espera(p_conversa uuid default null)
    returns integer
    language plpgsql
    as $fn$
    declare n integer;
    begin
      with certo as (
        select c.id,
               (select min(m.criado_em)
                  from public.mensagens m
                 where m.conversa_id = c.id
                   and m.origem = 'contato'
                   and m.criado_em > coalesce(
                         greatest(
                           (select max(m2.criado_em) from public.mensagens m2
                             where m2.conversa_id = c.id and m2.origem = 'advogado'),
                           c.tratada_em),
                         '-infinity'::timestamptz)) as quando
          from public.conversas c
         where p_conversa is null or c.id = p_conversa
      )
      update public.conversas c
         set esperando_desde = certo.quando
        from certo
       where c.id = certo.id
         and c.esperando_desde is distinct from certo.quando;
      get diagnostics n = row_count;
      return n;
    end
    $fn$
  $x$;

  execute 'revoke all on function public.zorvin_recontar_espera(uuid) from public';
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.zorvin_recontar_espera(uuid) to authenticated';
  end if;

  execute $x$
    create or replace function public.zorvin_marcar_espera()
    returns trigger
    language plpgsql
    as $fn$
    begin
      if new.origem = 'contato' then
        -- JÁ RESPONDIDA **OU JÁ TRATADA**? Então não põe ninguém na fila.
        --
        -- A segunda metade é o que este script acrescenta, e ela importa no
        -- caso de todo dia: tratada a conversa hoje de manhã, a rodada de
        -- recuperação da caixa de entrada pode gravar à tarde uma mensagem
        -- que o cliente mandou ANTES — e sem esta pergunta a conversa
        -- voltaria para a fila por causa de uma mensagem que já estava
        -- coberta pelo tratamento.
        if exists (select 1 from public.mensagens m
                    where m.conversa_id = new.conversa_id
                      and m.origem = 'advogado'
                      and m.criado_em >= new.criado_em)
           or exists (select 1 from public.conversas c
                       where c.id = new.conversa_id
                         and c.tratada_em >= new.criado_em) then
          return null;
        end if;

        update public.conversas
           set esperando_desde = least(coalesce(esperando_desde, new.criado_em), new.criado_em)
         where id = new.conversa_id;
      elsif new.origem = 'advogado' then
        -- E RESPONDER LIMPA O TRATAMENTO JUNTO.
        --
        -- Sem isto, `tratada_em` de agosto continuaria escrito depois de a
        -- conversa ter ido e voltado várias vezes, e uma recontagem futura o
        -- usaria como "a nossa última ação" — segurando fora da fila uma
        -- mensagem de setembro. A resposta é mais recente e mais forte: ela
        -- substitui o tratamento.
        update public.conversas
           set esperando_desde = null,
               tratada_em = null
         where id = new.conversa_id
           and coalesce(esperando_desde, tratada_em) <= new.criado_em;
      end if;
      return null;
    exception when others then
      raise warning 'zorvin_espera: %', sqlerrm;
      return null;
    end
    $fn$
  $x$;

  raise notice 'Zorvin: "já tratei" instalado — assuntos, registro e a conta da espera.';
end
$tratei$;
