-- ============================================================
--  A BUSCA PASSA A DIZER *QUAL* MENSAGEM CASOU
--
--  Hoje a busca acha a conversa pelo que foi dito dentro dela — mas ao abrir,
--  a conversa começa no fim, como qualquer outra. Se a palavra estava numa
--  mensagem de três meses atrás, a pessoa achou a conversa e ainda tem de
--  procurar dentro dela, rolando. No WhatsApp não é assim: clicar no resultado
--  leva à mensagem.
--
--  Para o painel poder fazer isso ele precisa saber QUAL mensagem casou, e não
--  só o texto dela. São duas colunas a mais no que a função devolve: o id da
--  mensagem (para achá-la na tela e destacá-la) e o horário dela (para o painel
--  carregar o pedaço certo do histórico em vez do fim).
--
--  Roda depois de `2026-08-busca-de-verdade.sql`. Seguro rodar de novo.
--
--  UM AVISO: como o formato do que a função devolve muda, ela precisa ser
--  APAGADA antes de recriada — `create or replace` não muda tipo de retorno.
--  Entre uma coisa e outra há uma fração de segundo em que a função não
--  existe. Quem estiver digitando na busca exatamente nesse instante cai no
--  caminho antigo até recarregar a página (a busca continua funcionando, só
--  sem o "ir para a mensagem"). Recarregar resolve.
-- ============================================================

set search_path = public, extensions;

drop function if exists buscar_conversas(uuid, text, int);

create or replace function buscar_conversas(
  p_advogado uuid,
  p_termo    text,
  p_limite   int default 80
)
returns table (
  id               uuid,
  motivo           text,        -- 'nome' | 'numero' | 'mensagem'
  trecho           text,        -- a mensagem que casou, quando foi por mensagem
  ultima_atividade timestamptz,
  mensagem_id      text,        -- QUAL mensagem casou (texto, para não depender
                                -- do tipo da chave em cada instalação)
  mensagem_em      timestamptz  -- e quando ela foi escrita
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with alvo as (
    select zorvin_sem_acento(p_termo) as termo,
           regexp_replace(coalesce(p_termo, ''), '\D', '', 'g') as digitos
  ),
  por_nome as (
    select c.id, 'nome'::text as motivo, null::text as trecho, c.ultima_atividade,
           null::text as mensagem_id, null::timestamptz as mensagem_em
      from conversas c
      join contatos ct on ct.id = c.contato_id
     cross join alvo a
     where c.advogado_id = p_advogado
       and length(a.termo) >= 3
       and ct.busca like '%' || a.termo || '%'
  ),
  por_numero as (
    select c.id, 'numero'::text, null::text, c.ultima_atividade,
           null::text, null::timestamptz
      from conversas c
      join contatos ct on ct.id = c.contato_id
     cross join alvo a
     where c.advogado_id = p_advogado
       and length(a.digitos) >= 4
       and ct.numero like '%' || a.digitos || '%'
  ),
  -- O teto é de MENSAGENS deste telefone, e não do escritório: uma palavra
  -- comum enche estas cinco mil com conversa DAQUI, que é o que se procurava.
  casadas as (
    select m.id as msg_id, m.conversa_id, m.texto, m.criado_em
      from mensagens m
      join conversas c on c.id = m.conversa_id
     cross join alvo a
     where c.advogado_id = p_advogado
       and length(a.termo) >= 3
       and zorvin_sem_acento(m.texto) like '%' || a.termo || '%'
     limit 5000
  ),
  -- A MAIS RECENTE de cada conversa. É a que a pessoa provavelmente procura:
  -- quem lembra de uma palavra dita numa conversa está pensando na última vez
  -- em que ela foi dita, e não na primeira.
  por_mensagem as (
    select distinct on (k.conversa_id)
           k.conversa_id as id, 'mensagem'::text as motivo, k.texto as trecho,
           c.ultima_atividade, k.msg_id::text as mensagem_id, k.criado_em as mensagem_em
      from casadas k
      join conversas c on c.id = k.conversa_id
     order by k.conversa_id, k.criado_em desc
  ),
  tudo as (
    select * from por_nome
    union all select * from por_numero
    union all select * from por_mensagem
  ),
  -- Uma conversa pode casar de dois jeitos. Vale o motivo mais direto: o nome
  -- explica melhor do que um trecho de mensagem por que ela apareceu.
  melhor as (
    select id, motivo, trecho, ultima_atividade, mensagem_id, mensagem_em,
           row_number() over (
             partition by id
             order by case motivo when 'nome' then 1 when 'numero' then 2 else 3 end
           ) as posicao
      from tudo
  )
  select id, motivo, trecho, ultima_atividade, mensagem_id, mensagem_em
    from melhor
   where posicao = 1
   order by ultima_atividade desc nulls last
   limit greatest(p_limite, 1);
$$;

comment on function buscar_conversas(uuid, text, int) is
  'A busca da lista de conversas: por nome (sem acento), por número e pelo que '
  'foi dito dentro da conversa. Devolve também QUAL mensagem casou, para a tela '
  'poder abrir a conversa já nela. Recortada no telefone e nas regras de '
  'visibilidade de quem chama.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function buscar_conversas(uuid, text, int) to authenticated';
  end if;
end $$;


-- ------------------------------------------------------------
--  CONFERÊNCIA — rode e leia
-- ------------------------------------------------------------
select 'a função existe'                as item,
       to_regprocedure('public.buscar_conversas(uuid,text,int)') is not null as ok
union all
select 'ela devolve a mensagem que casou',
       exists (select 1 from information_schema.routines r
                join information_schema.parameters p
                  on p.specific_name = r.specific_name
               where r.routine_name = 'buscar_conversas'
                 and p.parameter_name = 'mensagem_id');
