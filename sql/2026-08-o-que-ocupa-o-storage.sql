-- ============================================================
--  O QUE ESTÁ OCUPANDO O STORAGE
--
--  O plano gratuito do Supabase dá 1 GB de arquivos, e o Zorvin está perto do
--  teto. Antes de decidir para onde mudar, é preciso saber o que há lá dentro —
--  mudar 1 GB de lugar é trabalho, e pode ser que boa parte dele nem precise
--  existir.
--
--  ESTE SCRIPT NÃO APAGA NADA. Ele só lê e conta. Rode, leia as cinco
--  respostas, e me mande o resultado.
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


-- ------------------------------------------------------------
--  1. O TOTAL, E QUANTO FALTA PARA O TETO
-- ------------------------------------------------------------
select
  count(*)                                                          as arquivos,
  pg_size_pretty(sum((o.metadata->>'size')::bigint))                as ocupado,
  -- O `::numeric` não é enfeite: `1024^3` devolve ponto flutuante, e não
  -- existe `round(ponto flutuante, casas)` no Postgres. Sem o molde, esta
  -- consulta falha — e no editor do Supabase, que roda tudo numa transação
  -- só, ela derrubaria as outras cinco junto.
  round((100.0 * sum((o.metadata->>'size')::bigint) / 1073741824)::numeric, 1)
                                                                    as por_cento_de_1gb
from storage.objects o
where o.bucket_id = 'anexos';


-- ------------------------------------------------------------
--  2. QUEM OCUPA O QUÊ — por morador do balde
--
--  É esta resposta que diz onde vale mexer. Se 90% for `recebidos/`, mudar o
--  destino das mídias recebidas resolve; se for o que a equipe envia, o
--  caminho é outro.
-- ------------------------------------------------------------
select
  case
    when o.name like 'recebidos/%' then 'recebidos (dos contatos)'
    when o.name like 'perfil/%'    then 'perfil (fotos da equipe)'
    else 'enviados pelo painel'
  end                                                as morador,
  count(*)                                           as arquivos,
  pg_size_pretty(sum((o.metadata->>'size')::bigint)) as ocupado
from storage.objects o
where o.bucket_id = 'anexos'
group by 1
order by sum((o.metadata->>'size')::bigint) desc;


-- ------------------------------------------------------------
--  3. POR MÊS — para saber o ritmo, e se uma regra de idade resolveria
--
--  Duas leituras importam aqui: quanto entra por mês (daqui a quantos meses o
--  teto volta a apertar, mesmo depois de limpar) e quanto está velho o
--  bastante para uma regra de guarda.
-- ------------------------------------------------------------
select
  to_char(date_trunc('month', o.created_at), 'YYYY-MM')  as mes,
  count(*)                                              as arquivos,
  pg_size_pretty(sum((o.metadata->>'size')::bigint))     as ocupado
from storage.objects o
where o.bucket_id = 'anexos'
group by 1
order by 1;


-- ------------------------------------------------------------
--  4. FOTOS DE PERFIL ABANDONADAS — desperdício certo, e seguro de apagar
--
--  Cada vez que alguém troca a foto, o painel sobe um arquivo NOVO
--  (`perfil/<id>-<carimbo>.jpg`) e nunca apaga o antigo. Só a última está
--  ligada a alguém; as outras não aparecem em lugar nenhum do sistema e
--  ninguém jamais vai abri-las.
--
--  A conta é exata: o nome do arquivo está no endereço guardado em
--  `usuarios.foto_url`, então "não citada por ninguém" é uma resposta e não um
--  palpite.
-- ------------------------------------------------------------
select
  count(*)                                           as fotos_abandonadas,
  pg_size_pretty(coalesce(sum((o.metadata->>'size')::bigint), 0)) as ocupado
from storage.objects o
where o.bucket_id = 'anexos'
  and o.name like 'perfil/%'
  and not exists (
    select 1 from usuarios u
     where u.foto_url is not null
       and u.foto_url like '%' || o.name
  );


-- ------------------------------------------------------------
--  5. MÍDIAS RECEBIDAS ÓRFÃS — arquivo sem bolha
--
--  `recebidos/<id-da-mensagem>.<ext>`: o nome do arquivo É o identificador da
--  mensagem na Uazapi. Se não existe mensagem com aquele identificador, aquele
--  arquivo não aparece em conversa nenhuma.
--
--  Costuma acontecer quando a gravação da mensagem falhou DEPOIS de o arquivo
--  já ter subido — o upload vem antes do insert.
-- ------------------------------------------------------------
with recebidos as (
  select o.name,
         (o.metadata->>'size')::bigint as tamanho,
         -- Tira "recebidos/" da frente e a extensão do fim.
         --
         -- O 11 é contado, e não chutado: "recebidos/" tem dez letras, então o
         -- identificador começa na décima primeira. Com 12 — que foi como isto
         -- nasceu — some a primeira letra do identificador, NENHUMA mensagem
         -- casa, e a consulta responde que está tudo órfão. Uma resposta
         -- redonda, convincente, e completamente errada: apagar por ela
         -- levaria embora todos os anexos do escritório.
         split_part(substring(o.name from 11), '.', 1) as id_da_mensagem
    from storage.objects o
   where o.bucket_id = 'anexos'
     and o.name like 'recebidos/%'
)
select
  count(*)                                        as arquivos_orfaos,
  pg_size_pretty(coalesce(sum(r.tamanho), 0))     as ocupado
from recebidos r
where not exists (
  select 1 from mensagens m where m.id_uazapi = r.id_da_mensagem
);


-- ------------------------------------------------------------
--  6. OS DEZ MAIORES — só para olhar
--
--  Um vídeo de 40 MB pesa como quatrocentas fotos. Vale saber se o problema é
--  volume ou se são poucos arquivos grandes.
-- ------------------------------------------------------------
select
  o.name,
  pg_size_pretty((o.metadata->>'size')::bigint) as tamanho,
  o.metadata->>'mimetype'                        as tipo,
  o.created_at::date                             as entrou_em
from storage.objects o
where o.bucket_id = 'anexos'
order by (o.metadata->>'size')::bigint desc
limit 10;
