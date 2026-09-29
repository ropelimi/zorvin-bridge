-- ============================================================
--  A LINHA QUE VOLTOU NÃO FICA CAÍDA
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO CONSERTA
--
--  RELATO DE 29/09, com foto: a faixa vermelha dizia "A linha de SAC está
--  desconectada do WhatsApp. Nada sai por ela até alguém reconectar o
--  aparelho." — e o aparelho JÁ tinha sido reconectado e testado. A frase era
--  falsa na tela de quem atende, atrapalhando o trabalho.
--
--  O sinal `linhas_caidas` de `zorvin_saude()` deduzia "está caída" olhando só
--  para o PASSADO: mensagens que falharam com erro de desconexão nos últimos
--  30 minutos. Não havia pergunta nenhuma sobre o presente, então a única
--  saída do aviso era o relógio — meia hora de faixa vermelha depois de o
--  problema ter acabado.
--
--  O comentário do script original já dizia que essa era a troca escolhida.
--  A troca estava errada: alarme que não pede ação de quem lê é alarme que se
--  aprende a ignorar, e aí o próximo passa batido junto.
--
--  AGORA A LINHA SÓ CONTA COMO CAÍDA SE NÃO DEU SINAL DE VIDA depois do
--  último erro — uma mensagem que saiu, ou uma que chegou. A janela de 30
--  minutos continua sendo o teto.
--
--  NADA MAIS MUDA: os outros quatro sinais da função são os mesmos, letra por
--  letra. Isto é um `create or replace` da função inteira porque o Postgres
--  não sabe trocar meio corpo de função.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    sql/2026-09-o-painel-avisa-quando-algo-para.sql   (no repo do painel)
-- ============================================================

-- A GUARDA EXISTE POR CAUSA DA PROVA 51l-bis, que aplica esta pasta num banco
-- LIMPO. Sem as tabelas do Zorvin não há o que medir, e o certo é desistir em
-- silêncio — que também é o certo num cliente novo, cujo banco ainda não tem
-- esquema nenhum.
do $linha$
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA, e isso não é ordem à toa:
  -- criando-a só depois, o `select` da última linha ESTOURA num banco limpo,
  -- e um script que deveria desistir em silêncio derrubaria a prova 51l-bis.
  -- Foi o que aconteceu na primeira escrita deste arquivo.
  drop table if exists zorvin_conferencia_007;
  create temp table zorvin_conferencia_007 (item text, resposta text);

  if to_regclass('public.fila_envio') is null
     or to_regclass('public.conversas') is null
     or to_regclass('public.advogados') is null
     or to_regclass('public.mensagens') is null then
    insert into zorvin_conferencia_007
      values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas de conversas — script 007 não fez nada.';
    return;
  end if;

  execute $corpo$
create or replace function public.zorvin_saude()
returns table (sinal text, quantas integer, desde timestamptz, detalhe text)
language plpgsql
security definer
set search_path = public
as $zs$
begin
  -- ----------------------------------------------------------
  --  A FILA PAROU: mensagem que a equipe escreveu e não saiu.
  --
  --  Cinco minutos. O ciclo roda de 3 em 3 segundos, então qualquer coisa
  --  parada há cinco minutos não está "demorando" — está parada, e a ponte
  --  provavelmente não está no ar.
  --
  --  O ITEM QUE ESTÁ ESPERANDO A PRÓXIMA TENTATIVA NÃO CONTA. Ele tem hora
  --  marcada e está funcionando exatamente como projetado; contá-lo faria a
  --  retentativa automática acender um alarme a cada falha de rede — e alarme
  --  que toca à toa é alarme que se aprende a ignorar.
  -- ----------------------------------------------------------
  return query
  select 'fila_parada'::text, count(*)::int, min(f.criado_em), null::text
    from fila_envio f
   where f.status = 'pendente'
     and f.criado_em < now() - interval '5 minutes'
     and (f.tentar_em is null or f.tentar_em < now() - interval '1 minute')
  having count(*) > 0;

  -- ----------------------------------------------------------
  --  A FILA TRAVOU: item reivindicado e nunca concluído.
  --
  --  A própria ponte destrava isso depois de cinco minutos. Ver este sinal
  --  quer dizer que nem o destravamento está rodando — ou seja, a ponte está
  --  fora do ar, e é o mesmo diagnóstico do sinal de cima por outro caminho.
  -- ----------------------------------------------------------
  return query
  select 'fila_travada'::text, count(*)::int, min(f.enviando_em), null::text
    from fila_envio f
   where f.status = 'enviando'
     and f.enviando_em < now() - interval '6 minutes'
  having count(*) > 0;

  -- ----------------------------------------------------------
  --  A LINHA DO ESCRITÓRIO CAIU.
  --
  --  É o aviso mais acionável de todos, e o único que diz um nome: enquanto
  --  ninguém reconectar aquele aparelho, NADA sai por ele. Quem está atendendo
  --  por essa linha precisa saber antes de prometer resposta ao cliente.
  --
  --  Meia hora de janela: mais curto perderia a linha que caiu de madrugada,
  --  mais longo manteria o aviso na tela depois de o aparelho voltar.
  -- ----------------------------------------------------------
  --  E A LINHA QUE VOLTOU NÃO FICA CAÍDA (29/09).
  --
  --  O comentário acima já previa o problema e escolheu conviver com ele:
  --  "mais longo manteria o aviso na tela depois de o aparelho voltar". Em
  --  29/09 o Rodrigo reconectou a linha do SAC, mandou uma mensagem de teste
  --  que SAIU, e a faixa continuou lá dizendo que nada sai por ela.
  --
  --  A causa é de desenho: este sinal deduzia "está caída" do PASSADO, e a
  --  única saída era o relógio. Faltava a pergunta contrária — a linha deu
  --  algum sinal de vida DEPOIS do erro?
  --
  --  Duas provas de vida, e as duas são fatos do banco:
  --    - uma mensagem que SAIU por ela (`fila_envio.enviada`) — a ponte só
  --      marca assim depois de a Uazapi aceitar, e é exatamente o contrário
  --      do que a faixa afirma ("nada sai por ela");
  --    - uma mensagem que CHEGOU por ela — o webhook só dispara com o
  --      aparelho conectado.
  --
  --  A segunda é mais fraca (receber não é enviar) e entra assim mesmo, por
  --  duas razões: é a que aparece primeiro numa linha de SAC, e o erro dela
  --  se conserta sozinho — se a linha recebe mas não envia, o próximo envio
  --  falha, grava um erro NOVO, e o aviso volta. O que não se conserta
  --  sozinho é o alarme que fica de pé sem ter o que pedir a quem lê.
  --
  --  A JANELA DE 30 MINUTOS FICA. Ela é o teto; a prova de vida é a saída
  --  rápida. Tirá-la deixaria a linha que caiu de madrugada e não teve
  --  movimento nenhum sem aviso pela manhã.
  return query
  with erros as (
    select c.advogado_id, max(f.criado_em) as ultimo_erro
      from fila_envio f
      join conversas c on c.id = f.conversa_id
     where f.status = 'erro'
       and f.criado_em > now() - interval '30 minutes'
       and (coalesce(f.erro_motivo, '') || ' ' || coalesce(f.erro_detalhe, ''))
           ~* '(desconect|disconnected|not connected|reconectar)'
     group by c.advogado_id
  ),
  vivas as (
    -- SINAL DE VIDA 1: saiu alguma coisa por ela depois do erro.
    select e.advogado_id
      from erros e
     where exists (
       select 1
         from fila_envio f2
         join conversas c2 on c2.id = f2.conversa_id
        where c2.advogado_id = e.advogado_id
          and f2.status = 'enviada'
          and f2.enviado_em > e.ultimo_erro
     )
    union
    -- SINAL DE VIDA 2: chegou alguma coisa por ela depois do erro.
    select e.advogado_id
      from erros e
     where exists (
       select 1
         from mensagens m
         join conversas c3 on c3.id = m.conversa_id
        where c3.advogado_id = e.advogado_id
          and m.criado_em > e.ultimo_erro
     )
  )
  select 'linhas_caidas'::text,
         count(distinct a.id)::int,
         min(e.ultimo_erro),
         string_agg(distinct coalesce(a.nome, a.numero), ', ')
    from erros e
    join advogados a on a.id = e.advogado_id
   where e.advogado_id not in (select advogado_id from vivas)
  having count(*) > 0;

  -- ----------------------------------------------------------
  --  A CAIXA DE ENTRADA — só se ela existir.
  --
  --  `to_regclass` devolve nulo quando a tabela não foi criada. Sem esta
  --  conferência, um banco sem a caixa faria a função inteira dar erro, e o
  --  painel perderia TAMBÉM os três sinais de cima — trocando um aviso que
  --  falta por nenhum aviso.
  -- ----------------------------------------------------------
  if to_regclass('public.eventos_recebidos') is not null then
    -- MENSAGEM DE CLIENTE QUE NÃO ENTROU. O evento falhou cinco vezes e a ponte
    -- parou de tentar. É o sinal mais grave que existe aqui: alguém escreveu
    -- para o escritório e a conversa não mostra. Vai para a tela de todo mundo,
    -- porque muda o que quem atende deve acreditar sobre uma conversa calada.
    return query
    execute $q$
      select 'eventos_desistidos'::text, count(*)::int, min(recebido_em), null::text
        from eventos_recebidos
       where processado_em is null and tentativas >= 5
      having count(*) > 0
    $q$;

    -- A CAIXA ATRASADA. A rodada de recuperação passa de 30 em 30 segundos;
    -- dois minutos de atraso quer dizer que ela não está passando. Diferente do
    -- de cima, isto costuma se resolver sozinho — por isso é aviso de quem
    -- administra, e não da tela de quem atende.
    return query
    execute $q$
      select 'eventos_pendentes'::text, count(*)::int, min(recebido_em), null::text
        from eventos_recebidos
       where processado_em is null
         and tentativas < 5
         and recebido_em < now() - interval '2 minutes'
      having count(*) > 0
    $q$;
  end if;
end $zs$;
  $corpo$;

  execute 'revoke all on function public.zorvin_saude() from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_saude() from anon';
  end if;
  execute 'grant execute on function public.zorvin_saude() to authenticated';

  -- ----------------------------------------------------------
  --  A CONFERÊNCIA VAI DENTRO DO SCRIPT, e numa tabela temporária.
  --
  --  O editor do Supabase mostra só o resultado do ÚLTIMO comando, então a
  --  resposta de "deu certo?" tem de ser a última linha deste mesmo arquivo.
  --  E ela vive numa tabela temporária porque um `select` solto sobre
  --  `public.conversas` ESTOURA num banco limpo: o Postgres confere o nome da
  --  tabela ao PREPARAR a consulta, e um script que deveria desistir em
  --  silêncio derrubaria a prova 51l-bis.
  -- ----------------------------------------------------------
  insert into zorvin_conferencia_007
  select 'a função foi trocada'::text,
         (to_regprocedure('public.zorvin_saude()') is not null)::text
  union all
  select 'quem entrou pode chamá-la',
         has_function_privilege('authenticated', 'public.zorvin_saude()', 'EXECUTE')::text
  union all
  select 'quem NÃO entrou não pode',
         (not has_function_privilege('anon', 'public.zorvin_saude()', 'EXECUTE'))::text
  union all
  select 'linhas ainda apontadas como caídas',
         coalesce((select string_agg(s.detalhe, ', ')
                     from public.zorvin_saude() s
                    where s.sinal = 'linhas_caidas'), 'nenhuma — a faixa some');
end $linha$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_007;
