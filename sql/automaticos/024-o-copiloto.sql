-- ============================================================
--  O COPILOTO — o manual que ele lê antes de sugerir uma resposta
--
--  ------------------------------------------------------------
--  O QUE ELE É
--
--  Pedido do Rodrigo em 13/10: um copiloto de IA que sugere a resposta da
--  atendente. Decidido com ele: pelo Claude Haiku 5.5 (Anthropic), AO CLICAR
--  em "Sugerir resposta", e a sugestão cai na caixa de escrever — só sai
--  quando a atendente aperta Enviar. Quem fala com a Anthropic é a PONTE
--  (`POST /copiloto/sugerir`), onde mora a chave `ANTHROPIC_API_KEY`.
--
--  O copiloto lê, na hora do clique: as últimas mensagens da conversa aberta,
--  as mensagens rápidas da equipe (o jeito de escrever da casa) e ESTE
--  manual. Nenhuma conversa de cliente foi usada para escrevê-lo: o modelo
--  inicial abaixo é genérico, e o escritório o ajusta pela tela.
--
--  ------------------------------------------------------------
--  POR QUE UMA TABELA, E NÃO UM TEXTO NO CÓDIGO
--
--  A régua das palavras da casa (003): texto que exige chamar o fornecedor
--  para ser trocado é texto fixo. Quem administra abre Departamentos e
--  acessos → Copiloto e escreve; a próxima sugestão já lê o novo.
--
--  ------------------------------------------------------------
--  UMA LINHA SÓ, E É PROPOSITAL
--
--  `id` é fixo em `true` com `check (id)`, como no 003: duas linhas de
--  configuração viram a pergunta "qual delas vale".
--
--  ------------------------------------------------------------
--  QUEM LÊ E QUEM ESCREVE
--
--  Lê: quem entrou (a tela de administração mostra o texto; a ponte lê com a
--  chave dela). Escreve: só quem administra (`zorvin_admin()`, que já exige
--  `admin E ativo`). Ninguém apaga a linha: não há política de DELETE nem de
--  INSERT — sem a linha, o "Salvar" da tela não teria o que atualizar.
--
--  QUEM MUDOU E QUANDO são do gatilho, e não da tela: `atualizado_por` é
--  sempre quem estava entrado no momento, e `atualizado_em` é o relógio do
--  banco (a régua do 020 para `tratada_em`).
--
--  ------------------------------------------------------------
--  O MODELO INICIAL SÓ ENTRA NA RODADA QUE CRIA A TABELA
--
--  Regra 5 do LEIA-ME: rodar de novo não pode desfazer o que o escritório
--  escreveu. E se a linha sumir (só a chave da ponte conseguiria apagá-la),
--  ela volta VAZIA, e não com o modelo — o copiloto segue com as regras fixas
--  da ponte, e quem administra vê a caixa em branco.
--
--  ------------------------------------------------------------
--  ENQUANTO ESTE ARQUIVO NÃO FOR RODADO
--
--  O copiloto funciona com as regras fixas da ponte, as mensagens rápidas e a
--  conversa — só sem o manual. A ponte avisa uma vez no log, e a tela de
--  administração não mostra a seção.
--
--  DEPENDE DE JÁ TER RODADO
--    `usuarios`, `conversas` e `zorvin_admin()`. Num banco limpo (a prova
--    51l-bis, ou um cliente novo) ele desiste em silêncio.
-- ============================================================

do $copiloto$
declare
  v_nova boolean := to_regclass('public.zorvin_copiloto') is null;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DE TUDO — a lição do 006 e do 007:
  -- criada depois da guarda, o `select` da última linha estouraria num banco
  -- limpo.
  drop table if exists zorvin_conferencia_024;
  create temp table zorvin_conferencia_024 (item text, resposta text);

  -- A GUARDA PEDE AS CONVERSAS TAMBÉM, e não só `usuarios`: o 001 e o 002
  -- criam `usuarios` e `zorvin_admin()` até num banco sem o Zorvin (a prova
  -- 51l-bis), e um manual de copiloto num banco sem conversa não tem para
  -- quem sugerir nada. É a régua dos outros scripts ("sem as tabelas do
  -- Zorvin"), e foi a 51l-bis que a cobrou: o manual nascia ali preso a
  -- `usuarios`, e a cena que apaga `usuarios` parou de rodar.
  if to_regclass('public.usuarios') is null or to_regclass('public.conversas') is null
     or to_regprocedure('public.zorvin_admin()') is null then
    insert into zorvin_conferencia_024
      values ('sem as tabelas do Zorvin', 'o manual do copiloto não foi criado');
    raise notice 'Zorvin: sem as tabelas do Zorvin — o script 024 não criou o manual do copiloto.';
    return;
  end if;

  execute $x$
    create table if not exists public.zorvin_copiloto (
      id              boolean primary key default true check (id),
      instrucoes      text not null default '' check (length(instrucoes) <= 8000),
      atualizado_em   timestamptz not null default now(),
      atualizado_por  uuid references public.usuarios(id) on delete set null
    )
  $x$;
  execute $x$
    comment on table public.zorvin_copiloto is
      'O manual que o copiloto lê antes de sugerir uma resposta. Uma linha só '
      '(`check (id)`). Quem administra muda pela tela; a ponte lê a cada clique.'
  $x$;

  if v_nova then
    insert into public.zorvin_copiloto (id, instrucoes) values (true, $manual$QUEM SOMOS
Somos a equipe de atendimento de um escritório de advocacia. Pelo WhatsApp, respondemos clientes sobre o andamento dos processos, acordos, documentos e pagamentos.

COMO ESCREVEMOS
- Cordial e direto, como numa conversa de WhatsApp: frases curtas e sem juridiquês.
- Chamamos o cliente pelo primeiro nome.
- Cumprimentamos só na primeira mensagem do dia.
- No máximo um emoji, e só se o cliente usou.

QUANDO O CLIENTE MANDA DOCUMENTO, FOTO OU ÁUDIO
Confirmamos que recebemos. Se ainda for preciso conferir, dizemos que vamos verificar e retornar.

O QUE NÃO FAZEMOS
- Prometer resultado de processo, prazo de decisão, valor de acordo ou data de pagamento.
- Dar opinião jurídica nova. Se o cliente pedir, dizemos que vamos levar a pergunta ao advogado responsável e retornar.

QUANDO NÃO SABEMOS
Dizemos que vamos verificar e retornar, sem prometer um prazo que não temos.$manual$)
    on conflict (id) do nothing;
  end if;
  -- A LINHA EXISTE SEMPRE: sem ela, o "Salvar" da tela atualizaria zero
  -- linhas. Vazia, e não com o modelo — ver o cabeçalho.
  insert into public.zorvin_copiloto (id) values (true) on conflict (id) do nothing;

  -- QUEM MUDOU E QUANDO: do gatilho, nunca da tela.
  execute $x$
    create or replace function public.zorvin_copiloto_quem() returns trigger
      language plpgsql set search_path = public, auth as $f$
    begin
      new.atualizado_em := now();
      new.atualizado_por := auth.uid();
      return new;
    end
    $f$
  $x$;
  execute 'drop trigger if exists zorvin_copiloto_quem on public.zorvin_copiloto';
  execute 'create trigger zorvin_copiloto_quem before update on public.zorvin_copiloto
             for each row execute function public.zorvin_copiloto_quem()';

  execute 'alter table public.zorvin_copiloto enable row level security';
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'drop policy if exists zorvin_copiloto_leitura on public.zorvin_copiloto';
    execute 'create policy zorvin_copiloto_leitura on public.zorvin_copiloto
               for select to authenticated using (true)';
    -- ESCRITA SEPARADA DA LEITURA, e não `for all`: `for all` daria DELETE e
    -- INSERT junto (a régua do 003).
    execute 'drop policy if exists zorvin_copiloto_escrita on public.zorvin_copiloto';
    execute 'create policy zorvin_copiloto_escrita on public.zorvin_copiloto
               for update to authenticated
               using (public.zorvin_admin()) with check (public.zorvin_admin())';
    execute 'grant select, update on public.zorvin_copiloto to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant select on public.zorvin_copiloto to service_role';
  end if;

  insert into zorvin_conferencia_024
  select 'o manual do copiloto existe', (to_regclass('public.zorvin_copiloto') is not null)::text
  union all
  select 'caracteres no manual', coalesce((select length(instrucoes) from public.zorvin_copiloto), 0)::text;
end
$copiloto$;

-- ----------------------------------------------------------
--  A CONFERÊNCIA NO PAPEL DE QUEM ATENDE — a régua do 012: quem entrou lê o
--  manual sem "permission denied", e quem não administra não o muda. A
--  troca de papel volta atrás sozinha (o `true` do `set_config`), e a
--  tentativa de mudar é desfeita junto, porque vive dentro do bloco.
-- ----------------------------------------------------------
do $conf$
declare
  v_resposta text;
  v_mudou    int;
begin
  if to_regclass('public.zorvin_copiloto') is null
     or not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  begin
    perform set_config('request.jwt.claim.sub', '', true);
    perform set_config('role', 'authenticated', true);
    perform count(*) from public.zorvin_copiloto;
    v_resposta := 'true';
    update public.zorvin_copiloto set instrucoes = instrucoes where id;
    get diagnostics v_mudou = row_count;
    execute 'reset role';
    insert into zorvin_conferencia_024 values ('quem entrou lê o manual', v_resposta);
    insert into zorvin_conferencia_024 values ('só quem administra muda o manual',
      case when v_mudou = 0 then 'true' else 'NÃO — quem não administra conseguiu mudar o manual' end);
  exception when others then
    insert into zorvin_conferencia_024
      values ('quem entrou lê o manual', 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')');
  end;
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_024;
