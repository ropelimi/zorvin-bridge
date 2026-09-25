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
--  ENQUANTO ISTO NÃO FOR RODADO, NADA MUDA
--
--  O painel descobre sozinho que a coluna não existe (ela simplesmente não vem
--  nas linhas) e não oferece a ordem nova nem escreve a espera na lista. Tudo
--  se comporta como antes.
-- ============================================================

alter table public.conversas
  add column if not exists esperando_desde timestamptz;

comment on column public.conversas.esperando_desde is
  'Quando o cliente começou a esperar: a PRIMEIRA mensagem dele depois da '
  'nossa última resposta. Nulo = ninguém esperando. Mantida pelo gatilho '
  'zorvin_espera e recalculável por zorvin_recontar_espera().';

-- O ÍNDICE É SÓ DE QUEM ESTÁ ESPERANDO, e é isso que o torna barato: a tabela
-- tem dezenas de milhares de conversas e um punhado esperando. Um índice sobre
-- tudo custaria escrita em toda mensagem para responder uma pergunta que só
-- interessa sobre a fila.
create index if not exists conversas_esperando
  on public.conversas (advogado_id, esperando_desde)
  where esperando_desde is not null;

-- ============================================================
--  A CONTA DE VERDADE, NUM LUGAR SÓ
--
--  O gatilho abaixo é incremental, porque é barato — mas incremental depende
--  da ORDEM em que as mensagens entram. A importação de histórico insere um
--  arquivo inteiro de uma vez, e uma rodada de recuperação da caixa de entrada
--  pode gravar uma mensagem atrasada depois de outra mais nova.
--
--  Esta função é a verdade, calculada do zero a partir das mensagens. Serve
--  para encher a coluna agora e para consertar depois de uma importação, sem
--  ninguém precisar entender o gatilho.
--
--  Devolve quantas conversas mudaram — zero quer dizer "já estava tudo certo",
--  que é diferente de "não fiz nada".
-- ============================================================
create or replace function public.zorvin_recontar_espera(p_conversa uuid default null)
returns integer
language plpgsql
as $$
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
     -- conversa acorda o tempo real do Supabase para nada, e um `update` em
     -- dezenas de milhares de linhas chega aos painéis abertos como uma
     -- enxurrada de avisos de mudança.
     and c.esperando_desde is distinct from certo.quando;
  get diagnostics n = row_count;
  return n;
end $$;

-- ARMADILHA Nº 5: toda função nasce executável por `public`, que inclui quem
-- não entrou. A régua do projeto é tirar de `public` E DEVOLVER a
-- `authenticated` na mesma passada — o painel chama esta função depois de
-- importar histórico.
revoke all on function public.zorvin_recontar_espera(uuid) from public;
grant execute on function public.zorvin_recontar_espera(uuid) to authenticated;

-- ============================================================
--  O GATILHO — barato, e incapaz de derrubar a mensagem
-- ============================================================
create or replace function public.zorvin_marcar_espera()
returns trigger
language plpgsql
as $$
begin
  if new.origem = 'contato' then
    -- `least`, e não "só se estiver vazio".
    --
    -- Escrever de novo NÃO reinicia a espera — é o Cliente A do pedido. E o
    -- `least` ainda acerta quando uma mensagem ANTIGA entra depois de uma
    -- nova: a importação de histórico e a rodada de recuperação da caixa de
    -- entrada fazem isso. Sem ele, a espera passaria a valer da mensagem
    -- errada, e para menos tempo do que o cliente esperou de verdade.
    update public.conversas
       set esperando_desde = least(coalesce(esperando_desde, new.criado_em), new.criado_em)
     where id = new.conversa_id;
  elsif new.origem = 'advogado' then
    -- SÓ 'advogado' LIMPA, e está escrito assim de propósito. Um `else` faria
    -- qualquer origem futura ('sistema', 'aviso automático') zerar a espera de
    -- um cliente que continua sem resposta.
    update public.conversas
       set esperando_desde = null
     where id = new.conversa_id;
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
end $$;

drop trigger if exists zorvin_espera on public.mensagens;
create trigger zorvin_espera
  after insert on public.mensagens
  for each row execute function public.zorvin_marcar_espera();

-- ============================================================
--  E ENCHE A COLUNA COM O QUE JÁ EXISTE
--
--  Sem isto, a fila nasceria vazia e só iria se enchendo com as mensagens
--  novas — ou seja, o cliente que está esperando desde 21/09, que é o motivo
--  de tudo isto existir, não apareceria.
-- ============================================================
select public.zorvin_recontar_espera() as conversas_ajustadas;
