-- PAINEL COMPLETO — atendimentos, tempos, e cada um com os seus números.
--
-- Rodar no SQL Editor do Supabase. Idempotente: pode rodar de novo à vontade.
-- Não apaga nada; não reescreve nenhuma mensagem.
--
-- ==================================================================
--  O QUE É UM "ATENDIMENTO"
-- ==================================================================
--
-- O Zorvin não tem ticket, nem botão de "encerrar". Inventar uma tabela de
-- atendimentos resolveria o futuro e deixaria o passado em branco: o Painel
-- abriria com zero e só começaria a existir daqui para a frente.
--
-- Então o atendimento é DEDUZIDO das mensagens, que é o que já existe desde o
-- primeiro dia:
--
--   Um atendimento é um trecho de conversa. Ele COMEÇA na primeira mensagem
--   que chega depois de 6 HORAS de silêncio naquela conversa, e vai até a
--   última mensagem antes das próximas 6 horas de silêncio.
--
-- É a mesma ideia de "sessão" que o resto do mercado usa, e ela tem duas
-- qualidades que uma tabela nova não teria: vale para o histórico inteiro, e
-- não depende de ninguém lembrar de clicar em nada.
--
-- A JANELA É PARÂMETRO (`p_janela_horas`, 6 por padrão). Se um dia 6 horas se
-- mostrar curto ou longo demais para o escritório, muda-se o número aqui e
-- todos os relatórios, inclusive os do passado, passam a usar o novo corte.
--
-- Do atendimento saem os três tempos que a tela mostra:
--
--   INÍCIO         a primeira mensagem do trecho.
--   ATENDENTE      quem mandou a primeira resposta. É quem pegou o atendimento
--                  — não quem estava escalado, não quem abriu a tela: quem
--                  respondeu.
--   ESPERA         início → primeira resposta. Só existe quando foi o contato
--                  quem começou; quando fomos nós que procuramos o cliente,
--                  não há espera nenhuma para medir.
--   RESPOSTA       cada vez que o contato escreve e alguém responde, o tempo
--                  entre a primeira mensagem dele e a primeira nossa. Mensagens
--                  seguidas do contato contam como UMA pergunta: quem manda
--                  quatro mensagens seguidas está falando uma vez.
--
-- ==================================================================
--  MEDIANA, NÃO MÉDIA
-- ==================================================================
--
-- A tela mostra a MEDIANA como número principal, e a média ao lado, menor.
--
-- Não é preciosismo de estatística: um cliente que escreve às 22h e é
-- respondido às 8h da manhã seguinte põe 10 horas dentro da média, e a média de
-- um dia inteiro de respostas em 3 minutos vira "2 horas". Foi exatamente isso
-- que aconteceu no painel do sistema antigo, que anunciava "1666 horas" para
-- iniciar um atendimento — um número que não descreve nenhum atendimento que
-- tenha acontecido de verdade.
--
-- A mediana responde "como foi o atendimento típico". A média responde "quanto
-- tempo somou". As duas juntas mostram, pela distância entre elas, se houve
-- caso fora da curva. Por isso as duas aparecem.
--
-- ==================================================================
--  CADA UM VÊ O QUE É SEU
-- ==================================================================
--
-- `p_quem` recorta tudo para uma pessoa: os atendimentos que ELA pegou, as
-- mensagens que ELA enviou, e as recebidas nos atendimentos dela.
--
-- Quem não é administrador não escolhe: a função ignora o `p_quem` que vier e
-- usa o da própria sessão. Recorte que o navegador pode desligar não é
-- recorte — é sugestão.
--
-- A ÚNICA EXCEÇÃO É O RANKING DE ATENDENTES, que sai sempre com todo mundo. É
-- para isso que ele existe: comparação. Um ranking recortado só na própria
-- pessoa é uma linha, e uma linha não compara com nada.
--
-- E TUDO ISSO AINDA PASSA PELAS REGRAS DE ACESSO DO BANCO: a função é
-- `security invoker`, então cada pessoa só enxerga os telefones que ela já
-- alcança na lista de conversas. Não há como este painel mostrar um telefone
-- que a pessoa não pode abrir.

-- ------------------------------------------------------------------
--  0. OS ÍNDICES
-- ------------------------------------------------------------------
-- A conta percorre as mensagens de cada conversa EM ORDEM DE TEMPO, para achar
-- os silêncios de 6 horas. Sem este índice o banco ordena tudo a cada abertura
-- da tela.
create index if not exists mensagens_conversa_tempo on mensagens (conversa_id, criado_em);

-- Para achar a mensagem mais antiga da base sem varrer a base.
create index if not exists mensagens_criado_em on mensagens (criado_em);

-- PARA A REGRA "O MESMO RÓTULO É A MESMA PESSOA".
-- Ela é de propósito SEM corte de data — o vínculo entre um rótulo e uma pessoa
-- vale para sempre —, então ela varreria a tabela inteira toda vez. Este índice
-- parcial cobre exatamente as duas colunas e exatamente as linhas que ela olha
-- (as mensagens que já saem identificadas, de agosto/2026 em diante), e o banco
-- resolve tudo dentro dele, sem tocar na tabela.
create index if not exists mensagens_rotulo_identificado
  on mensagens (enviado_por, enviado_por_id)
  where origem = 'advogado' and enviado_por_id is not null;

-- ------------------------------------------------------------------
--  1. O DE-PARA (repetido aqui para este arquivo bastar sozinho)
-- ------------------------------------------------------------------
create table if not exists atendentes_de_para (
  nome_antigo text primary key,
  usuario_id  uuid,
  nome_novo   text,
  e_pessoa    boolean not null default true,
  criado_em   timestamptz default now()
);
alter table atendentes_de_para add column if not exists e_pessoa boolean not null default true;
alter table atendentes_de_para alter column nome_novo drop not null;
alter table atendentes_de_para enable row level security;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'drop policy if exists de_para_leitura on atendentes_de_para';
    execute 'create policy de_para_leitura on atendentes_de_para for select to authenticated using (true)';
  end if;
end;
$$;

-- ------------------------------------------------------------------
--  2. QUEM ENVIOU CADA MENSAGEM — uma definição só, em um lugar só
-- ------------------------------------------------------------------
--
-- Esta lógica já existia dentro de `painel_numeros`. Agora que DUAS funções
-- precisam dela, ela vira uma view: duas cópias da mesma regra sutil é como se
-- conserta um relatório e o outro continua errado.
--
-- A ORDEM É A ORDEM DA EVIDÊNCIA, da mais forte para a mais fraca:
--
--   1. o id gravado na própria mensagem (desde agosto/2026, sempre existe);
--   2. o id já visto em OUTRA mensagem com o mesmo rótulo — se alguma mensagem
--      assinada "Max Canaverde" traz id, todas as assinadas assim são dele;
--   3. o mesmo, pelo nome para o qual o de-para aponta;
--   4. o `usuario_id` escrito à mão no de-para;
--   5. o casamento do nome com um cadastro, quando só existe um com aquele nome.
--
-- O passo 2 vem ANTES do de-para de propósito: o `usuario_id` do de-para
-- costuma ser preenchido casando nome com cadastro, e quando há DOIS cadastros
-- de mesmo nome esse casamento escolhe um dos dois sem critério — foi o que fez
-- "Max Canaverde" aparecer duas vezes no ranking.
--
-- `security_invoker` para as regras de acesso continuarem valendo: sem isso a
-- view leria as mensagens com os olhos de quem a criou, e todo mundo veria
-- todos os telefones.
drop view if exists painel_mensagens;
create view painel_mensagens
with (security_invoker = true) as
with pessoa_por_nome as (
  -- `array_agg(...)[1]` e não `min`: o Postgres não compara uuid com `min`.
  -- Como o `having` garante uma linha só, qualquer uma serve.
  select lower(btrim(nome)) as chave, (array_agg(id))[1] as id
  from usuarios
  where coalesce(btrim(nome), '') <> ''
  group by 1
  having count(*) = 1
),
id_pelo_rotulo as (
  -- Sem corte por data de propósito: o vínculo entre rótulo e pessoa vale para
  -- sempre, e não só para o período que está na tela.
  select lower(btrim(enviado_por)) as chave, (array_agg(enviado_por_id))[1] as id
  from mensagens
  where origem = 'advogado'
    and enviado_por_id is not null
    and coalesce(btrim(enviado_por), '') <> ''
  group by 1
  having count(distinct enviado_por_id) = 1
)
select
  m.id,
  m.conversa_id,
  c.advogado_id,
  m.criado_em,
  m.origem,
  coalesce(nullif(btrim(m.enviado_por), ''), '(sem nome)') as rotulo,
  coalesce(m.enviado_por_id, ir.id, irn.id, dp.usuario_id, pn.id) as quem_id,
  coalesce(nullif(btrim(dp.nome_novo), ''), nullif(btrim(m.enviado_por), '')) as quem_nome,
  -- "WhatsApp" é o rótulo que a ponte grava quando a mensagem saiu pelo
  -- aparelho, fora do Zorvin. Não depende do de-para: é sempre aparelho.
  (coalesce(nullif(btrim(m.enviado_por), ''), '(sem nome)') = 'WhatsApp') as e_aparelho,
  -- Marcado como "não é pessoa" no de-para (nome de linha vindo do importador
  -- de histórico). Só vale quando a mensagem não traz id: se traz, alguém de
  -- verdade a enviou pelo Zorvin e o rótulo antigo não manda mais nada.
  (dp.e_pessoa is not null and dp.e_pessoa = false and m.enviado_por_id is null) as e_rotulo
from mensagens m
join conversas c on c.id = m.conversa_id
left join atendentes_de_para dp
  on lower(btrim(dp.nome_antigo)) = lower(coalesce(nullif(btrim(m.enviado_por), ''), '(sem nome)'))
left join id_pelo_rotulo ir
  on ir.chave = lower(coalesce(nullif(btrim(m.enviado_por), ''), '(sem nome)'))
left join id_pelo_rotulo irn
  on irn.chave = lower(btrim(dp.nome_novo))
left join pessoa_por_nome pn
  on pn.chave = lower(btrim(coalesce(nullif(btrim(dp.nome_novo), ''),
                                     coalesce(nullif(btrim(m.enviado_por), ''), '(sem nome)'))));

comment on view painel_mensagens is
  'Cada mensagem com quem a enviou já resolvido (id, nome, se é aparelho, se é rótulo).';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select on painel_mensagens to authenticated';
  end if;
end;
$$;

-- ------------------------------------------------------------------
--  3. O PAINEL
-- ------------------------------------------------------------------
--
-- Uma chamada devolve a tela inteira. Poderiam ser oito consultas, uma por
-- gráfico — e aí oito recortes teriam de concordar entre si sobre o que é o
-- período, o que é um atendimento e quem é cada pessoa. Concordam por
-- construção quando saem do mesmo `with`.
--
-- `p_fuso` é o fuso de quem está olhando, mandado pelo navegador. Sem ele o
-- banco corta o dia às 21h (o Supabase roda em UTC) e o mapa de horários sai
-- deslocado — um atendimento das 8h da manhã apareceria ao meio-dia.
-- Apaga qualquer versão anterior ANTES de criar. `create or replace` com outra
-- lista de argumentos não substitui: cria uma segunda função de mesmo nome, e
-- aí a chamada do navegador fica ambígua e o painel morre com
-- "could not choose the best candidate function".
do $$
declare r record;
begin
  for r in select oid::regprocedure as f from pg_proc where proname = 'painel_dashboard'
  loop execute 'drop function ' || r.f; end loop;
end;
$$;

create function painel_dashboard(
  p_desde        timestamptz default null,
  p_ate          timestamptz default null,
  p_quem         uuid        default null,
  p_fuso         text        default 'America/Campo_Grande',
  -- Em HORAS, e aceita fração: 0.5 é meia hora. Ver "o que é um atendimento",
  -- no alto do arquivo.
  p_janela_horas numeric     default 6
)
returns jsonb
language plpgsql
stable
as $$
declare
  v_desde   timestamptz;
  v_ate     timestamptz := coalesce(p_ate, now());
  v_janela  interval;
  v_fuso    text;
  v_quem    uuid := p_quem;
  v_notas   bigint := 0;
  v_primeira timestamptz;
  v_leitura timestamptz;   -- de onde as mensagens começam a ser lidas
  v_dias    numeric;
  v_passo   text;
  v_ant     timestamptz;   -- início do período ANTERIOR, do mesmo tamanho
  v_tem_antes boolean;     -- há histórico bastante para comparar?
  v_saida   jsonb;
begin
  -- QUEM NÃO É ADMINISTRADOR NÃO ESCOLHE. Aqui, e não no navegador: recorte que
  -- o navegador pode desligar não é recorte.
  if to_regprocedure('zorvin_admin()') is not null then
    if not zorvin_admin() then v_quem := auth.uid(); end if;
  end if;

  -- Em minutos por dentro: `make_interval(hours => ...)` só aceita inteiro, e
  -- meia hora tem de caber.
  v_janela := make_interval(mins => greatest(1, round(coalesce(p_janela_horas, 6) * 60))::int);

  -- Fuso inválido derrubaria a tela inteira com "time zone not recognized".
  -- Melhor cair no fuso da casa e mostrar os números.
  v_fuso := coalesce(p_fuso, 'America/Campo_Grande');
  if not exists (select 1 from pg_timezone_names where name = v_fuso) then
    v_fuso := 'America/Campo_Grande';
  end if;

  -- Direto de `mensagens`, e não da view: a view resolve quem enviou cada
  -- mensagem, e pedir a ela só a data mais antiga fazia esse trabalho todo
  -- para jogar fora. Com o índice em `criado_em`, isto é uma leitura só.
  select min(criado_em) into v_primeira from mensagens;
  v_desde := coalesce(p_desde, v_primeira, v_ate);
  if v_desde > v_ate then v_desde := v_ate; end if;
  v_ant := v_desde - (v_ate - v_desde);

  -- SEM PERÍODO ANTERIOR, NÃO SE LÊ O PERÍODO ANTERIOR. Não há com o que
  -- comparar quando o período começa antes da primeira mensagem da base, e ler
  -- para trás mesmo assim é dobrar o trabalho para devolver zero.
  --
  -- E há um teto: comparar UM ANO com o ano anterior obrigaria a ler dois anos
  -- de mensagens para pôr uma setinha num cartão. Acima de 92 dias a comparação
  -- não sai — e o que ela informaria, nesse tamanho, ninguém usa para decidir
  -- nada.
  -- O PASSO DO GRÁFICO DE PERÍODO. Em "Tudo", com dois anos de histórico, um
  -- ponto por dia dá 700 colunas de 1 pixel — que não é um gráfico, é uma
  -- textura. Passado o tamanho, o ponto vira semana e depois mês.
  v_dias := greatest(1, extract(epoch from (v_ate - v_desde)) / 86400.0);
  v_passo := case when v_dias <=  62 then 'day'
                  when v_dias <= 400 then 'week'
                  else 'month' end;

  v_tem_antes := p_desde is not null
             and v_dias <= 92
             and v_ant >= coalesce(v_primeira, v_ate);
  if not v_tem_antes then v_ant := v_desde; end if;

  -- ------------------------------------------------------------------
  --  ATÉ ONDE É PRECISO LER PARA TRÁS
  -- ------------------------------------------------------------------
  -- A primeira versão lia a tabela INTEIRA a cada abertura da tela, com a
  -- justificativa de que os silêncios de 6 horas só aparecem olhando a conversa
  -- inteira. A justificativa estava errada, e o preço foi a tela morrendo com
  -- "canceling statement due to statement timeout": a API do Supabase corta a
  -- consulta em 8 segundos.
  --
  -- Basta ler a partir de UMA JANELA antes do começo do período, e o motivo é
  -- exato, não aproximado:
  --
  --   Se a primeira mensagem de uma conversa dentro da leitura está em t, e
  --   t >= o começo do período, então não houve mensagem nenhuma entre
  --   (começo - janela) e t. O silêncio antes de t é, portanto, de pelo menos
  --   uma janela — e t abre um atendimento DE VERDADE, não por falta de
  --   informação.
  --
  --   E se a primeira mensagem lida está ANTES do começo do período, o
  --   atendimento que ela abre — certo ou partido ao meio — começa antes do
  --   período e sai da conta de qualquer forma, que é o que aconteceria com o
  --   atendimento verdadeiro também.
  --
  -- Vale a mesma coisa para o período anterior, por isso a leitura recua até
  -- ele. Em "Tudo" não há o que recortar: v_desde já é a primeira mensagem.
  v_leitura := least(v_desde, v_ant) - v_janela;


  -- As notas nunca saíram daqui: não são mensagem, e por isso ficam num número
  -- à parte em vez de engordar as enviadas.
  if to_regclass('public.notas') is not null then
    if exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'notas' and column_name = 'autor_id') then
      execute 'select count(*) from notas where criado_em >= $1 and criado_em <= $2 and ($3 is null or autor_id = $3)'
        into v_notas using v_desde, v_ate, v_quem;
    elsif v_quem is null then
      execute 'select count(*) from notas where criado_em >= $1 and criado_em <= $2'
        into v_notas using v_desde, v_ate;
    end if;
    -- Base antiga (sem `autor_id`) e recorte por pessoa: fica em zero. Chutar
    -- o total de todo mundo como se fosse o da pessoa seria pior.
  end if;

  with
  -- O corte é `v_leitura`, e não o começo do período: ver o raciocínio acima.
  base as (
    select conversa_id, advogado_id, criado_em, origem, rotulo, quem_id, quem_nome, e_aparelho, e_rotulo
    from painel_mensagens
    where origem in ('contato', 'advogado')
      and criado_em >= v_leitura
  ),
  -- As de origem desconhecida ficam fora de `base` (não são nem recebida nem
  -- enviada), e por isso são contadas à parte. Direto de `mensagens`: passá-las
  -- pela view seria resolver "quem enviou" para uma linha que nem entra em
  -- nenhuma das contas.
  outras_cte as (
    select count(*) as n from mensagens
    where origem not in ('contato', 'advogado')
      and criado_em >= v_desde and criado_em <= v_ate
  ),
  marcada as (
    select b.*,
           case when lag(criado_em) over w is null
                  or criado_em - lag(criado_em) over w > v_janela
                then 1 else 0 end as abre
    from base b
    window w as (partition by conversa_id order by criado_em)
  ),
  sessoes as (
    select m.*,
           sum(abre) over (partition by conversa_id order by criado_em
                           rows between unbounded preceding and current row) as sessao
    from marcada m
  ),
  -- O "bloco" separa cada pergunta da sua resposta. Ele só avança quando
  -- COMEÇA uma sequência de mensagens do contato — então quatro mensagens
  -- seguidas do cliente e as nossas respostas caem todas no mesmo bloco, e o
  -- tempo de resposta é medido da primeira dele até a primeira nossa.
  -- Em dois passos porque o Postgres não deixa uma janela dentro da outra
  -- (`sum(... lag(...) over ...) over ...` é erro de sintaxe, não de lógica).
  com_anterior as (
    select s.*,
           lag(origem) over (partition by conversa_id, sessao order by criado_em) as origem_anterior
    from sessoes s
  ),
  blocos as (
    select a.*,
           sum(case when origem = 'contato' and coalesce(origem_anterior, 'x') <> 'contato'
                    then 1 else 0 end)
             over (partition by conversa_id, sessao order by criado_em
                   rows between unbounded preceding and current row) as bloco
    from com_anterior a
  ),
  atend as (
    select
      conversa_id, sessao,
      min(criado_em) as inicio,
      max(criado_em) as fim,
      (array_agg(origem      order by criado_em))[1] as origem_inicio,
      (array_agg(advogado_id order by criado_em))[1] as advogado_id,
      min(criado_em) filter (where origem = 'advogado') as primeira_saida,
      -- QUEM PEGOU: quem mandou a primeira resposta de gente. Aparelho e rótulo
      -- de importação ficam de fora — nenhum dos dois atendeu ninguém.
      (array_agg(quem_id   order by criado_em)
         filter (where origem = 'advogado' and not e_aparelho and not e_rotulo and quem_id is not null))[1] as atendente_id,
      (array_agg(quem_nome order by criado_em)
         filter (where origem = 'advogado' and not e_aparelho and not e_rotulo and quem_nome is not null))[1] as atendente_nome,
      count(*) filter (where origem = 'contato')  as recebidas,
      count(*) filter (where origem = 'advogado') as enviadas
    from blocos
    group by 1, 2
  ),
  atend_marcado as (
    select a.*,
           case when origem_inicio = 'contato' and primeira_saida is not null
                then extract(epoch from primeira_saida - inicio) end as espera,
           (primeira_saida is null) as aguardando,
           (now() - fim) > v_janela as encerrado,
           timezone(v_fuso, inicio) as inicio_local
    from atend a
  ),
  -- O recorte por pessoa entra aqui, e não lá em cima: o atendimento existe
  -- inteiro, com todas as suas mensagens, e só depois se pergunta de quem ele é.
  meus as (
    select * from atend_marcado
    where inicio >= v_desde and inicio <= v_ate
      and (v_quem is null or atendente_id = v_quem)
  ),
  -- Mesmo período, mesmo tamanho, imediatamente antes: é o que dá sentido à
  -- setinha de "subiu 12%".
  anteriores as (
    select count(*) as atendimentos
    from atend_marcado
    where inicio >= v_ant and inicio < v_desde
      and (v_quem is null or atendente_id = v_quem)
  ),
  respostas as (
    select conversa_id, sessao, bloco,
           min(criado_em) filter (where origem = 'contato')  as chegou,
           min(criado_em) filter (where origem = 'advogado') as respondeu,
           (array_agg(quem_id order by criado_em)
              filter (where origem = 'advogado' and not e_aparelho and not e_rotulo))[1] as quem
    from blocos
    group by 1, 2, 3
  ),
  respostas_ok as (
    select r.*, extract(epoch from r.respondeu - r.chegou) as segundos
    from respostas r
    where r.chegou is not null and r.respondeu is not null
      and r.chegou >= v_desde and r.chegou <= v_ate
  ),
  minhas_respostas as (
    select * from respostas_ok where v_quem is null or quem = v_quem
  ),
  -- As mensagens do período, cada uma sabendo de qual atendimento faz parte —
  -- é o que permite dizer que uma RECEBIDA é "minha": ela chegou num
  -- atendimento que eu peguei.
  msg as (
    select b.*, a.atendente_id as dono
    from blocos b
    join atend a on a.conversa_id = b.conversa_id and a.sessao = b.sessao
    where b.criado_em >= v_desde and b.criado_em <= v_ate
  ),
  minhas_msg as (
    select * from msg
    where v_quem is null
       or (origem = 'advogado' and quem_id = v_quem)
       or (origem = 'contato'  and dono    = v_quem)
  ),
  msg_ant as (
    select b.*, a.atendente_id as dono
    from blocos b
    join atend a on a.conversa_id = b.conversa_id and a.sessao = b.sessao
    where b.criado_em >= v_ant and b.criado_em < v_desde
      and (v_quem is null
           or (b.origem = 'advogado' and b.quem_id = v_quem)
           or (b.origem = 'contato'  and a.atendente_id = v_quem))
  ),
  -- ---- as séries ----
  eixo as (
    select generate_series(
             date_trunc(v_passo, timezone(v_fuso, v_desde)),
             date_trunc(v_passo, timezone(v_fuso, v_ate)),
             ('1 ' || v_passo)::interval) as quando
  ),
  atend_por_passo as (
    select date_trunc(v_passo, inicio_local) as quando, count(*) as n
    from meus group by 1
  ),
  msg_por_passo as (
    select date_trunc(v_passo, timezone(v_fuso, criado_em)) as quando,
           count(*) filter (where origem = 'advogado') as enviadas,
           count(*) filter (where origem = 'contato')  as recebidas
    from minhas_msg group by 1
  ),
  resp_por_passo as (
    select date_trunc(v_passo, timezone(v_fuso, chegou)) as quando,
           percentile_cont(0.5) within group (order by segundos) as resposta
    from minhas_respostas group by 1
  ),
  espera_por_passo as (
    select date_trunc(v_passo, inicio_local) as quando,
           percentile_cont(0.5) within group (order by espera) as espera
    from meus where espera is not null group by 1
  ),
  serie as (
    select to_char(e.quando, 'YYYY-MM-DD') as quando,
           coalesce(a.n, 0)          as atendimentos,
           coalesce(m.enviadas, 0)   as enviadas,
           coalesce(m.recebidas, 0)  as recebidas,
           -- Tempo fica NULO no dia sem resposta nenhuma, e não zero: zero
           -- seria "respondemos na hora", que é o contrário de "não houve".
           rp.resposta,
           ep.espera
    from eixo e
    left join atend_por_passo  a on a.quando  = e.quando
    left join msg_por_passo    m on m.quando  = e.quando
    left join resp_por_passo   rp on rp.quando = e.quando
    left join espera_por_passo ep on ep.quando = e.quando
    order by e.quando
  ),
  -- O mapa de horários: dia da semana × hora. Zero é resposta — a hora vazia
  -- diz tanto quanto a cheia —, então o quadriculado inteiro sai do banco.
  grade as (
    select d as dia, h as hora
    from generate_series(0, 6) d, generate_series(0, 23) h
  ),
  hora_cheia as (
    select extract(dow  from inicio_local)::int as dia,
           extract(hour from inicio_local)::int as hora,
           count(*) as n
    from meus group by 1, 2
  ),
  mapa as (
    select g.dia, g.hora, coalesce(hc.n, 0) as atendimentos
    from grade g left join hora_cheia hc on hc.dia = g.dia and hc.hora = g.hora
    order by g.dia, g.hora
  ),
  tel_atend as (
    select advogado_id, count(*) as atendimentos from meus group by 1
  ),
  tel_msg as (
    select advogado_id,
           count(*) filter (where origem = 'contato')  as recebidas,
           count(*) filter (where origem = 'advogado') as enviadas
    from minhas_msg group by 1
  ),
  telefones as (
    select coalesce(a.advogado_id, m.advogado_id) as advogado_id,
           coalesce(a.atendimentos, 0) as atendimentos,
           coalesce(m.recebidas, 0)    as recebidas,
           coalesce(m.enviadas, 0)     as enviadas
    from tel_atend a full join tel_msg m on m.advogado_id = a.advogado_id
  ),
  -- ---- o ranking: SEMPRE com todo mundo, é para isso que ele serve ----
  todos_atend as (
    select * from atend_marcado where inicio >= v_desde and inicio <= v_ate
  ),
  ranking_atend as (
    select case when atendente_id is not null then 'id:' || atendente_id::text
                else 'nome:' || coalesce(atendente_nome, '(sem nome)') end as chave,
           (array_agg(atendente_id   order by inicio desc))[1] as id,
           (array_agg(coalesce(atendente_nome, '(sem nome)') order by inicio desc))[1] as nome,
           count(*) as atendimentos,
           percentile_cont(0.5) within group (order by espera) as espera_mediana
    from todos_atend
    where atendente_id is not null or atendente_nome is not null
    group by 1
  ),
  ranking_msg as (
    select case when quem_id is not null then 'id:' || quem_id::text
                else 'nome:' || coalesce(quem_nome, '(sem nome)') end as chave,
           count(*) as enviadas
    from msg
    where origem = 'advogado' and not e_aparelho and not e_rotulo
    group by 1
  ),
  ranking_resp as (
    select 'id:' || quem::text as chave,
           percentile_cont(0.5) within group (order by segundos) as resposta_mediana
    from respostas_ok where quem is not null group by 1
  ),
  ranking as (
    select coalesce(a.chave, m.chave) as chave,
           a.id, a.nome,
           coalesce(a.atendimentos, 0) as atendimentos,
           coalesce(m.enviadas, 0)     as enviadas,
           a.espera_mediana,
           r.resposta_mediana
    from ranking_atend a
    full join ranking_msg m on m.chave = a.chave
    left join ranking_resp r on r.chave = coalesce(a.chave, m.chave)
  ),
  -- O que foi TIRADO da lista de gente, discriminado. Sair do ranking não é a
  -- mesma coisa que sumir.
  rotulos as (
    select rotulo as nome, count(*) as enviadas
    from msg where origem = 'advogado' and e_rotulo group by 1
  )
  select jsonb_build_object(
    'de',        to_char(v_desde, 'YYYY-MM-DD"T"HH24:MI:SSOF'),
    'ate',       to_char(v_ate,   'YYYY-MM-DD"T"HH24:MI:SSOF'),
    'fuso',      v_fuso,
    'passo',     v_passo,
    'janela_horas', extract(epoch from v_janela) / 3600,
    'so_meu',    (v_quem is not null),
    'quem',      v_quem,
    'total', jsonb_build_object(
      'atendimentos', (select count(*) from meus),
      -- OS TRÊS ESTADOS SÃO EXCLUDENTES, e têm de somar o total: são as três
      -- fatias da mesma barra na tela. "Encerrado" exige `not aguardando`
      -- porque sem isso o atendimento que ninguém respondeu e que já esfriou
      -- entrava nas DUAS contas — e a barra somava mais do que o total.
      --
      -- E ele fica em "aguardando", não em "encerrado": o cliente escreveu e
      -- não teve resposta nenhuma. Ter esfriado não o resolve; só o piora.
      'aguardando',   (select count(*) from meus where aguardando),
      'em_andamento', (select count(*) from meus where not aguardando and not encerrado),
      'encerrados',   (select count(*) from meus where not aguardando and encerrado),
      'enviadas',     (select count(*) from minhas_msg where origem = 'advogado'),
      'recebidas',    (select count(*) from minhas_msg where origem = 'contato'),
      'notas',        v_notas,
      'respostas',        (select count(*) from minhas_respostas),
      'resposta_mediana', (select percentile_cont(0.5) within group (order by segundos) from minhas_respostas),
      'resposta_media',   (select avg(segundos) from minhas_respostas),
      'esperas',        (select count(*) from meus where espera is not null),
      'espera_mediana', (select percentile_cont(0.5) within group (order by espera) from meus where espera is not null),
      'espera_media',   (select avg(espera) from meus where espera is not null),
      -- Atendimentos que ninguém respondeu pelo Zorvin: ou ainda estão em pé, ou
      -- foram atendidos pelo aparelho. Sem dono, ficam fora do recorte de cada
      -- pessoa — e por isso a tela precisa dizer quantos são.
      'sem_atendente', (select count(*) from todos_atend where atendente_id is null and atendente_nome is null)
    ),
    'antes', jsonb_build_object(
      'atendimentos', (select atendimentos from anteriores),
      'enviadas',     (select count(*) from msg_ant where origem = 'advogado'),
      'recebidas',    (select count(*) from msg_ant where origem = 'contato'),
      'existe',       v_tem_antes
    ),
    'por_periodo',   coalesce((select jsonb_agg(to_jsonb(s)) from serie s), '[]'::jsonb),
    'por_hora',      coalesce((select jsonb_agg(to_jsonb(m)) from mapa m), '[]'::jsonb),
    'por_telefone',  coalesce((select jsonb_agg(to_jsonb(t)) from telefones t), '[]'::jsonb),
    'por_atendente', coalesce((select jsonb_agg(to_jsonb(r)) from ranking r), '[]'::jsonb),
    'por_rotulo',    coalesce((select jsonb_agg(to_jsonb(x)) from rotulos x), '[]'::jsonb),
    'aparelho',      (select count(*) from msg where origem = 'advogado' and e_aparelho),
    'sem_id',        (select count(*) from msg
                       where origem = 'advogado' and not e_aparelho and not e_rotulo and quem_id is null),
    'outras',        (select n from outras_cte)
  ) into v_saida;

  return v_saida;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function painel_dashboard(timestamptz, timestamptz, uuid, text, numeric) to authenticated';
  end if;
end;
$$;

-- ------------------------------------------------------------------
--  4. A FUNÇÃO ANTIGA, agora em cima da mesma view
-- ------------------------------------------------------------------
-- Ela continua existindo para o caso de o SQL ser rodado ANTES de a tela nova
-- subir — nessa janela de minutos, o Painel de hoje continua funcionando.
-- Passa a ler da view em vez de repetir a regra de "quem enviou": duas cópias
-- da mesma regra sutil é como se conserta um relatório e o outro continua
-- errado.
create or replace function painel_numeros(p_desde timestamptz default null)
returns jsonb
language plpgsql
stable
as $$
declare
  v_notas bigint := 0;
  v_saida jsonb;
begin
  if to_regclass('public.notas') is not null then
    execute 'select count(*) from notas where $1 is null or criado_em >= $1'
      into v_notas using p_desde;
  end if;

  with msg as (
    select * from painel_mensagens
    where p_desde is null or criado_em >= p_desde
  ),
  gente as (
    select case when quem_id is not null then 'id:' || quem_id::text
                else 'nome:' || coalesce(quem_nome, '(sem nome)') end as chave,
           (array_agg(quem_id order by criado_em desc))[1] as enviado_por_id,
           (array_agg(coalesce(quem_nome, '(sem nome)') order by criado_em desc))[1] as nome,
           count(*) as enviadas
    from msg
    where origem = 'advogado' and not e_aparelho and not e_rotulo
    group by 1
  ),
  rotulos as (
    select rotulo as nome, count(*) as enviadas
    from msg where origem = 'advogado' and e_rotulo group by 1
  ),
  tel as (
    select advogado_id,
           count(*) filter (where origem = 'contato')  as recebidas,
           count(*) filter (where origem = 'advogado') as enviadas
    from msg group by advogado_id
  )
  select jsonb_build_object(
    'recebidas', (select count(*) from msg where origem = 'contato'),
    'enviadas',  (select count(*) from msg where origem = 'advogado'),
    'outras',    (select count(*) from msg where origem not in ('contato', 'advogado')),
    'aparelho',  (select count(*) from msg where origem = 'advogado' and e_aparelho),
    'sem_id',    (select count(*) from msg
                   where origem = 'advogado' and not e_aparelho and not e_rotulo and quem_id is null),
    'notas',     v_notas,
    'por_telefone', coalesce((select jsonb_agg(to_jsonb(t)) from tel t), '[]'::jsonb),
    'por_pessoa',   coalesce((select jsonb_agg(to_jsonb(g)) from gente g), '[]'::jsonb),
    'por_rotulo',   coalesce((select jsonb_agg(to_jsonb(r)) from rotulos r), '[]'::jsonb)
  ) into v_saida;

  return v_saida;
end;
$$;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function painel_numeros(timestamptz) to authenticated';
  end if;
end;
$$;

-- ------------------------------------------------------------------
--  5. CONFERÊNCIA — rode e olhe
-- ------------------------------------------------------------------
--
--  -- Os atendimentos dos últimos 30 dias, do escritório inteiro:
--  select painel_dashboard((now() - interval '30 days'), now(), null, 'America/Campo_Grande')
--         -> 'total';
--
--  -- Os de uma pessoa (pegue o id em `select id, nome from usuarios order by nome`):
--  select painel_dashboard((now() - interval '30 days'), now(),
--                          '00000000-0000-0000-0000-000000000000'::uuid) -> 'total';
--
--  -- O ranking, para comparar com o que a tela mostra:
--  select jsonb_pretty(painel_dashboard(now() - interval '30 days') -> 'por_atendente');
