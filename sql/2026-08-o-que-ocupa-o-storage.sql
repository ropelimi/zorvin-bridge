-- ============================================================
--  O QUE ESTÁ OCUPANDO O STORAGE
--
--  O plano gratuito do Supabase dava 1 GB de arquivos, e o Zorvin tinha passado
--  dele (1125 MB, 109,9% do teto). O projeto foi então transferido para a
--  organização Pro — a mesma do Vantoro —, e o teto passou a ser 100 GB. Nada
--  se moveu: transferir preserva a URL, as chaves, o banco e o balde inteiro.
--
--  O TETO ESTÁ NUMA LINHA SÓ, logo abaixo, porque ele já mudou uma vez e vai
--  mudar de novo. Espalhado por seis lugares, a próxima mudança deixa metade
--  das respostas medindo contra um limite que não existe mais — e uma medição
--  errada assusta ou tranquiliza na hora errada, que é o pior dos dois mundos.
--
--  ESTE SCRIPT NÃO APAGA NADA. Ele só lê e conta.
--
--  UMA CONSULTA SÓ, E É DE PROPÓSITO.
--
--  A primeira versão disto eram seis `select` seguidos, um para cada pergunta.
--  Funcionava em qualquer terminal — e no editor do Supabase entregava UM
--  SEXTO do que prometia, porque ele mostra apenas o resultado da ÚLTIMA
--  consulta do arquivo. Quem rodou recebeu a lista dos dez maiores e mais
--  nada, e concluiu, com razão, que faltava script.
--
--  Então tudo virou uma resposta só, com uma linha por pergunta. Não é
--  capricho de formatação: é o script cabendo na ferramenta onde ele vai ser
--  usado, que é onde ele vale alguma coisa.
--
--  O balde é um só (`anexos`) e tem três moradores:
--
--    recebidos/     o que os contatos mandaram (a ponte grava)
--    perfil/        as fotos de perfil da equipe (o painel grava)
--    <id-conversa>/ o que a equipe mandou pelo painel
--
--  Rodar no SQL Editor do Supabase do ZORVIN.
-- ============================================================

set search_path = public;

with teto as (
  -- 100 GB, que é o que o plano Pro dá. Era 1 (o gratuito) até 20/08/2026.
  select 100::bigint as gigabytes
),

arquivos as (
  select o.name,
         (o.metadata->>'size')::bigint as tamanho,
         o.metadata->>'mimetype'       as tipo,
         o.created_at,
         case
           when o.name like 'recebidos/%' then 'recebidos (dos contatos)'
           when o.name like 'perfil/%'    then 'perfil (fotos da equipe)'
           else 'enviados pelo painel'
         end as morador,
         -- "recebidos/" tem DEZ letras, então o identificador começa na
         -- décima primeira. Com 12 — que foi como isto nasceu — some a
         -- primeira letra, nenhuma mensagem casa, e a conta dos órfãos
         -- responde que está tudo órfão: uma resposta redonda, convincente e
         -- completamente errada. Apagar por ela levaria embora todos os
         -- anexos do escritório.
         split_part(substring(o.name from 11), '.', 1) as id_da_mensagem
    from storage.objects o
   where o.bucket_id = 'anexos'
),

-- 1. O TOTAL, E QUANTO DO TETO
total as (
  select 1 as ordem, 'TOTAL' as o_que,
         -- `count(a.name)`, e não `count(*)`: a junção abaixo é pela ESQUERDA,
         -- de propósito, para o TOTAL existir mesmo com o balde vazio. Com
         -- `count(*)` esse caso responderia "1 arquivo", que é o próprio teto
         -- sendo contado como se fosse um anexo.
         count(a.name) as quantos,
         coalesce(sum(a.tamanho), 0) as bytes,
         -- O `::numeric` não é enfeite: `1024^3` devolve ponto flutuante, e
         -- não existe `round(ponto flutuante, casas)` no Postgres.
         round((100.0 * coalesce(sum(a.tamanho), 0)
                / (t.gigabytes * 1073741824))::numeric, 2)::text
           || '% do teto de ' || t.gigabytes || ' GB' as detalhe
    from teto t left join arquivos a on true
   group by t.gigabytes
),

-- 2. QUEM OCUPA O QUÊ. É esta resposta que diz onde vale mexer.
por_morador as (
  select 2 as ordem, morador as o_que, count(*) as quantos,
         sum(tamanho) as bytes, '' as detalhe
    from arquivos group by morador
),

-- 3. POR MÊS — o ritmo. Diz se uma limpeza compra meses ou semanas.
por_mes as (
  select 3 as ordem,
         'entrou em ' || to_char(date_trunc('month', created_at), 'YYYY-MM') as o_que,
         count(*) as quantos, sum(tamanho) as bytes, '' as detalhe
    from arquivos group by date_trunc('month', created_at)
),

-- 4. FOTOS DE PERFIL ABANDONADAS — desperdício certo, e seguro de apagar.
--
--    Cada troca de foto sobe um arquivo NOVO e nunca apaga o antigo. Só a
--    última está ligada a alguém; as outras não aparecem em lugar nenhum.
perfil_morto as (
  select 4 as ordem, 'fotos de perfil abandonadas' as o_que,
         count(*) as quantos, coalesce(sum(a.tamanho), 0) as bytes,
         'dá para apagar' as detalhe
    from arquivos a
   where a.morador = 'perfil (fotos da equipe)'
     and not exists (select 1 from usuarios u
                      where u.foto_url is not null and u.foto_url like '%' || a.name)
),

-- 5. MÍDIAS RECEBIDAS ÓRFÃS — arquivo sem bolha.
--
--    O nome do arquivo É o identificador da mensagem na Uazapi. Sem mensagem
--    com aquele identificador, o arquivo não aparece em conversa nenhuma.
--    Costuma ser gravação que falhou DEPOIS de o arquivo já ter subido.
orfaos as (
  select 5 as ordem, 'mídias recebidas órfãs' as o_que,
         count(*) as quantos, coalesce(sum(a.tamanho), 0) as bytes,
         'dá para apagar' as detalhe
    from arquivos a
   where a.morador = 'recebidos (dos contatos)'
     and not exists (select 1 from mensagens m where m.id_uazapi = a.id_da_mensagem)
),

-- 6. OS DEZ MAIORES — para separar "muito arquivo" de "poucos e grandes".
maiores as (
  select 6 as ordem, name as o_que, 1 as quantos, tamanho as bytes,
         coalesce(tipo, '') || ' · ' || created_at::date as detalhe
    from arquivos order by tamanho desc limit 10
)

select o_que, quantos, pg_size_pretty(bytes) as ocupado, detalhe
  from (
    select * from total
    union all select * from por_morador
    union all select * from por_mes
    union all select * from perfil_morto
    union all select * from orfaos
    union all select * from maiores
  ) tudo
 order by ordem, bytes desc;
