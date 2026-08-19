-- ============================================================
--  QUANTO TEMPO TEM O ÁUDIO
--
--  Na lista de conversas, um áudio recebido aparecia como "🎤 Mensagem de voz".
--  No WhatsApp aparece "🎤 Mensagem de voz (1:19)" — e o tempo não é enfeite:
--  é o que separa um "ok" de dez segundos de um relato de três minutos, na
--  hora de decidir o que ouvir primeiro.
--
--  Uma coluna, e nada mais. Vale para áudio e para vídeo.
--
--  O QUE ACONTECE COM O QUE JÁ ESTÁ GRAVADO: nada. A duração passa a ser
--  guardada a partir das mensagens que chegarem DEPOIS deste script; as
--  antigas ficam sem o tempo, e o rótulo delas continua "🎤 Mensagem de voz".
--  Não dá para descobrir a duração de um áudio antigo sem baixar o arquivo de
--  cada um deles, e mil downloads para um número entre parênteses não paga.
--
--  E SE ESTE SCRIPT NÃO FOR RODADO: também nada quebra. A ponte tenta gravar
--  com a duração, o banco recusa a coluna que não existe, e ela regrava sem —
--  a mensagem entra igual. O painel faz o mesmo do lado dele: pede a coluna,
--  não recebe, e mostra o rótulo sem o tempo.
--
--  Rodar no SQL Editor do Supabase.
-- ============================================================

set search_path = public;

alter table mensagens
  add column if not exists midia_segundos integer;

comment on column mensagens.midia_segundos is
  'Duração em segundos de áudio/vídeo, quando a Uazapi informa. Nulo nas '
  'mensagens anteriores a 19/08/2026 e sempre que a origem não disser.';


-- ------------------------------------------------------------
--  CONFERÊNCIA — rode depois de receber um áudio novo.
--
--  Antes de chegar o primeiro áudio, isto vem vazio, e está certo. Depois de
--  um, tem de aparecer uma linha com o tempo preenchido.
-- ------------------------------------------------------------
select tipo,
       count(*)                                   as quantas,
       count(midia_segundos)                      as com_tempo,
       max(midia_segundos)                        as maior_em_segundos
  from mensagens
 where tipo in ('audio', 'video')
 group by tipo
 order by tipo;
