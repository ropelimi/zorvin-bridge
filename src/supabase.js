// Conexão com o Supabase do Zorvin.
// As duas chaves vêm das "variáveis de ambiente" configuradas no Render.
// Aqui usamos a chave "anon" (pública) — é segura para o navegador.
import { createClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

export const supabase = createClient(url, anonKey);
