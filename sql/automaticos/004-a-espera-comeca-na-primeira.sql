-- ============================================================
--  A ESPERA COMEÇA NA PRIMEIRA MENSAGEM SEM RESPOSTA
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O PEDIDO, 25/09
--
--  As atendentes do SAC dizem que a organização não fica clara. Elas trabalham
--  de baixo para cima na lista, que é ordenada pela ÚLTIMA mensagem — e é
--  isso que erra. O exemplo do Rodrigo, com hoje sendo 25/09:
--
--    Cliente A  escreveu 21/09, escreveu DE NOVO 24/09, sem resposta
--    Cliente B  escreveu 21/09, sem resposta
--    Cliente C  escreveu 24/09, sem resposta
--
--  Pela última mensagem, A e C são a mesma coisa: "24/09". Mas A está
--  esperando desde 21/09, quatro vezes mais que C. A equipe zera o dia
--  achando que atendeu todo mundo, e A continua lá — parecendo novo.
--
--  ------------------------------------------------------------
--  O QUE ESTA COLUNA GUARDA
--
--  `conversas.esperando_desde` = a PRIMEIRA mensagem do cliente depois da
--  nossa última resposta. Nulo quando ninguém está esperando.
--
--  É o 21/09 do Cliente A, e continua sendo depois de ele escrever em 24/09.
--  Escrever de novo não reinicia a espera de ninguém — e é exatamente por isso
--  que a coluna existe, em vez de a tela fazer a conta com `ultima_atividade`.
--
--  ------------------------------------------------------------
--  O QUE **NÃO** CONTA COMO RESPOSTA, e os dois casos foram conferidos
--
--  1. NOTA INTERNA. Ela mora na tabela `notas`, e não em `mensagens` — o
--     gatilho abaixo nunca a vê. O cliente também não: recado entre a equipe
--     não é resposta a ninguém.
--  2. MENSAGEM QUE NÃO SAIU. A ponte só grava a linha em `mensagens` DEPOIS
--     que o WhatsApp aceita (ver `salvarMensagem`, chamado após o envio). A
--     bolha vermelha vive em `fila_envio`, não aqui. Então uma resposta que
--     falhou não zera a espera — que é o certo: o cliente não recebeu nada.
--
--  ------------------------------------------------------------
--  E A IMPORTAÇÃO DE HISTÓRICO É O PASSADO CHEGANDO DEPOIS
--
--  MEDIDO em 25/09: `/importar-historico` grava o horário de QUANDO A MENSAGEM
--  FOI ENVIADA, não o de agora. Sem as duas perguntas que o gatilho faz lá
--  embaixo, uma conversa JÁ ATENDIDA que recebesse histórico de 2024 passava a
--  esperar desde 2024 — 630 dias — e ia para o TOPO da fila do SAC.
--
--  A ponte também chama `zorvin_recontar_espera(conversa)` no fim da
--  importação: o gatilho se defende dos dois enganos piores, mas a conta certa
--  depois de um lote inteiro é a que recalcula tudo do zero.
--
--  ------------------------------------------------------------
--  POR QUE TUDO ISTO MORA DENTRO DE UM BLOCO, E NÃO SOLTO
--
--  MEDIDO, e foi a prova 51l-bis que pegou: ela aplica esta pasta inteira num
--  banco LIMPO, e num banco limpo não existe `conversas` — as tabelas do
--  Zorvin estão nos 37 scripts de `sql/`, que descrevem a HISTÓRIA e não são
--  reaplicados. O script soltou `relation "public.conversas" does not exist` e
--  derrubou a rodada.
--
--  A saída fácil seria a prova criar `conversas` e `mensagens` para este
--  script rodar. Seria escrever uma SEGUNDA definição daquelas tabelas, à mão,
--  ao lado da que roda em produção — para as duas divergirem no primeiro
--  conserto. É a mesma razão pela qual a prova empresta `zorvin_admin()` em
--  vez de deixar o script 003 trazer a sua própria.
--
--  Então o script DESISTE EM SILÊNCIO quando as tabelas não existem, e isso
--  não é só para agradar a prova: é o comportamento certo num cliente novo,
--  cujo banco ainda não tem esquema nenhum. A ponte sobe, o script se marca
--  como aplicado, e no dia em que as tabelas existirem ele é rodado de novo à
--  mão — ele é seguro de repetir.
--
--  ------------------------------------------------------------
--  ENQUANTO ISTO NÃO FOR RODADO, NADA MUDA
--
--  O painel descobre sozinho que a coluna não existe (ela simplesmente não vem
--  nas linhas) e não oferece a ordem nova nem escreve a espera na lista.
-- ============================================================

do $espera$
begin
  -- AS DUAS TABELAS, e não só uma: a coluna é de `conversas` e o gatilho é de
  -- `mensagens`. Conferir uma só deixaria o script morrer na metade, com a
  -- coluna criada e sem nada para mantê-la — o pior dos estados, porque a tela
  -- passaria a oferecer uma fila que nunca se enche.
  if to_regclass('public.conversas') is null or to_regclass('public.mensagens') is null then
    raise notice 'Zorvin: banco sem `conversas`/`mensagens` — nada a fazer aqui.';
    return;
  end if;

  execute 'alter table public.conversas add column if not exists esperando_desde timestamptz';

  execute $x$
    comment on column public.conversas.esperando_desde is
      'Quando o cliente começou a esperar: a PRIMEIRA mensagem dele depois da nossa '
      'última resposta. Nulo = ninguém esperando. Mantida pelo gatilho zorvin_espera '
      'e recalculável por zorvin_recontar_espera().'
  $x$;

  -- O ÍNDICE É SÓ DE QUEM ESTÁ ESPERANDO, e é isso que o torna barato: a
  -- tabela tem dezenas de milhares de conversas e um punhado esperando. Um
  -- índice sobre tudo custaria escrita em toda mensagem para responder uma
  -- pergunta que só interessa sobre a fila.
  execute 'create index if not exists conversas_esperando
             on public.conversas (advogado_id, esperando_desde)
             where esperando_desde is not null';

  -- ------------------------------------------------------------
  --  A CONTA DE VERDADE, NUM LUGAR SÓ
  --
  --  O gatilho mais abaixo é incremental, porque é barato — mas incremental
  --  depende da ORDEM em que as mensagens entram. A importação de histórico
  --  insere um arquivo inteiro de uma vez, e a rodada de recuperação da caixa
  --  de entrada pode gravar uma mensagem atrasada depois de outra mais nova.
  --
  --  Esta função é a verdade, calculada do zero. Serve para encher a coluna
  --  agora e para consertar depois de uma importação.
  --
  --  Devolve quantas conversas MUDARAM — zero quer dizer "já estava tudo
  --  certo", que é diferente de "não fiz nada".
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
                   -- DEPOIS DA NOSSA ÚLTIMA RESPOSTA. Sem resposta nenhuma, o
                   -- `-infinity` faz valer a primeira mensagem que o cliente
                   -- mandou na vida — que é o certo: ele espera desde então.
                   and m.criado_em > coalesce(
                         (select max(m2.criado_em) from public.mensagens m2
                           where m2.conversa_id = c.id and m2.origem = 'advogado'),
                         '-infinity'::timestamptz)) as quando
          from public.conversas c
         where p_conversa is null or c.id = p_conversa
      )
      update public.conversas c
         set esperando_desde = certo.quando
        from certo
       where c.id = certo.id
         -- SÓ AS QUE MUDARAM. Reescrever a coluna com o mesmo valor em toda
         -- conversa acorda o tempo real do Supabase para nada, e um `update`
         -- em dezenas de milhares de linhas chega aos painéis abertos como uma
         -- enxurrada de avisos de mudança.
         and c.esperando_desde is distinct from certo.quando;
      get diagnostics n = row_count;
      return n;
    end
    $fn$
  $x$;

  -- ARMADILHA Nº 5: toda função nasce executável por `public`, que inclui quem
  -- não entrou. A régua do projeto é tirar de `public` E DEVOLVER a
  -- `authenticated` na mesma passada — o painel chama esta função depois de
  -- importar histórico.
  execute 'revoke all on function public.zorvin_recontar_espera(uuid) from public';
  -- O PAPEL PODE NÃO EXISTIR num Postgres que não é do Supabase (é o caso do
  -- banco limpo da prova). Sem esta conferência o script morreria aqui, depois
  -- de já ter criado a coluna.
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.zorvin_recontar_espera(uuid) to authenticated';
  end if;

  -- ------------------------------------------------------------
  --  O GATILHO — barato, e incapaz de derrubar a mensagem
  -- ------------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_marcar_espera()
    returns trigger
    language plpgsql
    as $fn$
    begin
      if new.origem = 'contato' then
        -- ESTA MENSAGEM JÁ FOI RESPONDIDA? Então ela não põe ninguém na fila.
        --
        -- MEDIDO em 25/09, com Postgres de verdade: sem esta pergunta, uma
        -- conversa RESPONDIDA que recebesse histórico importado de 2024
        -- passava a esperar desde 2024 — 630 dias —, e ia para o TOPO da fila
        -- do SAC. A fila existe justamente para dizer quem está mais
        -- abandonado, e o primeiro lugar dela seria um cliente já atendido.
        --
        -- A importação de histórico grava o horário de QUANDO A MENSAGEM FOI
        -- ENVIADA (ver `horarioDeQuemEnviou`, na ponte), e não o de agora.
        -- Ou seja: mensagem de cliente com data velha entrando hoje é o caso
        -- comum da importação, não uma raridade.
        --
        -- A pergunta é barata: `mensagens_conversa_tempo` e
        -- `mensagens_conversa_criado_idx` já indexam (conversa_id, criado_em),
        -- e dentro de UMA conversa são poucas linhas.
        if exists (select 1 from public.mensagens m
                    where m.conversa_id = new.conversa_id
                      and m.origem = 'advogado'
                      and m.criado_em >= new.criado_em) then
          return null;
        end if;

        -- `least`, e não "só se estiver vazio".
        --
        -- Escrever de novo NÃO reinicia a espera — é o Cliente A do pedido. E
        -- o `least` ainda acerta quando uma mensagem ANTIGA entra depois de
        -- uma nova SEM resposta no meio: a rodada de recuperação da caixa de
        -- entrada faz isso. Sem ele, a espera passaria a valer da mensagem
        -- errada, e para menos tempo do que o cliente esperou.
        update public.conversas
           set esperando_desde = least(coalesce(esperando_desde, new.criado_em), new.criado_em)
         where id = new.conversa_id;
      elsif new.origem = 'advogado' then
        -- SÓ 'advogado' LIMPA, e está escrito assim de propósito. Um `else`
        -- faria qualquer origem futura ('sistema', 'aviso automático') zerar a
        -- espera de um cliente que continua sem resposta.
        --
        -- E SÓ LIMPA UMA ESPERA MAIS VELHA DO QUE ELA. É o espelho da
        -- pergunta lá de cima: uma resposta NOSSA de 2024 chegando por
        -- importação não pode apagar a espera de um cliente que escreveu
        -- ontem. Aqui o erro seria o pior dos dois — a conversa sumiria da
        -- fila, em vez de aparecer errada nela.
        update public.conversas
           set esperando_desde = null
         where id = new.conversa_id
           and esperando_desde <= new.criado_em;
      end if;
      return null;
    exception when others then
      -- O CORPO INTEIRO DESISTE EM SILÊNCIO SE ALGO DER ERRADO, e isto não é
      -- excesso de cuidado: um gatilho que estoura aqui derruba o INSERT da
      -- mensagem, e a mensagem do cliente some. Perder a ordem da fila é um
      -- incômodo; perder a mensagem é o pior desfecho deste sistema.
      --
      -- É a mesma decisão do script 001, e pelo mesmo motivo.
      raise warning 'zorvin_espera: %', sqlerrm;
      return null;
    end
    $fn$
  $x$;

  execute 'drop trigger if exists zorvin_espera on public.mensagens';
  execute 'create trigger zorvin_espera
             after insert on public.mensagens
             for each row execute function public.zorvin_marcar_espera()';

  -- E ENCHE A COLUNA COM O QUE JÁ EXISTE. Sem isto a fila nasceria vazia e só
  -- iria se enchendo com as mensagens novas — ou seja, o cliente que está
  -- esperando desde 21/09, que é o motivo de tudo isto, não apareceria.
  execute 'select public.zorvin_recontar_espera()';
  raise notice 'Zorvin: coluna da espera criada e preenchida.';
end
$espera$;
