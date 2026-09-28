-- ============================================================
--  A ESPERA NÃO COMEÇA NO RABICHO DA CONVERSA JÁ ATENDIDA
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O RELATO, EM 28/09, COM FOTO DA TELA
--
--  A conversa da ANDREIA dizia "esperando há 6 dias". O que aconteceu nela:
--
--    22/09 13:36  NÓS    "Estamos trabalhando para que dê certo!"
--    22/09 13:37  ela    "Tomara a Deus"
--    22/09 13:37  ela    "Estou orando por isso 🙏"
--    28/09 14:40  ela    "Boa tarde"
--    28/09 14:41  ela    "Temos alguma movimentação"
--
--  Pela regra do script 004 — *a primeira mensagem do cliente depois da nossa
--  última resposta* — a espera começa às 13:37, **um minuto** depois de a
--  Isabela ter respondido. Tecnicamente é "depois da nossa resposta". Na
--  prática é o RABICHO de uma conversa que foi atendida: ela não estava
--  esperando nada entre 22 e 28. A espera de verdade começou HOJE, 14:40.
--
--  Reproduzido num Postgres de verdade antes de escrever este script: o
--  gatilho devolve 22/09 13:37, exatamente como o painel mostrou. **O defeito
--  não é do gatilho, é da definição** — e é a definição que este script troca.
--
--  ------------------------------------------------------------
--  A REGRA NOVA, EM UMA FRASE
--
--    A espera começa na primeira mensagem do cliente que chega MAIS DE
--    30 MINUTOS depois da nossa última ação (resposta ou "já tratei").
--
--  E tem um ENCOSTO, que é a metade que impede o estrago:
--
--    Se NENHUMA mensagem dela chegar depois desses 30 minutos, vale a regra
--    de antes — a conversa continua na fila, com a data de sempre.
--
--  Sem o encosto, a cliente que pergunta cinco minutos depois da nossa
--  resposta e nunca mais escreve **sumiria da fila para sempre**, em silêncio.
--  Esse é o pior desfecho deste sistema, e nenhuma melhora de ordenação vale
--  pagá-lo. Com o encosto, o pior caso desta mudança é uma conversa
--  continuar exatamente como está hoje.
--
--  ------------------------------------------------------------
--  POR QUE 30 MINUTOS, E NÃO AS 48 HORAS QUE FORAM SUGERIDAS
--
--  MEDIDO em 28/09, sobre as **832 conversas** que estavam na fila, testando
--  quatro janelas de uma vez:
--
--    janela   mudariam   ficam como hoje   dias a menos, em média
--    30 min       93           311                  4,6
--     2 h         96           405                  5,9
--    12 h         92           452                  6,6
--    48 h         74           497                  9,8
--
--  Duas coisas saltam dessa tabela, e as duas apontam para a janela curta:
--
--  1. **Quantas conversas mudam quase não depende da janela** (93, 96, 92,
--     74) — mas **quanto tempo de espera é apagado, sim** (4,6 → 9,8 dias).
--     Janela grande não conserta mais casos; ela apaga mais dias de cada
--     caso.
--
--  2. Os textos que seriam pulados, na amostra de 48 h, incluem
--     *"Porfavor avisa ao financeiro que minha c…"* e *"E agr qual o próximo
--     passo pois já fazem…"* — **pedidos de verdade**. Apagar nove dias e
--     meio da espera de quem perguntou isso é o erro que não se vê: a
--     conversa continua na lista, só que dizendo "1 dia" onde eram dez.
--
--  A régua desta casa decide o empate: **entre um erro que se vê e um que
--  não, escolhe-se o que se vê.** Janela curta demais deixa na fila uma
--  conversa já resolvida — ruído, visível, e com uma saída pronta ("Já
--  tratei"). Janela longa demais apaga a espera de um cliente esquecido —
--  silêncio, e sem nada na tela dizendo que aconteceu.
--
--  ------------------------------------------------------------
--  O NÚMERO MORA NUMA FUNÇÃO SÓ, E ISSO É DE PROPÓSITO
--
--  `zorvin_carencia_da_espera()`. Trocar 30 minutos por outro valor é UMA
--  linha (`create or replace`) mais `select zorvin_recontar_espera();` — sem
--  script novo, sem esperar publicação. Escrito assim porque este número é
--  um palpite calibrado por uma medição, e não uma lei da natureza: ver a
--  fila com ele por uma semana é o que diz se está certo.
--
--  Escrita nas DUAS contas a partir dessa função, e não copiada em cada uma:
--  duas cópias divergiriam no primeiro ajuste, e divergir aqui é a fila da
--  tela discordar da fila recontada, sobre a mesma conversa.
--
--  ------------------------------------------------------------
--  E O GATILHO PRECISOU DE UMA ESPERA "PROVISÓRIA"
--
--  Esta é a parte que não é óbvia, e sem ela a mudança não funcionaria na
--  vida real — só na recontagem.
--
--  O gatilho é incremental: ele vê UMA mensagem por vez, e não sabe o futuro.
--  Quando o "Tomara a Deus" das 13:37 chega, ainda não existe o "Boa tarde"
--  de seis dias depois. Pelo encosto ele TEM de entrar na fila (é a única
--  mensagem que existe). Aí, quando o "Boa tarde" chega, a regra antiga
--  (`least`, que guarda sempre a mais antiga) manteria as 13:37 — e a tela
--  continuaria dizendo 6 dias.
--
--  Então a espera nascida DENTRO da carência é **provisória**, e a primeira
--  mensagem que chega FORA dela a substitui. Uma espera nascida fora da
--  carência é definitiva, e aí vale o `least` de sempre: escrever de novo
--  não reinicia a conta de ninguém, que é o contrato do script 004.
--
--  Como se sabe qual é qual, sem coluna nova: uma espera provisória é a que
--  cabe dentro de `nossa última ação + carência`. A conta está no lugar em
--  que a resposta mora, e não guardada num campo que poderia envelhecer.
--
--  ------------------------------------------------------------
--  O QUE ESTE SCRIPT **NÃO** MUDA
--
--  - a conversa que nunca respondemos (214 delas): sem "nossa última ação",
--    não há carência nenhuma e a primeira mensagem da vida dela vale, como
--    hoje;
--  - "escrever de novo não reinicia a espera": continua valendo, para toda
--    espera definitiva;
--  - a importação de histórico: o gatilho segue se defendendo dos dois
--    enganos do script 004, e `/importar-historico` segue recontando o lote.
-- ============================================================

do $rabicho$
begin
  -- ------------------------------------------------------------
  --  A CONFERÊNCIA É MONTADA AQUI DENTRO, e sai na última linha do arquivo.
  --
  --  Um `select count(*) from public.conversas` solto no fim NÃO serve: num
  --  banco limpo ele estoura antes de rodar, porque o Postgres confere o nome
  --  da tabela ao PREPARAR a consulta — e aí um script que deveria desistir
  --  em silêncio derruba a instalação inteira. Medido aqui, e é o que a prova
  --  51l-bis pegaria.
  --
  --  Guardando numa tabela temporária, o arquivo continua sendo UM só: o que
  --  o Rodrigo cola no Supabase é byte por byte o que está no repositório.
  --  Mandar o script numa mensagem e a conferência em outra custou dez idas e
  --  voltas em 26/09 — ver o CLAUDE.md.
  -- ------------------------------------------------------------
  drop table if exists zorvin_conferencia_006;
  create temp table zorvin_conferencia_006 (
    conversas_na_fila          bigint,
    em_vermelho_3_dias_ou_mais bigint,
    carencia_em_uso            interval,
    a_conta_nova_esta_no_ar    boolean
  );

  -- A GUARDA DE SEMPRE. A prova 51l-bis aplica esta pasta num banco LIMPO,
  -- onde `conversas` não existe — e num cliente novo também não existe.
  if to_regclass('public.conversas') is null
     or to_regclass('public.mensagens') is null then
    insert into zorvin_conferencia_006 values (null, null, null, false);
    raise notice 'Zorvin: sem as tabelas de conversas — script 006 não fez nada.';
    return;
  end if;

  -- ------------------------------------------------------------
  --  A CARÊNCIA, NUM LUGAR SÓ
  -- ------------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_carencia_da_espera()
    returns interval
    language sql
    immutable
    as $fn$ select interval '30 minutes' $fn$
  $x$;

  execute $x$
    comment on function public.zorvin_carencia_da_espera() is
      'Quanto tempo depois da nossa última ação uma mensagem do cliente ainda '
      'conta como rabicho da conversa atendida, em vez de começar uma espera. '
      'Trocar o número aqui e rodar select zorvin_recontar_espera(); basta — '
      'as duas contas da espera leem daqui.'
  $x$;

  -- A RÉGUA DA ARMADILHA Nº 5: tirar de `public` E DEVOLVER a
  -- `authenticated` na mesma passada. Toda função nasce executável por
  -- `public`, que inclui `anon` — e esta é chamada DE DENTRO das duas contas
  -- da espera, então tirá-la sem devolver quebraria a fila do escritório
  -- inteiro com `permission denied`.
  execute 'revoke all on function public.zorvin_carencia_da_espera() from public';
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.zorvin_carencia_da_espera() to authenticated';
  end if;

  -- ------------------------------------------------------------
  --  A CONTA FEITA DO ZERO
  --
  --  O `coalesce` entre as duas consultas É o encosto: a de cima procura a
  --  primeira mensagem FORA da carência; a de baixo, a primeira depois da
  --  nossa ação, que é a regra do script 004. Nulo na de cima quer dizer
  --  "não houve nenhuma fora da carência", e aí vale a de baixo.
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
               coalesce(
                 (select min(m.criado_em)
                    from public.mensagens m
                   where m.conversa_id = c.id
                     and m.origem = 'contato'
                     and m.criado_em > coalesce(nossa.quando, '-infinity'::timestamptz)
                     and (nossa.quando is null
                          or m.criado_em > nossa.quando
                                           + public.zorvin_carencia_da_espera())),
                 (select min(m.criado_em)
                    from public.mensagens m
                   where m.conversa_id = c.id
                     and m.origem = 'contato'
                     and m.criado_em > coalesce(nossa.quando, '-infinity'::timestamptz))
               ) as quando
          from public.conversas c
          cross join lateral (
            select greatest(
                     (select max(m2.criado_em) from public.mensagens m2
                       where m2.conversa_id = c.id and m2.origem = 'advogado'),
                     c.tratada_em) as quando
          ) nossa
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

  -- ------------------------------------------------------------
  --  O GATILHO INCREMENTAL
  -- ------------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_marcar_espera()
    returns trigger
    language plpgsql
    as $fn$
    declare
      nossa     timestamptz;
      carencia  interval := public.zorvin_carencia_da_espera();
    begin
      if new.origem = 'contato' then
        -- JÁ RESPONDIDA **OU JÁ TRATADA** depois desta mensagem? Não põe
        -- ninguém na fila. (Vem do script 005; vale para a caixa de entrada
        -- que recupera um evento atrasado, e para a importação de histórico.)
        if exists (select 1 from public.mensagens m
                    where m.conversa_id = new.conversa_id
                      and m.origem = 'advogado'
                      and m.criado_em >= new.criado_em)
           or exists (select 1 from public.conversas c
                       where c.id = new.conversa_id
                         and c.tratada_em >= new.criado_em) then
          return null;
        end if;

        select greatest(
                 (select max(m.criado_em) from public.mensagens m
                   where m.conversa_id = new.conversa_id
                     and m.origem = 'advogado'),
                 c.tratada_em)
          into nossa
          from public.conversas c
         where c.id = new.conversa_id;

        if nossa is null or new.criado_em > nossa + carencia then
          -- MENSAGEM DE VERDADE: começa a espera, e SUBSTITUI uma provisória.
          --
          -- A provisória é a que nasceu dentro da carência (ver o cabeçalho).
          -- Sem esta troca, o `least` guardaria o "Tomara a Deus" e a tela
          -- continuaria dizendo seis dias — o defeito inteiro deste script.
          update public.conversas
             set esperando_desde = case
                   when esperando_desde is null then new.criado_em
                   when nossa is not null
                        and esperando_desde <= nossa + carencia then new.criado_em
                   else least(esperando_desde, new.criado_em)
                 end
           where id = new.conversa_id;
        else
          -- DENTRO DA CARÊNCIA: é o encosto. Ela entra na fila só se não
          -- houver nada lá — uma espera que já existe não é rebaixada por
          -- uma mensagem que chegou colada na nossa resposta.
          update public.conversas
             set esperando_desde = coalesce(esperando_desde, new.criado_em)
           where id = new.conversa_id;
        end if;

      elsif new.origem = 'advogado' then
        -- E RESPONDER LIMPA O TRATAMENTO JUNTO (script 005, sem mudança).
        update public.conversas
           set esperando_desde = null,
               tratada_em = null
         where id = new.conversa_id
           and coalesce(esperando_desde, tratada_em) <= new.criado_em;
      end if;
      return null;
    exception when others then
      -- O CORPO INTEIRO NUM `exception`, como nos scripts 001 e 004: um
      -- gatilho que estoura derruba o INSERT da mensagem, e perder a
      -- mensagem do cliente é o pior desfecho deste sistema.
      raise warning 'zorvin_espera: %', sqlerrm;
      return null;
    end
    $fn$
  $x$;

  -- ------------------------------------------------------------
  --  E A FILA INTEIRA É RECONTADA AGORA
  --
  --  Sem isto, a regra nova valeria só para o que chegasse daqui para a
  --  frente, e as 832 conversas que estão na fila hoje continuariam com a
  --  data velha — a tela seguiria dizendo "6 dias" na conversa que motivou
  --  o script.
  -- ------------------------------------------------------------
  perform public.zorvin_recontar_espera();

  insert into zorvin_conferencia_006
  select (select count(*) from public.conversas where esperando_desde is not null),
         (select count(*) from public.conversas
           where esperando_desde is not null
             and esperando_desde < now() - interval '3 days'),
         public.zorvin_carencia_da_espera(),
         to_regprocedure('public.zorvin_carencia_da_espera()') is not null
           and to_regprocedure('public.zorvin_recontar_espera(uuid)') is not null
           and to_regprocedure('public.zorvin_marcar_espera()') is not null;

  raise notice 'Zorvin: a espera passou a ignorar o rabicho da conversa atendida.';
end
$rabicho$;

-- ============================================================
--  A CONFERÊNCIA — é a ÚLTIMA linha, e é o que aparece ao apertar Run.
-- ============================================================
select * from zorvin_conferencia_006;
