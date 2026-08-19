-- ============================================================
--  O FILTRO DE ATENDENTE EM TODO TELEFONE
--
--  O relato: "existem alguns telefones em que não apareceu essa opção de
--  filtrar". Não era o mesmo defeito nos dois lados, eram dois:
--
--  1. A TELA só mostrava o botão quando a lista tinha mais de um nome. Num
--     número atendido por uma pessoa só, o filtro sumia. (Corrigido no painel.)
--
--  2. A LISTA saía vazia em telefone cujo histórico é anterior à coluna
--     `mensagens.enviado_por_id`. A função só olhava quem tinha id; nesses
--     números TODA mensagem tem só o nome de quem escreveu, então ninguém
--     tinha id, então a lista vinha vazia — e a tela, obedecendo à regra
--     acima, escondia o botão. É este arquivo.
--
--  A `conversas_por_atendente` já casava pelo nome no histórico antigo; a
--  `atendentes_do_telefone`, que monta a lista de quem escolher, não. Ou seja:
--  o filtro sabia responder por gente que ele nunca oferecia.
--
--  E MAIS UMA COISA: quem está logado entra sempre na lista, mesmo com zero
--  conversas neste número. "Quais conversas eu participei" é a pergunta que dá
--  origem ao recurso — ela precisa ter resposta em todo telefone, inclusive
--  quando a resposta é "nenhuma". Sumir não é responder.
--
--  Depende de `zorvin_sem_acento` (SQL da busca) e dos índices do SQL do filtro
--  por atendente, ambos já rodados. Seguro rodar de novo.
-- ============================================================

set search_path = public;

create or replace function atendentes_do_telefone(p_advogado uuid)
returns table (id uuid, nome text, conversas bigint)
language sql
stable
security invoker
set search_path = public
as $$
  with faladas as (
    -- Quem assinou com id.
    select m.enviado_por_id as quem, m.enviado_por as nome_bruto, m.conversa_id
      from mensagens m
      join conversas c on c.id = m.conversa_id
     where c.advogado_id = p_advogado
       and m.enviado_por_id is not null
    union all
    -- E O HISTÓRICO ANTERIOR À COLUNA, casado pelo nome. É a metade que
    -- faltava: em telefone antigo ela é a única que traz alguma coisa.
    --
    -- `enviado_por is not null` repete a condição do índice parcial de
    -- propósito — sem essa linha o Postgres não consegue provar que as linhas
    -- procuradas cabem no índice e volta a ler `mensagens` inteira.
    select u.id, m.enviado_por, m.conversa_id
      from mensagens m
      join conversas c on c.id = m.conversa_id
      join usuarios  u on zorvin_sem_acento(u.nome) = zorvin_sem_acento(m.enviado_por)
     where c.advogado_id = p_advogado
       and m.enviado_por_id is null
       and m.enviado_por is not null
  ),
  contagem as (
    select f.quem,
           max(f.nome_bruto)              as nome_bruto,
           count(distinct f.conversa_id)  as conversas
      from faladas f
     group by f.quem
  ),
  -- QUEM ESTÁ LOGADO ENTRA SEMPRE, com zero se for o caso. `union` e não
  -- `union all`: se a pessoa já falou aqui, ela não pode aparecer duas vezes.
  todos as (
    select quem from contagem
    union
    select auth.uid() where auth.uid() is not null
  )
  select t.quem                                              as id,
         -- O nome de `usuarios` na frente, porque é o atual; o da mensagem
         -- atrás, para quem já saiu do escritório e não tem mais cadastro.
         coalesce(u.nome, k.nome_bruto, '(sem nome)')        as nome,
         coalesce(k.conversas, 0)                            as conversas
    from todos t
    left join contagem k on k.quem = t.quem
    left join usuarios u on u.id   = t.quem
   order by 3 desc, 2;
$$;

comment on function atendentes_do_telefone(uuid) is
  'Quem já escreveu alguma mensagem por este telefone, com quantas conversas '
  'cada um participou. Casa por id e, no histórico anterior à coluna '
  'enviado_por_id, pelo nome sem acento. Quem está logado entra sempre, ainda '
  'que com zero. É a lista que o filtro de atendentes oferece.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function atendentes_do_telefone(uuid) to authenticated';
  end if;
end $$;


-- ------------------------------------------------------------
--  CONFERÊNCIA — rode e leia
--
--  Troque o uuid pelo id de um telefone ANTIGO, desses em que o filtro não
--  aparecia. A lista tem que vir com nome. Antes vinha vazia.
-- ------------------------------------------------------------
-- select * from atendentes_do_telefone('cole-aqui-o-id-do-telefone'::uuid);

select 'a função existe' as item,
       to_regprocedure('public.atendentes_do_telefone(uuid)') is not null as ok
union all
select 'ela enxerga o histórico sem id',
       (select count(*) > 0
          from pg_proc
         where proname = 'atendentes_do_telefone'
           and prosrc like '%zorvin_sem_acento(m.enviado_por)%');
